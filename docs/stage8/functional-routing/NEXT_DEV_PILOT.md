# Next DEV pilot checkpoint — 27 October 2026

**Update:** native export/comparison completed PASS / SCOPED STORAGE EQUIVALENCE.
Do not repeat the export instructions below. Current approval package and qualified
graph-source status: [CURRENT_APPROVAL_CHECKPOINT.md](../stage-a/deployment-preparation/routing-initialization/CURRENT_APPROVAL_CHECKPOINT.md).

Owner-reported native read-only inventory: PASS (exit 0, READ ONLY/ROLLBACK,
approved OSM-OPS-20261018 coverage 926414 nodes / 2145828 directed edges,
three active diagnostic nodes, three worker logins present, no policies or frozen
manifests, recovery disabled). This is inventory evidence, not full graph equivalence
or effective worker access/activation proof. No new database connection by Codex.

## Next operator action: native read-only capture and offline comparison

From the repository root in interactive PowerShell:

```powershell
& '.\.venv-stage8\Scripts\python.exe' -B '.\docs\stage8\stage-a\deployment-preparation\routing-initialization\export_current_dev_native.py' --export
```

Python performs local preparation/file handling only; native psql17.11 obtains the
password using `-W`, loads the exact approved geolock_dev_owner_export service
profile, session pooler5432 and verify-full CA. Enter the verified PostgreSQL
database password locally. No Python authentication, password variable, credential
file, automatic retry or database write. Existing files/directories are preserved.

One REPEATABLE READ / READ ONLY transaction checks identity/TLS before export,
captures coverage/access/types and ordered nodes/edges including float storage
hex, then rolls back. Each statement has a60-second timeout and5-second lock
timeout. Ordering/export can consume server resources; no server graph traversal
is performed. If any operation fails, stop; do not rerun automatically or increase
timeouts. Partial evidence is retained in a new timestamped results/routing-current-export
directory and cannot produce a complete receipt.

On successful capture the existing offline comparator automatically checks pinned
CSV/coverage hashes, every node natural key/coordinate/metadata, directed endpoint
pairs and costs at IEEE754 REAL storage precision, generated edge-ID uniqueness
and mapping hash, and directed reachability among the three diagnostic nodes.
It has a180-second offline budget. Historical generated edge IDs are absent from
the source CSV and cannot be proved equal; original builder/PBF recovery, all-node
reachability, pilot-specific new node pairs and full-size matrix performance remain
outside this scoped comparison. Only a completed zero-mismatch report is PASS.
Export completion alone is not equivalence PASS. Preserve receipt, CSVs, queries,
metadata and equivalence JSON together.

Offline preparation executed locally: PASS with psql17.11, pinned files and approved
profile checked; six existing road-comparator tests PASS. No live export executed.

## Business decisions — all still NOT YET APPROVED

Keep the complete proposed JSON unchanged unless the owner requests a revision:
SHA256 `30826f3fdb5c52bde2b29605e54b30b19692740fbbb97d098daf4b22a3c0b030`,
request `0b8db479-20c8-4595-9d41-d831650cba93`.

1. Best effort (`mandatory=false`): infeasible tasks may remain unserved without
   automatic cancellation/recovery.
2. Four-hour horizon plus15-minute validity reserve: remaining lease/listing life
   must be strictly greater than255 minutes; a360-minute lease must be less than
   105 minutes old when the snapshot is taken. Recommend prompt claim→plan.
3. Handover assumptions:10 minutes direct donor /15 minutes hub stop.
4. Neutral fixed/distance cost weights1.0/1.0; task service takes priority over cost.
5. Initial solver budgets15 seconds per engine /0.25 deterministic seconds per pass;
   these do not bound graph loading, matrix building or total HTTP response time.
6. Keep contract constants: OR_TOOLS9.15.6755, workers1, seed42,
   PATH_CHEAPEST_ARC, GUIDED_LOCAL_SEARCH, TASK_ID_THEN_VEHICLE_ID,
   VALIDATED_INCUMBENT_ONLY. All17 proposed leaf values are detailed in
   ../stage-a/deployment-preparation/routing-initialization/POLICY_BUSINESS_REVIEW.md.

Policy installation requires separate exact-operation approval; accepting business
values does not authorize graph freeze or worker writes. Graph approval separately
addresses provenance mismatch/REAL representation, source-check results, intended
coverage and permanent network-maintenance freeze under the current contract.

## Minimum first pilot configuration after initialization approval

Choose Android emulator plus locally hosted planner/validator for the shortest
initial setup, or a reachable trusted HTTPS planner endpoint for a physical device.
Dedicated login presence alone does not establish that runtime authentication and
effective role permissions work.

* Planner: DEV project ref, separate graph/planner role-scoped DSNs (TLS verify-full),
  approved frozen graph UUID, DEV publishable key, private validator URL/token,
  protected persistent journal/cache. Never use owner/export credentials.
* Independent validator: its own role-scoped DSN and matching >=32-character
  service token, same pinned software versions; keep this process private.
* Activation flags GEOLOCK_ROUTING_ALLOW_DEV_WRITES=APPROVED and
  GEOLOCK_ROUTING_ACTIVATION_REF only after separate explicit worker-write approval.
  Warm the actual graph and verify runtime/memory before a user pilot.
* Flutter: DEV Supabase environment, existing NGO Auth session,
  GEOLOCK_ROUTING_API_URL=http://10.0.2.2:8787 for Android emulator debug;
  physical/release requires reachable trusted HTTPS. No worker secrets in Flutter.
* Real pilot: verified NGO depot, active/available owned vehicle and fresh admissible
  claim/listing; approved live lifecycle operations. Expired claims stay untouched.

Sequence: read-only comparison → approve policy + separately approve qualified graph
freeze → initialize with reviewed commands → scoped worker readiness/warm-up and
activation approval → Flutter pilot approval → claim/plan/authorize/pickup/depot close.
StageA003 stays closed; no replay, recovery enablement or live fixtures authorized.
