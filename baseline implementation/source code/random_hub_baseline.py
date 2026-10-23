"""Random feasible hub baseline (weak comparison method).

Rule: the same feasible hubs as Baseline A, shuffled uniformly with a recorded
seed per scenario; distance and reference scores do not influence the choice.

A baseline is a comparison METHOD, not an experiment: this script only writes the
baseline's rankings and recommendations. Comparisons belong to the E1 experiment.
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
import statistics
import sys

FOLDER = "2_random_hub"
TITLE = "Random Hub (baseline 2)"
WHAT = ("Among the hubs that pass all four hard rules, recommend one at random. The random order is fixed by --seed and the scenario ID, so a rerun gives the same answer.")
METHOD = "random"
HARD_RULES = ("item_compatible_flag", "capacity_feasible_flag", "active_feasible_flag", "route_available_flag")
TABLES = ("donations", "donors", "hubs", "donation_hub_candidates",
          "road_distance_matrix", "scenarios", "scenario_members")


def read_table(directory, name):
    with (directory / (name + ".csv")).open(encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


def index(rows, *fields):
    result = {}
    for row in rows:
        key = tuple(row[f] for f in fields)
        if key in result:
            raise ValueError(f"Duplicate key {fields}: {key}")
        result[key] = row
    return result


def flag(row, field):
    if row[field] not in ("0", "1"):
        raise ValueError(f"Invalid binary flag {field}: {row[field]!r}")
    return row[field] == "1"


def load_groups(directory, selected=None):
    """One group per recommendation scenario: the donation and its feasible hubs."""
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
            raise ValueError(f"Not a community-hub donation: {sid}")
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
    """Uniform shuffle seeded by (seed, scenario_id); input order does not matter."""
    ordered = sorted(feasible, key=lambda r: r["hub_id"])
    digest = hashlib.sha256(f"{seed}:{group['scenario_id']}".encode()).digest()
    random.Random(int.from_bytes(digest, "big")).shuffle(ordered)
    return ordered


def recommend(groups, seed):
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
    with path.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def spread(values, unit, digits=1):
    """median (10th-90th percentile; max) in plain words."""
    values = sorted(values)
    if not values:
        return "n/a"
    q = statistics.quantiles(values, n=10) if len(values) >= 10 else [values[0]] * 9
    return (f"median {statistics.median(values):,.{digits}f} {unit} "
            f"(10th-90th percentile {q[0]:,.{digits}f}-{q[-1]:,.{digits}f}; max {values[-1]:,.{digits}f})")


SPREAD_NOTE = ("How to read a spread such as \"median 3.8 km (10th-90th percentile 1.5-7.7; max 22.9)\": half of "
               "the donations are at or below the median; 8 in 10 lie between the two percentiles; max is the "
               "single largest value.")
GUIDE = dict(
 how=["Take the same feasible hubs as the other hub methods (all four hard rules pass).",
      "Shuffle them in a random order fixed by the seed and the scenario ID (same seed = same answer).",
      "The first hub after shuffling is the recommendation; the full shuffled order is the ranking."],
 expect=["A random choice is the usual \"chance level\" lower bound: a method that has learned anything must do "
         "better than it.",
         "Chance level for this benchmark: with k feasible hubs, a random pick equals any particular hub (for "
         "example the reference policy's choice) with probability 1/k. Averaged over these scenarios that is "
         "CHANCE_PCT. Its distance should be close to the average distance of the feasible hubs "
         "(median over scenarios: MEANDIST km)."],
 read=["**Hub recommended / No feasible hub**: same split as the other hub methods, because all use the same "
       "hard rules.",
       "**Road distance** should be near the average feasible-hub distance above; if it is, the method behaves "
       "as a fair random choice.",
       "`details/hub_ranking.csv` is the shuffled order. E1 scores it with Top-1, Top-3 and NDCG@3 [1], within each "
       "donation's candidate group [2]; random results should sit near chance level."],
 refs=['[1] Järvelin, K., & Kekäläinen, J. (2002). Cumulated gain-based evaluation of IR techniques. *ACM Transactions on Information Systems*, 20(4), 422-446. https://doi.org/10.1145/582415.582418 *(not yet in the report: add it if you cite it)*',
       '[2] Cao, Z., Qin, T., Liu, T.-Y., Tsai, M.-F., & Li, H. (2007). Learning to rank: From pairwise approach to listwise approach. *Proceedings of the 24th International Conference on Machine Learning*, 129-136. https://doi.org/10.1145/1273496.1273513 *(in the report reference list)*'])


def guide_lines(recommendations, rankings):
    g = GUIDE
    rec = [r for r in recommendations if r["status"] == "RECOMMENDED"]
    chance = sum(1 / r["feasible_candidate_count"] for r in rec) / len(rec) if rec else 0
    by = defaultdict(list)
    for r in rankings:
        by[r["scenario_id"]].append(r["road_distance_km"])
    meandist = statistics.median(statistics.mean(v) for v in by.values()) if by else 0
    fill = lambda t: t.replace("CHANCE_PCT", f"{chance:.1%}").replace("MEANDIST", f"{meandist:.1f}")
    lines = ["", "## How the method works", ""] + [f"{i}. {fill(t)}" for i, t in enumerate(g["how"], 1)]
    lines += ["", "## What to expect", ""] + [f"- {fill(t)}" for t in g["expect"]]
    lines += ["", "## How to read the results", ""] + [f"- {fill(t)}" for t in g["read"]] + ["", SPREAD_NOTE]
    lines += ["", "## References", ""] + [f"- {t}" for t in g["refs"]]
    return lines


def write_summary(path, recommendations, rankings, manifest, seed):
    rec = [r for r in recommendations if r["status"] == "RECOMMENDED"]
    none = [r for r in recommendations if r["status"] == "NO_FEASIBLE_HUB"]
    rows = [
        ("Scenarios", f"{len(recommendations):,}",
         "Small donations (< 10 kg), each with every hub within 20 km as a candidate"),
        ("Hub recommended", f"{len(rec):,}", "At least one hub passed all four hard rules"),
        ("No feasible hub", f"{len(none):,}", "No hub passed the hard rules, so the method correctly recommends nothing"),
        ("Feasible hubs per donation", spread([r["feasible_candidate_count"] for r in rec], "hubs", 0),
         "How many hubs the method could choose from"),
        ("Road distance from donor to the recommended hub", spread([r["road_distance_km"] for r in rec], "km"),
         "Candidates are within 20 km in a straight line; the road distance can be longer"),
    ]
    if METHOD == "random":
        rows.append(("Random seed", str(seed), "Same seed, same recommendations"))
    lines = [f"# {TITLE}", "", f"Benchmark {manifest['benchmark_version']}. This describes this method on its own; "
             "comparing methods is done in experiment E1.", "", f"**Method.** {WHAT}", "",
             "**Hard rules** (a hub must pass all four): accepts the donation's category; weight <= capacity - stored - "
             "reserved; hub active; a directed road route from the donor exists.", "",
             "| Result | Value | Meaning |", "| --- | --- | --- |"]
    lines += [f"| {a} | {b} | {c} |" for a, b, c in rows]
    lines += guide_lines(recommendations, rankings)
    lines += ["", "## Files", "", "| File | Content |", "| --- | --- |",
              "| `results_per_scenario.csv` | **The main result.** One row per donation (scenario). |",
              "| `details/hub_ranking.csv` | Every feasible hub of every donation, in this method's order (rank 1 = recommended). |",
              "| `run_info.md` | What produced this run (date, benchmark, script fingerprint, command). |", "",
              "### Columns of results_per_scenario.csv", "", "| Column | Meaning |", "| --- | --- |",
              "| `scenario_id` | Benchmark scenario (one small donation looking for a hub) |",
              "| `donation_id` | The donation |",
              "| `status` | RECOMMENDED, or NO_FEASIBLE_HUB when no hub passes the four hard rules |",
              "| `feasible_hubs` | How many hubs passed the hard rules (the method's choices) |",
              "| `recommended_hub` | The method's first choice (empty when NO_FEASIBLE_HUB) |",
              "| `distance_to_recommended_hub_km` | Road distance from the donor to that hub |",
              "| `second_hub`, `third_hub` | The method's 2nd and 3rd choices (empty if fewer hubs) |", ""]
    path.write_text("\n".join(lines), encoding="utf-8")


def write_run_info(path, title, rows):
    """Plain record of what produced the results (only needed to repeat or audit the run)."""
    lines = [f"# Run information: {title}", "",
             "This file only records what produced the results in this folder, so the run can be repeated "
             "and checked. You do not need it to read the results.", "",
             "| Item | Value |", "| --- | --- |"] + [f"| {a} | {b} |" for a, b in rows] + [""]
    path.write_text("\n".join(lines), encoding="utf-8")


def common_run_rows(manifest_path, script, command):
    manifest = Path(manifest_path)
    version = json.loads(manifest.read_text(encoding='utf-8'))['benchmark_version']
    manifest_hash = hashlib.sha256(manifest.read_bytes()).hexdigest()[:16]
    script_hash = hashlib.sha256(Path(script).read_bytes()).hexdigest()[:16]
    return [('Run at', datetime.now().astimezone().strftime('%Y-%m-%d %H:%M %Z')),
            ('Benchmark', f'{version} (generation_manifest.json SHA-256 {manifest_hash}...; '
                          'every input CSV was checked against this manifest)'),
            ('Script', f'`{Path(script).name}` (SHA-256 {script_hash}...)'),
            ('Python', sys.version.split()[0]),
            ('Command to repeat', f'`{command}`')]


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dataset-dir", type=Path, default=root / "benchmark dataset" / "dataset")
    parser.add_argument("--output-dir", type=Path, default=root / "baseline implementation" / "result" / FOLDER)
    parser.add_argument("--scenario-ids", type=Path, help="CSV with a scenario_id column, or one ID per line")
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
    # Hard-rule flags and road distances were checked against the matrix in load_groups().
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
    rows += [("Scenarios run", f"{len(recommendations):,}" + (" (selected with --scenario-ids)" if selected else " (all hub scenarios)")),
             ("Settings", "20 km candidate radius; four hard rules" + (f"; random seed {args.seed}" if METHOD == "random" else "")
              + ("; weights 0.45 / 0.20 / 0.25 / 0.10" if METHOD == "weighted" else ""))]
    write_run_info(out / "run_info.md", TITLE, rows)
    write_summary(out / "summary.md", recommendations, rankings, manifest, args.seed)
    print(f"{TITLE}: {info['recommended']} recommendations, {info['no_feasible_hub']} no feasible hub "
          f"-> {args.output_dir / 'summary.md'}")


if __name__ == "__main__":
    main()
