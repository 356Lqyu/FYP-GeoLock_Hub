# GeoLock Hub — three-day completion plan

**Audit date: 26 October 2026, Asia/Kuala_Lumpur. Overall: PARTIAL.**
Plan assumes working days **26–28 October**; confirm the actual submission cutoff
at the first approval. Estimates are engineering estimates, not measured promises.
It assumes two contributors with 8–10 focused hours/day plus unattended compute.
One contributor cannot credibly finish every remaining track in that window;
use the fallback and obtain explicit supervisor agreement on reduced claims.

**Decision:** stop repeating completed investigations. Reuse B.2/B.3/B.4.3 evidence.
Run software integration, offline evaluation and writing as independent lanes.
No implementation, tests, database connections or experiments were executed for
this audit. The only new deliverable is this plan. Existing dirty/untracked work
was inspected, not reset, reformatted or overwritten.

## 1. Readiness audit: what actually exists

PASS below means the cited component passed in its stated scope. It never means
that the entire current Flutter/Supabase deployment has passed acceptance.
BLOCKED means a prerequisite prevents progress; NOT RUN means no execution
evidence. Expected business rejection can be a passing test; it is not a system
FAIL. Retain confirmed rollback ERROR receipts separately from uncertain network
outcomes. Do not add historical suite counts together as current-stack coverage.

