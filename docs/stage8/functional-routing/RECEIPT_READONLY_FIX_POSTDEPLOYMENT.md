# Receipt-only migration: DEPLOYED / READ-ONLY POSTFLIGHT PASS

28 October 2026. User executed the approved migration through the native installer;
independent read-only catalog checks confirm receipt MD5
71203f7bc55086683d60f3d0afabbe54, unchanged owner/STABLE/SECURITY DEFINER/config/ACL
and unchanged writer helper MD5 15d5c2547cabd5df199e104451f5c2d6. The other 142
functions, graph, policy, leases and recovery configuration retain their saved
fingerprints. No additional SQL was deployed during verification.

At 14:52:32 MYT the existing signed-in physical Android NGO session called hosted
get_my_routing_authorization_receipt for original request
20a8b059-63fc-40b6-bea9-0751ef1a199b. Supabase edge log confirms POST HTTP200
(Dart/3.12), contract geolock.routing-auto-now.v1, expected owner and NOT_FOUND.
At 14:52:34 MYT the planner made the same receipt read under that verified NGO
context: hosted POST HTTP200 (Python-urllib/3.12). The phone's planner capability
client accepted HTTP200 with automatic_departure=true and
combined_generation_enabled=true. Thus both real hosted paths pass and the prior
SELECT FOR SHARE / read-only transaction defect is resolved. No JWT was extracted,
printed or persisted; the approved checks ran within the existing app session.

Initial local debug-expression attempts failed at compilation before API reads;
the single-line expression correction allowed one completed verification pair.
Those compiler failures are not database or authentication failures.

Post-check catalog: 4 snapshots, 1 candidate, 1 validation, 0 routes, 0 assignments,
0 owner authorization receipts and no snapshot for the blocked request. The exact
owner-scoped local blocked/preflight entry remains in Android preferences, with
its original request ID, vehicle and historical error code. Neither verification
call dismissed, resumed or replaced it. Historical saved candidate unchanged.

Evidence: results/receipt-readonly-fix/hosted-verification.json. Debug helper:
scripts/Verify-PhoneRoutingReads.dart. No full graph load, service restart, recovery
call, planning request, authorization, pickup or APK installation occurred.

Verified build (not installed):
frontend/geolock_hub_app/build/verified-dev-routing/geolock-dev-routing-20261028T065304Z-b58a3d.apk
SHA-256: 009dc88c54a98ff8b03ba50da758240ecda50624d7c879956a3ce92c76c649a1.
Built with GEOLOCK_SUPABASE_ENV=dev and GEOLOCK_ROUTING_API_URL=http://127.0.0.1:8787;
named artifact checksum matches build output and manifest installation_requested=false.

The simplified UI is locally tested (71 Flutter tests and clean focused analysis),
and the receipt correction has 15 disposable PG17.11 regression tests. A verified
DEV APK build is prepared separately; installation requires explicit approval.
The blocked preflight setup still requires the user's explicit safe dismissal
with local history retained before a new controlled planning attempt. Fresh
claim/vehicle eligibility and separate business-operation authorization remain
required. These read passes do not establish a completed live routing lifecycle.
