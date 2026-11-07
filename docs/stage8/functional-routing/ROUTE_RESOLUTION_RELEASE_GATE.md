# Route resolution — D02 local release gate

## 31 October 2026 — current LOCAL task-specific authorization correction

The same undeployed migration now has SHA-256
`a9fe7713fe2ffd65816743b52abd43695d63d1ecbb45fd216983c4a952eca557`.
This supersedes the historical checksum below; prior execution approvals do not
authorize deploying these revised bytes. Only submit_route_resolution_evidence
changed: each item locks through its own authorized claim, retaining the unchanged
complete-route lock helper and authorization rechecks under lock. NGO-only vehicle
accountability retains a route anchor. Grants, custody, version, replay and audit
rules remain unchanged. Normalized evidence function body MD5:
`7122f77ea8ed84d28bc08fbf77192d40`.

Actual disposable PG17 results: **10 focused + 74 existing SQL + 5 API/security
bridge = 89 PASS, 0 failures/errors**. Legitimate mixed-donor submissions,
cross-donor denial, third-item rollback, completed-route preservation, replay,
concurrency and audit identity checks pass. All three clusters stopped; input
integrity passed. No DEV connections or live records changed. Source diff, exact
commands, permissions and results:
`results/v2-resolution-local-correction-20261031/`.

**LOCAL correction PASS; DEV deployment/activation HOLD pending separate review.**
Broader acceptance check 55 remains BLOCKED; hosted parity, current recovery
capture/risk disposition, maintenance/installer/operator and activation approvals
are not supplied by these tests. No new migration or historical SQL was edited.

## Historical 29 October D02 release record

29 October 2026. **Security correction PASS; deployment/activation HOLD.**
No DEV access, deployment, activation, live fixtures, existing-route/V2 action,
scheduler/graph changes or APK build/install occurred.

- Same migration: [20261106_route_interruption_resolution.sql](C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/stage8/stage-a/forward-migrations/20261106_route_interruption_resolution.sql)
- Final SHA-256: `a8fc83b18da4ae13d771ae7ce513d5596a24cfbfdd8633d049da7da4db424020`
- Only three SQL function bodies changed from the previous LOCAL prototype.
  Signatures, owners, volatility, search paths, execution grants and effective
  permission matrix are unchanged. No historical migration changed.

| Changed function | Normalized prosrc MD5 (CRLF → LF) |
| --- | --- |
| `resolution_private.audit(uuid,uuid,text,uuid,jsonb)` | `1ef9fefee95154a4655f17687b3ccadb` |
| `resolution_private.audit_provenance()` | `c9712fd8ce39deed59989f91830b79e7` |
| `resolution_private.operator_key()` | `ed0bf0d0bc1585a51d34eef4ec345ad8` |

## Correction

The restricted operator helper rejects raw request.jwt.claim.sub,
request.jwt.claims and request.jwt.claim.role contexts before receipt replay,
case locks or writes, including malformed values. Resolver route audits derive
SYSTEM actor identity and operator principal/label solely from the database login
and active private mapping. The new audit trigger applies the same attribution to
existing donation-transition audit events without modifying the historical helper.
Ordinary NGO, donor and hub JWT attribution is preserved.

The original failing security test remains active, with rejection/no-write,
pre-lock, replay and clean-attribution assertions. Seven mixed-context variants
were rejected across operator entrypoints, with full business-state digests
unchanged; existing receipts cannot bypass the check. Clean finalization produced
six verified route/donation audit events. No additional security defect was found
in the executed checks; this is not an exhaustive proof or hosted-runtime result.

## Final actual results

| Suite | Result | Local evidence |
| --- | --- | --- |
| Disposable PG17 security/lifecycle/custody/concurrency/rollback + acceptance gaps | **74 PASS**, 0 failures/errors, 503.256s | results/route-resolution-d02-main-01.log |
| Real-SQL API bridge, cross-NGO holds, identity security and actual committed-response loss | **5 PASS**, 0 failures/errors, 112.707s | results/route-resolution-d02-bridge-final.log |
| Existing Python workers | **116 PASS**, 0 failures/errors | results/route-resolution-d02-worker.log |
| Python API/integration | **34 PASS**, 0 failures/errors | results/route-resolution-d02-python-api.log |
| Focused Flutter routing/resolution regressions | **97 PASS**, 0 failures | results/route-resolution-d02-flutter.log |
| Flutter analyze, seven affected sources/tests | **No issues** | results/route-resolution-d02-analyzer.log |