| Area | Implemented / reusable | Actual evidence and remaining gap | Readiness |
|---|---|---|---|
| Flutter authentication/onboarding | `frontend/geolock_hub_app/lib/auth/{auth_controller,auth_pages,auth_navigation}.dart`, `main.dart`: sign-in/up/reset, pending role registration, session/account-change guards, role routing | Source present and role/UI tests exist. Supabase Auth/email redirects, new-account onboarding and account-switch behavior in a current integrated build are **NOT RUN in this audit**. NGO location/readiness is required after login. | Implemented; authenticated acceptance incomplete |
| Donor | `donation_pages.dart`, `dashboard_pages.dart`: photo-backed creation, weight/classification, availability, eligible hubs/reservation, cancellation, history/status/photos | Stage B actual PostgreSQL direct creation/claim/pickup evidence; Flutter creation/photo/status tests exist. Actual app + Auth + Storage + current database flow has not been jointly accepted. | Implemented; integration incomplete |
| NGO | Discover/details, claim/request replay, claim cards, reconciliation, fleet, candidate comparison, route authorization/detail, start/complete/depot closure | Stage B direct SQL workflow passed; B.3 solver/pipeline passed; B.4.3 fixes current claim lock contention locally. Missing reviewed deployed pickup boundary, configured worker/validator and authenticated app-to-backend acceptance block an integrated pickup claim. | Strong local components; integrated route pickup BLOCKED |
| Hub administrator | Register hub; reservation/receipt/inventory; whole-donation batching/publication/detail pages; corresponding SQL RPCs | Source exists. Current composed-stack whole-batch receipt → claim → authorized route → all-member collection is not established by B.4.3's 18 tests or C.5. | Implemented; full whole-batch acceptance NOT RUN |
| Supabase schema/functions/RLS | Historical migrations through 20261031, private fleet/routing schemas, protected lifecycle/audit/failure receipts | Local catalog/role tests support components. C.1/C.3 contain **user-run historical DEV observations**, not a fresh query here. Ledger/history is unknown; full gateway-based RLS/Auth/Storage parity remains unverified. | Partial; no deployment approval |
| Stage A authority | Reviewed `docs/stage8/stage-a/forward-migrations/20261101...`, `20261102...`, `20261103...`; database task permits, bookings, reconciliation/legacy bridge | Local Stage B direct path passed. C.3 reports 001/002 function/table parity on supplied observations. C.1 reports 003 helpers/read APIs and task-authority trigger absent, pickup ACL mismatch; do not replay first-install 001/002 into existing schemas. | Implemented/local evidence; in-place upgrade BLOCKED |
| Routing optimization/reproducibility | `backend/routing/phase_b`, `integration`, `worker_service`: actual RoutingModel, FCFS/Nearest-Next/distance-only, matrix builder, independent validator, durable journal | **B.3 CLOSED:** 24 runs, 24 valid reports (21 feasible/3 infeasible), 98 regression tests; corrected 60-run replay stable. Guard unchanged. Policy proposal remains **NOT ACTIVATED**. No need to rerun B.3. | PASS for closed local scope; formal corpus still NOT RUN |
| B.2 spatial corrections | Reviewed `docs/stage8/stage-b2/forward-migrations/20261104_spatial_endpoint_validation.sql` | **69 PASS locally** with real PG17.11/PostGIS3.6.2/pgRouting4.0.1. Historical supplied DEV versions are PostGIS3.3.7/pgRouting3.4.1; helper privileges differ. Patch not approved/deployed here. | PASS locally; version/ACL/deployment gate open |
| B.4.3 concurrency correction | **Candidate 2** `docs/stage8/stage-b4-3/migrations/20261105_b43_claim_and_donation_lock_no_key_update.sql` changes two claim-path locks | **9/9 schedules**, 51 requests, 9 winners/42 conflicts, zero observed deadlocks/duplicates; **18/18 regressions**, including route SQL negatives and both start/recovery orderings. Candidate 1 is preserved **FAIL**, not deployable. No full 50-trial-per-condition experiment yet. | PASS for bounded local scope; not deployed |
| C.5 compatibility | `supabase/tests/stage8_stage_c5_isolated_test.py`; C.4 upgrade design; prepared normal-user environment smoke | Latest attempt: **0 PASS / 1 FAIL / 0 BLOCKED / 37 NOT RUN**. Startup token error 87 occurred before SQL. Lane readiness is ENVIRONMENT BLOCKED, not proof 003 failed. Some of 38 registered cases still lack handlers; assembly coverage and metadata checks also need completion. No smoke result directory found; smoke is prepared, not passed. | BLOCKED; implementation and execution incomplete |
| Experiment datasets | `benchmark dataset/dataset/{generation_manifest,validation_summary}.json`; directed matrix; original baselines; `ai hub ranking/data split/split/split_manifest.json` | Manifest reports 2,000 hub groups, 150 claim-coordination scenarios, 100 lease cases, 100 aggregation templates and 100 route cases. Split is 1368/295/337. Existence/metadata inspected; content hashes must be rechecked at execution. Baseline result folders are historical, not new paired results. | Inputs reusable; current formal evaluation NOT RUN |
| AI hub ranking | Geographic split and feasible-hub/weighted-reference baseline inputs | `ai hub ranking/README.md` explicitly says training code will be added; no trainer/saved model found in inspected project paths. A split is not a trained model or AI demonstration. | INCOMPLETE; independent of C.5 |
| Experiment controllers | Existing `claim_concurrency_test.py`, B.4.3 fixture/race seams; `backend/routing/benchmark_v32/{adapter,runner}.py`; baseline scripts | Formal claim/recovery controllers and common aggregation/AI evaluator missing. Routing settings remain `approved:false`; margin/admission need review (documented 499 admitted tasks/100 snapshots). Runner currently imports the real `phase_b.proposed`; README's CP-SAT description is stale. Do not replace the optimizer based on that stale prose. | Partial; freeze and approval required |
| Flutter/backend transport | Real repositories/RPC names; worker HTTP client, role-separated planner/validator, snapshot journal | Worker defaults disabled. No current real Auth/PostgREST/Storage/local gateway acceptance or complete Flutter integration driver found. Debug loopback HTTP is allowed for the worker, but Flutter's Supabase configuration remains project-restricted; local Auth adaptation is not automatic. | Integrated execution NOT RUN; infrastructure gap |
| FYP documentation | Existing report `C:/Users/User/Downloads/RSW_LimQianYu_LowSusan_FullText.docx`, reference contract, detailed stage reports/readiness matrices | Main DOCX exists (filesystem timestamp 10 October); its final Chapter 5 content was not revalidated here. Stage documents contain engineering results, not formal experiment results. Word methods/results/limitations must be reconciled with the current implementation. | Draft/reference available; final submission incomplete |

### Source anchors used for this audit

- [B report and evidence](stage8/stage-b/REPORT.md), `results/stage-b/verification.json`: 31 real PostgreSQL tests, 67 Flutter tests and analyzer PASS in that historical scope, with external adapters.
- [B.3 closure evidence](../results/stage-b3/final-verification-02/results.json) and [report](stage8/stage-b3/REPORT.md): reuse; policy remains inactive.
- [B.4.3 report](stage8/stage-b4-3/REPORT.md), `results/stage-b4-3/verification.json`: supersedes earlier B.4.1 deadlock/start-first gaps only for its tested cases.
- [C.1 supplied observations](stage8/stage-c1-manual/RESULTS.md), [C.3 supplied catalog comparison](stage8/stage-c3/RESULTS.md), [C.4 design](stage8/stage-c4/UPGRADE_DESIGN.md).
- [C.5 actual results](stage8/stage-c5/RESULTS.md), [prepared smoke](stage8/stage-c5/ENVIRONMENT_SMOKE.md), `results/stage-c5/nonparity-attempt-01/results.json`.
- [Existing experiment protocol](stage8/stage-a/CHAPTER5_READINESS.md), [current routing readiness](stage8/stage-b3/CHAPTER5_ROUTING_READINESS.md), `backend/routing/benchmark_v32/README.md`, `ai hub ranking/README.md`.

