[CmdletBinding()]
param(
    [ValidateSet('Inspect','QuarantineStalePid','Complete')][string]$Action = 'Inspect',
    [Parameter(Mandatory)][ValidatePattern('^\d{10,30}$')][string]$ExpectedSystemIdentifier,
    [string]$PgBin = (Join-Path $env:ProgramFiles 'PostgreSQL\17\bin'),
    [ValidateRange(1024,65535)][int]$Port = 55432,
    [switch]$ApprovePostgresStartForInspection,
    [string]$ConfirmStalePid,
    [string]$ConfirmRecovery
)

# Recovery is deliberately separate from setup_local_e2.ps1. It never deletes
# cluster files. Starting a stopped cluster can perform PostgreSQL crash recovery;
# the operator must explicitly acknowledge that before any connection is made.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$LocalRoot = Join-Path $env:LOCALAPPDATA 'GeoLockHub\E2'
$DataDir = Join-Path $LocalRoot 'cluster\data'
$ConfigPath = Join-Path $LocalRoot 'local.json'
$LogPath = Join-Path $LocalRoot 'postgresql.log'
$DatabaseName = 'geolock_e2'
$HostAddress = '127.0.0.1'
$E2Root = $PSScriptRoot

. (Join-Path $PSScriptRoot 'test_harness\e2_postgres_client.ps1')

if ($Port -eq 5432) { throw 'E2 requires a dedicated port other than 5432.' }

function Invoke-Query {
    param([string]$Database,[string]$Sql)
    Write-Host "[E2 recovery] Querying '$Database' (5s connect, 5s lock, 10s statement limits)."
    $rows = @(Invoke-E2PostgresClient $Psql @('-X','-q','-A','-t','-v','ON_ERROR_STOP=1','-h',$HostAddress,
        '-p',[string]$Port,'-U','postgres','-d',$Database,'-c',$Sql) -ReadOnly |
        ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne '' })
    return ,$rows
}

function Start-E2PostgresBounded {
    $startOptions = "-h $HostAddress -p $Port -c listen_addresses=$HostAddress"
    Write-Host "[E2 recovery] Starting only the verified E2 cluster on $HostAddress`:$Port with a 45-second pg_ctl startup timeout."
    # Do not capture pg_ctl start output in a PowerShell pipeline: the detached
    # postgres child can inherit redirected handles and keep that pipeline open.
    # Server diagnostics go to the already-verified E2 postgresql.log.
    & $PgCtl -D $DataDir -l $LogPath -o $startOptions -w -t 45 start
    $startExitCode = $LASTEXITCODE
    if ($startExitCode -ne 0) {
        throw "E2 pg_ctl start returned exit $startExitCode. Inspect '$LogPath' and the E2 PID/port before retrying; pg_ctl may leave a timed-out startup running."
    }
}

function Assert-NoReparse {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Recovery refused a symbolic link or reparse point: $Path"
    }
}

