# Physical Android DEV run. Both compile-time defines are mandatory and fixed.
# For launching the exact installed APK without rebuilding, use the phone icon.
[CmdletBinding()]
param([string]$Device, [switch]$CheckConfig)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$app=Join-Path $repo 'frontend/geolock_hub_app'
$dart='C:/flutter/src/flutter/bin/cache/dart-sdk/bin/dart.exe'
$flutter='C:/flutter/src/flutter/bin/cache/flutter_tools.snapshot'
$adb=Join-Path $env:LOCALAPPDATA 'Android/Sdk/platform-tools/adb.exe'
$defines=@('--dart-define=GEOLOCK_SUPABASE_ENV=dev','--dart-define=GEOLOCK_ROUTING_API_URL=http://127.0.0.1:8787')
foreach($path in @($dart,$flutter,$adb,$app)) {
 if(-not(Test-Path -LiteralPath $path)){throw 'Required local Flutter/ADB workspace dependency unavailable.'}
}
if($CheckConfig){
 [ordered]@{mode='OFFLINE_CONFIGURATION_CHECK';working_directory=$app;device=$Device;defines=$defines;database_operations=$false} | ConvertTo-Json
 return
}
if(-not $Device){
 $connected=@((& $adb devices) | Where-Object {$_ -match '^\S+\s+device$'} | ForEach-Object {($_ -split '\s+')[0]})
 if($LASTEXITCODE -ne 0 -or $connected.Count -ne 1){throw 'Specify -Device with exactly one authorized physical Android device.'}
 $Device=$connected[0]
}
if($Device -notmatch '^[a-zA-Z0-9._:-]+$'){throw 'Invalid device identifier.'}
& $adb -s $Device reverse tcp:8787 tcp:8787
if($LASTEXITCODE -ne 0){throw 'Planner ADB reverse failed.'}
& $adb -s $Device reverse tcp:8788 tcp:8788
if($LASTEXITCODE -ne 0){throw 'Validator ADB reverse failed.'}
Push-Location $app
try {
 & $dart $flutter --no-version-check run --debug --no-pub -d $Device @defines
 if($LASTEXITCODE -ne 0){throw 'DEV Flutter run failed. Do not uninstall or clear app storage.'}
} finally {Pop-Location}
