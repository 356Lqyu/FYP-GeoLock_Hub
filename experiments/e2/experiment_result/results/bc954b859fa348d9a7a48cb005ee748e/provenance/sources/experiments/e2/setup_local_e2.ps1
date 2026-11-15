[CmdletBinding()]
param(
    [string]$PgBin = (Join-Path $env:ProgramFiles 'PostgreSQL\17\bin'),
    [ValidateRange(1024, 65535)]
    [int]$Port = 55432
)

$ErrorActionPreference = 'Stop'
# PowerShell 7.3+ can promote native stderr to terminating errors when the user
# enables this preference. E2 captures stderr explicitly and checks exit codes.
$PSNativeCommandUseErrorActionPreference = $false
$E2Root = $PSScriptRoot
$RepoRoot = (Resolve-Path (Join-Path $E2Root '..\..')).Path
$LocalRoot = Join-Path $env:LOCALAPPDATA 'GeoLockHub\E2'
$DataDir = Join-Path $LocalRoot 'cluster\data'
$ConfigPath = Join-Path $LocalRoot 'local.json'
$LogPath = Join-Path $LocalRoot 'postgresql.log'
$DatabaseName = 'geolock_e2'
$HostAddress = '127.0.0.1'
$StartedHere = $false
$ClusterStartAttempted = $false

. (Join-Path $PSScriptRoot 'test_harness\e2_postgres_client.ps1')

if ($Port -eq 5432) { throw 'E2 requires a dedicated port other than 5432.' }

function Assert-LocalPortFree {
    $listener = $null
    try {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse($HostAddress), $Port)
        $listener.Start()
    } catch {
        throw "E2 setup refused: loopback port $Port is already occupied or unavailable. No PostgreSQL service was changed."
    } finally {
        if ($null -ne $listener) { $listener.Stop() }
    }
}

function Assert-NotReparsePoint {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "E2 setup refused a reparse point: $Path"
        }
    }
}

if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set; E2 local configuration cannot be stored safely.' }
if (-not (Test-Path -LiteralPath $PgBin -PathType Container)) { throw "PostgreSQL 17 bin directory not found: $PgBin" }
$PgBin = (Resolve-Path -LiteralPath $PgBin).Path
$Executables = @('initdb.exe', 'pg_ctl.exe', 'createdb.exe', 'psql.exe', 'postgres.exe', 'pg_config.exe', 'pg_controldata.exe')
foreach ($name in $Executables) {
    if (-not (Test-Path -LiteralPath (Join-Path $PgBin $name) -PathType Leaf)) {
        throw "Required PostgreSQL executable is missing: $(Join-Path $PgBin $name)"
    }
}

$version = (Invoke-E2Native (Join-Path $PgBin 'postgres.exe') @('--version') | Out-String).Trim()
if ($version -notmatch '\b17\.') { throw "PostgreSQL 17 is required; found: $version" }
$sharedir = (Invoke-E2Native (Join-Path $PgBin 'pg_config.exe') @('--sharedir') | Out-String).Trim()
foreach ($extension in @('pgcrypto', 'postgis')) {
    if (-not (Test-Path -LiteralPath (Join-Path $sharedir "extension\$extension.control") -PathType Leaf)) {
        throw "PostgreSQL extension '$extension' is unavailable in this PostgreSQL 17 installation. Install the PostgreSQL 17-compatible extension package, then rerun setup."
    }
}

$authSql = Join-Path $E2Root 'database\00_local_auth_compat.sql'
$markerSql = Join-Path $E2Root 'database\00_provision_e2_target_marker.sql'
foreach ($file in @($authSql, $markerSql)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required E2 setup SQL is missing: $file" }
}

