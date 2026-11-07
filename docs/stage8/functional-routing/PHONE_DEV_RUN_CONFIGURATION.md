# Physical Android DEV run: preserve the routing URL

28 October 2026. Installed generic app-debug.apk hash
0e25c191160fed5d8107fed48226e76f1bc3533202419c8530d77a58846c49c4
matched local build/app/outputs/flutter-apk/app-debug.apk. Current app process
logged PLANNER_URL_MISSING at 15:08:01 MYT. It was different from the approved
named APK, establishing an overwrite with a build missing the routing define.
The exact earlier Flutter command was not captured; no claim is made about its
complete argument list. Plain flutter run does not inherit defines from a
previously installed APK. Dart defines are compile-time inputs for EACH run/build.

Restored with adb install -r (no uninstall/data reset):
geolock-dev-routing-20261028T065304Z-b58a3d.apk
Installed SHA-256 verified:
009dc88c54a98ff8b03ba50da758240ecda50624d7c879956a3ce92c76c649a1.
Owner-scoped operation/history strings compared byte-for-byte before/after;
identical, including blocked request 20a8b059... and saved planning d184df24... .
Planner/validator health HTTP200 ACTIVE for rcgyuwiidqvrgbxswhqj and ADB reverse
8787/8788 present. No business request, local dismissal or Supabase change.

To open the EXACT installed artifact, use the phone's app icon; no rebuild needed.
For development with hot reload, use this launcher from the repository root:

```powershell
& '.\scripts\Run-RoutingDev.ps1' -Device '6f44c56b1020'
```

It always includes GEOLOCK_SUPABASE_ENV=dev and
GEOLOCK_ROUTING_API_URL=http://127.0.0.1:8787, sets both reverse mappings and
targets the specified phone. It rebuilds/reinstalls CURRENT source, so its hash
can legitimately differ from a pinned approved APK; use it for intentional
development, not as proof of an unchanged release artifact. It never uninstalls,
clears storage, starts workers or generates routes. Existing blocked-operation
history remains governed by the normal protected app workflow.

Equivalent explicit command from frontend/geolock_hub_app:

```powershell
& 'C:\flutter\src\flutter\bin\flutter.bat' run --debug --no-pub -d '6f44c56b1020' --dart-define=GEOLOCK_SUPABASE_ENV=dev --dart-define=GEOLOCK_ROUTING_API_URL=http://127.0.0.1:8787
```

Avoid an unconfigured IDE Run button or bare flutter run for this pilot. Hot
reload/restart within a correctly configured run retains its defines; a fresh
run/build needs them again. Use Build-VerifiedRoutingDev.ps1 for a NEW named
checksum-verified artifact when intentionally building a release for review.
Do not install an ambiguous generic app-debug.apk over a pinned artifact.

Offline launcher regression: scripts/Test-RunRoutingDev.ps1 PASS (PowerShell AST,
both fixed defines, reverse mappings and CheckConfig mode). Launcher was NOT run
against the device during this task, preserving the restored approved APK.
Latest code suite remains the prior 71 passing Flutter tests; no Dart production
code changed here, so it was not rerun. Physical missing-warning confirmation is
verified from the visible Pickup Routes hierarchy: correct page/Route support/
eligible-donation labels, no missing-URL warning, and current process logs
GeoLockRouting configuration=READY at 15:15:30 MYT. Checksum restoration PASS.
