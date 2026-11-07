"""Run existing custody/reconciliation cases on newly patched disposable clones."""
import json
import multiprocessing as mp
from pathlib import Path
import sys
import unittest
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'supabase/tests'))
import simplified_reconciliation_isolated_test as original

PATCH='docs/investigations/e2-shared-lock-review/proposed_migration.sql'

class SharedCustodyTests(original.CoordinationTests):
    def authorize(self):
        result=self.worker.plan_and_authorize(self.session,self.sid,self.request)
        self.lane.save('shared-fixture-authorization-'+str(self.request)+'.json',result)
        assert 'authorization' in result, result
        self.receipt=result['authorization'];self.rid=self.receipt['route_ids'][0]
        return result

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.lane.hashes[PATCH]=original.base.auto.assembly.digest(ROOT/PATCH)
        apply=cls.lane.apply
        def coordinated(relative):
            apply(relative)
            if relative==original.MIGRATION:
                # Match the primary fixture's explicit authenticated grant.
                # Both retain their existing default PUBLIC execute privilege;
                # authorization remains inside the unchanged function body.
                cls.lane.sql('GRANT EXECUTE ON FUNCTION public.claim_listing(uuid,uuid) TO authenticated;')
                # The legacy fixture deliberately doubles blank lines while
                # testing CRLF migration transport. Align format only after
                # proving every nonblank source line is exactly unchanged.
                alignment=[]
                for f in json.loads((ROOT/'docs/investigations/e2-shared-lock-review/caller-catalog.json').read_text()):
                    signature=f['signature'] if '.' in f['signature'] else 'public.'+f['signature']
                    actual=cls.lane.js("SELECT jsonb_build_object('source',prosrc,'hash',md5(replace(prosrc,chr(13),''))) FROM pg_proc WHERE oid='"+signature+"'::regprocedure")
                    if actual['hash']!=f['hash']:
                        nonblank=lambda value:[line for line in value.replace('\r','').splitlines() if line.strip()]
                        assert nonblank(actual['source'])==nonblank(f['source']), 'SUBSTANTIVE_FIXTURE_SOURCE_DRIFT: '+signature
                        alignment.append(dict(signature=signature,before=actual['hash'],after=f['hash'],change='blank lines only'))
                        cls.lane.sql(f['definition'])
                cls.lane.save('fixture-format-alignment-'+str(cls.lane.seq)+'.json',alignment)
                apply(PATCH)
        cls.lane.apply=coordinated

def main():
    SharedCustodyTests.runtime=ROOT/'.tmp/geolock-spatial-runtime-safe-cancel'
    names=['test_coord_01_started_false_false_and_checkpoint','test_coord_02_started_true_true_keeps_vehicle',
      'test_coord_03_mutual_review_rounds_and_old_receipts','test_coord_08_ownership_versions_and_receipt_payload',
      'test_coord_09_concurrent_matching_resolution_once','test_coord_13_recorded_collection_and_incidents_block_release',
      'test_coord_15_missing_lease_and_private_permit_denial','test_coord_17_checkpoint_racing_next_dispatch',
      'test_coord_20_source_window_expired_release_keeps_listing_closed','test_coord_21_route_incident_blocks_matching_no_handover',
      'test_coord_22_hub_matching_handover_completes_all_members']
    result=unittest.TextTestRunner(verbosity=2,failfast=True).run(unittest.TestSuite(SharedCustodyTests(n) for n in names))
    summary={'passed':result.wasSuccessful(),'tests':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'evidence':str(getattr(SharedCustodyTests,'out','')),'remote_connections':0}
    (ROOT/'docs/investigations/e2-shared-lock-review/custody-tests.json').write_text(json.dumps(summary,indent=2)+'\n')
    return not result.wasSuccessful()

if __name__=='__main__':mp.freeze_support();raise SystemExit(main())
