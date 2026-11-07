# Phase C1 v2 authenticated RPC and concurrency verification plan

**Status: READY FOR REVIEW; execution is NOT authorized. DEV only: `rcgyuwiidqvrgbxswhqj`.**

This document specifies tests, not a test-run result. No authenticated calls, account creation, fixture creation or database writes were performed while preparing it. No C2 work, application changes, grants, policy changes or lifecycle changes are proposed. Every attempted mutator, including an expected denial, idempotent retry or no-op, belongs to a later approved write phase.

## 1. Reviewed evidence and current prerequisites

Reviewed [the installed v2 source](../proposed_migration_v2.sql), [the 32-check postflight report](../deployment/dev-postflight-report-2026-10-24.md), its JSON summary and installed-source comparison, and the isolated v2 test definitions. Local migration SHA-256 remains:

`f50af9705de117bdd12581f2515605c8e5c548e0fee7ae01d7ea33ecfbb0cb05`.

The accepted postflight established 712/712 protected object matches, correct ACLs/guards/seal, zero existing fleet/route data, 117 offline routing tests and 12 package/comparator tests passing. Those are historical checkpoint results, not newly executed behavioral tests. The prior 44 isolated migration tests use a reduced schema and simulated authentication; they must never be pointed at DEV or presented as real JWT evidence.

A fresh SELECT-only inventory at **2026-10-24 18:56:50 MYT** confirmed the project URL, retrieved all five deployed public RPC definitions, and found:

| Prerequisite | Observation | Consequence |
|---|---|---|
| Vehicles / routes / stops / assignments | 0 / 0 / 0 / 0 | No existing active/terminal route fixtures or unverified-owner vehicles to reuse. |
| NGO profiles | Two, both active with matching NGO/auth identities | Potential A/B identities exist; permission to use them as test identities has NOT been established. |
| Verified operational depots | Both NGOs currently qualify | Node-level prerequisites exist; this does not establish connected road paths or route feasibility. |
| Unverified / inactive NGOs | Zero / zero | Negative identity/depot tests need approved dedicated fixtures or an isolated environment. Do not alter an existing NGO to manufacture them. |
| Coverage | `OSM-OPS-20261018`, active, OPERATIONAL, approved | Existing dataset can support depot checks. Do not alter coverage/node flags for tests. |
| Installation seal | `geolock-stage8-c1-v2:364bdf2b0f4e413ce0f43d10c56684dc` | Fresh SELECT confirmed the stored seal equals the computed fingerprint; repeat before/after execution alongside separate ACL checks. |

[Captured aggregate inventory and deployed RPC definitions](prerequisite-evidence-2026-10-24.json) contain no contact details or credentials. This targeted inventory does not rerun or replace all 32 postflight checks.

[Supplemental SELECT evidence](seal-and-route-status-evidence-2026-10-24.json) confirms seal equality and the seven deployed route status values.

[Fresh source comparison](source-comparison-2026-10-24.json) confirms all five retrieved RPC bodies match the pinned v2 SQL after newline normalization. This is source review, not authenticated execution evidence.

### Required identities, sessions and fixture approvals

- **A, B:** two explicitly designated, active test NGOs, each with its own existing user JWT and verified approved operational depot. They may share coverage; ownership tests must use different users. Do not automatically use the two existing NGOs just because they are eligible.
- **U:** active test NGO without a verified operational depot, needed for new-registration denial and empty-fleet behavior. It does not currently exist. A missing node, inactive/unapproved coverage and invalid node encoding are additional depot-negative variants best exercised in a disposable environment, not by changing shared DEV network data.
- **N / I:** an existing authenticated non-NGO and inactive NGO for role/profile denials. Inactive NGO is absent; presence and authorization of a suitable non-NGO identity remain unverified. No accounts or profile changes are authorized.
- Existing valid JWTs obtained through an owner-approved flow, plus the project's existing public API key, are needed for end-to-end tests. Never store tokens, passwords or backend keys in the repository, logs or chat. Logging in or refreshing tokens can write Auth sessions; that preparation also needs authorization. Do not create users or forge JWT claims.
- An existing trusted operator connection is needed for read-only observation, controlled route fixtures and two-session locking tests. Existing service-role credentials, if used for backend guard tests, remain server-side. Do not add privileges or expose keys to NGO clients.
- Agree on a maintenance window, a fixture owner, a post-C1 recovery point/backup and a checked fixture manifest before writes. The earlier pre-migration backup was user-reported, not restore-tested; restoring it would also remove C1 and later data. Whole-database restore is not routine fixture cleanup.