$repoPrefix = [IO.Path]::GetFullPath($RepoRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$localFull = [IO.Path]::GetFullPath($LocalRoot)
if ($localFull.Equals($repoPrefix.TrimEnd([IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase) -or
    $localFull.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'E2 local cluster and config must remain outside the repository.'
}
$checkPath = $LocalRoot
while ($checkPath) {
    Assert-NotReparsePoint $checkPath
    $parentPath = Split-Path -Parent $checkPath
    if (-not $parentPath -or $parentPath -eq $checkPath) { break }
    $checkPath = $parentPath
}
Assert-NotReparsePoint (Join-Path $LocalRoot 'cluster')
Assert-NotReparsePoint $DataDir
Assert-NotReparsePoint $ConfigPath
if (Test-Path -LiteralPath $DataDir) { throw "E2 setup refused: cluster data directory already exists: $DataDir. It will not reuse or delete it. Use recover_local_e2.ps1 only after reviewing the existing cluster." }
if (Test-Path -LiteralPath $ConfigPath) { throw "E2 setup refused: local config already exists: $ConfigPath. It will not overwrite it." }
if (Test-Path -LiteralPath $LogPath) { throw "E2 setup refused: a PostgreSQL log already exists at $LogPath. Review it before setup; it will not be appended or overwritten." }
if (Test-Path -LiteralPath $LocalRoot) {
    $existingSetupItems = @(Get-ChildItem -LiteralPath $LocalRoot -Force)
    if ($existingSetupItems.Count -gt 0) {
        throw "E2 setup refused: reserved local E2 root is not empty: $LocalRoot. Review its contents; setup will not reuse or delete them."
    }
}
Assert-LocalPortFree

New-Item -ItemType Directory -Path $LocalRoot -Force | Out-Null
Assert-NotReparsePoint $LocalRoot
New-Item -ItemType Directory -Path (Split-Path -Parent $DataDir) -Force | Out-Null
Assert-NotReparsePoint (Split-Path -Parent $DataDir)
$targetId = [Guid]::NewGuid().ToString('N')
$pgCtl = Join-Path $PgBin 'pg_ctl.exe'
$psql = Join-Path $PgBin 'psql.exe'
$createdb = Join-Path $PgBin 'createdb.exe'

try {
    Invoke-E2Native (Join-Path $PgBin 'initdb.exe') @('-D', $DataDir, '-U', 'postgres', '--encoding=UTF8', '--no-locale', '--auth-local=trust', '--auth-host=trust') | Out-Null

    @("listen_addresses = '$HostAddress'", "port = $Port", 'password_encryption = scram-sha-256') |
        Add-Content -LiteralPath (Join-Path $DataDir 'postgresql.conf') -Encoding ASCII
    @(
        '# E2-owned local cluster: TCP only on IPv4 loopback.',
        'local all all trust',
        "host all all $HostAddress/32 trust",
        'host all all ::1/128 reject',
        'host all all 0.0.0.0/0 reject',
        'host all all ::/0 reject'
    ) | Set-Content -LiteralPath (Join-Path $DataDir 'pg_hba.conf') -Encoding ASCII

    $startOptions = "-h $HostAddress -p $Port -c listen_addresses=$HostAddress"
    # Mark before invocation so the finally block can clean up if PowerShell is
    # interrupted while pg_ctl -w start is still waiting.
    $ClusterStartAttempted = $true
    & $pgCtl -D $DataDir -l $LogPath -o $startOptions -w -t 45 start
    if ($LASTEXITCODE -ne 0) { throw "pg_ctl start failed (exit $LASTEXITCODE). Review '$LogPath'." }
    $StartedHere = $true
    Invoke-E2PostgresClient $createdb @('-h', $HostAddress, '-p', [string]$Port, '-U', 'postgres', '-T', 'template0', $DatabaseName) | Out-Null
    Invoke-E2PostgresClient $psql @('-X', '-v', 'ON_ERROR_STOP=1', '-h', $HostAddress, '-p', [string]$Port,
        '-U', 'postgres', '-d', $DatabaseName, '-f', $authSql) | Out-Null
    Invoke-E2PostgresClient $psql @('-X', '-v', 'ON_ERROR_STOP=1', '-v', "e2_target_id=$targetId",
        '-h', $HostAddress, '-p', [string]$Port, '-U', 'postgres', '-d', $DatabaseName, '-f', $markerSql) | Out-Null
    $clusterId = (Invoke-E2PostgresClient $psql @('-X', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-h', $HostAddress,
        '-p', [string]$Port, '-U', 'postgres', '-d', $DatabaseName, '-c',
        'select system_identifier::text from pg_control_system()') | Out-String).Trim()
    if ($clusterId -notmatch '^\d+$') { throw 'Could not verify the new local PostgreSQL cluster identifier.' }
} catch {
    $nativeError = $_.Exception.Message
    throw "E2 setup stopped. Any newly created cluster data was preserved for review at '$DataDir'. Error: $nativeError. Inspect postgresql.log and pg_controldata; do not delete or reinitialize the cluster."
} finally {
    if ($StartedHere -or $ClusterStartAttempted) {
        $statusOutput = & $pgCtl -D $DataDir status 2>&1
        $statusCode = $LASTEXITCODE
        if ($statusCode -eq 0) {
            $stopOutput = & $pgCtl -D $DataDir -m fast -w -t 45 stop 2>&1
            if ($LASTEXITCODE -ne 0) { Write-Warning "Could not stop only the E2-created cluster. Inspect '$LogPath' and '$DataDir' before retrying." }
        } elseif ($statusCode -ne 3) {
            Write-Warning "Could not determine the E2 cluster status after setup interruption. No other cluster was targeted. Inspect '$LogPath' and '$DataDir' before retrying."
        }
    }
}

$config = [ordered]@{
    version = 1
    mode = 'local'
    host = $HostAddress
    port = $Port
    dbname = $DatabaseName
    user = 'postgres'
    target_id = $targetId
    cluster_system_identifier = $clusterId
    data_dir = [IO.Path]::GetFullPath($DataDir)
    pg_bin = $PgBin
    setup_approval = 'created_as_new_e2_owned_cluster'
}
$json = $config | ConvertTo-Json -Depth 4
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$configStream = [IO.File]::Open($ConfigPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $configWriter = [System.IO.StreamWriter]::new($configStream, $utf8NoBom)
    try { $configWriter.WriteLine($json) } finally { $configWriter.Dispose() }
} finally {
    if ($configStream) { $configStream.Dispose() }
}
Write-Host "E2 local cluster prepared and stopped. Config: $ConfigPath"
Write-Host "Dedicated target: $DatabaseName on 127.0.0.1:$Port. No system PostgreSQL service was registered or modified."
Write-Host 'Next: run experiments/e2/run.ps1 from the repository root.'
