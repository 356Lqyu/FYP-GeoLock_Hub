# Stage B.3 — RoutingModel reproducibility investigation and verification

**COMPLETE within the approved local B.3 scope.** Broader Stage B remains PARTIAL.
This is diagnostic verification, not Chapter 5 results or deployment acceptance.
The interrupted work was resumed from saved artifacts; no 30-second experiment
was repeated during finalization. No Supabase/MCP connection, deployment,
migration execution during resume, production worker, live fixture or cron
change occurred. B.4 and Stage C files/work were not modified.

## Confirmed root cause

The preserved historical exception is in
`results/stage-b/python-routing-tests-final.log`: the offline benchmark rejected
`phase_a/mixed/proposed`. It was not a live worker error. That historical log did
not retain the original two raw plans; B.3 reproduced the same failure condition
with uncorrected source and preserved all new raw plans.

Across **60 warm-process 0.2-second executions**, only Plan.timeout differed:
**45 true, 15 false**. Snapshot/matrix hashes, route stop order, vehicle assignment,
objective, distance, duration, native-result metadata other than timeout, and
independent validation stayed identical. There were two strict semantic hashes.
The original source calculated `perf_counter() >= deadline` after extracting and
rebuilding the route. Millisecond-rounded native search budgets and variable
post-search Python work could put the reporting instant on either side of the
outer deadline. The guard includes timeout while excluding the two runtime
fields, so this reporting variation triggered NONREPRODUCIBLE_RESULT.

Twenty separate fresh-process short runs also preserved routes/metrics but did
not reproduce semantic variation. This distinction is retained rather than
presenting every execution mode as a failed replay. The matching warm-process
reproduction and controlled reporting tests isolate the confirmed defect.

## Targeted correction

`backend/routing/phase_b/routing_model.py` now reads RoutingModel.CheckLimit()
immediately after search, records native timeout status and derives timeout from
those observations. Route extraction cannot retroactively turn an early search
into a timeout. A mandatory coverage pass's one-solution stop is distinguished
from a time-limited secondary/optional-coverage pass. Proven infeasibility is not
reported as timeout. The exact diff is saved in
`results/stage-b3/final-verification-02/timeout-correction.diff`.

No objective coefficient, constraint, input order, matrix, strategy, search
budget allocation or Plan/candidate schema was changed. Existing two-pass
coverage-first then fixed-plus-distance behavior remains. No additional tie
penalty, solver switch or unsupported seed/work-budget mapping was introduced.

The corrected **60-run warm replay has one semantic result**, with identical
routes, metrics and validation. Regression tests separately control native-limit
metadata and post-processing clock movement; these controlled tests are not
presented as measured 30-second performance evidence.

## Repeated 30-second verification

Eight frozen synthetic fixtures, **three fresh Python processes per fixture**,
sequential executions, PYTHONHASHSEED=0. Three repetitions give direct diagnostic
comparisons without exceeding a 12-minute nominal search ceiling; they are not
enough for a narrow stability estimate or universal determinism claim. Actual
source hashes, ordered inputs, matrices and full native parameters are retained.
The matrices come from the existing directed graph/path builder using declared
synthetic edges, not real OSM measurements or live road data.

OR-Tools **9.15.6755**, Python 3.12.14, Windows 11. Primary engine is RoutingModel
native single-threaded CP with CP-SAT/generalized fallback disabled;
PATH_CHEAPEST_ARC and GUIDED_LOCAL_SEARCH. Each input declares a **30-second total
per-snapshot budget**, 240-minute vehicle/horizon limits and 10-minute stop service.
Actual native pass budgets share the remaining snapshot budget and are recorded,
not reset to 30 seconds per pass. Declared seed 42 is not a supported native
RoutingModel seed setting and is not claimed to have been applied. Legacy CP-SAT
deterministic_seconds_per_pass is not mapped into this engine.

| Scenario | Executions | Served tasks | Distance km | Sum route duration min | Secondary cost units | Observed elapsed seconds | Termination |
|---|---:|---:|---:|---:|---:|---|---|
| One vehicle, one pickup | 3 | 1 | 4.5 | 19 | 9.5 | 0.0426–0.0698 | Early |
| One vehicle, multiple pickups | 3 | 2 | 11 | 42 | 16 | 30.0210–30.0418 | Search limit |
| Multiple vehicles/pickups | 3 | 2 | 15.5 | 51 | 17.5 | 30.0215–30.0354 | Search limit |
| Capacity constrained | 3 | 2 | 15.5 | 51 | 29.4 | 30.0260–30.0287 | Search limit |
| Time-window constrained | 3 | 2 | 11 | 45 | 16 | 30.0256–30.0305 | Search limit |
| Infeasible capacity | 3 | 0 | N/A | N/A | N/A | 0.0471–0.0570 | Proven infeasible, early |
| Directed road distances | 3 | 2 | 7 | 34 | 12 | 30.0269–30.0334 | Search limit |
| Tied/equivalent costs | 3 | 2 | 3 | 26 | 8 | 30.0311–30.0350 | Search limit |

Metrics and route/assignment order were identical within each scenario. **18 runs
reached the native search limit; six finished early.** Elapsed time includes
imports/reporting overhead, explaining small elapsed values above the configured
30-second search budget. Full raw timings are retained; none are rounded to an
invented 30.000 seconds.

All **24 independent validation reports are valid**. There are **21 feasible
plans** and **three correctly classified infeasibility reports**; infeasible
empty routes are not successful candidates or distance improvements. Secondary
optimality/gap is not asserted. Native ROUTING_SUCCESS can accompany an incumbent
at the time limit; it does not mean globally optimal or necessarily early. The
zero-cost primary coverage pass's ROUTING_OPTIMAL is not secondary-cost proof.

