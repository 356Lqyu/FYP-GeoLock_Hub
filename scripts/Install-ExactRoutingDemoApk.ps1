# Operator-run only after separate installation approval. Never builds or clears data.
[CmdletBinding()]
param([switch]$ValidateOnly)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$apk=Join-Path $repo 'frontend/geolock_hub_app/build/verified-dev-routing/geolock-dev-routing-20261029T192415Z-940510.apk'
$expected='ccc835761d4e673fc447993f341ebf8750dc5fbf4917d160e2c338871d4a7210'
$manifest=Get-Content -LiteralPath ($apk+'.json') -Raw | ConvertFrom-Json
if ((Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected -or
    $manifest.sha256 -ne $expected -or $manifest.bytes -ne (Get-Item -LiteralPath $apk).Length -or
    $manifest.environment -ne 'dev' -or $manifest.planner_url -ne 'http://127.0.0.1:8787' -or
    $manifest.route_resolution_enabled -ne $false) {throw 'Exact approved DEV artifact mismatch. STOP.'}
$adb=Join-Path $env:LOCALAPPDATA 'Android/Sdk/platform-tools/adb.exe'
if (!(Test-Path -LiteralPath $adb -PathType Leaf)) {throw 'Existing Android SDK adb unavailable.'}
if ($ValidateOnly) {
    [ordered]@{status='PASS / LOCAL ARTIFACT CHECK ONLY';sha256=$expected;route_resolution_enabled=$false;installed=$false;device_contacted=$false} | ConvertTo-Json
    return
}
$devices=@((& $adb devices) | Where-Object {$_ -match '^\S+\s+device$'} | ForEach-Object {($_ -split '\s+')[0]})
if ($LASTEXITCODE -ne 0 -or $devices.Count -ne 1) {throw 'Exactly one authorized Android device required. No installation attempted.'}
$device=$devices[0]
& $adb -s $device install -r $apk
if ($LASTEXITCODE -ne 0) {throw 'Install failed. Do not uninstall, clear storage or retry automatically.'}
$packageLines=@(& $adb -s $device shell pm path com.example.geolock_hub_app)
if ($LASTEXITCODE -ne 0 -or $packageLines.Count -ne 1) {throw 'Cannot verify installed package. STOP.'}
$installed=($packageLines[0] -replace '^package:','').Trim()
if ($installed -notmatch '^/data/app/[a-zA-Z0-9_./=+~-]+/base.apk$') {throw 'Unexpected installed package path.'}
$digest=((& $adb -s $device shell sha256sum $installed) -join '').Trim()
if ($LASTEXITCODE -ne 0 -or ($digest -split '\s+')[0] -ne $expected) {throw 'Installed artifact checksum mismatch. STOP.'}
foreach ($port in @(8787,8788)) {
    & $adb -s $device reverse "tcp:$port" "tcp:$port"
    if ($LASTEXITCODE -ne 0) {throw 'ADB reverse failed. STOP.'}
}
& $adb -s $device shell am start -n com.example.geolock_hub_app/.MainActivity
if ($LASTEXITCODE -ne 0) {throw 'Installed APK verified but launch failed. STOP.'}
Write-Host 'Exact APK installed in place and verified; ADB reverse set; app launched. No business action invoked. Do not press Generate or pickup controls.'
