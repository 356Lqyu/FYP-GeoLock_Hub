# Explicit operator-run catalog/planning inspection only; never executes a graph load.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$psql='C:\Program Files\PostgreSQL\17\bin\psql.exe'
$service=Join-Path $repo 'backups\stage-a003\pg_service.conf'
$sql=Join-Path $PSScriptRoot 'GRAPH_PAGING_PLAN.readonly.sql'
if (!(Test-Path -LiteralPath $service -PathType Leaf)) { throw 'Approved read-only owner export service missing.' }
if (!(Test-Path -LiteralPath $psql -PathType Leaf)) { throw 'Native PostgreSQL17 psql missing.' }
# Libpq options/startup settings must not inherit arbitrary caller overrides.
# Restore the caller environment afterward, never save passwords or connection strings.
$saved=@{}
foreach ($entry in @(Get-ChildItem Env:)) {
    if ($entry.Name -match '^PG') { $saved[$entry.Name]=$entry.Value; Remove-Item -LiteralPath ('Env:'+ $entry.Name) }
}
try {
    $env:PGSERVICEFILE=$service
    $env:PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=10000 -c lock_timeout=2000'
    & $psql -X -W --dbname 'service=geolock_dev_owner_export' --set ON_ERROR_STOP=1 --file $sql
    if ($LASTEXITCODE -ne 0) { throw 'Read-only plan check failed. STOP; no full probe retry.' }
} finally {
    foreach ($entry in @(Get-ChildItem Env:)) {
        if ($entry.Name -match '^PG') { Remove-Item -LiteralPath ('Env:'+ $entry.Name) }
    }
    foreach ($name in $saved.Keys) { Set-Item -LiteralPath ('Env:'+ $name) -Value $saved[$name] }
}
