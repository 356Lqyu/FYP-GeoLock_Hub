# Offline inspection only. Never imports encrypted profiles or activates workers.
[CmdletBinding()]
param(
    [switch]$ValidateOnly,
    [string]$CaPath,
    [string]$DbHost
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
$python = Join-Path $root '.venv-stage8/Scripts/python.exe'
if (-not (Test-Path -LiteralPath $python)) { throw 'Create .venv-stage8 with Python 3.12 and install worker_service/requirements.txt first.' }
Push-Location $root
try {
    $arguments = @('-B', (Join-Path $PSScriptRoot 'local_setup_check.py'))
    if ($ValidateOnly) { $arguments += '--validate-only' }
    if ($CaPath) { $arguments += @('--ca-path', $CaPath) }
    if ($DbHost) { $arguments += @('--db-host', $DbHost) }
    & $python @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Offline setup check failed; see fixed diagnostic labels above. No DEV connection was attempted.' }
} finally { Pop-Location }
