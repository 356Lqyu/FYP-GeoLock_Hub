"""Summarize completed GeoLock E2 artifacts without changing their raw files."""
from __future__ import annotations
import argparse
import csv
import json
import math
from pathlib import Path
from statistics import median

REQUEST_ERROR_OUTCOMES = {"ERROR", "TIMEOUT", "DATABASE_ERROR", "CONNECTION_ERROR"}
ROLLBACK_ERROR_REASON = "CLAIM_TRANSACTION_ROLLED_BACK"


def wilson(successes: int, n: int, z: float = 1.959963984540054) -> tuple[float, float]:
    if not n:
        return (math.nan, math.nan)
    p = successes / n
    d = 1 + z*z/n
    c = (p + z*z/(2*n))/d
    h = z*math.sqrt(p*(1-p)/n + z*z/(4*n*n))/d
    return c-h, c+h


def exact_mcnemar(b: int, c: int) -> float | None:
    n = b+c
    if n == 0:
        return None
    tail = sum(math.comb(n, k) for k in range(min(b, c)+1)) / 2**n
    return min(1.0, 2*tail)


def load(folder: Path, filename: str):
    return json.loads((folder / filename).read_text(encoding="utf-8"))


def pct(value):
    return "n/a" if value is None or (isinstance(value, float) and math.isnan(value)) else f"{value*100:.1f}%"


def percentile(values: list[float], p: float) -> float | None:
    """Linearly interpolated percentile on sorted request latency observations."""
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * p
    low = math.floor(position)
    high = math.ceil(position)
    if low == high:
        return ordered[low]
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def is_request_error(request: dict) -> bool:
    return (request.get("outcome") in REQUEST_ERROR_OUTCOMES
            or request.get("reason_code") == ROLLBACK_ERROR_REASON)


