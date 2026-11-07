"""Read-only artifact and launcher guard checks; no solve/DB startup."""
import csv,hashlib,json,subprocess,sys,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
E2=ROOT/'experiments/e2_atomic_claiming/results/e2-20261105-v33-actual-01'
E4=ROOT/'experiments/e4_post_claim_routing/results/e4-20261105-v33-actual-02'
def read(p):return json.loads(p.read_text())
def csv_rows(p):
    with p.open(encoding='utf-8-sig',newline='') as f:return list(csv.DictReader(f))

class ArtifactChecks(unittest.TestCase):
    def test_exact_manifest_csv_bytes_and_originals_unchanged(self):
        m=read(ROOT/'benchmark dataset/dataset/generation_manifest.json')
        for name,expected in m['generated_csv_sha256'].items():
            p=ROOT/'experiments/repro_inputs/v33'/(name+'.csv')
            self.assertEqual(hashlib.sha256(p.read_bytes()).hexdigest(),expected)
            original=(ROOT/'benchmark dataset/dataset'/(name+'.csv')).read_bytes()
            self.assertEqual(p.read_bytes().replace(b'\r\n',b'\n'),original.replace(b'\r\n',b'\n'))
    def test_all_e4_methods_share_exact_input_hashes(self):
        rr=csv_rows(E4/'results_per_scenario.csv');self.assertEqual(len(rr),300)
        for sid in {r['scenario_id'] for r in rr}:
            group=[r for r in rr if r['scenario_id']==sid]
            self.assertEqual({r['method'] for r in group},{'nearest_next','fcfs','proposed'})
            self.assertEqual(len({r['frozen_sha256'] for r in group}),1)
            self.assertEqual(len({r['valid_tasks'] for r in group}),1)
        self.assertEqual(read(E4/'verification.json')['saved_routes_independently_revalidated'],300)
    def test_e2_complete_current_functions_and_committed_owner_evidence(self):
        self.assertEqual(read(E2/'completion.json')['completed_proposed'],275)
        self.assertTrue(read(E2/'cluster-stop.json')['stopped'])
        m=read(E2/'manifest.json');self.assertTrue(m['function_sources_unchanged'])
        funcs=m['function_catalog']['e2_proposed']
        self.assertEqual(funcs['claim_listing(uuid,uuid)']['md5'],'2c1f60c876797c61b44b3cb43591bab8')
        self.assertEqual(funcs['recover_expired_claims(integer)']['md5'],'05fe46d8b76085f71c87fcc5f6520775')
        actual=read(E2/'proposed_committed_states.json');self.assertEqual(len(actual),275)
        self.assertTrue(all(r['active_owner_count']==1 for r in actual))
    def test_e2_generic_errors_have_sqlstate_evidence(self):
        requests=read(E2/'proposed_requests.json')
        errors=[r for r in requests if r['outcome']=='ERROR']
        audit=csv_rows(E2/'database_errors.csv')
        self.assertEqual(len(errors),len(audit))
        self.assertEqual({str(r['request_uuid']) for r in errors},{r['request_id'] for r in audit})
        self.assertTrue(all(r['sqlstate'] and r['rollback_confirmed']=='true' for r in audit))
    def test_invalid_run_id_rejected_before_execution(self):
        r=subprocess.run([sys.executable,str(ROOT/'experiments/run_repro_benchmarks.py'),'--experiment','E2','--run-id','../outside'],capture_output=True,text=True,timeout=20)
        self.assertNotEqual(r.returncode,0);self.assertIn('simple, unique',r.stderr)
    def test_existing_run_cannot_be_overwritten(self):
        before=hashlib.sha256((E4/'completion.json').read_bytes()).hexdigest()
        r=subprocess.run([sys.executable,str(ROOT/'experiments/run_repro_benchmarks.py'),'--experiment','E4','--run-id',E4.name],capture_output=True,text=True,timeout=20)
        self.assertNotEqual(r.returncode,0);self.assertIn('Output already exists',r.stderr)
        self.assertEqual(hashlib.sha256((E4/'completion.json').read_bytes()).hexdigest(),before)

if __name__=='__main__':unittest.main(verbosity=2)
