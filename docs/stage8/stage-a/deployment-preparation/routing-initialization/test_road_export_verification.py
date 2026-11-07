"""In-memory/local-source checks only. No connections, fixtures or seeded data."""
import csv
from decimal import Decimal
import json
import random
import struct
import time
import unittest

from road_export_contract import (ROOT,REFERENCE,NODES,EDGES,real_bits,ratio_round_even,
   coverage_reference,reference_check)
from verify_current_export import Checks,merge,numeric

class VerificationTests(unittest.TestCase):
    def test_exact_rounding_boundaries(self):
        self.assertEqual(real_bits('1.000000059604644775390625'),'3f800000')
        self.assertEqual(real_bits('1.000000178813934326171875'),'3f800002')
        self.assertEqual(real_bits('1.000000059604644775390625000000000001'),'3f800001')
        self.assertEqual(real_bits('1.000000059604644775390624999999999999'),'3f800000')

    def test_normal_import_range_against_independent_float_conversion(self):
        rng=random.Random(20261027)
        for _ in range(5000):
            text=str(Decimal(rng.randint(1,1_000_000))/Decimal(100000))
            self.assertEqual(real_bits(text),struct.pack('!f',float(text)).hex())

    def test_nonpositive_nonfinite_rejected(self):
        for text in ('0','-1','NaN','Infinity'):
            with self.assertRaises(AssertionError): real_bits(text)

    def test_merge_reports_directional_missing_and_extra(self):
        checks=Checks()
        result=list(merge(iter([((1,2),{'key':'expected'}),((2,3),{})]),
                          iter([((1,2),{'key':'actual'}),((3,2),{})]),checks,'edge'))
        self.assertEqual(checks.counts,{'edge_missing':1,'edge_unexpected':1})
        self.assertEqual(len(result),2)
        self.assertIsNone(result[1][0])

    def test_exact_precision_validator(self):
        self.assertEqual(numeric('0.000001',positive=True),Decimal('0.000001'))
        self.assertEqual(numeric('1.0000000',positive=True),Decimal('1'))
        for value in ('0.0000001','0','NaN'):
            with self.assertRaises(Exception): numeric(value,positive=True)

    def test_coverage_parser_matches_observed_database_wkb_hash(self):
        self.assertEqual(coverage_reference()['wkb_sha256'],
                         '4fbceda7f5d5c6196c484719d1c7b982a237b1f76d921e66cfecaf6adeb64361')

def reference_storage_scan():
    """New preparation check: entire input ordering and expected REAL projection.

    This never compares DEV rows and cannot produce a DEV-equivalence PASS.
    """
    start=time.monotonic(); hashes=reference_check(); nodes=edges=0; previous=0
    with (REFERENCE/'road_network_nodes.csv').open(newline='') as f:
        for row in csv.DictReader(f):
            node=int(row['osm_node_id']); assert node>previous; previous=node
            assert row['network_snapshot_id']=='OSM-OPS-20261018' and row['active_flag']=='true'
            nodes+=1
    previous=(0,0); rounding_nonzero={'road_km':0,'travel_minutes':0}; cache={}
    with (REFERENCE/'road_network_edges.csv').open(newline='') as f:
        for row in csv.DictReader(f):
            pair=(int(row['source_node']),int(row['target_node'])); assert pair>previous; previous=pair
            for name in rounding_nonzero:
                text=row[name]
                if text not in cache:
                    bits=real_bits(text); value=struct.unpack('!f',bytes.fromhex(bits))[0]
                    numeric(format(value,'.6g'),positive=True)
                    cache[text]=Decimal.from_float(value)!=Decimal(text)
                rounding_nonzero[name]+=int(cache[text])
            edges+=1
            if edges%65536==0 and time.monotonic()-start>90: raise TimeoutError('Reference scan budget exceeded')
    assert (nodes,edges)==(NODES,EDGES)
    return {'status':'REFERENCE PREPARATION PASS / NOT A DEV COMPARISON',
        'reference_hashes':hashes,'nodes_scanned':nodes,'edges_scanned':edges,
        'strict_unique_key_ordering':True,'expected_real_projection_precision':'PASS',
        'expected_nonzero_decimal_to_real_conversion_counts':rounding_nonzero,
        'distinct_cost_strings_checked':len(cache),'elapsed_seconds':round(time.monotonic()-start,3),
        'current_dev_export_compared':False}

if __name__=='__main__':
    result=unittest.TextTestRunner(verbosity=1).run(unittest.defaultTestLoader.loadTestsFromTestCase(VerificationTests))
    if not result.wasSuccessful(): raise SystemExit(1)
    report=reference_storage_scan()
    path=ROOT/'results/routing-initialization-preparation/reference-storage-check.json'
    path.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report,indent=2))