**Current blockers:** test identities are not designated; JWT access is not established; U/I negative identities are absent; no vehicle/route fixtures exist; write scope and retained retired vehicles are not approved; unresolved-task/assignment fixture teardown has no approved workflow. Catalog readiness alone does not remove these blockers.

## 2. Execution channels and assertions

| Class | Examples | Authorization / evidence boundary |
|---|---|---|
| R0: SELECT-only metadata | Counts, constraints, permissions, fingerprints, coverage/profile aggregates | Allowed for preparation; no mutation RPCs. |
| R1: read-only authenticated requests | `list_my_vehicles`, denied direct table reads, denied anonymous list | Run only after approval of identities/session use. No application data writes expected; obtaining sessions is separate. |
| W1: authenticated attempts | Registration, updates, availability, deactivation, denied direct writes, stale/no-op/retry calls | All require explicit controlled DEV write approval, even when rejection is expected. Real HTTP calls commit independently. |
| W2: trusted fixture/locking attempts | Minimal empty routes, backend guard probes, transaction-local role emulation | Separate exact fixture/teardown approval; never substitute this for real JWT isolation tests. |
| X: lifecycle-dependent fixtures | Existing terminal holds, assignments, task states, depot revocation and inactive-profile variants | Blocked until separately approved safe fixtures/teardown exist; otherwise run in an isolated copy and label that evidence accordingly. |

Real RPC requests target only `https://rcgyuwiidqvrgbxswhqj.supabase.co/rest/v1/rpc/<name>` with the appropriate A/B JWT. Do not use a service JWT or admin-injected `auth.uid()` as proof of NGO authentication. Admin `SET ROLE`/claim emulation may inspect DB guards in approved rollback-scoped sessions but proves neither token validation nor gateway permissions.

For each test, record run ID, actor alias, request key, target UUID, expected/current version, sanitized payload/result/error, timing, transaction outcome, before/after row state and audit delta. A SELECT-only observer verifies affected and unrelated rows independently. Never assert success from HTTP status alone. Assert SQL error message/code where available; authentication/gateway/argument decoding can reject before an RPC body runs, so do not hard-code one HTTP status for all denials.

Every rejected transaction must leave target and unrelated rows, versions, timestamps and success-audit counts unchanged. Effective successful fleet changes increment version once and create one matching `FLEET_INSERT`/`FLEET_UPDATE` success event. No-op/replay calls produce no extra success event or version/timestamp change. Failed calls need not create rejected audit rows. All returned fleet objects must omit `registration_payload`.

All five RPCs are SECURITY DEFINER, owned by postgres, fixed `search_path=pg_catalog,pg_temp`, and derive ownership through `require_ngo()`/`auth.uid()`; none accepts a client NGO/depot ID. Verify these facts and ACLs before calls. Ordinary anon/authenticated direct vehicle access is denied; service_role retains SELECT/INSERT/UPDATE but no vehicle DELETE/TRUNCATE and no private-helper access or public fleet RPC EXECUTE.

## 3. Five-RPC functional test matrix

IDs below are planned tests, all **NOT RUN**. W1 applies unless marked R1. Each semicolon-separated variant is a separate recorded assertion.