def counted_reason(request: dict) -> str:
    reason = request.get("reason_code")
    if reason:
        return str(reason)
    outcome = request.get("outcome")
    return str(outcome) if outcome in REQUEST_ERROR_OUTCOMES else "UNSPECIFIED"


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--non-atomic", type=Path, required=True)
    p.add_argument("--protected", type=Path, required=True)
    p.add_argument("--lease", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    a=p.parse_args()
    folders={"NON_ATOMIC_BASELINE":a.non_atomic,"PROTECTED_ATOMIC":a.protected}
    data={k:(load(v,"run_info.json"),load(v,"trials.json")) for k,v in folders.items()}
    leases=load(a.lease,"lease_trials.json")
    summary=[]
    md=["# GeoLock Hub E2 results", "", "Only recorded artifacts are summarized. Incomplete and uncertain trials remain visible; this report does not label smoke runs as formal results.", "", "Request errors include ERROR, TIMEOUT, DATABASE_ERROR, CONNECTION_ERROR, and any CLAIM_TRANSACTION_ROLLED_BACK reason code. Error reasons are listed separately. Latency summaries use every request with a recorded latency, including unsuccessful outcomes; the population size is shown. p95 uses linear interpolation over sorted observations. Wilson intervals are trial-level intervals for duplicate ownership and invariant violations; request errors are descriptive because requests within a trial are concurrent.", ""]
    pairmaps={}
    for condition,(info,trials) in data.items():
        md += [f"## {condition} ({info.get('run_kind')}; {info.get('status')})", "", "| Workers | Completed / planned | Duplicate ownership | Single-owner invariant | Duplicate 95% Wilson CI | Violation 95% Wilson CI | Zero winners | Errors / requests | Error rate | Latency n | Min | Median | p95 | Max (ms) |", "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
        pairmaps[condition]={}
        requests=load(folders[condition],"requests.json")
        for n in sorted({int(t["concurrency"]) for t in trials}):
            rows=[t for t in trials if int(t["concurrency"])==n]
            done=[t for t in rows if t.get("completed")]
            dup=sum(bool(t.get("conflicting_committed_ownership")) for t in done)
            invariant_preserved=sum(bool(t.get("at_most_one_owner_preserved")) for t in done)
            invariant_violations=len(done)-invariant_preserved
            zero=sum(bool(t.get("unexpected_zero_winner")) for t in done)
            lo,hi=wilson(dup,len(done))
            vlo,vhi=wilson(invariant_violations,len(done))
            req=[r for r in requests if int(r.get("concurrency",0))==n]
            lat=[float(r["latency_ms"]) for r in req if r.get("latency_ms") is not None]
            timeout=sum(bool(r.get("timed_out")) or r.get("outcome")=="TIMEOUT" for r in req)
            error_rows=[r for r in req if is_request_error(r)]
            errors=len(error_rows)
            reason_counts={}
            outcome_counts={}
            for request in error_rows:
                reason=counted_reason(request)
                reason_counts[reason]=reason_counts.get(reason,0)+1
                outcome=request.get("outcome") or "UNKNOWN"
                outcome_counts[outcome]=outcome_counts.get(outcome,0)+1
            p95=percentile(lat,0.95)
            min_latency=min(lat) if lat else None
            max_latency=max(lat) if lat else None
            summary.append(dict(condition=condition,concurrency=n,completed_trials=len(done),planned_trials=len(rows),
              duplicate_trials=dup,duplicate_rate=dup/len(done) if done else None,wilson95_low=lo,wilson95_high=hi,
              invariant_violation_rate=invariant_violations/len(done) if done else None,
              invariant_wilson95_low=vlo,invariant_wilson95_high=vhi,
              invariant_preserved_trials=invariant_preserved,invariant_violation_trials=invariant_violations,
              zero_winner_trials=zero,request_count=len(req),timeouts=timeout,request_errors=errors,
              request_error_rate=errors/len(req) if req else None,
              request_error_outcome_counts=json.dumps(outcome_counts,sort_keys=True),
              request_error_reason_counts=json.dumps(reason_counts,sort_keys=True),
              latency_sample_count=len(lat),min_request_latency_ms=min_latency,
              median_request_latency_ms=median(lat) if lat else None,p95_request_latency_ms=p95,
              max_request_latency_ms=max_latency))
            inv=f"{invariant_preserved}/{len(done)} preserved; {invariant_violations} violations"
            dup_ci=f"[{pct(lo)}, {pct(hi)}]"
            inv_ci=f"[{pct(vlo)}, {pct(vhi)}]"
            err_text=f"{errors} / {len(req)}" if req else "0 / 0"
            rate=pct(errors/len(req) if req else None)
            latency=[f"{len(lat)}",f"{min_latency:.2f}" if min_latency is not None else "n/a",
                     f"{median(lat):.2f}" if lat else "n/a",f"{p95:.2f}" if p95 is not None else "n/a",
                     f"{max_latency:.2f}" if max_latency is not None else "n/a"]
            md.append(f"| {n} | {len(done)} / {len(rows)} | {dup} ({pct(dup/len(done) if done else None)}) | {inv} | {dup_ci} | {inv_ci} | {zero} | {err_text} | {rate} | " + " | ".join(latency) + " |")
            md.append(f"  - Request error outcomes: `{json.dumps(outcome_counts, sort_keys=True)}`; reason codes: `{json.dumps(reason_counts, sort_keys=True)}`; timeouts: {timeout}.")
            for t in done:
                pairmaps[condition][(n,t.get("trial_number"))]=bool(t.get("conflicting_committed_ownership"))
        md.append("")
    md += ["## Paired analysis", "", "Not computed: the runner gives each condition fresh independent fixtures and does not establish matched trial pairs. Trial-number matching alone would not justify McNemar analysis.", ""]
    done_lease=[x for x in leases if x.get("completed")]
    successes=sum(bool(x.get("lease_recovery_success")) for x in done_lease)
    lo,hi=wilson(successes,len(done_lease))
    md += ["", "## Lease recovery", "", f"Completed {len(done_lease)} / {len(leases)}; successful release and reclaim {successes} ({pct(successes/len(done_lease) if done_lease else None)}); 95% Wilson CI [{pct(lo)}, {pct(hi)}].", "", "Raw JSON is the source of record. A trial without confirmed post-trial state is not considered completed.", ""]
    a.output.mkdir(parents=True,exist_ok=True)
    with (a.output/"summary.csv").open("w",newline="",encoding="utf-8") as f:
        w=csv.DictWriter(f,fieldnames=list(summary[0]) if summary else ["condition","concurrency"]); w.writeheader();w.writerows(summary)
    (a.output/"report.md").write_text("\n".join(md),encoding="utf-8")
    print(json.dumps({"summary_csv":str(a.output/"summary.csv"),"report_markdown":str(a.output/"report.md"),"lease_completed":len(done_lease)},indent=2))

if __name__=="__main__": main()