Commands reused (from repository root; Flutter runs from frontend/geolock_hub_app):

```powershell
.\.venv-stage8\Scripts\python.exe -B supabase/tests/route_resolution_isolated_test.py --run-isolated --runtime 'C:\Users\User\AppData\Local\Temp\geolock-spatial-runtime-24dbda5e04a04d48bd8d8dab0299d7eb'
.\.venv-stage8\Scripts\python.exe -B supabase/tests/route_resolution_api_isolated_test.py --run-isolated --runtime 'C:\Users\User\AppData\Local\Temp\geolock-spatial-runtime-24dbda5e04a04d48bd8d8dab0299d7eb'
.\.venv-stage8\Scripts\python.exe -B -m unittest discover -s backend/routing/worker_service/tests -t . -v
.\.venv-stage8\Scripts\python.exe -B -m unittest discover -s backend/routing/integration/tests -v
```

Flutter used the unchanged 11-suite invocation from the prior implementation
report, with --no-pub and the existing automatic-routing LOCAL capture. No APK
command ran. This correction changed no Flutter/API implementation source.

- Main SQL evidence: C:/Users/User/Downloads/FYP-GeoLock_Hub/results/automatic-routing-local/20261029T094349Z-aa8f14
- Final bridge evidence: C:/Users/User/Downloads/FYP-GeoLock_Hub/results/automatic-routing-local/20261029T094920Z-5b6e0e
- Both clusters stopped cleanly; frozen-input integrity checks pass, zero DEV/remote
  connections. Prior failing evidence and earlier PASS runs are preserved.
- PostgreSQL 17.11; PostGIS 3.6.2 / pgRouting 4.0.1 differ from DEV. Synthetic auth,
  Storage and inert cron adapters are not hosted Supabase/JWT/cron parity.
- All 141 unaffected baseline functions retain body/owner/config/ACL metadata.
  The two previously approved baseline guard amendments remain unchanged by D02.

## 58 acceptance checks

**57 PASS, 0 FAIL, 1 BLOCKED. Not all 58 pass.**

Six prior gaps are closed: terminal-consumer compatibility; all successful-report
lease/execution timestamps; missing/inconsistent item rollback; self-counterparty
and SQL access revocation; newly issued 360-minute leases after release; and
resolution-specific real COMMIT-response-loss reconciliation. The former audit
FAIL is PASS. See [acceptance-evidence.json](C:/Users/User/Downloads/FYP-GeoLock_Hub/results/route-resolution-local-review/20261029-d02-corrected/acceptance-evidence.json).

Check 55 remains BLOCKED: exact DEV synthetic fixture/discovery isolation is not
approved or verified. Registry provenance alone is not visibility isolation. No
new privacy policy, account or fixture was invented to close it. Hosted account
revocation, institution-specific retention approval and actual DEV compatibility
remain separate deployment controls, not claimed local test results.

## Remaining steps — separate approvals required

1. Approve fresh READ ONLY DEV preflight against the pinned migration: target,
   absence/drift, current definitions/ACLs/role inheritance, audit context and
   preserved route/claim/vehicle/graph/recovery state. No current DEV state was
   inspected by this local correction.
2. Approve current backup/recovery capture and verification; decide isolated
   restore or explicitly accept DEV-only recovery limitations. Name installer,
   maintenance/writer pause and recovery operator. Prior approvals are not reused.
3. Review/approve the exact checksum and migration execution separately. Install
   once, default-disabled, then read-only postflight including hosted owner-scoped
   readers. Do not provision/activate the resolver or perform case operations as
   an implicit migration side effect.
4. Before live synthetic testing, approve an exact independent fixture manifest
   and verified discovery controls (check 55), truthful simulation semantics and
   named resolver mapping. Retention remains provisional before real-user use.
5. Separately approve feature activation and a DEV APK build/install retaining
   existing routing URL/environment settings. Test read-only navigation first;
   each report, statement and finalization needs exact business-operation approval.
   Existing planner/validator services were neither restarted nor changed.

No permission to resolve route db1b455e-92d0-4d58-9fa1-5de07d7ab0f9 or release V2
is conveyed. Unsafe expired listings still remain MANUAL_REVIEW; no forced release
or withdrawal exists. Current live state is not certified by these local results.
Use the existing forward-correction/receipt-reconciliation recovery plan; do not
undo legitimate collection, delete history or silently retry uncertain writes.
