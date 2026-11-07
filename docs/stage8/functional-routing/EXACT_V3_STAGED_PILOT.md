# Exact V3 pilot — local implementation, live execution not approved

The normal Flutter Generate & Authorize button still uses the existing combined
endpoint. **Do not use it for this exact-three-task pilot.** No Flutter source or
APK change is required for the separate operator-assisted pilot below. After a
successful authorization, Flutter's existing protected Refresh displays the route.

## Stages and authority

1. `POST /v1/exact-route-plan` authenticates the NGO through existing Supabase JWT
   verification. It checks protected capabilities, overview, fleet and claim cards
   before creating one snapshot under that same NGO JWT. Admission requires every
   requested task, an available owned V3, capacity and strictly more than 255 minutes
   on every active lease. Current protected overview supplies pickup-window eligibility.
2. Existing `RoutingWorker.plan` performs planning-only and independent validation.
   It retains a local immutable witness of the validator acknowledgement and the
   candidate payload, snapshot, matrix and policy bindings. It makes no authorization.
3. The pilot gate requires one Proposed route on the specified vehicle, exactly the
   three pinned task IDs with no duplicates/extras/missing/unserved tasks, ATTESTED
   validation, matching immutable input/witness bindings and fresh protected reads.
   The response is `EXACT_CANDIDATE_VERIFIED`, still advisory. **Stop and inspect it.**
4. A separate explicit `POST /v1/exact-route-authorize` redoes those checks and
   records the stable authorization request ID and send marker before calling
   `authorize_my_routing_candidate(..., p_depart_at := NULL)` as the verified NGO.
   PostgreSQL retains all final transactional lease, custody, reservation, capacity,
   time-window, owner and attestation checks. No pickup operation is exposed.

`V3_EXACT_ROUTE_PILOT.proposed.json` pins the reviewed NGO, V3, policy, graph and
three historical task IDs, plus one stable planning request UUID. Reclaimed claims
may have new task IDs: never substitute them or generate replacement request IDs
automatically. A different fixture/task manifest needs review and approval.

## Activation and operator commands — separate approvals required

Both new endpoints are disabled unless planner startup has explicitly enabled
`GEOLOCK_EXACT_ROUTE_ENABLED=APPROVED`. `Start-Worker.ps1 -EnableExactWorkflow`
requires planner mode, `-Activate` and an explicit `-ApprovalRef`. Preserve the
previous approved startup options and graph ID; only the planner needs a controlled
restart. Leave the validator running. No migration or permission change is needed.

After separate restart approval, stop only the existing planner from its own
terminal, then use the reviewed native startup path below. This example preserves
the previously approved combined flag; it does not use that endpoint for the pilot.
Do not run it until the existing activation settings and approval reference have
been confirmed:

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
& '.\backend\routing\worker_service\windows\Start-Worker.ps1' -Mode planner -GraphId 'eab1f7ee-a8e0-4bed-a0e1-2c4bff024936' -Activate -ApprovalRef '<APPROVED_PLANNER_RESTART_REFERENCE>' -EnableCombinedWorkflow -EnableExactWorkflow
```

The dedicated graph/planner passwords are entered only at the existing native
hidden prompts. Keep the sealed cache and the existing private state directory;
never clear either journal when restarting.

The operator tool reads the matching DEV session from the connected debug phone
only into memory. The planner independently verifies that JWT. No password/token
argument or plaintext token file is used. Separate approval for this session use,
service restart and live pilot remains required. An expired session stops the stage;
the tool does not refresh credentials or retry automatically.

Local check only (safe without live approval):

```powershell
& '.\.venv-stage8\Scripts\python.exe' -B '.\scripts\Run-ExactV3Pilot.py' --stage check-local
```

Proposed operator calls, **not authorized by this document**:

```powershell
& '.\.venv-stage8\Scripts\python.exe' -B '.\scripts\Run-ExactV3Pilot.py' --stage plan --approval-ref '<APPROVED_REFERENCE>'
# STOP: inspect exact task set, Proposed result and ATTESTED status.
& '.\.venv-stage8\Scripts\python.exe' -B '.\scripts\Run-ExactV3Pilot.py' --stage authorize --approval-ref '<APPROVED_REFERENCE>'
```

Each call is explicit, never chained. Both services must be healthy. Recheck fresh
DEV eligibility before approving execution; the previous captured 255-minute
admission deadline was 30 October 2026, 04:06:28 MYT. Snapshot freshness is also
bounded by the existing worker limit (normally 300 seconds). Local tests are not
evidence that these live claims still qualify or that their joint route is feasible.
The admission deadline has passed. This historical manifest is not permission to
reuse expired claims. A fresh, separately approved protected read and review of the
exact fixture/task IDs must precede any future live test.

## Receipts, uncertainty and preservation

Server journal: existing private planner state directory, request/snapshot-scoped
steps. Operator journal: `%LOCALAPPDATA%\GeoLockHubRoutingDev\exact-pilot-client`.
Both persist original scope, IDs and send markers, never tokens. Construction and
reopening send nothing. Locks prevent concurrent duplicate sends. Snapshot/planning
uncertainty stops; preserve IDs for operator investigation, never regenerate.

After an authorization error/lost response, do not repeat `authorize`. Only a
separately approved `--stage reconcile` uses the existing read-only receipt endpoint.
It requires the planner, but not the validator, to be healthy:

```powershell
& '.\.venv-stage8\Scripts\python.exe' -B '.\scripts\Run-ExactV3Pilot.py' --stage reconcile --approval-ref '<APPROVED_READONLY_REFERENCE>'
```

NOT_FOUND never clears a send marker or permits a retry. A found matching receipt
is evidence of commit; it does not start pickup. Do not press normal Flutter Generate
while this operator-managed pilot is pending: its journal is separate from Flutter's
SharedPreferences. No phone preferences are edited by this tool.

No cancellation, recovery, claim release, reconciliation finalization, pickup or
depot-return call is part of this workflow. The old V2 route and all its evidence
remain unchanged. Stop after authorization and inspect protected route reads before
separately approving any pickup action.

## Local verification

The resumed verification includes abrupt subprocess termination after a durable
authorization-send marker, reopening the client/server journals, and concurrent
independent clients. No test uses a real NGO token, live device or DEV connection.
Synthetic transports use the real local solver and independent validator where
stated; protected PostgreSQL authorization is mocked, so this is not a DEV E2E PASS.
