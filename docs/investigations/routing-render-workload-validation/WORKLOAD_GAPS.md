# Workload facts, modeled assumptions and remaining approvals

7 November 2026 MYT. This stage uses **user-authorized provisional synthetic cases**, not new authoritative operational facts. No DEV database, live journal or credential was accessed. No SQL grant/table or journal redesign was implemented.

| Topic | Evidence available offline | Still needed before an operational capacity claim |
| --- | --- | --- |
| Pickup counts | Frozen v3.3 sample/adapter and user-requested 3/10/25/100 provisional cases | Approved actual demand distribution or an explicit supported product/demo envelope; provisional counts are not empirical typical/maxima |
| Fleet | Existing benchmark 100 kg car / 500 kg van templates, replicated to 2/2/5/10 vehicles | Real selected fleet sizes, capacities, costs, duration limits, vehicle eligibility/depot/hold facts; no deployed maximum fleet was inspected |
| Tasks versus locations | Modeled 3/10/25/100 tasks use 4/11/26/100 required nodes | Confirm actual co-location/unique-node patterns; 100 distinct pickup nodes plus a depot would exceed the local source's 100-node matrix cap |
| Task types | All modeled pickups are direct donations with benchmark weight/window patterns | Representative hub/batch/inventory joins, member counts/body sizes and mixed-source cases if required for the demonstration |
| Road graph | Historical sealed 926,414-node / 2,145,828-edge export, original manifest/hash and prior approved probe | Separately authorized current manifest/configuration confirmation before deployment; no new graph download is needed for these offline tests |
| Geography | Public benchmark coordinates matched by OSM node ID, one selected depot, known mutually reachable nodes inside a modeled 17 km circle | Real locality/longest-road-detour expectations; benchmark coordinates were not rechecked against current DEV coordinates |
| Cross-version road IDs | One of three benchmark depots is absent from the historical graph; the original chosen depot has only 77 matched nearby nodes; the selected alternative has 223 | Do not assume all v3.3 road IDs map to the operational graph. A verified mapping or explicit modeled replacement is required where IDs differ |
| Policy | Original synthetic E4 10-minute service, optional pickups, 240-minute horizon, 30s solver wall cap, deterministic 0.25s/pass, one worker, seed42 retained | Current actual policy ID/digest, mandatory/optional rules, service/availability/dispatch/freshness rules and solver budgets. The benchmark policy is not asserted to be DEV's policy |
| Snapshot envelope | The actual saved-result compatibility capture is partial; complete benchmark phase-A inputs exist | For trusted integration: real captured snapshot/request/NGO/policy IDs, cutoff, sealed_at, digest and matrix linkage from an approved source, or a separately reviewed disposable-DB fixture |
| Matrix envelope | Exact full-graph costs and local matrix hashes are measured | Trusted matrix UUID/digest/graph links for `prepare_bundle`/work-item tests; these were not fabricated from local hashes |
| Candidate/attestation/authorization | Offline plans have `dispatch_authority_issued=false`; independent plan checks run separately | Real protected reader/attestation/authorization acceptance needs its own approved test. No database receipts were minted or inferred |
| Sanitization | Benchmark entities and public road data; no raw DEV capture copied into cases | Data-owner approval for any operational derivative, permitted location handling, consistent ID remapping, preservation of joins and constraint-relevant timing/loads, source/derivative seals and retention. Changed bodies must not retain claims of an original DB digest |
| Headroom | Actual Docker memory/CPU caps, process/cgroup counters and single-run timings | Cold file-cache behavior, repeated/P95/concurrent workload and provider-specific CPU/IO/network overhead. The 30% RAM reserve + 72 MiB cold-artifact allowance and 120s process target are explicit review assumptions |
| Validator | Separate raw-input plan validation, including correctly unusable solver outcomes | Actual private source work-item shape, DB joins/digest/freshness checks, TLS/role/network/attestation overhead; raw validation alone is not full trusted-service qualification |
| Recovery | Previously measured synthetic Linux-volume SIGKILL/restore and original-UUID replay | Named operator, current approved real baseline/off-service backup, isolated restore and actual provider disk check. No real backup was inspected/copied here |
| Public access | Existing Linux images/API contracts and default-disabled startup tested previously | Verified HTTPS/proxy ingress, scoped runtime secrets/CA, existing DEV role/grant/network preflight, hosted URL APK and separately approved physical-device acceptance |

## Provisional case construction

The user explicitly asked to proceed with provisional workload sizes. `WORKLOAD_MANIFEST.json` keeps `operational_approval: null` and `observed_real_world_demand: false`. Fleet replicas, task copies, locality, inherited synthetic dates and local state-token hashes are openly modeled. `source.kind=SYNTHETIC_BENCHMARK` and `project_ref=null` prevent a claim that these are operational database snapshots. No missing DB envelope field was guessed.

The full graph is not cropped. Mutual reachability and the 17 km coordinate radius select known public workload locations; every matrix still searches all graph edges with unchanged distance/time/tie rules. The complete selected 100-node matrix was checked against the legacy implementation. Only the benchmark trust/provenance wrapper differs; numeric costs and the frozen graph version do not.

The first preparation failed safely because its chosen depot lacked enough known in-radius nodes. That failed attempt is retained. The second run evaluated the existing sample depots, selected the one with the largest available valid pool, and recorded the decision. No missing road coordinate or live NGO fact was invented to make the desired node count pass.

## What the next approval should cover

For a near-term demonstration, approve a **bounded scope** (for example at most ten direct pickups, two eligible vehicles, known local geography and the actual reviewed operational policy), then complete the provider ingress and recovery/role/network preflight before any deployment. This is not a new deployed API cap: no production admission rule changed.

If larger loads are required, separately review the solver-budget policy and repeat offline tests with explicit budgets while preserving the objective, correctness and freshness/lease protections. A no-incumbent timeout is not proof of infeasibility and must not be converted into an authorized baseline route. More RAM alone does not establish that the existing deterministic search budget supports 25 or 100 pickups.

For a zero-recurring-compute-cost requirement, first confirm a maintained university VM. A PostgreSQL journal replacement for Render Free is a separate design/implementation approval, not permission implied by these modeled benchmarks. See `ROUTING_HOSTING_RECOVERY_OPTIONS.md` for the design-only comparison.
