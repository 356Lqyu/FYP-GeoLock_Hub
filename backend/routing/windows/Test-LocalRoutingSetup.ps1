# Offline inspection only. Never imports encrypted profiles or activates workers.
[CmdletBinding()]
param([ValidateSet('DEV','KLSEL')][string]$Environment = 'DEV')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$python = Join-Path $root '.venv-stage8/Scripts/python.exe'
if (-not (Test-Path -LiteralPath $python)) { throw 'Create .venv-stage8 with Python 3.12 and install backend/routing/requirements.txt first.' }
$names = @('GEOLOCK_ENVIRONMENT','GEOLOCK_PG_SERVICE_FILE')
foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
if ($Environment -ne 'DEV') {
    $env:GEOLOCK_ENVIRONMENT = $Environment
    $env:GEOLOCK_PG_SERVICE_FILE = Join-Path (Join-Path $env:LOCALAPPDATA 'GeoLockHubRoutingKLSEL') 'pg_service.conf'
}
Push-Location $root
try {
    & $python -B (Join-Path $PSScriptRoot 'local_setup_check.py')
    if ($LASTEXITCODE -ne 0) { throw 'Offline setup check failed; see fixed diagnostic labels above. No DEV connection was attempted.' }
} finally {
    Pop-Location
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
}
