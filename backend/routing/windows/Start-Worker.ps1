[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('planner','validator')][string]$Mode,
    [switch]$CheckConfig,
    [switch]$CheckConnection,
    [switch]$Activate,
    [string]$ApprovalRef,
    [string]$GraphId,
    [switch]$EnableCombinedWorkflow,
    [switch]$EnableExactWorkflow,
    [ValidateSet('DEV','KLSEL')][string]$Environment = 'DEV',
    [switch]$WarmGraph
)
$ErrorActionPreference = 'Stop'
if ($EnableCombinedWorkflow -and (-not $Activate -or $Mode -ne 'planner')) { throw 'Combined workflow requires explicit planner activation approval.' }
if ($EnableExactWorkflow -and (-not $Activate -or $Mode -ne 'planner')) { throw 'Exact workflow requires explicit planner activation approval.' }
if ($CheckConnection -and ($Activate -or $CheckConfig)) { throw 'Read-only connection check must be invoked separately, without activation.' }
if ($CheckConfig -and $Activate) { throw 'Configuration inspection must not activate services.' }
if ($WarmGraph -and ($Mode -ne 'planner' -or $Activate -or $CheckConfig -or $CheckConnection -or -not $ApprovalRef)) {
    throw 'Graph warm-up is planner-only, separate from activation/checks, and needs -ApprovalRef. It starts no server.'
}
$environments = @{
    DEV   = @{ Project = 'rcgyuwiidqvrgbxswhqj'; Directory = 'GeoLockHubRoutingDev'; Label = 'DEV'; GraphId = $null
              Service = $null }
    KLSEL = @{ Project = 'ppwmdsyoesvhgmqiaoxa'; Directory = 'GeoLockHubRoutingKLSEL'; Label = 'NEW (KL/Selangor)'
              GraphId = '19c44bd2-8871-4eca-bf6b-4262f1bf766d'; Service = 'geolock_klsel_worker' }
}
$selected = $environments[$Environment]
$project = $selected.Project
$directory = Join-Path $env:LOCALAPPDATA $selected.Directory
$label = $selected.Label
if ($Environment -ne 'DEV' -and $GraphId -and $GraphId -ne $selected.GraphId) { throw ($label + ' accepts only its own frozen graph ' + $selected.GraphId + '.') }
$profileFile = Join-Path $directory ($Mode + '.clixml')
if (-not (Test-Path -LiteralPath $profileFile)) { throw ('Run Save-WorkerConfig.ps1 -Environment ' + $Environment + ' first.') }
$config = Import-Clixml -LiteralPath $profileFile
if ($config.Project -ne $project) { throw ($label + ' project mismatch.') }
if ($Environment -ne 'DEV') {
    $serviceFile = Join-Path $directory 'pg_service.conf'
    if (-not (Test-Path -LiteralPath $serviceFile)) { throw ('pg_service.conf missing in ' + $directory + '; rerun Save-WorkerConfig.ps1 -Environment ' + $Environment + '.') }
}

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
 'GEOLOCK_ROUTING_ACTIVATION_REF','GEOLOCK_COMBINED_ROUTE_ENABLED','GEOLOCK_EXACT_ROUTE_ENABLED',
 'GEOLOCK_ENVIRONMENT','GEOLOCK_PG_SERVICE_FILE')
foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
try {
    $env:GEOLOCK_PROJECT_REF = $project
    if ($Environment -ne 'DEV') {
        # DEV leaves both unset (cleared above), so a DEV run can never inherit another environment.
        $env:GEOLOCK_ENVIRONMENT = $Environment
        $env:GEOLOCK_PG_SERVICE_FILE = $serviceFile
    }
    $env:GEOLOCK_VALIDATOR_TOKEN = Reveal $config.ValidatorToken
    $env:GEOLOCK_MAX_SNAPSHOT_AGE_SECONDS = '300'
    if ($Mode -eq 'validator') {
        $env:GEOLOCK_VALIDATOR_DSN = Worker-Dsn 'geolock_validator_login'
    } else {
        $env:GEOLOCK_GRAPH_DSN = Worker-Dsn 'geolock_graph_login'
        $env:GEOLOCK_PLANNER_DSN = Worker-Dsn 'geolock_planner_login'
        $env:GEOLOCK_SUPABASE_PUBLISHABLE_KEY = Reveal $config.PublishableKey
        $env:GEOLOCK_VALIDATOR_URL = 'http://127.0.0.1:8788'
        $env:GEOLOCK_GRAPH_ID = if ($Environment -ne 'DEV') { $selected.GraphId } elseif ($GraphId) { $GraphId } else { $config.GraphId }
        $env:GEOLOCK_WORKER_STATE = Join-Path $directory 'state'
    }
    if ($Activate -or $WarmGraph) {
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
    $root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $python = Join-Path $root '.venv-stage8/Scripts/python.exe'
    if (-not (Test-Path -LiteralPath $python)) { throw 'Stage 8 Python environment not found.' }
    Push-Location $root
    try {
        $arguments = @('-B','-m','backend.routing.service.start_worker','--mode',$Mode)
        if ($CheckConfig) { $arguments += '--check-config' }
        if ($CheckConnection) { $arguments += '--check-runtime-connection' }
        if ($WarmGraph) { $arguments += '--warm-graph' }  # read-only graph download into this environment's cache; no server
        & $python @arguments
        if ($LASTEXITCODE -ne 0) { throw 'Worker exited unsuccessfully; no credentials are printed.' }
    } finally { Pop-Location }
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
}
