"""Run only approved Stage A offline checks with network/process/DB fences."""
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import platform
import socket
import subprocess
import sys
import unittest
from unittest.mock import patch

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
sys.path[:0]=[str(ROOT/'supabase/tests'),str(ROOT)]
MODULES=(
 'stage8_stage_a_offline_test','claim_e2e_offline_test','claim_two_actor_offline_test',
 'donation_creation_interface_contract_test','persisted_donation_lifecycle_contract_test',
 'role_onboarding_contract_test','listing_eligibility_async_refresh_contract_test',
 'cancel_claim_audit_contract_test','claim_recovery_reconciliation_audit_contract_test',
 'claim_card_expiry_contract_test','stage8_reconciliation_proposal_static_test',
 'backend.routing.integration.tests.test_sql_package',
 'backend.routing.integration.tests.test_worker',
 'backend.routing.worker_service.tests.test_worker_flow')


def forbidden(*args,**kwargs):
    raise AssertionError('STAGE_A_OFFLINE_ONLY: connection or external process forbidden')


def main():
    results=[]
    # Cache OS metadata before the test fence. On Windows platform.machine()
    # otherwise invokes the read-only OS version probe during pandas import.
    environment=platform.platform()
    platform.uname()
    with patch.object(socket.socket,'connect',forbidden),patch.object(socket,'create_connection',forbidden), \
         patch.object(subprocess,'run',forbidden),patch.object(subprocess,'Popen',forbidden):
        import psycopg
        with patch.object(psycopg,'connect',forbidden):
            for module in MODULES:
                output=io.StringIO()
                result=unittest.TextTestRunner(stream=output,verbosity=1).run(
                    unittest.defaultTestLoader.loadTestsFromName(module))
                row=dict(module=module,tests=result.testsRun,failures=len(result.failures),
                         errors=len(result.errors),skipped=len(result.skipped),output=output.getvalue())
                results.append(row)
                print(f"{module}: {row['tests']} tests, {row['failures']} failures, {row['errors']} errors, {row['skipped']} skips",flush=True)
    totals={key:sum(row[key] for row in results) for key in ('tests','failures','errors','skipped')}
    evidence=dict(recorded_at=datetime.now(timezone.utc).isoformat(),
        scope='STAGE_A_OFFLINE_SOURCE_AND_IN_MEMORY_TESTS_ONLY',python=sys.version,platform=environment,
        sql_executed=False,network_permitted=False,subprocesses_permitted=False,
        runtime_postgresql_validation='UNVERIFIED_NOT_EXECUTED',supabase_connections=0,
        new_forward_migrations=json.loads((HERE/'package-manifest.json').read_text())['files'],
        runner_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),totals=totals,results=results)
    (HERE/'offline-results.json').write_text(json.dumps(evidence,indent=2)+'\n',encoding='utf-8')
    print('TOTAL '+json.dumps(totals))
    return int(bool(totals['failures'] or totals['errors'] or totals['skipped']))


if __name__=='__main__':
    raise SystemExit(main())
