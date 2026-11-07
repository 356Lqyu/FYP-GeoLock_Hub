# Fresh V3 end-to-end pilot — proposal only

No live action is approved by this file. The preserved V2 route, claims, cases and
vehicle hold remain untouched. Route resolution stays disabled.

## Fastest sequence

1. Approve read-only account/V3/policy/service readiness and a controlled planner-only
   restart. Confirm the existing NGO identity and name the approved DEV donor.
   Start services before claiming; keep existing sealed cache and journals.
2. Review `FRESH_V3_THREE_DONATION_PILOT.proposed.json`: three NEW direct donations
   A/B/C, 15 kg each (45 kg total). Existing threshold is >=10 kg direct. Use the
   ordinary donor form, valid category, 1–3 approved synthetic test photos and
   confirmed pickup locations. `create_donation_with_images` creates the direct
   AVAILABLE donation/listing; inspect committed results instead of assuming a
   separate publish action. Locations/nodes are proposed from prior evidence only.
3. Approve creation/publication and claiming of precisely those fixtures. The NGO
   must discover each through `discover_eligible_listing_cards`, then claim through
   the ordinary protected flow. The deployed 20 km road rule must pass; location
   labels and Google distances are not proof. Do not force road-node IDs.
4. Claim all three consecutively just before planning, after donor setup/services
   are ready. Aim to start planning within 10 minutes. Fresh leases last 360 minutes;
   strict admission needs >255 minutes, so claim-time headroom is only 105 minutes.
   Existing/default source/listing windows must pass the protected admission read.
5. Read the new donation/listing/claim/task IDs, V3 version/hold, lease/server times
   and protected overview. Confirm these are exactly the three intended eligible
   tasks; other eligible claims are a pilot blocker, not permission to release them.
   Explicitly review and repin the staged manifest with the NEW task IDs. Do not
   execute the old historical task manifest or replace uncertain operation IDs.
6. Approve one staged planning/authorization operation. Invoke plan once, inspect
   `EXACT_CANDIDATE_VERIFIED` and ATTESTED with precisely those three tasks on V3,
   then invoke authorize separately. Respect the existing snapshot freshness limit
   (normally 300 seconds). Any failed or uncertain result means STOP, no retry.
7. Refresh Flutter Pickup Routes, open the NEW V3 route, and inspect authoritative
   authorization, ordered stops and action permissions. Operator authorization
   does not start pickup and needs no local Flutter planning record.
8. After new-route execution approval, press Start Route ONCE. This creates only
   that route's execution intent and starts its first permitted stop. Complete the
   current stop only after actual collection OR explicitly approved synthetic
   handover. Confirmed completion triggers a fresh permission read and starts only
   the next permitted stop under that Start Route intent. Keep the page foreground;
   leaving/reopening pauses rather than starting a stop automatically.
9. Repeat completion in the AUTHORIZED order (fixture names A/B/C do not prescribe
   optimizer order). After all are COLLECTED, explicitly confirm actual or approved
   simulated depot return. Protected closure requires `can_close=true`.
10. Read-only verification after each stage: task DISPATCHED / donation
    PICKUP_IN_PROGRESS at start; task/donation COLLECTED, listing CLOSED and claim/
    lease COMPLETED at completion; route COMPLETED, binding closed, assignments
    removed and V3 hold released after depot closure. Verify audits and no unexpected
    cases. Old V2 evidence must not be changed. Actual writes remain database-controlled.

## Commands for review only

After approval, stop ONLY the old planner in its own terminal, then:

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
& '.\backend\routing\worker_service\windows\Start-Worker.ps1' -Mode planner -GraphId 'eab1f7ee-a8e0-4bed-a0e1-2c4bff024936' -Activate -ApprovalRef '<APPROVED_RESTART_REF>' -EnableCombinedWorkflow -EnableExactWorkflow
```

Leave the validator running; start it through its existing approved command only
if unavailable and separately approved. Preserve its credentials/configuration.

```powershell
& "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" reverse tcp:8787 tcp:8787
& "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" reverse tcp:8788 tcp:8788
& '.\.venv-stage8\Scripts\python.exe' -B '.\scripts\Run-ExactV3Pilot.py' --stage plan --approval-ref '<APPROVED_PILOT_REF>'
# STOP: inspect exact verified result; do not press Flutter Generate.
& '.\.venv-stage8\Scripts\python.exe' -B '.\scripts\Run-ExactV3Pilot.py' --stage authorize --approval-ref '<APPROVED_PILOT_REF>'
```

## Minimum approval groups

1. Planner-only restart, read-only readiness and in-memory use of the matching
   authenticated DEV phone session (no APK update or migration).
2. Named donor/NGO, exact new synthetic fixtures and locations/photos, publication,
   claims, reviewed new task manifest, and ONE staged planning/authorization attempt.
3. New-route Start Route intent (including automatic next-stop starts), all three
   completions and depot closure. If no physical handover/return occurs, explicitly
   designate this as synthetic DEV simulation and acknowledge ordinary RPC audits
   record normal lifecycle SUCCESS, not a server-derived simulation flag. Do not
   describe that evidence as actual food collection.

Synthetic labels do not enforce private discovery isolation. Approve a controlled
DEV test window. If private-only visibility or server-derived synthetic provenance
is mandatory, stop for a separate decision rather than altering security controls.
