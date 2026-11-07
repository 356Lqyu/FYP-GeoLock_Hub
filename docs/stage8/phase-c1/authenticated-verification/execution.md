# C1 verification execution handoff

The [existing 54-group plan](test-plan.md) remains the test specification. This handoff adds runnable code and one consolidated Batch B approval boundary; it does not authorize execution or recreate the plan.

**Subsequent implementation update:** the user has conditionally approved Batch B; it remains blocked and no DEV writes have occurred. The old command below now defaults to provision-only. The hardened CLI takes `--mode provision|run|cleanup`, reuses one atomic synthetic fixture journal and requires recorded password-rotation and usable post-C1 recovery evidence. Interrupted test execution cannot be restarted blindly. See [the current implementation checkpoint](../../phase-c2/implementation-and-workflow.md); the original approval scope remains history, not a request to approve it again. Local C2 preparation is now authorized, while all live database stages remain gated.

## Batch A result

PASS: all 32 fresh SELECT-only DEV checks, exact 712 protected fingerprint matches, matching installed seal, zero vehicles/routes/stops/assignments. The original deployment comparator passed against the fresh pre-migration baseline. Queries were separate observations, not an atomic database snapshot.

PASS: 117 routing tests, 12 package/comparator tests, 23 new harness/catalog checks and 44 existing disposable PostgreSQL tests. The latter use a reduced schema/authentication double and are **isolated evidence only**. PostgreSQL initially could not start inside the Windows sandbox; the same loopback-only harness subsequently passed outside the sandbox. No existing database connection is accepted by that harness. All 14 freshly captured managed function bodies also match the pinned SQL after newline normalization.

PASS: 252 saved synthetic reports revalidated, 84 reproducible groups and 17 Phase A source files preserved. These remain synthetic results.

Two real anonymous read-only HTTP probes were executed: list RPC without bearer was denied with HTTP 401 / SQLSTATE 42501; invalid bearer was denied with HTTP 401 / PGRST301. This covers only part of F16. No real-user credential, authenticated NGO RPC, account creation or DEV mutation was used.

## Harness and execution

- `rpc_harness.py`: standard-library real HTTP client and stateful fleet test suite, pinned DEV origin, redirect refusal, 1,200-request ceiling, external approval gate, exact synthetic user markers, A/B ownership checks, independent service readback/audit deltas and parallel requests. Failures stop without automatic repairs. Parallel HTTP requests alone do not establish observed server lock contention.
- `provision_synthetic.py`: **Batch B only**, creates exactly five synthetic users and normal role profiles, logs in using their generated credentials in memory, establishes A/B depots through the unchanged protected resolver, makes synthetic I inactive through existing trusted rights, runs tests and performs success-path cleanup. It does not reuse existing users. Passwords and JWTs are never persisted.
- `anonymous_probe.py`: only the read-only anonymous list RPC; no session creation and no mutation RPC calls.
- `test_harness.py`: 23 offline safety/captured-catalog tests. Its fabricated unit inputs test harness gates and error assertions, never live authentication.
- `run_batch_a.py`: reproducible offline regressions/captured-catalog validation. It never executes Batch B or connects to Supabase. `--include-isolated` additionally starts a new disposable loopback PostgreSQL cluster.
- `coverage.json`: maps every original group, distinguishing prepared partial live automation, isolated coverage, actual execution and blockers. **36/54 groups have real-HTTP test code; variant coverage remains partial. Zero complete groups have passed live authenticated DEV execution. F16 has two actual anonymous list variants.**

From the repository root:

```powershell
.\.venv-stage8\Scripts\python.exe docs/stage8/phase-c1/authenticated-verification/run_batch_a.py
```

The SQL catalog export must be refreshed through the existing MCP SELECT-only postflight checks when repeating Batch A. Replaying an old export is not a new live inspection. `batch-a-live-catalog.json` and `batch-a-anonymous-results.json` are the live evidence; offline logs and `coverage.json` do not turn missing authenticated tests into passes.

Only **after explicit approval**, an operator records approval in an external copy of `batch-b-approval.example.json`, sets a new run UUID, an expiry within 24 hours and recovery readiness, and supplies `C1_PUBLIC_KEY` / `C1_SERVICE_KEY` through a secure process environment. The repository example stays disabled. The receipt records operator approval; it is not a cryptographic authorization mechanism.

```powershell
.\.venv-stage8\Scripts\python.exe docs/stage8/phase-c1/authenticated-verification/provision_synthetic.py --approval <approved-external-receipt.json> --output-directory <new-run-directory>
```

