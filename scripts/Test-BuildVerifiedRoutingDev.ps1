# Offline only: no Flutter build, device action or database connection.
$ErrorActionPreference='Stop'
$path=Join-Path $PSScriptRoot 'Build-VerifiedRoutingDev.ps1'
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw 'Builder PowerShell syntax invalid.' }
$checks=0
foreach ($case in @(
    @{args=@{};expected=$false},
    @{args=@{EnableRouteResolution=$true};expected=$true},
    @{args=@{EnableRouteResolution=$false};expected=$false},
    @{args=@{EnableRouteResolution=$true;Install=$true};expected=$true}
)) {
    $arguments=$case.args
    $config=& $path -CheckConfig @arguments | ConvertFrom-Json
    if ($config.mode -ne 'OFFLINE_CONFIGURATION_CHECK' -or $config.build_attempted -ne $false -or $config.installation_attempted -ne $false) { throw 'Offline validation attempted a build or installation.' }
    if ($config.route_resolution_enabled -isnot [bool] -or $config.route_resolution_enabled -ne $case.expected) { throw 'Wrong flag selection or JSON type.' }
    if ($config.environment -ne 'dev' -or $config.planner_url -ne 'http://127.0.0.1:8787') { throw 'DEV configuration changed.' }
    $expected=@('--dart-define=GEOLOCK_SUPABASE_ENV=dev','--dart-define=GEOLOCK_ROUTING_API_URL=http://127.0.0.1:8787',('--dart-define=GEOLOCK_ROUTE_RESOLUTION_ENABLED='+$case.expected.ToString().ToLowerInvariant()))
    if ($config.defines.Count -ne 3 -or (Compare-Object $expected $config.defines)) { throw 'Defines disagree with selected configuration.' }
    $checks++
}
# Verify the actual build and manifest consume the same checked settings.
$source=[IO.File]::ReadAllText($path)
if (!$source.Contains('build apk --debug --no-pub @defines') -or !$source.Contains('route_resolution_enabled=$routeResolutionEnabled;defines=$defines;')) { throw 'Build/manifest configuration is not shared.' }
Write-Output "PASS: $checks configuration cases; PowerShell syntax and shared build/manifest settings. No APK, device or database action."