| ID | RPC / setup and action | Expected result |
|---|---|---|
| F01 (R1) | A and B list before registration | Each gets `vehicles=[]`, `fleet_outcome=NO_FEASIBLE_PLAN`, `reason=NO_REGISTERED_VEHICLES`. No default vehicle. |
| F02 | A registers with new request UUID, explicit valid fields, omitted availability | One A-owned vehicle, derived depot, active=true, availability=false, version=1. Label/type trimmed. No guessed operational values. |
| F03 | A registers a second request UUID with availability=true | A may own multiple vehicles. Explicit complete fields and verified depot; eligible=true when unheld. |
| F04 | Replay original request and original normalized payload, then replay after profile/availability changes | Same vehicle ID, current state returned, no new row/audit/version. Replay does not undo edits. Whitespace normalization is respected. |
| F05 | Same owner/request, different valid payload | `REGISTRATION_REQUEST_CONFLICT`, no effects. Invalid payload is rejected by input checks before replay lookup. |
| F06 | B uses A's registration request UUID with B's valid payload | Separate B-owned vehicle permitted. Idempotency key is owner-scoped; no A row disclosure. |
| F07 (R1) | A/B list populated fleet | Own vehicles only, stable vehicle-ID ordering, inactive/unavailable rows included. Eligibility matches depot/availability/hold checks. `AVAILABLE_VEHICLES` means fleet eligibility, not a feasible route solution. |
| F08 | A updates all permitted profile fields with current version | Only label/type/capacity/costs/duration change; owner, depot, registration key/payload preserved. Version +1, updated timestamp, one audit. |
| F09 | Exact normalized profile no-op | Success with unchanged version/timestamp and no audit. Do not require every successful update call to increment. |
| F10 | Null, stale and impossible expected versions on update/availability/deactivate | `VEHICLE_VERSION_CONFLICT` on an otherwise active, owned vehicle. No lost update. |
| F11 | A sets availability true, false, and repeats each current state | Effective changes increment once; exact repeats are no-ops. True requires verified depot/completeness even if already true. Ineligible fleet lists explicitly report `NO_FEASIBLE_PLAN`. |
| F12 | A deactivates an unheld vehicle | active=false and available=false; version +1, one audit, still present in own list with eligible=false. |
| F13 | Repeat deactivation with new current version, then old version | Current-version retry succeeds as no-op; stale version conflicts. No reactivation RPC. |
| F14 | Update profile / set availability on deactivated vehicle; replay its original registration | Update and availability reject `VEHICLE_DEACTIVATED` before version checking. Registration replay returns same inactive current row, not a revived vehicle. |
| F15 | For each ID-based mutator, B supplies A's known vehicle UUID; repeat with unknown and null IDs | `VEHICLE_NOT_FOUND` without exposing A's data; no mutation/audit. Mirror A against B. |
| F16 | Call every RPC anonymously, with missing/invalid/expired bearer token | Gateway/EXECUTE denial; no data exposure or change. `UNAUTHENTICATED` is a private guard behavior, not guaranteed externally when EXECUTE is denied first. |
| F17 | Call every RPC as authenticated non-NGO and inactive NGO | `ACTIVE_NGO_PROFILE_REQUIRED`, no effects. Requires approved N/I identities. |
| F18 | Supply extra owner/depot/metadata fields or wrong argument shape to RPC endpoint | Signature/argument rejection, never ownership override. Do not assume unknown parameters are silently ignored. |
| F19 | Direct authenticated/anon table reads and targeted INSERT/UPDATE/DELETE attempts against known fixture IDs | Access denied. Reads R1; all write attempts W1. Preserve table and column ACL denial; no extra RLS policies. Never issue broad or cascading destructive probes in DEV. |
| F20 | Attempt private helper invocation and service-role public fleet RPC invocation | Denied by schema/function privileges. Ordinary user cannot choose private `p_actor` to escalate privileges. |

### Input validation variants (register and update)

Run each field independently against a known-valid payload; for failed registration use an approved request key and prove zero rows created. Include availability-null on its dedicated RPC and request/availability-null during registration.

