# Logic copied from "baseline implementation/source code/random_hub_baseline.py". Only the paths changed and parts not used here were removed.
"""E1 baseline 2: Random Hub.

Shuffles the same feasible hubs with a fixed seed per scenario, so distance and scores play no
part. This file only writes the baseline's rankings; the comparison is done in experiment_result.
"""
import argparse
import csv
import hashlib
import json
import random
import math
from collections import defaultdict
from datetime import datetime
from pathlib import Path
import sys

FOLDER = "2_random_hub"
TITLE = "Random Hub (baseline 2)"
METHOD = "random"
HARD_RULES = ("item_compatible_flag", "capacity_feasible_flag", "operating_feasible_flag", "active_feasible_flag", "route_available_flag")
TABLES = ("donations", "donors", "hubs", "donation_hub_candidates",
          "road_distance_matrix", "scenarios", "scenario_members")


def read_table(directory, name):
    """Read one benchmark table."""
    with (directory / (name + ".csv")).open(encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


def index(rows, *fields):
    """Index rows by key columns and stop on a duplicate key."""
    result = {}
    for row in rows:
        key = tuple(row[f] for f in fields)
        if key in result:
            raise ValueError(f"Duplicate key {fields}: {key}")
        result[key] = row
    return result


def flag(row, field):
    """Read a 0/1 column as True or False."""
    if row[field] not in ("0", "1"):
        raise ValueError(f"Invalid binary flag {field}: {row[field]!r}")
    return row[field] == "1"


def load_groups(directory, selected=None):
    """One group per scenario: the donation and its feasible hubs."""
    manifest = json.loads((directory / "generation_manifest.json").read_text(encoding="utf-8"))
    tables, hashes = {}, {}
    for name in TABLES:
        hashes[name + ".csv"] = hashlib.sha256((directory / (name + ".csv")).read_bytes()).hexdigest()
        if manifest["generated_csv_sha256"][name] != hashes[name + ".csv"]:
            raise ValueError(f"Input hash differs from generation manifest: {name}")
        tables[name] = read_table(directory, name)
    donations = index(tables["donations"], "donation_id")
    donors = index(tables["donors"], "donor_id")
    hubs = index(tables["hubs"], "hub_id")
    candidates = index(tables["donation_hub_candidates"], "donation_id", "hub_id")
    matrix = index(tables["road_distance_matrix"], "from_node_id", "to_node_id")
    members = defaultdict(list)
    for row in tables["scenario_members"]:
        members[row["scenario_id"]].append(row)
    groups = []
    for scenario in sorted(tables["scenarios"], key=lambda r: r["scenario_id"]):
        sid = scenario["scenario_id"]
        if scenario["scenario_type"] not in ("HUB_RECOMMENDATION", "HUB_RECOMMENDATION_VERIFICATION"):
            continue
        if selected is not None and sid not in selected:
            continue
        sources = [r["entity_id"] for r in members[sid] if r["scenario_role"] == "SOURCE_DONATION"]
        shortlist = [r["entity_id"] for r in members[sid] if r["scenario_role"] == "CANDIDATE_HUB"]
        if len(sources) != 1 or len(shortlist) != len(set(shortlist)):
            raise ValueError(f"Malformed recommendation scenario {sid}")
        donation = donations[(sources[0],)]
        if donation["collection_path"] != "COMMUNITY_HUB":
            raise ValueError(f"Not a community hub donation: {sid}")
        origin = donors[(donation["donor_id"],)]["road_node_id"]
        feasible = []
        for hid in shortlist:
            cand = candidates[(donation["donation_id"], hid)]
            ok = all(flag(cand, f) for f in HARD_RULES)
            if ok != flag(cand, "feasible_flag"):
                raise ValueError(f"Inconsistent feasibility {sid}/{hid}")
            road = matrix[(origin, hubs[(hid,)]["road_node_id"])]
            if flag(road, "route_available_flag") != flag(cand, "route_available_flag"):
                raise ValueError(f"Route availability mismatch {sid}/{hid}")
            if ok:
                km = float(road["road_distance_km"])
                if not math.isclose(km, float(cand["road_distance_km"]), abs_tol=1e-5):
                    raise ValueError(f"Frozen road distance mismatch {sid}/{hid}")
                feasible.append(dict(cand, road_distance_km=km))
        groups.append(dict(scenario_id=sid, scenario_type=scenario["scenario_type"],
                           scenario_profile=scenario["scenario_profile"], donation_id=donation["donation_id"],
                           geographic_group_id=donation["geographic_group_id"],
                           candidate_count=len(shortlist), feasible=feasible))
    if selected is not None and selected - {g["scenario_id"] for g in groups}:
        raise ValueError("Selection contains unknown or non-recommendation scenario IDs")
    if not groups:
        raise ValueError("No recommendation scenarios selected")
    return groups, manifest, hashes


def rank(feasible, group, seed):
    """Shuffle seeded by (seed, scenario_id)."""
    ordered = sorted(feasible, key=lambda r: r["hub_id"])
    digest = hashlib.sha256(f"{seed}:{group['scenario_id']}".encode()).digest()
    random.Random(int.from_bytes(digest, "big")).shuffle(ordered)
    return ordered


def recommend(groups, seed):
    """Rank the feasible hubs of every donation and keep the first one as the recommendation."""
    recommendations, rankings = [], []
    for group in groups:
        ordered = rank(group["feasible"], group, seed)
        base = {k: v for k, v in group.items() if k != "feasible"}
        base["feasible_candidate_count"] = len(ordered)
        chosen = ordered[0] if ordered else None
        recommendations.append(dict(base, method=METHOD,
                                    status="RECOMMENDED" if chosen else "NO_FEASIBLE_HUB",
                                    recommended_hub=chosen["hub_id"] if chosen else "",
                                    road_distance_km=chosen["road_distance_km"] if chosen else ""))
        for position, cand in enumerate(ordered, 1):
            rankings.append(dict(scenario_id=group["scenario_id"], donation_id=group["donation_id"],
                                 method=METHOD, rank=position, hub_id=cand["hub_id"],
                                 road_distance_km=cand["road_distance_km"]))
    return recommendations, rankings


def write_csv(path, rows):
    """Write rows to a CSV file."""
    with path.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def write_run_info(path, title, rows):
    """Record of what produced the results."""
    lines = [f"# Run information: {title}", "",
             "This file only records what produced the results in this folder, so the run can be repeated "
             "and checked. You do not need it to read the results.", "",
             "| Item | Value |", "| --- | --- |"] + [f"| {a} | {b} |" for a, b in rows] + [""]
    path.write_text("\n".join(lines), encoding="utf-8")


def common_run_rows(manifest_path, script, command):
    """Rows shared by every run_info.md."""
    manifest = Path(manifest_path)
    version = 'GEOLOCK-BENCHMARK-DATASET'
    manifest_hash = hashlib.sha256(manifest.read_bytes()).hexdigest()[:16]
    script_hash = hashlib.sha256(Path(script).read_bytes()).hexdigest()[:16]
    return [('Run at', datetime.now().astimezone().strftime('%Y-%m-%d %H:%M %Z')),
            ('Benchmark', f'{version} (generation_manifest.json SHA-256 {manifest_hash}...; '
                          'every input CSV was checked against this manifest)'),
            ('Script', f'`{Path(script).name}` (SHA-256 {script_hash}...)'),
            ('Python', sys.version.split()[0]),
            ('Command to repeat', f'`{command}`')]


def main():
    """Rank the hubs of every test donation and write the result folder."""
    root = Path(__file__).resolve().parents[4]
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dataset-dir", type=Path, default=root / "benchmark dataset" / "dataset")
    parser.add_argument("--output-dir", type=Path, default=Path(__file__).resolve().parents[1] / FOLDER)
    parser.add_argument("--scenario-ids", type=Path,
                        default=root / "ai hub ranking" / "data split" / "split" / "test_scenario_ids.csv",
                        help="CSV with a scenario_id column, or one ID per line (default: the 349 E1 test donations)")
    parser.add_argument("--seed", type=int, default=42, help="Used by the random baseline only")
    args = parser.parse_args()
    selected = None
    if args.scenario_ids:
        text = args.scenario_ids.read_text(encoding="utf-8-sig").splitlines()
        selected = ({r["scenario_id"] for r in csv.DictReader(text)} if text and text[0].split(",")[0] == "scenario_id"
                    else {line.strip() for line in text if line.strip()})
        if not selected:
            parser.error("Empty scenario selection")
    groups, manifest, hashes = load_groups(args.dataset_dir, selected)
    # hard rule flags and distances were already checked in load_groups()
    recommendations, rankings = recommend(groups, args.seed)
    out = args.output_dir
    (out / "details").mkdir(parents=True, exist_ok=True)
    ranked = defaultdict(list)
    for r in rankings:
        ranked[r["scenario_id"]].append(r)
    results = []
    for r in recommendations:
        order = [x["hub_id"] for x in sorted(ranked[r["scenario_id"]], key=lambda x: x["rank"])]
        results.append(dict(scenario_id=r["scenario_id"], donation_id=r["donation_id"], status=r["status"],
                            feasible_hubs=r["feasible_candidate_count"], recommended_hub=r["recommended_hub"],
                            distance_to_recommended_hub_km=round(r["road_distance_km"], 3) if order else "",
                            second_hub=order[1] if len(order) > 1 else "",
                            third_hub=order[2] if len(order) > 2 else ""))
    write_csv(out / "results_per_scenario.csv", results)
    write_csv(out / "details" / "hub_ranking.csv",
              [dict(scenario_id=r["scenario_id"], donation_id=r["donation_id"], rank=r["rank"], hub_id=r["hub_id"],
                    distance_km=round(r["road_distance_km"], 3),
                    **({"weighted_score": round(r["weighted_score"], 6)} if "weighted_score" in r else {}))
               for r in rankings])
    info = dict(recommended=sum(r["status"] == "RECOMMENDED" for r in recommendations),
                no_feasible_hub=sum(r["status"] == "NO_FEASIBLE_HUB" for r in recommendations))
    rows = common_run_rows(args.dataset_dir / "generation_manifest.json", __file__,
                           f"python {Path(__file__).name}" + (f" --seed {args.seed}" if METHOD == "random" and args.seed != 42 else ""))
    rows += [("Scenarios run", f"{len(recommendations):,}" + (" (E1 test split: ai hub ranking/data split/split/test_scenario_ids.csv)" if selected else " (all hub scenarios)")),
             ("Settings", "20 km candidate radius; five hard rules" + (f"; random seed {args.seed}" if METHOD == "random" else "")
              + ("; weights 0.45 / 0.20 / 0.25 / 0.10" if METHOD == "weighted" else ""))]
    write_run_info(out / "run_info.md", TITLE, rows)
    print(f"{TITLE}: {info['recommended']} recommendations, {info['no_feasible_hub']} no feasible hub "
          f"-> {args.output_dir}")


if __name__ == "__main__":
    main()
