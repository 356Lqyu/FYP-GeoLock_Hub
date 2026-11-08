"""Offline guards for the targeted claim lock correction."""
import ast
import hashlib
from collections import Counter
from pathlib import Path
import re
import unittest
from experiments.repro_benchmark import DATA, module

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / 'supabase/migrations/20261109120000_fix_claim_listing_fk_lock_deadlock.sql'
CLAIM_SOURCE = ROOT / 'supabase/migrations/20261031_claim_audit_and_failure_capture.sql'
HELPER_SOURCE = ROOT / 'supabase/migrations/20261027_persisted_donation_lifecycle.sql'
REGRESSIONS = ROOT / 'experiments/e2_atomic_claiming/claim_lock_regressions.py'


def function_body(path: Path, name: str) -> str:
    source = path.read_text(encoding='utf-8')
    match = re.search(
        rf'CREATE(?: OR REPLACE)? FUNCTION public\.{name}\b.*?AS \$function\$(.*?)\$function\$;',
        source,
        re.IGNORECASE | re.DOTALL,
    )
    if not match:
        raise AssertionError(f'Function not found: {name}')
    return match.group(1).replace('\r', '')


class ClaimLockMigrationTests(unittest.TestCase):
    def test_only_reviewed_lock_sites_and_claim_reason_change(self):
        claim = function_body(CLAIM_SOURCE, 'claim_listing')
        helper = function_body(HELPER_SOURCE, 'geolock_lock_listing_donations')
        expected_claim = claim.replace(
            'select * into v_l from public.listings where listing_id=p_listing for update;',
            'select * into v_l from public.listings where listing_id=p_listing for no key update;',
        ).replace(
            "elsif v_l.listing_status<>'AVAILABLE' then v_reason:='CLAIM_CONFLICT';",
            "elsif v_l.listing_status='CLAIMED' then v_reason:='ALREADY_CLAIMED';\n"
            "  elsif v_l.listing_status<>'AVAILABLE' then v_reason:='CLAIM_CONFLICT';",
        )
        expected_helper = helper.replace(
            'where listing_id=p_listing for update;',
            'where listing_id=p_listing for no key update;',
        )
        self.assertEqual(claim.count('where listing_id=p_listing for update;'), 1)
        self.assertEqual(helper.count('where listing_id=p_listing for update;'), 1)
        self.assertEqual(hashlib.md5(claim.encode()).hexdigest(), '2c1f60c876797c61b44b3cb43591bab8')
        self.assertEqual(hashlib.md5(expected_claim.encode()).hexdigest(), '0e1954dc17a5d30b81c57a161d99faac')
        self.assertEqual(hashlib.md5(expected_helper.encode()).hexdigest(), 'e97a3fd80673a827465f3eaa79b65903')
        self.assertIn('where request_id=p_request for update;', expected_claim)
        self.assertIn('from public.donations where donation_id=v_l.donation_id for update;', expected_helper)
        self.assertIn('from public.hub_batches where batch_id=v_l.batch_id for update;', expected_helper)
        self.assertIn('for update;', expected_helper)

    def test_migration_is_guarded_and_does_not_write_custody_rows(self):
        sql = MIGRATION.read_text(encoding='utf-8').lower()
        self.assertIn("md5(claim_body) is distinct from '2c1f60c876797c61b44b3cb43591bab8'", sql)
        self.assertIn("md5(helper_body) is distinct from '90816e7c6db3606dc8b6451a899d8036'", sql)
        self.assertIn("claim_before->>'security_definer' is distinct from 'true'", sql)
        self.assertIn("helper_before->>'security_definer' is distinct from 'false'", sql)
        self.assertIn('claim_after is distinct from claim_before', sql)
        self.assertIn('helper_after is distinct from helper_before', sql)
        self.assertIn('execute replace(replace(claim_def, claim_old, claim_new), claimed_old, claimed_new)', sql)
        self.assertIn('execute replace(helper_def, helper_old, helper_new)', sql)
        for table in ('donations', 'donation_claims', 'claim_leases', 'pickup_tasks', 'audit_events', 'claim_reconciliation_cases'):
            self.assertNotRegex(sql, rf'\b(?:insert\s+into|update|delete\s+from)\s+(?:public\.)?{table}\b')

    def test_database_regression_suite_covers_required_cases(self):
        suite = REGRESSIONS.read_text(encoding='utf-8')
        for requirement in (
            'for n in (2,5,10)',
            'distinct authenticated NGO identities',
            'add_synthetic_eligible_ngo',
            'synthetic_eligible_actors',
            'benchmark_inputs_modified',
            'same UUID replay',
            'LOCAL_FAULT_INJECTION',
            'manual same UUID retry',
            'recovery/release and claim',
            'active lease remains protected',
            'rollback receipt',
            'SET LOCAL ROLE authenticated',
            "mutation['sqlstate']=='42501'",
            'receipt_value_before',
            'receipt_value_after',
            'application_role_denied',
        ):
            self.assertIn(requirement, suite)

    def test_validator_connect_calls_match_captured_database_helper(self):
        tree = ast.parse(REGRESSIONS.read_text(encoding='utf-8'))
        validate = next(
            node for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name == 'validate'
        )
        connect = next(
            node for node in validate.body
            if isinstance(node, ast.FunctionDef) and node.name == 'connect'
        )
        self.assertEqual(connect.args.args, [])
        self.assertEqual(connect.args.kwonlyargs, [])
        bad_calls = [
            node for node in ast.walk(validate)
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == 'connect'
            and node.args
        ]
        self.assertEqual(bad_calls, [], 'connect() captures db settings; calls take keyword options only')

    def test_frozen_e2_levels_are_requests_and_cycle_scenario_ngo_ids(self):
        baseline = module('protected_claim_without_lease_recovery')
        bench = baseline.Benchmark(DATA)
        distributions = {2: Counter(), 5: Counter(), 10: Counter()}
        for scenario in bench.select(('CLAIM_COORDINATION',)):
            request_count = baseline.worker_count(scenario['scenario_id'], None)
            ngo_ids = bench.ids(
                scenario['scenario_id'], 'NGO', 'POTENTIAL_REQUESTER_UNASSESSED'
            )
            assignments = [ngo_ids[i % len(ngo_ids)] for i in range(request_count)]
            distributions[request_count][len(set(assignments))] += 1
        self.assertEqual(distributions[2], Counter({2: 50}))
        self.assertEqual(distributions[5], Counter({4: 26, 3: 18, 2: 6}))
        self.assertEqual(distributions[10], Counter({4: 34, 3: 10, 2: 6}))


if __name__ == '__main__':
    unittest.main()