| ID | Boundary / invalid cases | Expected result |
|---|---|---|
| I01 | Label null, blank, 121 chars; type null, blank, 81 chars | `INVALID_VEHICLE_FIELDS`; lengths 1/120 and 1/80 accepted with trimming. |
| I02 | Capacity null, zero, negative, >=1,000,000,000, nonzero fourth decimal | `INVALID_VEHICLE_FIELDS`; positive 0.001 and up to 999999999.999 allowed. Exact trailing-zero precision is not a rejection criterion for capacity. |
| I03 | Fixed cost null/negative/>2 decimal scale; distance cost null/negative/>4 scale | `INVALID_VEHICLE_FIELDS`. Explicit zero costs valid. Preserve numeric encoding in the test client; floating point normalization must not erase a scale test. |
| I04 | Duration null, zero, negative, >3 decimal scale | `INVALID_VEHICLE_FIELDS`; positive values at supported scale accepted. |
| I05 | Numeric NaN/Infinity/-Infinity and malformed numeric input | No invalid stored value. JSON cannot carry nonfinite numeric literals: distinguish transport/type rejection from RPC validation. Typed-numeric DB probes require separately approved isolated/transactional harness; do not claim the same error on all transports. |
| I06 | Register null request or null availability; availability RPC null flag | `REQUEST_AND_AVAILABILITY_REQUIRED` / `AVAILABILITY_REQUIRED`, respectively, after applicable identity/ownership/version checks. |

Synthetic test values, for example capacity 12.345 kg, fixed cost RM7.50, distance cost RM0.2500/km and duration 90.000 min, are test fixtures only. These are neither actual NGO vehicle properties nor defaults for real planning. Prefix labels with `C1TEST:<run-id>` and keep availability=false except in bounded availability/route tests. Real planning consumers must exclude test identities during the window; no such live integration is assumed to exist.

## 4. Unverified depot behavior

| ID | Setup / action | Expected installed behavior / prerequisite |
|---|---|---|
| D01 (R1) | U lists an empty fleet | Allowed for active NGO; explicit `NO_FEASIBLE_PLAN` / `NO_REGISTERED_VEHICLES`. No need to verify a depot merely to list. |
| D02 | U attempts new registration with availability=false and then true | Both reject `VERIFIED_OPERATIONAL_DEPOT_REQUIRED`; no row created. U fixture required. |
| D03 | Existing U-owned active, unavailable vehicle; update profile, set false, deactivate | Unheld profile edits/false/deactivation may succeed without depot verification. They do not enable planning. This fixture cannot be registered while U is unverified; requires separately approved fixture history or isolated copy. |
| D04 | Same existing vehicle, set true | `VERIFIED_OPERATIONAL_DEPOT_REQUIRED`; no effects. |
| D05 | Original valid registration replay after depot verification is lost | May return existing current row because replay precedes `require_depot`; no new vehicle, no renewed eligibility. Requires approved depot-history fixture. |
| D06 | Trusted depot revocation/change on idle versus held vehicle | Idle cleared depot disables availability; re-verification must not automatically re-enable it. Effective held depot change rejects `VEHICLE_HAS_ACTIVE_ROUTE` and rolls back the surrounding trusted operation. No maintenance bypass. Separately approved location fixture or isolated environment only. |
| D07 | Missing/unparseable/out-of-range node, inactive node, inactive/unapproved/non-OPERATIONAL coverage | No eligible planning/new registration. Derived depot only; client cannot submit a depot through fleet RPCs. Exercise without changing real DEV network coverage. |

Do not unverify either existing NGO, deactivate network coverage, change trusted location code, or bypass the existing depot trigger to make these tests runnable. D03–D07 remain blocked in DEV until their exact setup and cleanup are approved. Verified node membership is not proof that every road arc between depots/tasks is reachable; road-matrix integration is outside C1.

## 5. Route holds, terminal states and operational limitations

Deployed route statuses are **DRAFT, VALIDATED, AUTHORISED, IN_PROGRESS, COMPLETED, CANCELLED, STALE**. `vehicle_has_hold` freezes effective profile/depot/availability/activity changes for any nonterminal route, any active assignment on a vehicle's route, or any route stop whose task is PLANNED/DISPATCHED. Terminal status alone does not release a vehicle. A no-op may succeed because it changes no protected value.