function Assert-E2PostgresState {
    param([string]$RecordedPostmasterPid = '',[switch]$RequireStopped)
    $status = & $PgCtl -D $DataDir status 2>&1
    $statusCode = $LASTEXITCODE
    try { $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop) }
    catch { throw 'Recovery refused: active process inventory could not be read; process identity is uncertain.' }
    try { $services = @(Get-CimInstance -ClassName Win32_Service -Filter "Name='postgresql-x64-17'" -ErrorAction Stop) }
    catch { throw 'Recovery refused: Windows PostgreSQL service configuration could not be inspected.' }
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
        throw 'Recovery refused: Get-NetTCPConnection is unavailable, so listener ownership cannot be checked.'
    }
    . (Join-Path $PSScriptRoot 'test_harness\e2_process_safety.ps1')
    $listeners = @(Get-E2ListenerInventory -Port $Port)
    Write-Host "[E2 recovery] Process/service and port $Port inventories collected; validating ownership."
    $activeE2Pid = ''
    if ($statusCode -eq 0) { $activeE2Pid = $RecordedPostmasterPid }
    Assert-E2ProcessSafety -PgCtlStatusCode $statusCode -DataDir $DataDir -PgBin $PgBin `
        -ProgramFilesRoot $env:ProgramFiles -Port $Port -Processes $processes -Services $services `
        -Listeners $listeners -RecordedPostmasterPid $RecordedPostmasterPid -E2PostmasterPid $activeE2Pid `
        -RequireStopped:$RequireStopped
    return $statusCode
}

function Read-PostmasterPidFile {
    param([string]$Path,[string]$ExpectedDir,[int]$ExpectedPort)
    Assert-NoReparse $Path
    $raw = [IO.File]::ReadAllText($Path)
    $lines = $raw -split "`r?`n"
    if ($lines.Count -lt 4 -or $lines[0] -notmatch '^\d+$' -or $lines[3] -notmatch '^\d+$') {
        throw 'Recovery refused: postmaster.pid is malformed; preserve it for manual review.'
    }
    $recordedDir = [IO.Path]::GetFullPath($lines[1].Trim()).TrimEnd('\')
    $expected = [IO.Path]::GetFullPath($ExpectedDir).TrimEnd('\')
    if ($recordedDir -ine $expected -or [int]$lines[3] -ne $ExpectedPort) {
        throw 'Recovery refused: postmaster.pid data path or port differs from the verified E2 target.'
    }
    return [pscustomobject]@{ Pid=$lines[0].Trim(); DataDirectory=$recordedDir; Port=[int]$lines[3]; Raw=$raw }
}

if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable; recovery cannot identify the E2-owned paths.' }
if ($Action -eq 'Inspect' -and -not $ApprovePostgresStartForInspection -and -not (Test-Path -LiteralPath (Join-Path $DataDir 'postmaster.pid'))) {
    throw 'Inspecting database inventory requires starting PostgreSQL, which may replay WAL and update cluster state. Re-run only after approving that startup with -ApprovePostgresStartForInspection.'
}
if ($Action -eq 'QuarantineStalePid' -and -not (Test-Path -LiteralPath (Join-Path $DataDir 'postmaster.pid'))) {
    throw 'QuarantineStalePid requires an existing postmaster.pid; no file was changed.'
}
if ($Action -eq 'Complete' -and $ConfirmRecovery -cne "COMPLETE E2 SETUP $ExpectedSystemIdentifier") {
    throw "Completion requires -ConfirmRecovery 'COMPLETE E2 SETUP $ExpectedSystemIdentifier'. No cluster was started."
}
if (Test-Path -LiteralPath $ConfigPath) { throw "Recovery refused because local.json already exists. Use the normal read-only E2 preflight instead: $ConfigPath" }
if (-not (Test-Path -LiteralPath $DataDir -PathType Container)) { throw "E2 cluster data directory is missing: $DataDir" }
if (-not (Test-Path -LiteralPath $PgBin -PathType Container)) { throw "PostgreSQL bin directory does not exist: $PgBin" }
$PgBin = (Resolve-Path -LiteralPath $PgBin).Path
foreach ($path in @($LocalRoot,(Join-Path $LocalRoot 'cluster'),$DataDir,$PgBin,(Join-Path $PgBin 'pg_ctl.exe'),
                    (Join-Path $PgBin 'pg_controldata.exe'),(Join-Path $PgBin 'postgres.exe'),
                    (Join-Path $PgBin 'psql.exe'),(Join-Path $PgBin 'createdb.exe'))) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required recovery path is missing: $path" }
    Assert-NoReparse $path
}
for ($parent = Split-Path -Parent $LocalRoot; $parent; $parent = Split-Path -Parent $parent) {
    if (Test-Path -LiteralPath $parent) { Assert-NoReparse $parent }
    $next = Split-Path -Parent $parent
    if (-not $next -or $next -eq $parent) { break }
}
$allowedRootItems = @('cluster','postgresql.log')
$unexpectedRootItems = @(Get-ChildItem -LiteralPath $LocalRoot -Force | Where-Object { $_.Name -notin $allowedRootItems })
if ($unexpectedRootItems.Count -gt 0) { throw "Recovery refused: unexpected files are present under the E2 root: $($unexpectedRootItems.Name -join ', ')." }
$clusterParent = Join-Path $LocalRoot 'cluster'
$unexpectedClusterItems = @(Get-ChildItem -LiteralPath $clusterParent -Force | Where-Object { $_.Name -ne 'data' })
if ($unexpectedClusterItems.Count -gt 0) { throw "Recovery refused: unexpected files are present beside the E2 data directory: $($unexpectedClusterItems.Name -join ', ')." }
$expectedData = [IO.Path]::GetFullPath($DataDir).TrimEnd('\')
if ((Get-Content -LiteralPath (Join-Path $DataDir 'PG_VERSION') -Raw).Trim() -ne '17') {
    throw 'Recovery refused: PG_VERSION is not 17.'
}
$version = (Invoke-E2Native (Join-Path $PgBin 'postgres.exe') @('--version') | Out-String).Trim()
if ($version -notmatch '\b17\.') { throw "Recovery requires PostgreSQL 17 binaries; found: $version" }
$controlText = Invoke-E2Native (Join-Path $PgBin 'pg_controldata.exe') @('-D',$DataDir) | Out-String
$idMatch = [regex]::Match($controlText,'Database system identifier:\s*(\d+)')
$stateMatch = [regex]::Match($controlText,'Database cluster state:\s*(.+)')
if (-not $idMatch.Success -or $idMatch.Groups[1].Value -cne $ExpectedSystemIdentifier) {
    throw 'Recovery refused: on-disk cluster system identifier does not match the operator-supplied value.'
}
if (-not $stateMatch.Success) { throw 'Could not determine the on-disk PostgreSQL cluster state.' }
$PgCtl = Join-Path $PgBin 'pg_ctl.exe'
$pidPath = Join-Path $DataDir 'postmaster.pid'
$pidRecord = $null
if (Test-Path -LiteralPath $pidPath) {
    $pidRecord = Read-PostmasterPidFile $pidPath $DataDir $Port
}
$recordedPid = if ($pidRecord) { $pidRecord.Pid } else { '' }
$serverStatus = Assert-E2PostgresState -RecordedPostmasterPid $recordedPid -RequireStopped:($Action -eq 'QuarantineStalePid')
$serverAlreadyRunning = $serverStatus -eq 0
if ($serverAlreadyRunning -and -not $pidRecord) {
    throw 'Recovery refused: PostgreSQL is running but no verified E2 postmaster.pid exists.'
}
$listener = $null
if (-not $serverAlreadyRunning) {
    try {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse($HostAddress),$Port)
        $listener.Start()
    } catch { throw "Recovery refused: 127.0.0.1:$Port is occupied. No server was started." }
    finally { if ($null -ne $listener) { $listener.Stop() } }
}

$Executables = @('pg_ctl.exe','pg_controldata.exe','postgres.exe','psql.exe','createdb.exe')
$Psql = Join-Path $PgBin 'psql.exe'
$Createdb = Join-Path $PgBin 'createdb.exe'
$authSql = Join-Path $E2Root 'database\00_local_auth_compat.sql'
$markerSql = Join-Path $E2Root 'database\00_provision_e2_target_marker.sql'
foreach ($sqlPath in @($authSql,$markerSql)) { if (-not (Test-Path -LiteralPath $sqlPath -PathType Leaf)) { throw "Required E2 bootstrap SQL is missing: $sqlPath" } }

if ($pidRecord -and -not $serverAlreadyRunning) {
    $pidHash = (Get-FileHash -LiteralPath $pidPath -Algorithm SHA256).Hash
    Write-Host "Verified stale PID candidate: PID $($pidRecord.Pid), path $($pidRecord.DataDirectory), port $($pidRecord.Port), cluster $ExpectedSystemIdentifier."
    if ($Action -eq 'Inspect') {
        Write-Host 'No file changed and PostgreSQL was not started. Use the separately approved QuarantineStalePid action only if this PID is confirmed stale.'
        return
    }
    if ($Action -ne 'QuarantineStalePid') {
        throw 'Recovery refused: quarantine the verified stale PID file in a separate approved action before database inspection.'
    }
    $required = "QUARANTINE STALE PID $($pidRecord.Pid) FOR E2 CLUSTER $ExpectedSystemIdentifier"
    if ($ConfirmStalePid -cne $required) { throw "Stale PID quarantine requires -ConfirmStalePid '$required'. No file was changed." }
    # Repeat identity/process/listener checks immediately before the same-directory
    # rename. File.Move fails if the unique destination already exists.
    $controlTextAgain = Invoke-E2Native (Join-Path $PgBin 'pg_controldata.exe') @('-D',$DataDir) | Out-String
    $idAgain = [regex]::Match($controlTextAgain,'Database system identifier:\s*(\d+)')
    if (-not $idAgain.Success -or $idAgain.Groups[1].Value -cne $ExpectedSystemIdentifier) { throw 'Cluster identity changed; stale PID was not moved.' }
    $pidAgain = Read-PostmasterPidFile $pidPath $DataDir $Port
    if ($pidAgain.Raw -cne $pidRecord.Raw) { throw 'postmaster.pid changed after inspection; it was not moved.' }
    Assert-E2PostgresState -RecordedPostmasterPid $pidRecord.Pid -RequireStopped
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $archivePath = "$pidPath.stale.$stamp.$([Guid]::NewGuid().ToString('N'))"
    $beforeHash = (Get-FileHash -LiteralPath $pidPath -Algorithm SHA256).Hash
    [IO.File]::Move($pidPath,$archivePath)
    $afterHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    if ($beforeHash -cne $afterHash -or $beforeHash -cne $pidHash) { throw "PID file was preserved at '$archivePath', but its verification hash differed. Stop and review." }
    Write-Host "Stale PID file preserved by rename: $archivePath"
    Write-Host "SHA-256: $afterHash"
    Write-Host 'No database was started or connected. Next, run Action Inspect with -ApprovePostgresStartForInspection.'
    return
} elseif ($Action -eq 'QuarantineStalePid') {
    throw 'No postmaster.pid exists to quarantine; no file was changed.'
}

if ($Action -eq 'Complete' -and $pidRecord -and -not $serverAlreadyRunning) {
    throw 'Completion requires postmaster.pid to be absent after separately approved quarantine; no database was started.'
}
if ($Action -eq 'Inspect' -and -not $ApprovePostgresStartForInspection -and -not $serverAlreadyRunning) {
    throw 'Inspecting database inventory requires starting PostgreSQL, which may replay WAL. Use -ApprovePostgresStartForInspection after approving that action.'
}

if (-not $serverAlreadyRunning) {
    Start-E2PostgresBounded
} else {
    Write-Host "[E2 recovery] Attaching read-only inspection to the verified running E2 cluster (PID $recordedPid); the existing server will remain running."
}

$serverRows = Invoke-Query 'postgres' "select inet_server_addr()::text||'|'||inet_server_port()||'|'||current_setting('data_directory')||'|'||(select system_identifier::text from pg_control_system())"
if ($serverRows.Count -ne 1) {
    throw "Connected server identity query returned $($serverRows.Count) rows; exactly one row is required. Raw output: [$($serverRows -join ' ; ')]"
}
$serverParts = $serverRows[0] -split '\|',4
if ($serverParts.Count -ne 4) {
    throw "Connected server identity row had $($serverParts.Count) fields; expected address|port|data_directory|system_identifier. Raw row: [$($serverRows[0])]"
}
. (Join-Path $PSScriptRoot 'test_harness\e2_process_safety.ps1')
Assert-E2ServerIdentity -ActualAddress $serverParts[0] -ActualPort $serverParts[1] `
    -ActualDataDirectory $serverParts[2] -ActualSystemIdentifier $serverParts[3] `
    -ExpectedAddress $HostAddress -ExpectedPort $Port -ExpectedDataDirectory $expectedData `
    -ExpectedSystemIdentifier $ExpectedSystemIdentifier

