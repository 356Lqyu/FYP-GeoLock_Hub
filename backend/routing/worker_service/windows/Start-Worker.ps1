[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('planner','validator')][string]$Mode,
    [switch]$CheckConfig,
    [switch]$CheckConnection,
    [switch]$Activate,
    [string]$ApprovalRef,
    [string]$GraphId,
    [switch]$EnableCombinedWorkflow,
    [switch]$EnableExactWorkflow
)
$ErrorActionPreference = 'Stop'
if ($EnableCombinedWorkflow -and (-not $Activate -or $Mode -ne 'planner')) { throw 'Combined workflow requires explicit planner activation approval.' }
if ($EnableExactWorkflow -and (-not $Activate -or $Mode -ne 'planner')) { throw 'Exact workflow requires explicit planner activation approval.' }
if ($CheckConnection -and ($Activate -or $CheckConfig)) { throw 'Read-only connection check must be invoked separately, without activation.' }
if ($CheckConfig -and $Activate) { throw 'Configuration inspection must not activate services.' }
$project = 'rcgyuwiidqvrgbxswhqj'
$directory = Join-Path $env:LOCALAPPDATA 'GeoLockHubRoutingDev'
$profileFile = Join-Path $directory ($Mode + '.clixml')
if (-not (Test-Path -LiteralPath $profileFile)) { throw 'Run Save-WorkerConfig.ps1 first.' }
$config = Import-Clixml -LiteralPath $profileFile
if ($config.Project -ne $project) { throw 'DEV project mismatch.' }

function Reveal([Security.SecureString]$Value) {
    return [System.Net.NetworkCredential]::new('', $Value).Password
}
function Quote-ConnValue([string]$Value) {
    return "'" + $Value.Replace('\','\\').Replace("'", "\'") + "'"
}
function Worker-Dsn([string]$Login) {
    if ($config.Pooled) { $Login += '.' + $project }
    # Identity/TLS only. Database passwords NEVER traverse PowerShell or env.
    return 'host=' + (Quote-ConnValue $config.DbHost) + ' port=5432 dbname=postgres user=' +
        (Quote-ConnValue $Login) +
        ' sslmode=verify-full sslrootcert=' + (Quote-ConnValue $config.Ca)
}
$names = @('GEOLOCK_PROJECT_REF','GEOLOCK_GRAPH_DSN','GEOLOCK_PLANNER_DSN',
 'GEOLOCK_VALIDATOR_DSN','GEOLOCK_VALIDATOR_TOKEN','GEOLOCK_VALIDATOR_URL',
 'GEOLOCK_SUPABASE_PUBLISHABLE_KEY','GEOLOCK_GRAPH_ID','GEOLOCK_WORKER_STATE',
 'GEOLOCK_MAX_SNAPSHOT_AGE_SECONDS','GEOLOCK_ROUTING_ALLOW_DEV_WRITES',
 'GEOLOCK_ROUTING_ACTIVATION_REF','GEOLOCK_COMBINED_ROUTE_ENABLED','GEOLOCK_EXACT_ROUTE_ENABLED')
foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
try {
    $env:GEOLOCK_PROJECT_REF = $project
    $env:GEOLOCK_VALIDATOR_TOKEN = Reveal $config.ValidatorToken
    $env:GEOLOCK_MAX_SNAPSHOT_AGE_SECONDS = '300'
    if ($Mode -eq 'validator') {
        $env:GEOLOCK_VALIDATOR_DSN = Worker-Dsn 'geolock_validator_login'
    } else {
        $env:GEOLOCK_GRAPH_DSN = Worker-Dsn 'geolock_graph_login'
        $env:GEOLOCK_PLANNER_DSN = Worker-Dsn 'geolock_planner_login'
        $env:GEOLOCK_SUPABASE_PUBLISHABLE_KEY = Reveal $config.PublishableKey
        $env:GEOLOCK_VALIDATOR_URL = 'http://127.0.0.1:8788'
        $env:GEOLOCK_GRAPH_ID = if ($GraphId) { $GraphId } else { $config.GraphId }
        $env:GEOLOCK_WORKER_STATE = Join-Path $directory 'state'
    }
    if ($Activate) {
        if (-not $ApprovalRef) { throw 'Activation requires an explicit approved change reference.' }
        if ($Mode -eq 'planner') {
            $parsed = [Guid]::Empty
            if (-not [Guid]::TryParse($env:GEOLOCK_GRAPH_ID, [ref]$parsed)) { throw 'An existing approved frozen graph UUID is required.' }
        }
        $env:GEOLOCK_ROUTING_ALLOW_DEV_WRITES = 'APPROVED'
        $env:GEOLOCK_ROUTING_ACTIVATION_REF = $ApprovalRef
        if ($EnableCombinedWorkflow) { $env:GEOLOCK_COMBINED_ROUTE_ENABLED = 'APPROVED' }
        if ($EnableExactWorkflow) { $env:GEOLOCK_EXACT_ROUTE_ENABLED = 'APPROVED' }
    }
    $root = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
    $python = Join-Path $root '.venv-stage8/Scripts/python.exe'
    if (-not (Test-Path -LiteralPath $python)) { throw 'Stage 8 Python environment not found.' }
    Push-Location $root
    try {
        $arguments = @('-B','-m','backend.routing.worker_service.native_worker','--mode',$Mode)
        if ($CheckConfig) { $arguments += '--check-config' }
        if ($CheckConnection) { $arguments += '--check-runtime-connection' }
        & $python @arguments
        if ($LASTEXITCODE -ne 0) { throw 'Worker exited unsuccessfully; no credentials are printed.' }
    } finally { Pop-Location }
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
}