## 2. Critical path and approval gates

**Integrated demo:** usable approved test host → complete C.5 executable assembly/
compatibility checks → reviewed upgrade path → separate explicit DEV execution
approval (if DEV is chosen) → backend/worker/validator readiness → authenticated
direct pickup → whole-batch path → recorded rehearsal.

Do not confuse the environment smoke with C.5 PASS. The existing 003 is the
unchanged first candidate in a verified disposable baseline. Intended tested
order is baseline/001/002 → 003 → B.2 → B.4.3 **Candidate 2**. Applying Candidate 2
first can invalidate earlier source guards. Existing DEV schemas require an
in-place upgrade design, not blind replay of 001/002 or `migrate up`. B.2's
service-role privilege mismatch must be resolved through a reviewed package,
never by silently changing guards or adopting observed fingerprints.

**Independent evaluation path:** freeze data/metrics/approved configuration →
additive offline controllers → authorized disposable/offline experiment runs →
validated raw results → tables/plots → Chapter 5. This path need not wait for a
DEV deployment. Database-based claim/recovery tests still require a usable owned
disposable PostgreSQL host. UI acceptance and scientific evaluation are separate.

Gates: this plan authorizes neither implementation nor execution. Next batch
needs user approval; formal experiment protocol/execution needs explicit approval;
any DEV query/change, fixture, migration or worker activation needs separate scope.
Never access the shared project. Existing historical/overdue records and live
preflight guards remain untouched. No runtime safety/authority bypass is a fallback.

## 3. Prioritized remaining tasks and estimates

Effort is focused person-hours; compute/wait is additional. Parallel rows overlap;
the upper estimates do not all fit 72 hours. Gates and scope cuts are mandatory.

| ID | Priority / task | Effort / hard limit | Dependency / completion criterion |
|---|---|---|---|
| T0 | **P0** Assign file ownership, freeze inputs/evidence and exact deadline/demo scope | 0.5–1 h | No destructive git operations. One owner per shared file; changes additive in new run folders. Agree which RQs remain submission claims. |
| T1 | **P0** One environment-only decision | 30–45 min maximum | After approval, use the already prepared normal-user smoke once, or an already available supported host. Record result; no sandbox bypass, privilege changes, new WSL/Docker installation marathon or repeated retries. |
| T2 | **P0** Complete and run critical C.5 compatibility coverage | 6–10 h; decision by Day 1 hour 6 | Requires T1 PASS and C.5 owner's coordination. Finish handlers/assembly evidence, exact contracts/ACLs, unchanged 003, negative rollback, legacy/writer locking and correction order. No passing declaration from scenario registration/counts alone. |
| T3 | **P0** Review upgrade/rollback and backend acceptance prerequisites | 2–4 h + user review | Only after relevant C.5 evidence. Separate reviewed artifact and approval; no automatic deployment. Verify versions, privileges, task cutover state and worker/validator boundary. If gate fails, integrated DEV demo is NO-GO. |
| T4 | **P0** Current Flutter regression/build and one authenticated direct route pickup | 3–5 h | Build/widget checks can start independently. Real end-to-end part depends on T3 and approved test identities/fixtures/worker. Verify committed COLLECTED, CLOSED, COMPLETED and depot-return booking release. No direct-pickup bypass. |
| T5 | **P0** Whole-hub-batch happy path plus one rollback/authorization negative | 3–5 h | Coordinate existing B.4 owner; reuse hub RPCs and fixtures. Receipt → publish → one claim/task/lease → authorized hub pickup → all members collected atomically. Required if aggregation remains a system claim. |
| T6 | **P0** Common experiment manifests/preflight and append-only output adapters | 3–5 h | Independent of DEV. Hash data/split/source; align admission, margin, units and actual RoutingModel metadata. Leave teammate baseline/data folders unchanged; no `approved:true` or policy activation without review. |
| T7 | **P0 if RQ1 retained** RF/XGBoost trainer and heldout evaluator | 6–10 h + measured training time | Reuse frozen split/reference features. Training-only search and grouped CV; select on validation, evaluate 337 test groups once. Never train on test labels or call a rule score learned AI. No trained model currently exists. |
| T8 | **P0** Current-version disposable claim/recovery formal controllers | 4–6 h + 2–4 h execution allowance | Reuse Candidate 2 and B.4 fixtures; real local transactions/distinct actors. Separate unsafe baselines in disposable DBs only. Source-pin outcomes/retries, actual trial counts, timings and audits. Does not establish DEV parity. |
| T9 | **P0** Routing/validation and matched aggregation evaluation | 3–5 h preparation + 1–4 h compute | Reuse existing path builder/baselines/validator. Freeze 100 snapshots and 100 matched original-donation scenarios; no changing operational 10 kg policy to simulate counterfactual direct collection. |
| T10 | **P0** Chapter 5 automation, report reconciliation and demo recording | 6–8 h spread across all days | Raw outcomes first; automatic tables/plots with units/denominators, limitations and reproducible commands. Review screenshots against tested build and distinguish local/manual/mock evidence. |
| T11 | **P1** Additional Auth/Storage/email, cross-role RLS and lifecycle negatives | 2–4 h | Beyond core identity/ownership denial already essential in T4/T5. Address serious failures before demo; record remaining permutations as NOT RUN. |
| T12 | **P2** UI polish, broader stress corpus, new model-serving endpoint, cross-platform replay, exact-version runtime installation | Defer | Do not consume the critical path unless all P0 gates are met. New AI serving is optional only if not claimed as a completed system feature. |