| ID | Fixture / action | Expected result |
|---|---|---|
| H01 | One empty route in each of DRAFT/VALIDATED/AUTHORISED/IN_PROGRESS, separately | Own profile change, availability=false and deactivation each reject `VEHICLE_HAS_ACTIVE_ROUTE`; eligible=false. Original registration replay and profile/availability no-ops do not mutate held vehicle. |
| H02 | Clean empty terminal route, each of COMPLETED/CANCELLED/STALE | No hold from this route alone; effective fleet edits succeed with correct version. A fixture with COMPLETED status is not proof of pickup completion. |
| H03 | Two nonterminal routes on same vehicle; release only one | Remaining route keeps vehicle frozen. C1 does not itself prevent multiple route bookings. |
| H04 | Terminal route with active assignment or PLANNED/DISPATCHED stop | Still frozen. Requires safely obtained historical fixture or approved isolated copy; not present in DEV. Do not forge claims/tasks to manufacture this state. |
| H05 | Attempt terminal transition with unresolved assignment or PLANNED/DISPATCHED stop; COMPLETED with any non-COLLECTED stop | `ROUTE_HAS_UNRESOLVED_ACTIVITY`; route and vehicle unchanged. Actual task/assignment fixtures are separately gated. |
| H06 | Attempt route vehicle/NGO rebinding, terminal-to-different-state change, active-route DELETE | `ROUTE_VEHICLE_BINDING_IMMUTABLE`, `ROUTE_TERMINAL_STATE_IMMUTABLE`, `ACTIVE_ROUTE_DELETE_FORBIDDEN`, respectively. Test targeted fixtures only. |
| H07 | Nonterminal route creation against unavailable/inactive/wrong-owner vehicle | `VEHICLE_NOT_AVAILABLE`; missing/stale verified depot rejects using applicable depot guard. No route persists. |
| H08 | Trusted backend tries held profile change, ownership/request/payload change, version/timestamp overwrite, reactivation | Hold/identity/metadata/deactivated guards reject as applicable. Backend RLS bypass is not trigger bypass. Service SELECT/INSERT/UPDATE rights remain intact; do not grant private EXECUTE or use superuser trigger-disabling capabilities. |

**Pickup completion currently does not close routes or clear assignments.** No test may infer release from `complete_pickup`, invoke `start_pickup`, cancel real claims, or clean real assignments. Route status fixtures exercise the C1 guard, not a finished route authorization/closure workflow. Later protected route closure/release remains separate Phase C work, not implemented here. Historical stop references also affect claim recovery; no new task/claim/stop/assignment fixtures are in the initial proposed write scope.

## 6. Concurrency design

Use two independent requests/connections, explicit client barriers, bounded waits and READ COMMITTED. Capture server sessions/lock waits through existing trusted observer permissions where available; simultaneous start timestamps alone do not prove overlap. Do not install sleep functions, change production code or disable guards. A client timeout is inconclusive until server transaction outcome is reconciled.

| ID | Ordered contention test | Expected outcome |
|---|---|---|
| C01 | Same NGO, same new request UUID, identical normalized payload, two parallel registrations | Same returned vehicle ID, exactly one row, version=1 and one insertion audit. Advisory lock plus unique owner/request key prevents duplicates. |
| C02 | Same NGO/key, two different valid payloads | One winner; other `REGISTRATION_REQUEST_CONFLICT`. Exactly one row with winner's immutable payload. Winner is nondeterministic. |
| C03 | A/B register concurrently with same request UUID | Independent owner-scoped results. May reuse F06 setup; each NGO gets only its own vehicle. |
| C04 | Two different profile updates read the same version and execute in parallel | One succeeds, version +1; other `VEHICLE_VERSION_CONFLICT`. No mixed fields/lost update. Repeat same-version no-ops separately: both can succeed without version advance. |
| C05 | Profile update versus availability change at same version | One effective winner; other version conflict. Re-read row and reconcile, never retry blindly with a refreshed version. |
| C06 | Profile update versus deactivation | If update wins, deactivation conflicts; if deactivation wins, update rejects `VEHICLE_DEACTIVATED` before version check. Result stays coherent and inactive vehicle cannot be revived. |
| C07 | Session A creates nonterminal route and holds vehicle lock; B attempts effective fleet change; A commits | B waits then rejects `VEHICLE_HAS_ACTIVE_ROUTE` after seeing committed hold. Repeat profile edit/false/deactivation variants. This leaves a committed route and requires preapproved teardown. |
| C08 | Same route-first ordering, A rolls back | B waits then may succeed; no route survives. Distinguish rollback case from committed-hold proof. |
| C09 | A deactivates or makes vehicle unavailable, holds lock; B creates nonterminal route; A commits | B waits then rejects `VEHICLE_NOT_AVAILABLE`. If A rolls back, B may succeed; successful B route needs cleanup. |
| C10 | Empty route terminalization/cancellation holds vehicle lock; B changes fleet; closure commits versus rolls back | Commit releases only if no other hold; rollback preserves hold and B rejects. Tests trusted fixture transition, not a public route-closure RPC. Repeat clean COMPLETED and CANCELLED as separate variants. |
| C11 | Release one of two held routes while fleet update races | Other hold still prevents modification; no premature release. |
| C12 | Trusted depot update versus fleet/route write | No stale available depot or silent invalidation of held route; complete trusted change rejects if held. Requires dedicated location fixture; blocked initially. |
| C13 | Approved rollback-scoped operator probes under REPEATABLE READ and SERIALIZABLE attempt fleet/route writes | `FLEET_REQUIRES_READ_COMMITTED`; no committed mutation. Existing guard intentionally rejects those isolation levels. No isolation configuration change for normal clients. |

