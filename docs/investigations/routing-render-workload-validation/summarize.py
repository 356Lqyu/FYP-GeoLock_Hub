"""Summarize completed modeled runs; do not equate structural validity with a route."""
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parent
RUN=ROOT/'run2'
MIB=1024**2


def main():
    rows=json.loads((RUN/'receipts.json').read_text());assert len(rows)==34
    manifest=json.loads((RUN/'WORKLOAD_MANIFEST.json').read_text());assert manifest['legacy_csr_parity']
    lines=['# Full-graph provisional workload measurements — 7 November 2026 MYT','',
        '**Offline modeled entities only. No authoritative DB snapshot metadata, grants, receipts or deployment approval were created.**',
        'The complete sealed graph and all four unchanged methods were used. Separate processes run the independent raw-input plan validator. Production source-envelope/RPC attestation and authorization are not simulated or claimed.','',
        '## Workload provenance','',
        'Case sizes (3/10/25/100 pickups; 2/2/5/10 vehicles) were explicitly treated as provisional by the user. Their relation to actual NGO demand is unknown. The source template is the existing synthetic GEOLOCK-BM-v3.3 fixture; no original CSV or previous result was overwritten.','',
        '| Case | Pickups | Vehicles | Required road nodes |','| --- | ---: | ---: | ---: |']
    for c in manifest['cases']:lines.append(f"| {c['name']} | {c['pickups']} | {c['vehicles']} | {c['required_nodes']} |")
    lines+=['',f"Selected source: {manifest['selected_base_scenario']}, with {manifest['mutually_reachable_candidates']} matched public benchmark road nodes within 17 km. Largest selected straight-line distance is {manifest['largest_selected_straight_line_km']:.3f} km. This is coordinate-based model locality, not observed trips or independently verified current DEV coordinates.",
        'The graph remains complete for every shortest-path search; connectivity filtering selects workload locations only. At 100 pickups, two modeled tasks share one of 99 pickup nodes, plus the depot. Counts are not asserted to be real-world maxima.',
        f"Legacy/compact matrix parity at {manifest['largest_required_nodes']} nodes: PASS; compact {manifest['csr_matrix_seconds']:.2f} s, legacy {manifest['legacy_matrix_seconds']:.2f} s (preparation run, 8 GiB / 2 CPU).",
        'Raw graph matrix source tags are wrapped as SYNTHETIC_BENCHMARK for the unchanged benchmark contract; numeric costs, path policy, graph version and tie behavior are unchanged. Local frozen-input hashes/state tokens are not PostgreSQL digests or authority.','',
        'Inherited model policy: direct-only pickups; 10-minute service; optional tasks; 240-minute horizon; historical synthetic cutoff/windows/leases; 100kg/500kg vehicle templates; 30s solver wall budget, one worker, seed42, unchanged deterministic 0.25s per pass. Do not assume this is the current DEV policy.','',
        '## Planner results','',
        '| Case / profile | Process wall s | CPU s | Peak RSS MiB | Cgroup peak MiB | Proposed served / pickups | Proposed usable | Solver timeout flag | Review screen |',
        '| --- | ---: | ---: | ---: | ---: | --- | --- | --- | --- |']
    screening=[]
    for r in rows:
        if not r['label'].endswith('-planner'):continue
        if 'result' not in r:
            outcome='OOM' if r['oom'] else 'HARNESS TIMEOUT' if r['external_timeout'] else 'ERROR'
            lines.append(f"| {r['label']} | {r['wall_seconds']:.2f} (controller) | N/A | N/A | N/A | N/A | No result | {outcome} | NO |");continue
        a=r['result'];m=a['metrics'];cg=int(m['cgroup']['memory.peak']);rss=m['peak_rss_bytes']
        proposed=next(x for x in a['methods'] if x['method']=='proposed')
        memory_screen=max(rss,cg)+72*MIB<=.7*r['limits']['Memory']
        time_screen=a['wall_seconds']<=120
        passed=memory_screen and time_screen and a['proposed_usable'] and a['all_plans_valid']
        screening.append(dict(case=a['case'],profile=r['profile'],memory_screen=memory_screen,
            time_screen=time_screen,usable=a['proposed_usable'],screen_pass=passed))
        lines.append(f"| {r['label']} | {a['wall_seconds']:.2f} | {m['cpu_seconds']:.2f} | {rss/MIB:.1f} | {cg/MIB:.1f} | {proposed['served']}/{a['pickups']} | {a['proposed_usable']} | {a['any_solver_timeout']} | {'CANDIDATE' if passed else 'NO'} |")
    lines+=['',
        'Review screen (an explicit engineering assumption, not a provider guarantee): require a usable independently valid proposed route, <=120s process wall time (30s nominal reserve inside the app 150s POST budget), and at least 30% RAM reserve after taking the larger of observed process/cgroup peaks plus a conservative 72 MiB extra cold-artifact page-cache allowance. No host cache flush was performed. Passing is a local model candidate, not deployment approval.',
        'A timeout flag with a valid feasible incumbent is distinguished from UNKNOWN/no incumbent. Partial heuristic routes and structurally valid no-route reports do not make the required proposed candidate usable. No solver budget/objective was changed and no baseline route was substituted for authorization.','',
        '## Separate independent plan validator','',
        '| Case / profile | Wall s | CPU s | RSS MiB | Cgroup MiB | Four reports structurally valid | Proposed usable | Plan source |',
        '| --- | ---: | ---: | ---: | ---: | --- | --- | --- |']
    validators=[]
    for r in rows:
        if not r['label'].endswith('-validator'):continue
        if 'result' not in r:
            lines.append(f"| {r['label']} | N/A | N/A | N/A | N/A | FAILED | Unknown | {r.get('plan_source_file','')} |");continue
        a=r['result'];m=a['metrics'];proposed=next(x for x in a['methods'] if x['method']=='proposed')
        validators.append(dict(profile=r['profile'],rss=m['peak_rss_bytes'],cgroup=int(m['cgroup']['memory.peak']),wall=a['wall_seconds'],valid=a['all_valid']))
        lines.append(f"| {r['label']} | {a['wall_seconds']:.3f} | {m['cpu_seconds']:.3f} | {m['peak_rss_bytes']/MIB:.1f} | {int(m['cgroup']['memory.peak'])/MIB:.1f} | {a['all_valid']} | {proposed['usable']} | {r.get('plan_source_file','')} |")
    lines+=['',
        'Where a planner failed before producing plans, validator-only measurements use the completed 8 GiB reference plans; this is not recovery or proof that the failed planner succeeded. The validator checks all four plans/reports, including baseline routes and correctly unusable CP-SAT outcomes. It does not attest a DB work item or issue database authorization.',
        '512 MiB / 0.1 CPU is the minimum tested raw-plan-validator profile if all its rows pass with headroom. Actual trusted validator source reads, DB joins/digests, TLS/network latency and private work-item shape remain unmeasured here.','',
        '## Limits and unresolved prerequisites','',
        'One depot, direct pickups, one deterministic modeled location selection and one run per profile do not establish a fleet/demand distribution, worst geography, hub batching/body-size behavior, concurrency, P95 latency or an actual Render CPU/memory SLA. The initial depot had only 77 matching in-radius nodes, and another sample depot did not exist in the frozen graph; preparation switched explicitly to the matching 223-node depot. Initial failed preparation receipts remain in the parent folder.',
        'No production routing/grant/journal code changed in this stage. Real work-item envelopes, current operational policy, provider ingress, actual backup/recovery and deployment approval remain separate prerequisites. PostgreSQL journal replacement is design-only; see ROUTING_HOSTING_RECOVERY_OPTIONS.md.']
    with (ROOT/'MEASUREMENTS.md').open('x',encoding='utf-8') as f:f.write('\n'.join(lines)+'\n')
    summary=dict(cases=34,planner_cases=16,validator_cases=16,
        oom=sum(r['oom'] for r in rows),external_timeouts=sum(r['external_timeout'] for r in rows),
        screening=screening,validator_peak_rss_mib=max(v['rss'] for v in validators)/MIB,
        validator_peak_cgroup_mib=max(v['cgroup'] for v in validators)/MIB,
        validator_runs_completed=len(validators),validators_all_valid=len(validators)==16 and all(v['valid'] for v in validators),
        outcome='LOCAL_MODELED_RESULTS_ONLY; NO-GO FOR DEPLOYMENT')
    with (ROOT/'RESULTS_SUMMARY.json').open('x',encoding='utf-8') as f:json.dump(summary,f,indent=2)
    print(json.dumps(summary,indent=2))


if __name__=='__main__':main()