## 4. Day-by-day milestones

### Day 1 — unblock or choose the fallback; freeze study design

- **Hour 0–1:** T0 ownership/scope and T1 one-shot host decision. Keep B.3 closed.
- **Hour 1–6, lane A:** T2 compatibility handlers and tests on an approved usable
  host. Flutter analyzer/widget/build checks run independently of database startup.
- **Hour 1–6, lane B:** T6 dataset/split integrity, paired-method preflight and
  T7 trainer/evaluator implementation. Start report methods/evidence matrix now.
- **Hour 6 hard gate:** if C.5 cannot establish required compatibility, stop the
  integrated-deployment path for this deadline; activate the limited fallback.
  Do not spend Day 2 on Windows token diagnosis. Even a startup PASS does not
  clear missing C.5 fixture handlers or parity checks.
- **End-of-day deliverable:** executable build evidence; explicit integration
  GO/NO-GO; approved or pending experiment manifest; reproducible data preflight;
  model training pipeline or an explicit RQ1 scope blocker. No invented results.

### Day 2 — execute approved evaluation; prove the selected demo

- **Lane A:** if compatibility and separate approvals pass, complete T3/T4,
  then T5. Otherwise produce the explicitly separated local/UI fallback artifacts.
  Reuse B.4.3 race/negative evidence rather than repeating its diagnosis.
- **Lane B:** execute only approved T7–T9 evaluations. Keep independent raw run
  directories, failure receipts and immutable configuration. Train/validate before
  opening the heldout test evaluation. Freeze models before reporting test scores.
- **Writing lane (both contributors in short handoffs):** fill Chapter 5 from
  generated tables, document test environment and distinguish engineering tests
  from experiments. At the end of Day 2, mark missing studies NOT RUN and freeze
  scope; do not fill gaps with B.3 toy runs or historical baseline numbers.
- **Milestone:** evidence-backed direct demo (or labelled fallback), whole-batch
  result if available, raw evaluation outputs and draft results/limitations.

### Day 3 — finish, verify and submit

- Morning: T10 tables/plots, paired statistics, actual counts, source/run hashes,
  final Word narrative and requirement traceability. Fix only demonstrated P0
  defects; do not introduce new architecture or change study policy.
- Midday: rehearse the exact build/data/role accounts; capture demo video and a
  backup walkthrough. Keep offline evidence available if network/auth fails.
- Last 4 hours: feature freeze. Check PDF export, figure/table references,
  bibliography, limitations, reproducibility instructions and submission files.
  No risky migrations, new installations or experiment reruns for nicer outcomes.
- **Milestone:** tested submission artifact, demo recording, raw evidence index,
  clear PASS/FAIL/BLOCKED/NOT RUN ledger, known limitations and recovery instructions.

## 5. Parallel work and ownership

