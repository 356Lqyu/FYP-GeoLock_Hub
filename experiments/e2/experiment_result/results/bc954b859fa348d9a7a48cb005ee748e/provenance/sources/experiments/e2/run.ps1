[CmdletBinding()]
param(
    [ValidateSet('all', 'baseline1', 'baseline2', 'proposed')]
    [string]$Method = 'all',
    [switch]$PreflightOnly,
    [switch]$AllowStart,
    [switch]$Hosted,
    [string]$ConfirmProject,
    [string]$Python
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if (-not $Python) {
    $Python = Join-Path $PSScriptRoot '..\..\.venv-e2\Scripts\python.exe'
}
if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
    throw "Python executable not found at '$Python'. Create .venv-e2 or pass -Python with an executable path."
}
$Python = (Resolve-Path -LiteralPath $Python).Path
$runner = Join-Path $PSScriptRoot 'run_e2.py'
$runnerArgs = @('--method', $Method.ToLowerInvariant())
if ($PreflightOnly) { $runnerArgs += '--preflight-only' }
if ($AllowStart) { $runnerArgs += '--allow-start' }
if ($Hosted) { $runnerArgs += @('--mode', 'hosted') }
if ($ConfirmProject) { $runnerArgs += @('--confirm-project', $ConfirmProject) }
& $Python $runner @runnerArgs
exit $LASTEXITCODE
