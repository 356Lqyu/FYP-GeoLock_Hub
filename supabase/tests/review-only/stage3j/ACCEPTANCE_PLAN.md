# Focused current-version acceptance plan

This is a review-only plan. No stateful DEV testing, fixture provisioning, RPC
rejection attempts, recovery, cron operation or test-code edit is authorized here.
Job 3 stays inactive. Retain all Stage 3I fixture/audit records unchanged.

## Can acceptance testing start directly?

Existing isolated/source evidence can be accepted and indexed immediately.
Live current-version multi-NGO acceptance cannot run unchanged today: only one
active NGO has verified road-node evidence; the guarded runner unconditionally
requires ten distinct JWT subjects; its delayed-lock branch has an unlock-order
defect; and there is no 50-client branch or deployment-bound result manifest.
These are narrow preparation tasks, not a reason to restart recovery development.
No production SQL change is proposed without a reproduced authority defect.

## Shortest safe execution order

1. **Reuse now.** Freeze this matrix, current function/ACL/config snapshot, 106
   passing source contracts, historical benchmark outputs and Stage 3F/3I
   results. Do not rerun migration deployment, the completed direct recovery
   experiment, or old unsafe fixture scripts. The four captured coordination
   RPC bodies exactly match DEV, making their isolated race results relevant.
2. **One bounded test-only change after approval.** Parameterize the existing
   DEV-allowlisted harness for 2/10/50 request cohorts; fix release-before-executor-
   shutdown on every normal/error path; preserve JWT uniqueness policy for the
   two/ten-NGO rounds; record 50 clients separately from distinct NGO subjects.
   Add donation/member lifecycle, listing version, eligibility generation/queue
   assertions and a sanitized result manifest. Isolate-test lock observation,
   timeout/error drainage and delayed-case INCONCLUSIVE handling. Do not weaken
   allowlists or install production delay hooks. Add the missing focused replay
   and stale-holder cases to the existing runner rather than build another suite.
3. **Provision only necessary new test actors/fixtures after execution approval.**
   Begin with a second legitimate DEV NGO through existing onboarding/location/
   asynchronous eligibility workflow; ensure every assigned actor can really
   discover its dedicated new listing. Never mark synthetic benchmark nodes or
   user locations verified by direct SQL. Five AVAILABLE listings are not five
   approved fixtures. Do not claim the retained Stage 3I listing. Start with the
   two-actor cohort, then ten; use existing legitimate sessions where feasible.
4. **Run the smallest authority acceptance bundle.** Two-actor contention plus
   same-request replay/mismatch, released-holder rejection, and normal protected
   cancellation/reclaim on dedicated fixtures. Advance to ten and fifty clients
   only after the two-actor checks pass. Use separate fresh listings per trial;
   match the historical three rounds per cohort for descriptive comparison, and
   disclose sample size rather than infer a production failure probability.
   Claim requests commit and retain history; no cleanup by arbitrary deletes.
5. **Close integration-specific gaps locally first.** Actual full-schema claim
   required-write rollback, post-commit transport loss, whole-hub transition/
   custody cases, and expiry vs Start/Complete/reconciliation. Reuse Stage 3F's
   exact-source tests and current lifecycle triggers, substituting genuine auth,
   RLS and routing dependencies only where their absence is the gap. Keep local
   failure hooks isolated; DEV installation needs separate approval and is not
   necessary simply to repeat existing reduced-schema recovery rollback proof.
6. **Collect UI and geographic evidence alongside this bundle.** Record Flutter
   build and Released/History/active-count screenshots using read-only refresh.
   Execute the teammate-agreed boundary plan against the correct graph; no
   algorithm changes. Bring verified results into Chapter 5 and the matrix.

No new approval cycle is needed for this documentation review. Future test-code
edits, DEV test fixtures and mutating test runs have not been authorized by this
task and require their own concrete scope approval. Continuous recovery remains
a separate operational decision, not a prerequisite for these claim tests.

## Acceptance cases to execute, without duplicating existing proof