| Lane | Can start without C.5? | Work / ownership boundary |
|---|---|---|
| Backend compatibility owner | Environment decision first | Own C.5 harness/upgrade review. Coordinate with existing B.4/C.5 contributor before editing. No other writer touches those files. |
| Flutter owner | Yes for analyze/widgets/build | Own `donation_pages.dart`, auth/routing screens and integration driver. Delay genuine end-to-end assertions until backend approval; never fake a production success. |
| Evaluation owner | Yes for offline data, AI and routing prep | Add new experiment wrappers/manifests outside teammate baseline/model sources. Claim/recovery runtime needs a disposable DB; hub/route/AI analysis does not need Supabase. |
| Report/evidence owner | Yes, immediately | Read-only raw artifacts → tables/figures and Word draft. Avoid concurrent edits to the same DOCX; use section handoffs. Sanitize credentials, JWTs, names/addresses and exact personal coordinates. |

With only two people, combine backend+Flutter serially in lane A and evaluation+
writing in lane B; do not pretend four full-time lanes exist. Schedule heavy
model/solver jobs to avoid unnecessary timing interference. Separate policy
approval, environment wait and compute time from engineering effort.

## 6. Minimum viable system demonstration

**Target integrated demonstration (conditional on gates):**

1. Real login and server-enforced donor/NGO/hub-admin roles. At least one ownership
   denial and no stale session evidence exposed after account switching.
2. Donor creates a photo-backed 20 kg direct donation; eligible NGO discovers and
   claims it; one ACTIVE claim/360-minute lease/CONFIRMED task is committed.
3. Valid vehicle/depot → fixed matrix/snapshot → RoutingModel candidate → independent
   validation → explicit NGO authorization. Planning alone never enables pickup.
4. Start → complete → donation COLLECTED, listing CLOSED, claim/lease COMPLETED;
   confirm depot return and release bookings. Show corresponding scoped audit IDs.
5. Hub branch: three compatible small donations, e.g. 3 × 4 kg, protected hub
   reservation and receipt, one published whole batch, one NGO claim/task and
   all-member collection through the same authority path. Show inventory/capacity.

Reuse existing screens; new visual polish is unnecessary. Do not simulate six
hours of natural expiry by editing live timestamps. Recovery/concurrency belong
in separately labelled disposable tests. If a feature is only a local SQL test
or mocked UI, label it that way; it cannot complete the integrated demonstration.

## 7. Minimum defensible Chapter 5 evaluation

Eight readiness areas consolidate into **four report experiments**, not eight
new research projects. Preserve the report's sample requirements unless the
supervisor explicitly approves a narrower design. All eight formal areas remain
PARTIAL today; dataset rows and regression cases are not completed trials.

| Experiment / areas | Minimum evidence for the retained claim | Reuse / execution budget |
|---|---|---|
| E1 — feasible-hub ranking (D/E) | Same feasible groups/reference for learned model and Nearest/seeded Random; actual 337 heldout groups, no geographic leakage; Top-1, NDCG@3, coverage and runtime. Current report design: RF/XGBoost, 30 configurations/family, training 5-fold GroupKFold, validation selection before test. If reduced to one model, obtain an explicit methodology amendment. | Existing 1368/295/337 split and baseline outputs are inputs, not trained-model results. New trainer/evaluator required. Time-box pipeline work; report AI NOT RUN if it cannot finish honestly. |
| E2 — atomicity/geographic eligibility/lease recovery (A/B/C) | 2/5/10 distinct eligible NGOs × 50 independent trials per condition; if three conditions retained, 450 contention trials. Separate 100 lease cases. Count committed winners/conflicts/rollback/unknown outcomes, duplicate-authority rate, latency and audit invariants. Use controlled geographic oracle cases, including preserved real B.2 boundaries. | Adapt current Candidate 2 harness and protected RPCs in disposable infrastructure. Never run old unsafe baseline scripts against DEV/shared. Existing 9 schedules are supporting verification, not the formal trial population. |
| E3 — hub aggregation vs direct (F) | 100 matched original-donation scenarios; same fleet/depot/matrix/downstream solver; NGO km, donor km, trips/cost index and membership/capacity invariants. Counterfactual direct collection is offline only. | Existing templates/direct baseline; current paired proposed controller missing. Label simulation/benchmark evidence separately from protected whole-batch workflow acceptance. |
| E4 — constrained routing plus independent validation (G/H) | 100 immutable snapshots, primary Nearest-Next vs RoutingModel; FCFS/distance-only supplementary. Compare coverage first, then km, durations, cost index and runtime; retain all invalid/infeasible/timeout outcomes. Every output independently validated; strict reproducibility guard remains active. | Existing adapter/runner and B.3-corrected optimizer. 100 × 30 s ≈ 50 min primary search per repeat; three repeats ≈ 2.5 h, plus baselines/validation. Repetition policy still needs approval; B.3's inactive proposal does not authorize a change. |