Observe both lock orders for C07–C10; repeat each ordered case at least five times using a bounded fixture budget, reusing safely reset **nonterminal** fixtures where permitted. Terminal states cannot be reopened. Proposed defaults for operator agreement: five-second lock-wait budget and 30-second client budget, with server outcome observation before retry. Timeout/deadlock is not a functional pass; investigate and retain evidence. Do not silently widen timeouts to hide a failure.

SQL transactions may coordinate route locks and fixture rollback; real A/B mutation HTTP requests supply authentication evidence on the competing side. If both sides use admin role emulation, label results DB-guard-only. RPC-only duplicate/update races use real JWTs on both sides. A loopback simulation cannot substitute for these DEV races.

## 7. Fixture scope and execution order

No fixture IDs have been allocated and no fixture SQL is authorized. Before execution, produce an exact allowlist of actor aliases, request UUIDs, vehicle IDs as returned, route UUIDs, expected changes and operator-approved teardown. Use a run ledger; unknown IDs are never touched.

Proposed **initial functional scope: at most five committed synthetic vehicle rows**: four owned by A (main, second/deactivation, duplicate-race winner, conflicting-payload-race winner), one by B. C03/F06 share the B/main registration key scenario. Reuse those rows for edits and remaining races; run deactivation last because it is irreversible through fleet RPCs. Extra U/I vehicles are excluded and require separate approval. All five will remain as retired records after cleanup; get explicit acceptance of that before any registration.

Route scope is a **separate approval gate**. Inspect current route columns/defaults/FKs before drafting a fixture manifest. Empty synthetic routes must use authorized test NGO/vehicle bindings only; no task, stop, assignment, claim or donation writes. Approve exact route UUIDs, maximum creations, initial statuses and targeted terminalization/deletion teardown together. A guarded trusted cancellation/delete of an empty test fixture is test teardown, not an implemented operational closure workflow. If that teardown is unacceptable, use rollback-only cases or an isolated copy and mark committed-hold tests blocked. Do not promise one enclosing rollback for independent HTTP commits.

1. **Gate 0 — recovery and scope:** designate test users, approve session handling and write/cleanup budgets; verify recovery point; reserve window and ensure test identities cannot enter real planning.
2. **R0 refresh:** re-confirm DEV URL, migration hash, all 32 catalog/preservation assertions, 712 protected fingerprints, seal and counts. Stop on unexplained drift. Snapshot affected row/audit baselines. No Auth or fixture writes.
3. **R1 identity checks:** existing valid A/B JWT lists, zero-fleet result, denied direct reads and anonymous/non-NGO list where identities exist. Confirm own-user mapping through observed RPC results, without logging JWTs.
4. **W1 registration/input/ownership:** after explicit approval, F02–F08, I cases, cross-owner/anonymous mutator attempts and C01–C03. Never create a row merely to hide a failed assertion.
5. **W1 mutable behavior:** profile/no-op/version/availability tests and C04–C05. Check audit deltas and isolation after each group.
6. **W2 route holds/races:** only with separate fixture and teardown approval, H01–H03/H06–H08 and C07–C11. Unresolved-source H04/H05, depot-history D03–D07 and C12 remain deferred unless their own prerequisites are approved. Do not count deferred cases as passes.
7. **W1 permanent final state:** C06, F12–F14, then cleanup all synthetic vehicles to unavailable/inactive using current-version owner RPCs after proving no holds. Read-only lists confirm retained inactive rows and `NO_FEASIBLE_PLAN` for otherwise empty test NGOs.
8. **Final observation:** verify fixture ledger totals, no test routes/stops/assignments left, all retained vehicles inactive/unavailable, audit deltas correct, ACLs/guards/seal unchanged, 712 protected object fingerprints equal. Rerun 117 offline Phase A/B tests and 12 comparator/package tests using established commands from the postflight package, with no database connection. Report actual results, failures and blocked tests separately.