## Candidate serialization and digest comparison

Each scenario has one route/metric/strict-semantic result but **three distinct raw
candidate payloads and hashes**. The differing candidate fields are measured
runtime_seconds and solver_runtime_seconds. Canonical dictionary serialization,
task/vehicle ordering, graph normalization and SHA-256 were not found defective.
An explicit task/vehicle input-permutation regression preserves routes/metrics.

The actual existing PostgreSQL expression
`encode(sha256(convert_to(body::jsonb::text,'UTF8')),'hex')` was evaluated for all
24 artifacts in a new disposable PostgreSQL 17.11 cluster during the original
B.3 work. Each scenario also has three distinct PostgreSQL candidate digests.
These are genuine local jsonb hashes, distinct from Python canonical hashes;
no candidate was submitted/attested/authorized in that database. The database
is stopped: shutdown log, recorded cleanup result and absent postmaster.pid were
verified during resume. No database was started or queried during resume.

Candidate runtime telemetry remains inside the bound payload. Removing it from
the operational digest would alter the protected contract; this was **not done**.
New independent computations may therefore create different valid artifact
digests. Same-request retries instead replay the persisted exact computed payload.
Five existing in-memory-transport pipeline tests pass for lost acknowledgements,
saved response/payload replay, restart-safe journaling, tamper rejection and
planning without reservation. They use real solvers/validator with synthetic
transports, not real Auth or a live worker.

## Guard and authority preservation

`backend/routing/phase_b/benchmark.py` is **byte-for-byte identical** to its saved
pre-correction copy. The NONREPRODUCIBLE_RESULT check was not weakened, disabled,
removed or replaced with the proposed policy. Candidate/attestation binding,
independent validator and routing-worker authority code match recorded hashes.
All diagnostic plans have dispatch_authority_issued=false.

During offline resume audit, all 24 saved plans were revalidated and replayed
through the **original benchmark guard**: all eight groups passed. A separately
labelled controlled timeout mutation was rejected with NONREPRODUCIBLE_RESULT.
No optimizer executed in this audit; native SolveWithParameters was fenced to
fail if called. Replay manifests describe a replay adapter, so their engine label
is not used as native-engine evidence; the original native parameters/protocol
are authoritative for that question.

## Verification and evidence

- 93 routing/worker/reproducibility regression tests: PASS, zero failures/skips.
- Five targeted candidate-pipeline tests: PASS, zero failures/skips.
- 24 recorded native runs: all revalidated; eight strict guard groups PASS.
- 60 original warm runs: two semantic results, timeout 45 true/15 false.
- 60 corrected warm runs: one semantic result.
- PostgreSQL digest audit: all 24 payloads/text/digests match; cluster stopped.
- Recorded execution/source hashes still match the current B.3 files.

Raw evidence: `results/stage-b3/repeated-30s/`, `pre-correction/`,
`corrected-warm/`, `postgres-hashing/`, `unit-regressions.log`,
`candidate-pipeline-tests.log`, `analysis.json` and `final-verification-02/`.
The first offline finalization attempt had a protobuf parser setup error
(parsing saved fields into an already populated default object). Clearing the
protobuf before parsing fixed only the verifier; native records were not changed.
All 30-second runs and the earlier 98 tests were retained, not repeated on resume.

## Exact changed files and purposes

Modified production-side Python file:
- `backend/routing/phase_b/routing_model.py` — native timeout interpretation only.

New diagnostic/test files:
- `backend/routing/diagnostics/__init__.py` — isolated diagnostic package.
- `backend/routing/diagnostics/reproducibility.py` — frozen fixtures, fresh-process
  execution traces, raw records and short replay diagnostics.
- `backend/routing/diagnostics/policy_proposal.py` — inactive comparison classifier.
- `backend/routing/diagnostics/postgres_candidate_hashes.py` — disposable local
  jsonb digest evidence; not invoked on resume.
- `backend/routing/diagnostics/summarize.py` — comparison of retained observations.
- `backend/routing/diagnostics/finalize.py` — offline resume audit/guard replay.
- `backend/routing/phase_b/tests/test_reproducibility.py` — targeted reporting,
  ordering, hash and inactive-policy regressions.

New documents: this REPORT.md, REPRODUCIBILITY_POLICY_PROPOSAL.md,
CHAPTER5_ROUTING_READINESS.md and generated changed-files.json. Generated evidence
is indexed in `results/stage-b3/evidence-manifest.json`. Unrelated existing dirty
worktree files and other-account work are excluded from this change list.

## Policy, readiness and next checkpoint

The policy proposal is **NOT ACTIVATED**. It separates frozen inputs, pinned
execution, observed solution equality, metric distributions and independent
authorization. It proposes preserving all technical repeats, snapshot-level
paired analysis and prespecified failure handling rather than selecting the best
run. Strict byte-identical route equality is an observed result here, not a
universal promise for wall-time GLS or equivalent-cost alternatives.

The local timeout defect is closed. Formal routing experiments remain PARTIAL:
tiny synthetic corpus, only three technical repeats, representative 100-snapshot
corpus/bridge still to be approved, policy/statistical treatment not activated,
and operational integration/authority deployment not established by these runs.
The separate DEV findings supplied by the user are awareness only, not verified
here or converted into deployment approval. B.2's spatial migration remains a
reviewed local artifact; it was not deployed in B.3.

**Next checkpoint:** review the B.3 correction and approve/reject the inactive
reproducibility/statistical proposal. Any further verification must receive a
separate coordinated scope that does not duplicate/interfere with existing B.4
work. No Stage C investigation, deployment or formal experiment follows from
this completion. Stop after B.3.