If all four claims cannot be evaluated, deliver completed E2/E4 studies where
infrastructure allows, deterministic hub comparator results where valid, and
honestly documented E1/E3 gaps. That is a **reduced evaluation**, not completion
of the original four-RQ specification. Obtain supervisor agreement and amend
claims; do not silently reduce samples, substitute baselines for AI, or reuse toy
diagnostics as empirical results.

Raw run requirements: immutable manifest and input/source hashes, original
responses/plans, unit-labelled metrics, validator reports, request/transaction/
audit IDs where relevant, timings and independent-unit counts. Pair by scenario;
use the existing paired/statistical protocol and report uncertainty. Technical
repeats are not additional independent scenarios. Do not cherry-pick best routes
or discard failures. Cost indices are not measured RM. No formal run is approved
merely by writing this plan.

## 8. C.5-blocked fallback and stop rules

After the 45-minute environment cap, do **not** install a new container runtime,
change Windows security controls or continue token debugging. If an already
available teammate/normal-user supported host can run the reviewed procedure
within the cap, request that scoped execution; otherwise preserve BLOCKED.

If C.5 is still incomplete at the Day 1 hour-6 gate:

- No DEV upgrade, live route pickup or worker activation. Keep unchanged guards,
  permissions and backend-enforced pickup restrictions.
- Demonstrate the Flutter build and its tested fail-closed screens separately
  from recorded real local SQL direct-pickup/spatial/concurrency evidence and the
  offline routing demonstration. Label mocked/injected UI data explicitly.
- Use already completed B.2/B.3/B.4.3 evidence with their original versions,
  hashes and limitations. A prior local pass does not fill C.5 NOT RUN rows.
- Continue independently approved offline E1/E3/E4 work. Run E2 only on a usable
  approved disposable host; otherwise retain historical engineering evidence
  and mark the formal E2 study BLOCKED/NOT RUN.
- State plainly that this fallback is **not a fully integrated system demo**.
  Record the unmet integration requirement and seek supervisor acceptance of a
  reduced deliverable. No safe shortcut can turn missing acceptance into PASS.

## 9. Completion and first approval batch

Submission is complete only when the tested build/demo, raw-results index,
scope-correct Chapter 5, methods/implementation reconciliation, final PDF and
known-limitations ledger are delivered. Claim "integrated system complete" only
after the real role/Auth/Storage/worker/database path above passes on the chosen
approved backend. Claim each experiment complete only when every planned unit
has an outcome, all acceptance/validation checks pass and completion manifest is
written. Partial runs retain their actual counts. The broader Stage B remains
PARTIAL until its unresolved acceptance requirements are met.

**Proposed Batch 1 for approval: a four-hour local automation/build batch.**

1. Assign owners and record a read-only source/evidence/data manifest in new
   deadline-owned paths; preserve all stage/baseline outputs (30 min).
2. Execute at most one separately approved, prepared normal-user environment
   smoke; otherwise spend no more than 45 min assessing an already available
   local host. Record the branch decision; no C.5 migration execution in this
   first batch and no security-context bypass (45 min cap).
3. Implement the additive common experiment manifest/evidence writer and a
   minimal paired heldout-ranking evaluator, with synthetic unit tests. Include
   a read-only preflight for split/data hashes and missing model/runner inputs;
   expose unapproved routing margin/admission settings and C.5 coverage gaps.
   This is reusable T6 implementation, not another proposal. Do not edit
   teammate-owned sources, train models or produce formal scores yet (90 min).
4. Run current Flutter analyzer, selected existing widgets and an offline build
   if cached dependencies permit; capture real PASS/FAIL/BLOCKED outcomes. No
   launch with live credentials and no new gateway implementation (45 min).
5. Return the concrete Day-1 GO/NO-GO, ownership assignments and next code batch
   (C.5 completion on a usable host **or** offline evaluation-controller work),
   plus any required protocol approval (30 min).

New automation can live under `scripts/fyp_deadline/` and
`experiments/fyp_deadline/`; exact paths/ownership are confirmed before coding.
This first batch produces actionable readiness and a build without another long
environment investigation. The subsequent controller/trainer/integration work
needs an approved implementation scope; DEV execution and formal experiments
retain separate explicit approval gates. **Stop after this audit/plan for review.**
