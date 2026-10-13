"""Standalone Nearest-Hub baseline for GEOLOCK-BM CSV benchmark inputs.

Selection never uses reference scores: they are read only after ranking for
evaluation. Each scenario is an independent replay of the frozen hub state.
"""
import argparse
import csv
import hashlib
import json
import math
from pathlib import Path
import sys
from collections import defaultdict


FLAGS = ("item_compatible_flag", "capacity_feasible_flag",
         "operating_feasible_flag", "active_feasible_flag", "route_available_flag")


def read_table(directory, name):
    with (directory / (name + ".csv")).open(encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


def unique_index(rows, fields):
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


def nonnegative(row, field):
    value = float(row[field])
    if not math.isfinite(value) or value < 0:
        raise ValueError(f"Invalid {field}: {row[field]!r}")
    return value


def load_groups(directory, scope="scenarios", scenario_ids=None):
    donations = unique_index(read_table(directory, "donations"), ("donation_id",))
    donors = unique_index(read_table(directory, "donors"), ("donor_id",))
    hubs = unique_index(read_table(directory, "hubs"), ("hub_id",))
    locations = unique_index(read_table(directory, "locations"), ("location_id",))
    candidates = unique_index(read_table(directory, "donation_hub_candidates"),
                              ("donation_id", "hub_id"))
    matrix = unique_index(read_table(directory, "road_distance_matrix"),
                          ("from_node_id", "to_node_id"))
    manifest = json.loads((directory / "generation_manifest.json").read_text(encoding="utf-8"))
    specs = []
    if scope == "scenarios":
        scenarios = unique_index(read_table(directory, "scenarios"), ("scenario_id",))
        members = defaultdict(list)
        for row in read_table(directory, "scenario_members"):
            members[row["scenario_id"]].append(row)
        for (sid,), scenario in sorted(scenarios.items()):
            if scenario["scenario_type"] not in ("HUB_RECOMMENDATION", "HUB_RECOMMENDATION_VERIFICATION"):
                continue
            if scenario_ids is not None and sid not in scenario_ids:
                continue
            sources = [r["entity_id"] for r in members[sid]
                       if r["entity_type"] == "DONATION" and r["scenario_role"] == "SOURCE_DONATION"]
            shortlist = [r["entity_id"] for r in members[sid]
                         if r["entity_type"] == "HUB" and r["scenario_role"] == "CANDIDATE_HUB"]
            if len(sources) != 1 or not shortlist or len(shortlist) != len(set(shortlist)):
                raise ValueError(f"Malformed recommendation scenario {sid}")
            if scenario["matrix_id"] != manifest["matrix_id"]:
                raise ValueError(f"Matrix mismatch for {sid}")
            specs.append((sid, scenario["scenario_type"], sources[0], shortlist))
        if scenario_ids is not None:
            missing = scenario_ids - {s[0] for s in specs}
            if missing:
                raise ValueError(f"Unknown/non-recommendation scenario IDs: {sorted(missing)}")
    else:
        by_donation = defaultdict(list)
        for did, hid in candidates:
            by_donation[did].append(hid)
        specs = [("", "ALL_COMMUNITY_HUB", did, sorted(by_donation[did]))
                 for (did,), d in sorted(donations.items()) if d["collection_path"] == "COMMUNITY_HUB"]
    if not specs:
        raise ValueError("No recommendation groups selected")
    groups = []
    for sid, kind, did, shortlist in specs:
        donation = donations[(did,)]
        if donation["collection_path"] != "COMMUNITY_HUB" or not flag(donation, "valid_input_flag"):
            raise ValueError(f"Not a valid community-hub donation: {did}")
        donor = donors[(donation["donor_id"],)]
        origin = locations[(donor["location_id"],)]["road_node_id"]
        eligible = []
        for hid in shortlist:
            candidate = candidates[(did, hid)]
            feasible = all([flag(candidate, f) for f in FLAGS])
            if feasible != flag(candidate, "feasible_flag"):
                raise ValueError(f"Inconsistent feasibility for {did}/{hid}")
            destination = locations[(hubs[(hid,)]["location_id"],)]["road_node_id"]
            road = matrix[(origin, destination)]
            if road["matrix_id"] != manifest["matrix_id"]:
                raise ValueError(f"Wrong frozen matrix for {did}/{hid}")
            if flag(road, "route_available_flag") != flag(candidate, "route_available_flag"):
                raise ValueError(f"Route availability mismatch for {did}/{hid}")
            if flag(road, "route_available_flag"):
                for field in ("road_distance_km", "travel_time_min"):
                    if not math.isclose(nonnegative(road, field), nonnegative(candidate, field), abs_tol=1e-5):
                        raise ValueError(f"Frozen road value mismatch: {did}/{hid}/{field}")
            if feasible:
                eligible.append(dict(candidate, road_distance_km=nonnegative(road, "road_distance_km"),
                                     travel_time_min=nonnegative(road, "travel_time_min"),
                                     hub_name=hubs[(hid,)]["osm_name"]))
        groups.append(dict(scenario_id=sid, scenario_type=kind, donation_id=did,
                           donor_id=donation["donor_id"], geographic_group_id=donation["geographic_group_id"],
                           candidate_count=len(shortlist), feasible=eligible))
    return groups, manifest


def rank_candidates(candidates):
    """Rank feasible hubs by directed road distance; break ties by hub ID."""
    return sorted(candidates, key=lambda row: (row["road_distance_km"], row["hub_id"]))


def ranking_metrics(ordered, top_k):
    reference = sorted(ordered, key=lambda r: (float(r["reference_score"]),
                                               r["road_distance_km"], r["hub_id"]))
    best = reference[0]["hub_id"]
    scores = [float(r["reference_score"]) for r in ordered]
    if not all(math.isfinite(s) for s in scores):
        raise ValueError("Non-finite reference score")
    low, high = min(scores), max(scores)
    ndcg = None
    if high != low:
        def dcg(rows):
            return sum((2 ** (1 - (float(r["reference_score"]) - low) / (high - low)) - 1)
                       / math.log2(i + 2) for i, r in enumerate(rows[:3]))
        ndcg = dcg(ordered) / dcg(reference)
    return best, int(ordered[0]["hub_id"] == best), int(best in [r["hub_id"] for r in ordered[:top_k]]), ndcg


def evaluate(groups, seed=42, top_k=3):
    method = "nearest"
    recommendations, rankings = [], []
    for group in groups:
        ordered = rank_candidates(group["feasible"])
        base = {k: v for k, v in group.items() if k != "feasible"}
        base.update(method=method, random_seed=seed if method == "random" else "",
                    feasible_candidate_count=len(ordered))
        row = dict(base, status="NO_FEASIBLE_HUB", recommended_hub="", hub_name="",
                   road_distance_km="", travel_time_min="", reference_best_hub="",
                   top1_agreement="", topk_coverage="", ndcg_at_3="")
        if ordered:
            best, agreement, coverage, ndcg = ranking_metrics(ordered, top_k)
            chosen = ordered[0]
            row.update(status="RECOMMENDED", recommended_hub=chosen["hub_id"],
                       hub_name=chosen["hub_name"], road_distance_km=chosen["road_distance_km"],
                       travel_time_min=chosen["travel_time_min"], reference_best_hub=best,
                       top1_agreement=agreement, topk_coverage=coverage,
                       ndcg_at_3=ndcg if ndcg is not None else "")
            for rank, candidate in enumerate(ordered, 1):
                rankings.append(dict(base, rank=rank, hub_id=candidate["hub_id"],
                                     road_distance_km=candidate["road_distance_km"],
                                     travel_time_min=candidate["travel_time_min"],
                                     reference_score=candidate["reference_score"],
                                     reference_rank=candidate["reference_rank"]))
        recommendations.append(row)
    metric_rows = [r for r in recommendations if r["status"] == "RECOMMENDED"
                   and r["scenario_type"] != "HUB_RECOMMENDATION_VERIFICATION"]
    ndcg_rows = [r for r in metric_rows if r["ndcg_at_3"] != ""]
    def mean(rows, key):
        return sum(r[key] for r in rows) / len(rows) if rows else None
    verification = [r for r in recommendations if r["scenario_type"] == "HUB_RECOMMENDATION_VERIFICATION"]
    summary = dict(groups=len(groups), recommended=sum(r["status"] == "RECOMMENDED" for r in recommendations),
                   no_feasible_hub=sum(r["status"] == "NO_FEASIBLE_HUB" for r in recommendations),
                   ranking_metric_groups=len(metric_rows), top_k=top_k,
                   top1_agreement=mean(metric_rows, "top1_agreement"),
                   topk_coverage=mean(metric_rows, "topk_coverage"), ndcg_at_3=mean(ndcg_rows, "ndcg_at_3"),
                   ndcg_groups=len(ndcg_rows), degenerate_reference_groups=len(metric_rows)-len(ndcg_rows),
                   verification_groups=len(verification),
                   verification_no_recommendation_count=sum(r["status"] == "NO_FEASIBLE_HUB" for r in verification))
    return recommendations, rankings, summary


def write_csv(path, rows, fields):
    with path.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def main():
    method = "nearest"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-dir", type=Path,
                        default=Path(__file__).resolve().parents[2] / "benchmark dataset" / "dataset")
    parser.add_argument("--output-dir", type=Path, default=Path(__file__).resolve().parents[1] / "result")
    parser.add_argument("--scope", choices=("scenarios", "all-community-hub"), default="scenarios")
    parser.add_argument("--scenario-ids", type=Path, help="Frozen selection: CSV with scenario_id column, or one ID per line")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--top-k", type=int, default=3)
    args = parser.parse_args()
    if args.top_k < 1:
        parser.error("--top-k must be positive")
    selected = None
    if args.scenario_ids:
        if args.scope != "scenarios":
            parser.error("--scenario-ids requires --scope scenarios")
        content = args.scenario_ids.read_text(encoding="utf-8-sig")
        if not content.strip():
            parser.error("Empty scenario selection")
        if content.splitlines()[0].split(",")[0] == "scenario_id":
            selected = {r["scenario_id"] for r in csv.DictReader(content.splitlines())}
        else:
            selected = {line.strip() for line in content.splitlines() if line.strip()}
        if not selected:
            parser.error("Empty scenario selection")
    groups, manifest = load_groups(args.dataset_dir, args.scope, selected)
    recommendations, rankings, summary = evaluate(groups, args.seed, args.top_k)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    prefix = args.output_dir / (method + "_hub")
    write_csv(prefix.with_name(prefix.name + "_recommendations.csv"), recommendations, list(recommendations[0]))
    ranking_fields = [k for k in recommendations[0] if k not in
                      ("status", "recommended_hub", "hub_name", "road_distance_km", "travel_time_min",
                       "reference_best_hub", "top1_agreement", "topk_coverage", "ndcg_at_3")]
    ranking_fields += ["rank", "hub_id", "road_distance_km", "travel_time_min", "reference_score", "reference_rank"]
    write_csv(prefix.with_name(prefix.name + "_rankings.csv"), rankings, ranking_fields)
    inputs = ["donations.csv", "donors.csv", "hubs.csv", "locations.csv", "donation_hub_candidates.csv",
              "road_distance_matrix.csv", "generation_manifest.json"]
    if args.scope == "scenarios":
        inputs += ["scenarios.csv", "scenario_members.csv"]
    summary.update(method=method, seed=args.seed if method == "random" else None,
                   benchmark_version=manifest["benchmark_version"], matrix_id=manifest["matrix_id"],
                   scope=args.scope, dataset_dir=str(args.dataset_dir.resolve()),
                   evaluation_status="EXPLORATORY_ALL_INPUTS" if selected is None else "USER_SELECTED_SCENARIOS",
                   selected_scenario_ids=sorted(selected) if selected is not None else None,
                   input_sha256={name: hashlib.sha256((args.dataset_dir / name).read_bytes()).hexdigest() for name in inputs},
                   runner_sha256={p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in
                                  (Path(__file__),)},
                   python_version=sys.version, independent_frozen_state=True,
                   candidate_scope="Supplied shortlist only; not a global search over every hub")
    prefix.with_name(prefix.name + "_summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: summary[k] for k in ("method", "groups", "recommended", "no_feasible_hub",
                                             "top1_agreement", "topk_coverage", "ndcg_at_3", "evaluation_status")}, indent=2))
    print(f"Results saved in {args.output_dir.resolve()}")


if __name__ == "__main__":
    main()