The old zero-count postflight baseline must remain intact as evidence. After approved registrations, expected counts change deliberately; compare the new deltas to the exact fixture ledger, not to an assertion that vehicles remain zero. Do not alter the old comparator or claim its original no-data-change mode passed after writes. Protected-object and installation checks should still be unchanged. Underlying donation/claim/lease/hub/pickup row changes are outside the approved test scope; capture privacy-conscious relevant aggregate/hash baselines for the supervised window and investigate any unrelated changes rather than attributing them automatically to tests.

## 8. Cleanup, rollback and stop conditions

- Reconcile every timed-out request before retry. Registration retries reuse the original owner/request/payload; updates require explicit result reconciliation because refreshing a version and retrying can overwrite a concurrent actor's legitimate change.
- Roll back open operator fixture transactions first; independently committed RPC writes remain committed. An aborted session must not be assumed to undo another session's work.
- For committed empty route fixtures, an operator may perform only separately approved, exact-ID cleanup after checking no stops/assignments. Nonterminal DELETE is blocked; terminalization must pass the unchanged guard, and terminal row deletion is allowed only where constraints/permissions permit. If a fixture unexpectedly gains activity, stop and report it; do not clear assignments, change task statuses or disable triggers to free it.
- Deactivate owned test vehicles through existing RPCs using fresh versions once no hold remains. Vehicle DELETE is prohibited even to trusted callers by the row guard; do not disable it or reset identities. Keep audit history and the fixture ledger. Retired registration keys remain consumed.
- Do not delete accounts or change verification/coverage during cleanup. Any separately approved identity/location setup must include its own reviewed restoration order and original-value snapshot, or stay in an isolated environment.
- Do not use TRUNCATE, cascade deletes, grant changes, policy weakening, fixture helper functions or migration rollback as routine cleanup. Do not rerun the migration to repair test failures. Database-wide restore requires a separate incident decision and explicit authorization because it can lose unrelated data.
- Stop immediately on cross-NGO exposure/mutation, unauthorized successful direct write, unexpected row/audit delta, guard/seal/fingerprint drift, unexplained timeout/deadlock, stranded route hold or unapproved fixture dependency. Preserve sanitized evidence and current state; no automatic repairs. If an alleged-denial test unexpectedly succeeds, rollback an open local transaction where possible, then report any committed effect before further writes.

## 9. Approval checklist and acceptance boundary

Before W1, approve the exact A/B identities and session flow, at-most-five retained synthetic vehicles with explicit values, attempted negative writes, concurrency repetitions, window/observer and cleanup owner. Before W2, additionally approve each minimal route fixture and teardown; no implicit permission for tasks/assignments or NGO/network changes. U/I and depot-history cases need separate identity/fixture approval or an explicit isolated-only evidence decision.

The final report must distinguish **PASS**, **FAIL**, **BLOCKED**, **NOT RUN** and **ISOLATED ONLY**, per test variant and authentication channel. Full authenticated/concurrency sign-off requires evidence for its claimed coverage, no unexplained failures, invariant preservation and completed approved cleanup. If negative identity/history cases remain blocked, report conditional partial coverage rather than full C1 verification. Successful C1 tests will not establish live route authorization, route closure/recovery, road matrices, solver production readiness or dispatch enforcement. Phase C2 remains unstarted and requires its own approval.

**Current decision: plan prepared; retain conditional read-only sign-off and wait for explicit test-execution approval.**