| Case | Existing reusable test | Minimum new assertion/evidence |
|---|---|---|
| Two/ten/fifty client contention | claim_concurrency_test.py run_race/assert_committed_round | One committed owner/lease/task, all initial request/audit outcomes, donation and whole-batch state consistency, explicit concurrency and actor counts |
| Same UUID concurrent and sequential replay | Current digest/replay body and main replay test | Same original ID; no extra lease/task/audit/version/generation; changed NGO/listing rejected; replay after release returns historical result without reauthorizing pickup |
| Released/expired holder and new claimant | Stage 3F inherited start-after-recovery / concurrent reclaim; stage1_claim_recovery_dev_test.py test_expired_lease_rejects_pickup | Authenticated Start and Complete fail; no state/audit side effects for thrown rejection; new legitimate holder exclusively authorized on a new dedicated listing |
| Delayed contention | Current run_delayed_race and pg_blocking_pids observation | Both requests observed blocked by intended PID; release lock before waiting for completion, including error path; unavailable observation = INCONCLUSIVE |
| Response retry | Existing discarded-200-response test | Preserve this label; additionally demonstrate true after-commit response loss with controlled isolated transport and same UUID retry |
| Required claim-write rollback | Existing seven failpoint definitions | Full-schema rollback at all seven points, including donation transition/deferred checks; not durable in-transaction audit proof |
| Whole hub/custody/reconciliation | Stage 3F direct/hub matrices, lock races and existing hub runner | Real helper/trigger/RLS integration; whole member set restored or none; never reopen after custody; audit reflects final outcome |
| Geographic eligibility | Existing operational functions and teammate work | Boundary direction/snapshot/generation correctness and fail-closed behavior, independently checked expected distances |

For the stale-holder scenario, a dedicated normal protected cancellation can
create a RELEASED old holder without a new expiry/recovery experiment. This
complements the already-proved expired direct recovery; use isolated natural-
expiry/recovery fixtures for the expiry-specific race permutations. Do not renew,
backdate or manually reopen any DEV claim to save test time.

## Manifest and pass criteria

Before and after each approved future run, retain UTC server timestamps, DEV
project reference, git revision plus dirty-source hashes, complete relevant
function-body and ACL/config fingerprints, migration artifact hashes, graph
snapshot, runner hash, app build (if used), fixture mappings, NGO subject count,
request concurrency, barrier/observed DB contention evidence, request UUIDs,
HTTP outcome/SQLSTATE, latency distribution and final committed-state assertions.
Keep secrets and private photo URLs out of evidence. No result from another
project or synthetic graph is relabelled as current operational DEV evidence.

Preserve original successful and failed/INCONCLUSIVE rounds. Required outcomes:
one active owner; no duplicate artifacts; no partial donation/member transitions;
correct 360-minute valid lease; exact request-scoped successful/rejected audits;
server-side stale-holder denial; replay grants no new authority; true exceptions
roll back all required writes; road/cache failures deny authority. An audit
insert inside a failed transaction is expected to disappear. Record that failure
through trusted test-process output or an approved separate incident mechanism.

Stop on project/source/security drift, missing eligibility, unexpected historical
fixture selection, lifecycle/audit mismatch, timeout/deadlock, unexplained extra
rows or unfinished requests. Drain requests, preserve evidence and inspect; do
not retry with new UUIDs blindly or delete records to make the run pass. A fresh
listing may be consumed even on INCONCLUSIVE lock observation.

## Operational work outside this acceptance bundle

Permanent unattended recovery remains blocked on independent monitoring/alerts,
named coverage and escalation, bounded repeated-failure/starvation response,
trusted failure evidence, pause/in-flight/restart drills and normal-write
concurrency. A single SQL error rolls back the invocation; an oldest candidate
can repeatedly fail. SKIP LOCKED skips claim rows, not every later lock.
Do not redesign catch-and-continue or increase batch size under this review.
The five-minute pause receipts from Stage 3I were not available, so keep that
operational qualification in final reporting. No new cron activation is planned.