Do not run that command now. Do not paste credentials into chat or commit them. The operator must supply existing trusted service rights; denial stops execution rather than granting privileges. The suite pins the host and checks every user's trusted `app_metadata.c1_test_run` through Auth before mutations. The script is not an environment-provisioning RPC or production feature.

## One consolidated Batch B approval request

Approve one supervised DEV-only run with the following complete scope:

1. **Identities and permissions:** create five new Admin Auth users named `c1test.<new-run-uuid>.<a|b|u|i|n>@example.invalid`, confirm them without email, and mark them through trusted app metadata. Register A/B/U/I as NGO and N as DONOR using existing `register_role_profile`. No existing NGO account or credential is used. Use existing service administration rights, existing ordinary authenticated RPC permissions and the existing public API key; grant nothing new.
2. **Depot setup:** A/B use synthetic depot address text at the approved road-node candidate `28918006` (3.145694, 101.7150234), snapshot `OSM-OPS-20261018`. Revalidate its active approved coverage before execution. The unchanged `set_ngo_operating_location` resolves/verifies the node; do not directly set verified flags or accept a client node. This queues at most two initial NGO refresh jobs and may create up to 12 eligibility rows against the current six listings. U remains unverified. I is made inactive through an exact-ID trusted profile update. No real NGO/location/network row changes.
3. **Fleet tests:** create at most five explicit synthetic vehicles; edit them through the five installed RPCs, perform invalid/unauthorized attempts, idempotency/version checks and parallel registration/update/deactivation races. Values are test-only (12.345 kg, RM7.50 fixed, RM0.25/km, 90 minutes initially), never real fleet defaults. Expect ownership isolation, rejected invalid/stale requests, one-row idempotency and valid version/audit deltas.
4. **Route fixtures:** allow up to 12 exact-UUID empty synthetic route records, never more than two at once. The current HTTP suite uses seven (four active-status guard fixtures and three clean terminal-status fixtures). No stops, assignments, tasks, donations, claims or leases are created/changed. Trusted route statuses here exercise guards only and do not attest route validation/authorization. Allow targeted cancellation of empty nonterminal fixtures and deletion of their clean terminal rows as test teardown. Unexpected activity stops cleanup; never clear it by force.
5. **Persistent footprint and cleanup:** at most **20 primary retained fixture rows**: five Auth users, five user profiles, four NGO profiles, one donor profile and five vehicles. In addition, up to two refresh jobs, up to 12 eligibility rows at the current listing count, normal audit entries and Auth identity/session/log records may remain. These generated audit/Auth records are not represented as zero or given a false fixed total. No route fixture should remain after successful teardown. Vehicles are deactivated, all synthetic NGOs made inactive, sessions globally signed out and synthetic Auth accounts banned; retain all audit history and UUIDs. Already issued access JWTs can remain valid until expiry, so NGO profile inactivity and vehicle deactivation are also checked. Do not delete vehicle or Auth rows through cascades.
6. **Recovery and stop rules:** establish a post-C1 recoverable backup/checkpoint and a quiet execution window first; verify the unchanged 712 fingerprints/ACLs/seal and expected listing count. Keep a sanitized fixture ledger. HTTP commits cannot be undone by rolling back an operator transaction. Failure/timeout stops the harness for reconciliation; it performs no automatic repair/cleanup on failure. Retained rows are intentional; whole-database restore needs a separate incident decision because it can lose unrelated data and remove C1 if the old backup is used.

**Blockers/limits included in this approval:** trusted backend credentials and recovery readiness are not available/verified yet. Dedicated accounts do not yet exist. Unresolved assignment/task terminal holds (H04/H05) remain isolated-only because safe live source fixtures and protected route closure/assignment cleanup are unfinished. Live ordered route-lock races C07–C11 need an operator-controlled two-session fixture driver/lock observation; current code covers parallel fleet races and serial active-route holds, and existing isolated tests cover selected route races. Those remaining live variants are not claimed automated or passed. Depot-history/revocation cases D03–D07/C12 and stronger-isolation operator probes C13 are outside this initial HTTP runner; they remain blocked/isolated-only. Fresh cross-owner concurrent insertion, expired-token variants and other per-group boundary variants remain coverage gaps explicitly recorded in `coverage.json`.

Identity setup uses the [official Admin create-user flow](https://supabase.com/docs/reference/python/auth-admin-createuser); Auth/session cleanup limitations follow [Supabase user management](https://supabase.com/docs/guides/auth/managing-user-data). No production code, deployed migration, grants/RLS or lifecycle RPC definitions change. No C2 work is included.

**Await explicit approval for this Batch B scope. No account or fixture will be created before approval.**