$dbRows = Invoke-Query 'postgres' "select datname||'|'||r.rolname from pg_database d join pg_roles r on r.oid=d.datdba order by datname"
Write-Host '[E2 recovery] Database inventory query completed.'
$dbSet = @($dbRows | Sort-Object)
$customRoles = Invoke-Query 'postgres' "select rolname from pg_roles where rolname !~ '^pg_' and rolname<>'postgres' order by rolname"
. (Join-Path $PSScriptRoot 'test_harness\e2_process_safety.ps1')
$inventoryState = Get-E2DatabaseInventoryState -DatabaseRows $dbSet -CustomRoles $customRoles
$dbMissing = $inventoryState -eq 'RecoverableMissingE2Database'
Write-Host '[E2 recovery] Database and role inventory classification completed.'
$expectedRoles = @('anon','authenticated','service_role')
$rolesAbsent = $customRoles.Count -eq 0
$rolesComplete = $customRoles.Count -eq 3 -and (@(Compare-Object $customRoles $expectedRoles).Count -eq 0)
if (-not $rolesAbsent -and -not $rolesComplete) { throw "Recovery refused: unexpected role inventory: $($customRoles -join ', ')." }

$state = 'fresh-cluster-before-e2-database'
$markerId = $null
$authComplete = $false
if ($dbMissing) {
    Write-Host "[E2 recovery] '$DatabaseName' is absent. Checking for a clean, database-free E2 setup state; no database will be created by Inspect."
    if (-not $rolesAbsent) { throw 'Recovery refused: E2 roles exist but the E2 database does not; this is an inconsistent partial state.' }
} else {
    $dbOwner = (Invoke-Query $DatabaseName 'select pg_get_userbyid(datdba) from pg_database where datname=current_database()')[0]
    if ($dbOwner -ne 'postgres') { throw 'Recovery refused: geolock_e2 is not owned by postgres.' }
    $schemas = Invoke-Query $DatabaseName "select nspname from pg_namespace where nspname not like 'pg\_%' escape '\' and nspname<>'information_schema' order by nspname"
    $extensionRows = Invoke-Query $DatabaseName 'select extname from pg_extension order by extname'
    $relations = Invoke-Query $DatabaseName "select n.nspname||'.'||c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname not like 'pg\_%' escape '\' and n.nspname<>'information_schema' and c.relkind in ('r','p','v','m','f','S') and not exists(select 1 from pg_depend d where d.classid='pg_class'::regclass and d.objid=c.oid and d.refclassid='pg_extension'::regclass and d.deptype='e') order by 1"
    $schemasReady = (@(Compare-Object $schemas @('auth','extensions','public')).Count -eq 0)
    $extensionsReady = (@(Compare-Object $extensionRows @('pgcrypto','plpgsql','postgis')).Count -eq 0)
    if ($extensionsReady) {
        $extensionOwners = Invoke-Query $DatabaseName "select e.extname||'|'||r.rolname||'|'||n.nspname from pg_extension e join pg_roles r on r.oid=e.extowner join pg_namespace n on n.oid=e.extnamespace order by e.extname"
        $extensionsReady = @(Compare-Object $extensionOwners @('pgcrypto|postgres|public','plpgsql|postgres|pg_catalog','postgis|postgres|extensions')).Count -eq 0
    }
    $relationNames = @('auth.users')
    $markerPresent = $relations -contains 'public.e2_disposable_target'
    if ($markerPresent) { $relationNames += 'public.e2_disposable_target' }
    $relationsReady = (@(Compare-Object $relations $relationNames).Count -eq 0)
    if ($schemasReady -and $extensionsReady -and $relationsReady -and $rolesComplete) {
        $schemaOwners = Invoke-Query $DatabaseName "select n.nspname||'|'||r.rolname from pg_namespace n join pg_roles r on r.oid=n.nspowner where n.nspname in ('auth','extensions') order by n.nspname"
        if (@(Compare-Object $schemaOwners @('auth|postgres','extensions|postgres')).Count -ne 0) { throw 'Recovery refused: Auth or extension schema ownership differs from the local bootstrap.' }
        $userFunctions = Invoke-Query $DatabaseName "select n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')' from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('auth','public','extensions') and not exists(select 1 from pg_depend d where d.classid='pg_proc'::regclass and d.objid=p.oid and d.refclassid='pg_extension'::regclass and d.deptype='e') order by 1"
        if (@(Compare-Object $userFunctions @('auth.role()','auth.uid()')).Count -ne 0) { throw 'Recovery refused: unexpected non-extension functions exist in the E2 bootstrap schemas.' }
        $userTypes = Invoke-Query $DatabaseName "select n.nspname||'.'||t.typname from pg_type t join pg_namespace n on n.oid=t.typnamespace where n.nspname in ('auth','public','extensions') and t.typtype in ('e','d','r','m') and not exists(select 1 from pg_depend d where d.classid='pg_type'::regclass and d.objid=t.oid and d.refclassid='pg_extension'::regclass and d.deptype='e') order by 1"
        if ($userTypes.Count -ne 0) { throw 'Recovery refused: unexpected non-extension data types exist in the E2 bootstrap schemas.' }
        $columns = Invoke-Query $DatabaseName "select a.attname||'|'||format_type(a.atttypid,a.atttypmod)||'|'||a.attnotnull from pg_attribute a where a.attrelid='auth.users'::regclass and a.attnum>0 and not a.attisdropped order by a.attname"
        if (@(Compare-Object $columns @('email|text|true','id|uuid|true')).Count -ne 0) { throw 'Recovery refused: auth.users columns do not match the E2 bootstrap.' }
        $userConstraints = Invoke-Query $DatabaseName "select conname||'|'||pg_get_constraintdef(oid) from pg_constraint where conrelid='auth.users'::regclass order by conname"
        if (@(Compare-Object $userConstraints @('users_email_key|UNIQUE (email)','users_pkey|PRIMARY KEY (id)')).Count -ne 0) { throw 'Recovery refused: auth.users key constraints do not match the E2 bootstrap.' }
        $users = [int](Invoke-Query $DatabaseName 'select count(*) from auth.users')[0]
        if ($users -ne 0) { throw 'Recovery refused: auth.users contains rows; this is not a pristine setup state.' }
        $functions = Invoke-Query $DatabaseName "select p.proname||'|'||r.rolname||'|'||l.lanname||'|'||p.provolatile||'|'||p.prosecdef||'|'||coalesce(array_to_string(p.proconfig,','),'') from pg_proc p join pg_namespace n on n.oid=p.pronamespace join pg_roles r on r.oid=p.proowner join pg_language l on l.oid=p.prolang where n.nspname='auth' order by p.proname"
        $expectedFunctions = @('role|postgres|sql|s|false|search_path=pg_catalog','uid|postgres|sql|s|false|search_path=pg_catalog')
        if (@(Compare-Object $functions $expectedFunctions).Count -ne 0) { throw 'Recovery refused: auth function inventory, owner, language, volatility, or security mode differs from the E2 bootstrap.' }
        $functionBodies = Invoke-Query $DatabaseName "select proname from pg_proc where pronamespace='auth'::regnamespace and position(case proname when 'uid' then 'request.jwt.claim.sub' else 'request.jwt.claim.role' end in prosrc)>0 and position('request.jwt.claims' in prosrc)>0 order by proname"
        if (@(Compare-Object $functionBodies @('role','uid')).Count -ne 0) { throw 'Recovery refused: auth.uid()/auth.role() do not contain the E2 JWT-claims behavior.' }
        $roleFlags = Invoke-Query 'postgres' "select rolname||'|'||rolcanlogin||'|'||rolbypassrls from pg_roles where rolname in ('anon','authenticated','service_role') order by rolname"
        if (@(Compare-Object $roleFlags @('anon|false|false','authenticated|false|false','service_role|false|true')).Count -ne 0) { throw 'Recovery refused: E2 role attributes differ from the local Auth bootstrap.' }
        $authAcl = (Invoke-Query $DatabaseName "select has_schema_privilege('anon','auth','USAGE') and has_schema_privilege('authenticated','auth','USAGE') and has_schema_privilege('service_role','auth','USAGE') and has_function_privilege('anon','auth.uid()','EXECUTE') and has_function_privilege('authenticated','auth.uid()','EXECUTE') and has_function_privilege('service_role','auth.uid()','EXECUTE') and not has_table_privilege('anon','auth.users','SELECT') and not has_table_privilege('authenticated','auth.users','SELECT') and not has_table_privilege('service_role','auth.users','SELECT')")[0]
        if ($authAcl -ne 't') { throw 'Recovery refused: Auth permissions differ from the local E2 compatibility bootstrap.' }
        $triggers = Invoke-Query $DatabaseName "select count(*) from pg_trigger where not tgisinternal and tgrelid in ('auth.users'::regclass,coalesce(to_regclass('public.e2_disposable_target'),'auth.users'::regclass))"
        $policies = Invoke-Query $DatabaseName "select count(*) from pg_policies where schemaname in ('auth','public','extensions')"
        if ($triggers[0] -ne '0' -or $policies[0] -ne '0') { throw 'Recovery refused: unexpected triggers or row-level policies exist in the setup scope.' }
        $state = 'auth-bootstrap-complete'
        if ($markerPresent) {
            $markerColumns = Invoke-Query $DatabaseName "select a.attname||'|'||format_type(a.atttypid,a.atttypmod)||'|'||a.attnotnull from pg_attribute a where a.attrelid='public.e2_disposable_target'::regclass and a.attnum>0 and not a.attisdropped order by a.attnum"
            if (@(Compare-Object $markerColumns @('singleton|boolean|true','target_id|uuid|true','project_ref|text|false','provisioned_at|timestamp with time zone|true')).Count -ne 0) { throw 'Recovery refused: E2 marker columns do not match the expected local marker.' }
            $markerOwner = (Invoke-Query $DatabaseName "select tableowner from pg_tables where schemaname='public' and tablename='e2_disposable_target'")[0]
            if ($markerOwner -ne 'postgres') { throw 'Recovery refused: E2 marker is not owned by postgres.' }
            $markerAcl = (Invoke-Query $DatabaseName "select not has_table_privilege('anon','public.e2_disposable_target','SELECT') and not has_table_privilege('authenticated','public.e2_disposable_target','SELECT') and not has_table_privilege('service_role','public.e2_disposable_target','SELECT')")[0]
            if ($markerAcl -ne 't') { throw 'Recovery refused: E2 target marker permissions differ from the local bootstrap.' }
            $markerRows = Invoke-Query $DatabaseName "select target_id::text||'|'||coalesce(project_ref,'<null>') from public.e2_disposable_target order by target_id"
            if ($markerRows.Count -gt 1) { throw 'Recovery refused: E2 marker has multiple rows.' }
            if ($markerRows.Count -eq 1) {
                $markerParts = $markerRows[0] -split '\|',2
                if ($markerParts[1] -ne '<null>' -or $markerParts[0] -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Recovery refused: E2 marker does not identify a local target.' }
                $markerId = $markerParts[0]
                $state = 'bootstrap-and-marker-complete'
            } else { $state = 'bootstrap-complete-marker-empty' }
        }
        $authComplete = $true
    } elseif ($schemas.Count -eq 1 -and $schemas[0] -eq 'public' -and $extensionRows.Count -eq 1 -and
              $extensionRows[0] -eq 'plpgsql' -and $relations.Count -eq 0 -and $rolesAbsent) {
        $state = 'empty-e2-database'
    } else {
        throw "Recovery refused: database bootstrap is partial or contains unexpected objects. Schemas=[$($schemas -join ',')]; extensions=[$($extensionRows -join ',')]; relations=[$($relations -join ',')]; roles=[$($customRoles -join ',')]. Preserve the cluster and request manual review."
    }
}

Write-Host "Verified cluster state: $($stateMatch.Groups[1].Value.Trim())"
Write-Host "Verified system identifier: $ExpectedSystemIdentifier"
Write-Host "Verified server: 127.0.0.1:$Port; data directory: $expectedData"
Write-Host "Database inventory: $($dbRows -join ', ')"
Write-Host "E2 setup stage: $state"
if ($Action -eq 'Inspect') {
    if ($dbMissing) {
        Write-Host "Recoverable setup state: verified E2 cluster with only default databases and no custom roles. Action Complete can create only '$DatabaseName', install the E2 Auth compatibility objects and target marker, and write local.json after explicit confirmation."
    }
    Write-Host 'Inspection only. No database objects, rows, or local.json were written.'
    return
}

# No mutation occurs until the complete identity and inventory checks above pass.
if ($dbMissing) {
    Invoke-E2PostgresClient $Createdb @('-h',$HostAddress,'-p',[string]$Port,'-U','postgres','-T','template0',$DatabaseName) | Out-Null
    Invoke-E2PostgresClient $Psql @('-X','-v','ON_ERROR_STOP=1','-h',$HostAddress,'-p',[string]$Port,'-U','postgres','-d',$DatabaseName,'-f',$authSql) | Out-Null
} elseif (-not $authComplete) {
    Invoke-E2PostgresClient $Psql @('-X','-v','ON_ERROR_STOP=1','-h',$HostAddress,'-p',[string]$Port,'-U','postgres','-d',$DatabaseName,'-f',$authSql) | Out-Null
    $authComplete = $true
}
if (-not $markerId) {
    $markerId = [Guid]::NewGuid().ToString()
    $markerExists = (Invoke-Query $DatabaseName "select to_regclass('public.e2_disposable_target') is not null")[0]
    if ($markerExists -eq 't') {
        Invoke-E2PostgresClient $Psql @('-X','-v','ON_ERROR_STOP=1','-h',$HostAddress,
            '-p',[string]$Port,'-U','postgres','-d',$DatabaseName,'-c',
            "insert into public.e2_disposable_target(singleton,target_id,project_ref) values(true, '$markerId'::uuid, null)") | Out-Null
    } else {
        Invoke-E2PostgresClient $Psql @('-X','-v','ON_ERROR_STOP=1','-v',"e2_target_id=$markerId",
            '-h',$HostAddress,'-p',[string]$Port,'-U','postgres','-d',$DatabaseName,'-f',$markerSql) | Out-Null
    }
}
$markerId = (Invoke-Query $DatabaseName "select target_id::text from public.e2_disposable_target where singleton is true")[0]
if ($markerId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Recovery did not verify exactly one local E2 marker.' }

if ($Action -eq 'Complete') {
    $config = [ordered]@{ version=1; mode='local'; host=$HostAddress; port=$Port; dbname=$DatabaseName; user='postgres';
        target_id=$markerId; cluster_system_identifier=$ExpectedSystemIdentifier; data_dir=$expectedData; pg_bin=$PgBin;
        setup_approval='created_as_new_e2_owned_cluster' }
    $json = $config | ConvertTo-Json -Depth 4
    $stream = [IO.File]::Open($ConfigPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $writer = [IO.StreamWriter]::new($stream,[System.Text.UTF8Encoding]::new($false)); try { $writer.WriteLine($json) } finally { $writer.Dispose() } }
    finally { if ($stream) { $stream.Dispose() } }
    Write-Host "Local E2 setup metadata recovered without deleting or recreating the cluster: $ConfigPath"
    Write-Host 'Next run: experiments/e2/run.ps1 -PreflightOnly'
}
