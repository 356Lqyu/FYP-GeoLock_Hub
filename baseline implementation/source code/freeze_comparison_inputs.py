"""Freeze geographic E1 partitions and the configuration for future comparisons."""
import argparse
import csv
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import random


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dataset-dir', type=Path, default=root/'benchmark dataset'/'dataset')
    parser.add_argument('--output-dir', type=Path, default=root/'baseline implementation'/'comparison inputs')
    parser.add_argument('--seed', type=int, default=20260915)
    args = parser.parse_args()
    def read(name):
        with (args.dataset_dir/(name+'.csv')).open(encoding='utf-8-sig', newline='') as stream:
            return list(csv.DictReader(stream))
    donations = {r['donation_id']:r for r in read('donations')}
    scenarios = {r['scenario_id'] for r in read('scenarios') if r['scenario_type']=='HUB_RECOMMENDATION'}
    grouped = defaultdict(list)
    for r in read('scenario_members'):
        if r['scenario_id'] in scenarios and r['scenario_role']=='SOURCE_DONATION':
            d = donations[r['entity_id']]
            grouped[d['geographic_group_id']].append({'scenario_id':r['scenario_id'], 'donation_id':d['donation_id']})
    order = sorted(grouped)
    random.Random(args.seed).shuffle(order)
    fractions = {'train':.70, 'validation':.15, 'test':.15}
    counts = {k:0 for k in fractions}
    partitions = {k:[] for k in fractions}
    assignments = {}
    total = len(scenarios)
    for group in order:
        split = min(fractions, key=lambda k: (counts[k]/(total*fractions[k]), list(fractions).index(k)))
        assignments[group] = split
        counts[split] += len(grouped[group])
        partitions[split].extend(grouped[group])
    inputs = ['donations.csv','scenarios.csv','scenario_members.csv','donation_hub_candidates.csv','generation_manifest.json']
    manifest = dict(schema_version=1, seed=args.seed, fractions=fractions, policy='SEEDED_WHOLE_GEOGRAPHIC_GROUP_BALANCING',
                    target_scenario_counts={k:total*v for k,v in fractions.items()}, realized_scenario_counts=counts,
                    geographic_group_assignments=assignments, partitions=partitions,
                    input_sha256={n:hashlib.sha256((args.dataset_dir/n).read_bytes()).hexdigest() for n in inputs},
                    reference_scores_used_in_split=False)
    manifest['split_id'] = hashlib.sha256(json.dumps(manifest,sort_keys=True).encode()).hexdigest()
    args.output_dir.mkdir(parents=True,exist_ok=True)
    path = args.output_dir/'e1_split_manifest.json'
    if path.exists() and json.loads(path.read_text(encoding='utf-8'))!=manifest:
        raise ValueError('Existing split differs. Use a new output folder rather than replacing a frozen split.')
    path.write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
    for split, rows in partitions.items():
        with (args.output_dir/('e1_'+split+'_scenario_ids.csv')).open('w',encoding='utf-8',newline='') as stream:
            writer = csv.DictWriter(stream,fieldnames=['scenario_id','donation_id','geographic_group_id'])
            writer.writeheader()
            writer.writerows(dict(row, geographic_group_id=donations[row['donation_id']]['geographic_group_id'])
                             for row in sorted(rows,key=lambda r:r['scenario_id']))
    print(json.dumps({'split_id':manifest['split_id'],'realized_scenario_counts':counts},indent=2))


if __name__=='__main__':
    main()
