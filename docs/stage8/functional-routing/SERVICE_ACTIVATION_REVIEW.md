# Service activation review — HOLD: planner publishable-key configuration

**Hidden-paste correction:** the updater now uses Windows ReadConsoleW with
line buffering and echo disabled instead of host-dependent Read-Host SecureString
input. Paste is consumed through Enter; console mode is restored and temporary
buffers cleared. Nothing is echoed, including asterisks. Isolated hidden-console
tests under Windows PowerShell5.1 and PowerShell7 passed a >1000-character dummy
paste, verified the reader waited for a separate Enter, no dummy appeared in
output, and the original console mode was restored. Synthetic DPAPI/preservation
tests PASS (`results/worker-config-update-tests/82a5300a07044e089a09f5046f94c0de`).
No actual profiles, credentials, services or databases were modified by this fix.

**Secure update prepared:** run
`backend/routing/worker_service/windows/Update-PlannerPublishableKey.ps1` from an
interactive PowerShell at repo root. Paste only the DEV publishable key at its
hidden prompt. It atomically replaces only planner.PublishableKey, preserves a
unique encrypted backup and all other encrypted fields, and automatically reruns
local readiness plus both DISABLED startup checks. It reports PASS/FAIL and saves
a sanitized report outside Git. `-CheckOnly` repeats checks without an update.
Synthetic DPAPI regression tests PASS, including byte-for-byte preservation of
other encrypted credential fields. Actual key entry/update is pending the operator;
no actual configuration PASS is inferred from the synthetic tests.

27 October2026. No service, business operation, permission or recovery change made.

Reviewed actual DEV evidence, both reports PASS:
`results/worker-runtime-connections/20261027T095305Z-2ea399/result.json` and
`results/worker-runtime-connections/20261027T095412Z-b02a67/result.json`.
All three native17.11 logins, intended roles,8-RPC permission matrices, verify-full
configuration, observed TLS1.3, READ ONLY, rollback and closure PASS. Null SSL fields
after SET ROLE are expected redaction; actual login TLS observations are true.
Completed full-size graph probe and prepared checksum-verified cache are reused.

Additional LOCAL startup checks: project matches; shared validator token equality
and >=32character requirement PASS; TCP8787/8788 free at inspection; runtime graph
cache/seal present. No graph export, graph load or database investigation repeated.

**One blocker:** protected planner profile's PublishableKey does not start with
`sb_publishable_`. Existing `SupabaseAuth.__init__` explicitly requires this prefix,
so active planner construction would fail PUBLISHABLE_KEY_REQUIRED. The value was
neither displayed nor written. Do not claim all technical startup gates closed.
Supply the correct DEV publishable key through a hidden local configuration update,
preserving the rest of the encrypted profiles and backup. Do not rerun the
all-credentials Save-WorkerConfig script or change database passwords. No configuration
update or API Auth request was performed in this review.

After the key correction and non-secret format recheck, explicit service-only
approval may name proposed reference `GLH-DEV-SERVICES-20261027-01`. This is a label
for the user's actual approval, not an authorization token or approval by itself.

From repo root, separate interactive PowerShell terminals, AFTER explicit approval:

```powershell
# Terminal1: validator first.
.\backend\routing\worker_service\windows\Start-Worker.ps1 -Mode validator -Activate -ApprovalRef 'GLH-DEV-SERVICES-20261027-01'
```

```powershell
# Terminal2: planner.
.\backend\routing\worker_service\windows\Start-Worker.ps1 -Mode planner -GraphId 'eab1f7ee-a8e0-4bed-a0e1-2c4bff024936' -Activate -ApprovalRef 'GLH-DEV-SERVICES-20261027-01'
```

Validator prompts once for its native password. Planner prompts for graph then
planner passwords, before its listener starts. Expect JSON mode/project/statusACTIVE.
There are no scheduled jobs or automatic planning RPCs at startup. Request handlers
have write capability once activated; service-only approval is not permission to
send pilot planning/authorization requests. The cache remains the existing local
sealed graph; no graph refreeze, reload probe or policy installation.

After approved startup, read-only health checks:

```powershell
Invoke-RestMethod 'http://127.0.0.1:8788/health'
Invoke-RestMethod 'http://127.0.0.1:8787/health'
```

Each must return statusACTIVE and project_ref`rcgyuwiidqvrgbxswhqj`. Health proves
listener/activation state only, not NGO Auth, complete API latency or routing success.
Keep validator private and use emulator planner URLhttp://10.0.2.2:8787.

Shutdown: when no request is in flight, Ctrl+C in planner terminal, then validator.
Launcher clears its routing environment and native factory clears mutable password
buffers. Do not force-stop during a write if avoidable. If interrupted, preserve
journal/request IDs and inspect protected state before retrying. Shutdown does not
undo committed routes, reservations, claims or pickups.

Separate named-pilot approval must specify NGO, vehicle, donation(s) and permitted
write scope: claim if needed, planning snapshot, matrix storage, sealing, candidate,
independent attestation, NGO route authorization, start/complete pickup with actual
handover and confirmed depot-return closure. Preselect eligible inputs with sufficient
capacity and >255minutes remaining lease/listing validity. No manual fixtures,
expired-claim recovery, permission changes or scheduler activation is included.
