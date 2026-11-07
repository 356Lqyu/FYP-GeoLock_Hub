# Offline inspection only. Never imports encrypted profiles or activates workers.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
$python = Join-Path $root '.venv-stage8/Scripts/python.exe'
if (-not (Test-Path -LiteralPath $python)) { throw 'Create .venv-stage8 with Python 3.12 and install worker_service/requirements.txt first.' }
Push-Location $root
try {
    & $python -B (Join-Path $PSScriptRoot 'local_setup_check.py')
    if ($LASTEXITCODE -ne 0) { throw 'Offline setup check failed; see fixed diagnostic labels above. No DEV connection was attempted.' }
} finally { Pop-Location }
