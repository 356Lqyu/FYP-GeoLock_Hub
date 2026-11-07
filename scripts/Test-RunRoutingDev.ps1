# Offline regression: parse the launcher and inspect its immutable run settings.
$ErrorActionPreference='Stop'
$scriptPath=Join-Path $PSScriptRoot 'Run-RoutingDev.ps1'
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Launcher syntax failed.'}
$source=[IO.File]::ReadAllText($scriptPath)
foreach($required in @('--dart-define=GEOLOCK_SUPABASE_ENV=dev','--dart-define=GEOLOCK_ROUTING_API_URL=http://127.0.0.1:8787','run --debug --no-pub -d $Device @defines','reverse tcp:8787 tcp:8787','reverse tcp:8788 tcp:8788')) {
 if(-not $source.Contains($required)){throw 'Required DEV run setting missing.'}
}
if($source -match '\b(uninstall|pm clear)\s+com\.example'){throw 'Destructive app reset must not be present.'}
$result=& $scriptPath -Device 'synthetic-offline-device' -CheckConfig | ConvertFrom-Json
if($result.defines.Count -ne 2 -or $result.database_operations -ne $false -or $result.mode -ne 'OFFLINE_CONFIGURATION_CHECK'){throw 'Offline run configuration invalid.'}
Write-Output 'PASS: launcher syntax, both fixed dart-defines, ADB reverse and offline configuration. No device/database action executed.'
