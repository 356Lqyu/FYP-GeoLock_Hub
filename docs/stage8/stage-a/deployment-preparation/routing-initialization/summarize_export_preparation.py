"""Summarize actual partial evidence; never labels missing current export PASS."""
import json
import re
from road_export_contract import ROOT,HERE,reference_check,coverage_reference,real_bits,sha,POLICY_SHA,POLICY_REQUEST

path=ROOT/'results/routing-initialization-preparation'
reference_check()
raw=json.loads((path/'read-only-conversion-and-coverage.json').read_text())
envelope=json.loads(raw['content'][0]['text'])['result']
match=re.search(r'<untrusted-data-[^>]+>\s*(\[.*?\])\s*</untrusted-data-',envelope,re.S)
evidence=json.loads(match[1])[0]['evidence']
assert evidence['read_only']=='on'
conversions=evidence['conversions']
assert len(conversions)==7 and all(real_bits(r['decimal'])==r['real_hex'] for r in conversions)
expected=coverage_reference()
cov=evidence['coverage']
assert len(cov)==1
criteria={**expected,'network_snapshot_id':'OSM-OPS-20261018','dataset_kind':'OPERATIONAL',
          'active_flag':True,'node_count':926414,'edge_count':2145828,'max_snap_distance_m':500,
          'srid':4326,'dimensions':2,'valid_geometry':True,'geometry_type':'MULTIPOLYGON'}
assert all(cov[0].get(k)==v for k,v in criteria.items()) and cov[0]['approved_at']
completed=list((ROOT/'results/routing-current-export').glob('*/receipt.json'))
if completed:
    raise RuntimeError('Export directories exist: inspect their actual reports instead of regenerating a pending-export summary')
report={'verdict':'NOT VERIFIED / CURRENT DEV NODE-EDGE COMPARISON NOT RUN',
  'reason':'Secure local password-prompted export required; Codex did not read or request credentials',
  'current_dev_nodes_compared':0,'current_dev_edges_compared':0,'current_dev_mismatch_counts':None,
  'mismatch_note':'No zero-mismatch claim: current node/edge comparison has not occurred',
  'coverage_geometry_and_metadata':'PASS / PINNED IMPORT MATCH',
  'coverage_wkb_sha256':expected['wkb_sha256'],'sql_conversion_probes':'7/7 PASS',
  'small_readonly_query_observed_at_utc':evidence['observed_at'],
  'reference_storage_check':json.loads((path/'reference-storage-check.json').read_text()),
  'local_export_preparation':json.loads((path/'export-preparation.json').read_text())['status'],
  'policy_sha256':sha(HERE/'policy.proposed.json'),'policy_request_id':POLICY_REQUEST,
  'policy_unchanged':sha(HERE/'policy.proposed.json')==POLICY_SHA,
  'write_authorization':'NONE','database_writes':False,
  'remaining':['Run secure local export and complete offline comparison',
      'Review exact mismatch/progress/receipt and directed reachability results',
      'Owner policy business choices; exact write approval still absent',
      'Builder provenance, maintenance freeze and performance/runtime risks remain separate']}
(path/'export-equivalence-preparation.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
print(json.dumps({k:report[k] for k in ['verdict','coverage_geometry_and_metadata','sql_conversion_probes','policy_unchanged']},indent=2))
