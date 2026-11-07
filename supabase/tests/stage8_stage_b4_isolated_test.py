"""Stage B.4 pickup/recovery races in a NEW disposable loopback PostgreSQL.

Reuses the current captured lifecycle fixtures and PostgreSQL setup from the
automatic recovery harness. Auth, road eligibility and cron remain explicit
test doubles; this is not a Supabase gateway or deployment test.
"""
import argparse
from pathlib import Path
import os
import re
import shutil
import unittest

import claim_recovery_automatic_isolated_test as recovery


class StageB4RaceTests(recovery.AutomaticRecoveryTests):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        # The parent fixture predates the latest audit-context migration. Add
        # only its audit columns and install the exact current lifecycle bodies
        # in the newly created disposable cluster.
        cls.query("ALTER TABLE public.audit_events ADD COLUMN IF NOT EXISTS donation_id uuid; "
                  "ALTER TABLE public.audit_events ADD COLUMN IF NOT EXISTS listing_id uuid;")
        source = (recovery.ROOT / 'supabase/migrations/20261031_claim_audit_and_failure_capture.sql').read_text(encoding='utf-8')
        lifecycle = source
        transition = re.search(
            r'CREATE OR REPLACE FUNCTION public\.geolock_transition_listing_donations'
            r'\(.*?\bAS\s+(\$\w*\$).*?\1\s*;', lifecycle, re.S | re.I,
        )
        if transition is None:
            raise AssertionError('Missing lifecycle donation transition function')
        cls.query(transition.group(0))
        for name in ('start_pickup', 'complete_pickup', 'recover_expired_claims'):
            match = re.search(
                r'CREATE OR REPLACE FUNCTION public\.' + name
                + r'\(.*?\bAS\s+(\$\w*\$).*?\1\s*;', source, re.S | re.I,
            )
            if match is None:
                raise AssertionError(f'Missing current function body: {name}')
            cls.query(match.group(0))

    def test_completion_commits_before_waiting_recovery(self):
        f = self.fixture()
        self.query(
            f"update public.claim_leases set expires_at=clock_timestamp()+"
            f"interval '500 milliseconds' where claim_id='{f['claim']}';"
        )
        self.ngo(f"select public.start_pickup('{f['claim']}')")
        sql = (f"begin; set local request.jwt.claim.sub='{recovery.OWNER}'; "
               f"select public.complete_pickup('{f['claim']}',true); "
               "select pg_sleep(2); commit;")
        with self.background(sql):
            import time
            time.sleep(.55)
            self.assertEqual(self.recover(), '0')

        state = self.state()
        self.assertEqual(state['claim'], 'COMPLETED')
        self.assertEqual(state['donations'], ['COLLECTED'])
        self.assertEqual(state['recovery_audits'], 0)

    def test_recovery_commits_before_waiting_completion(self):
        f = self.fixture()
        self.query(
            f"update public.claim_leases set expires_at=clock_timestamp()+"
            f"interval '1 minute' where claim_id='{f['claim']}';"
        )
        self.ngo(f"select public.start_pickup('{f['claim']}')")
        self.query(
            f"update public.claim_leases set expires_at=clock_timestamp()-"
            f"interval '1 minute' where claim_id='{f['claim']}';"
            "create or replace function public.b4_slow_reconciliation() "
            "returns trigger language plpgsql as $$ begin "
            "if new.lease_status='RECONCILIATION_REQUIRED' then "
            "perform pg_sleep(2); end if; return null; end $$; "
            "create trigger b4_slow_reconciliation after update on public.claim_leases "
            "for each row execute function public.b4_slow_reconciliation();"
        )
        try:
            with self.background('select public.recover_expired_claims(1);'):
                self.ngo(
                    f"select public.complete_pickup('{f['claim']}',true)",
                    expect_error='NOT_ACTIVE_CLAIM_HOLDER',
                )
        finally:
            self.query(
                "drop trigger if exists b4_slow_reconciliation on public.claim_leases; "
                "drop function if exists public.b4_slow_reconciliation();"
            )

        state = self.state()
        self.assertEqual(state['claim'], 'RECONCILIATION_REQUIRED')
        self.assertEqual(state['donations'], ['PICKUP_IN_PROGRESS'])
        self.assertEqual(state['recovery_audits'], 1)
        self.assertEqual(state['cases'], 1)


def load_tests(loader, tests, pattern):
    # Run only B.4 additions while keeping inherited fixture/setup methods.
    return unittest.TestSuite(
        StageB4RaceTests(name)
        for name in StageB4RaceTests.__dict__
        if name.startswith('test_')
    )


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-isolated', action='store_true')
    parser.add_argument('--pg-bin', type=Path, required=True)
    args = parser.parse_args()
    if not args.run_isolated:
        parser.error('--run-isolated required; no external connections supported')
    bins = {name: str(args.pg_bin / (name + ('.exe' if os.name == 'nt' else '')))
            for name in ('initdb', 'pg_ctl', 'psql')}
    if any(not Path(value).is_file() for value in bins.values()):
        parser.error('initdb, pg_ctl and psql required')
    StageB4RaceTests.bins = bins
    unittest.main(argv=[__file__], verbosity=2)
