# Builds and optionally installs one named DEV artifact. Never clears app data.
[CmdletBinding()]
param([switch]$Install, [switch]$EnableRouteResolution, [switch]$CheckConfig)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$app = Join-Path $repo 'frontend/geolock_hub_app'
$dart = 'C:/flutter/src/flutter/bin/cache/dart-sdk/bin/dart.exe'
$flutter = 'C:/flutter/src/flutter/bin/cache/flutter_tools.snapshot'
$adb = Join-Path $env:LOCALAPPDATA 'Android/Sdk/platform-tools/adb.exe'
$routeResolutionEnabled = [bool]$EnableRouteResolution
$defines = @(
    '--dart-define=GEOLOCK_SUPABASE_ENV=dev',
    '--dart-define=GEOLOCK_ROUTING_API_URL=http://127.0.0.1:8787',
    ('--dart-define=GEOLOCK_ROUTE_RESOLUTION_ENABLED=' + $routeResolutionEnabled.ToString().ToLowerInvariant())
)
if ($CheckConfig) {
    [ordered]@{mode='OFFLINE_CONFIGURATION_CHECK';environment='dev';planner_url='http://127.0.0.1:8787';route_resolution_enabled=$routeResolutionEnabled;defines=$defines;build_attempted=$false;installation_attempted=$false} | ConvertTo-Json
    return
}
$tag = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,6)
$destination = Join-Path $app ('build/verified-dev-routing/geolock-dev-routing-' + $tag + '.apk')
$manifest = $destination + '.json'
if ((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath $manifest)) { throw 'Refuse to overwrite a release artifact.' }
Push-Location $app
try {
    # Keep this build sequential: tests/other Flutter builds must not run in parallel.
    & $dart $flutter --no-version-check build apk --debug --no-pub @defines
    if ($LASTEXITCODE -ne 0) { throw 'DEV build failed; no installation attempted.' }
    $source = Join-Path $app 'build/app/outputs/flutter-apk/app-debug.apk'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($source)
    try {
        $entry = $zip.GetEntry('assets/flutter_assets/kernel_blob.bin')
        if ($null -eq $entry) { throw 'Expected debug kernel missing.' }
        $stream = $entry.Open()
        $memory = [IO.MemoryStream]::new()
        try {
            $stream.CopyTo($memory)
            $kernel = [Text.Encoding]::UTF8.GetString($memory.ToArray())
            if (!$kernel.Contains('http://127.0.0.1:8787')) { throw 'Compiled DEV planner URL missing.' }
        } finally { $stream.Dispose(); $memory.Dispose(); $kernel = $null }
    } finally { $zip.Dispose() }
    New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination
    $sha = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sha -ne (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'Build output changed during copy; no installation.' }
    [ordered]@{ apk=$destination;sha256=$sha;bytes=(Get-Item -LiteralPath $destination).Length;environment='dev';planner_url='http://127.0.0.1:8787';route_resolution_enabled=$routeResolutionEnabled;defines=$defines;built_at_utc=[DateTime]::UtcNow.ToString('o');installation_requested=[bool]$Install } |
        ConvertTo-Json | Set-Content -LiteralPath $manifest -Encoding UTF8
    if ($Install) {
        & $adb install -r $destination
        if ($LASTEXITCODE -ne 0) { throw 'Install failed; do not uninstall or clear data.' }
        $installed = ((& $adb shell pm path com.example.geolock_hub_app) -replace '^package:','').Trim()
        if ($installed -notmatch '^/data/app/[a-zA-Z0-9_./=+~-]+/base.apk$') { throw 'Unexpected installed package path.' }
        $line = ((& $adb shell sha256sum $installed) -join '').Trim()
        if ($LASTEXITCODE -ne 0 -or ($line -split '\s+')[0] -ne $sha) { throw 'Installed APK hash does not match named artifact.' }
        & $adb reverse tcp:8787 tcp:8787
        if ($LASTEXITCODE -ne 0) { throw 'Planner ADB reverse failed.' }
        & $adb reverse tcp:8788 tcp:8788
        if ($LASTEXITCODE -ne 0) { throw 'Validator ADB reverse failed.' }
        & $adb shell am start -n com.example.geolock_hub_app/.MainActivity
        if ($LASTEXITCODE -ne 0) { throw 'App launch failed.' }
        Write-Host 'Installed exact verified DEV artifact; app data retained. No business action invoked.'
    }
    Write-Host "APK: $destination"
    Write-Host "SHA256: $sha"
    Write-Host "Manifest: $manifest"
} finally { Pop-Location }
