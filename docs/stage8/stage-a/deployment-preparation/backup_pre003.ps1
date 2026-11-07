# Operator-run only. Passwords are entered at native hidden PostgreSQL prompts.
# No migration, DDL, DML, restore, role provisioning or source security changes.
[CmdletBinding()]
param([string]$VerifyArchiveDirectory, [switch]$PreFreeze, [switch]$PreAutomaticDeparture, [switch]$PreRouteResolution, [switch]$PreClaimScopedReconciliation, [switch]$PreSimplifiedReconciliation, [switch]$ValidateOnly)
$ErrorActionPreference = 'Stop'
if (([int]$PreFreeze.IsPresent+[int]$PreAutomaticDeparture.IsPresent+[int]$PreRouteResolution.IsPresent+[int]$PreClaimScopedReconciliation.IsPresent+[int]$PreSimplifiedReconciliation.IsPresent) -gt 1) { throw 'BACKUP_PREFLIGHT_FAILED:CAPTURE_MODES_MUTUALLY_EXCLUSIVE' }
if ($ValidateOnly -and (!($PreRouteResolution -or $PreClaimScopedReconciliation -or $PreSimplifiedReconciliation) -or $VerifyArchiveDirectory)) { throw 'BACKUP_PREFLIGHT_FAILED:VALIDATE_ONLY_MODE' }
$stage003CurrentCapture = $PreAutomaticDeparture -or $PreRouteResolution -or $PreClaimScopedReconciliation -or $PreSimplifiedReconciliation
$stage003SavedPg = $null
function Restore-Stage003PgEnvironment {
    if ($null -ne $script:stage003SavedPg) {
        foreach ($entry in @(Get-ChildItem Env:)) { if ($entry.Name -match '^PG') { Remove-Item -LiteralPath ('Env:'+$entry.Name) } }
        foreach ($name in $script:stage003SavedPg.Keys) { Set-Item -LiteralPath ('Env:'+$name) -Value $script:stage003SavedPg[$name] }
        $script:stage003SavedPg = $null
    }
}
$stage003OwnsCapture = $false
# Only a newly allocated capture directory is marked on failure. Existing failed
# attempts and verification-only inputs are never reused as a fresh capture.
trap {
    $stage003Failure = $_
    $stage003SafeFailureCode = $null
    if ($stage003Failure.Exception.Message -match '^(BACKUP_INVENTORY_FAILED:[A-Za-z0-9_.,():=-]+)') {
        $stage003SafeFailureCode = $Matches[1]
    } else {
        $stage003SafeFailureCode = 'BACKUP_FAILED_PHASE:' + ($stage003Phase -replace '[^A-Za-z0-9_-]','_')
    }
    Restore-Stage003PgEnvironment
    if ($stage003OwnsCapture -and (Test-Path -LiteralPath $stage003Dir -PathType Container)) {
        [ordered]@{status='FAILED / NOT A VERIFIED BACKUP';phase=$stage003Phase;failure_code=$stage003SafeFailureCode} |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage003Dir 'backup-status.json') -Encoding UTF8
    }
    Write-Host "Backup stopped: $stage003SafeFailureCode"
    throw
}
$stage003Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
$stage003BackupRoot = Join-Path $stage003Root 'backups\stage-a003'
$stage003Bin = 'C:\Program Files\PostgreSQL\17\bin'
$stage003ServiceFile = Join-Path $stage003BackupRoot 'pg_service.conf'
$stage003ArchiveName = if ($PreFreeze) { 'dev-prefreeze.dump' } else { 'dev-pre003.dump' }
if ($PreFreeze) { $stage003BackupRoot = Join-Path $stage003BackupRoot 'pre-freeze' }
if ($PreAutomaticDeparture) {
    $stage003ArchiveName = 'dev-pre-automatic-departure.dump'
    $stage003BackupRoot = Join-Path $stage003BackupRoot 'pre-automatic-departure'
}
if ($PreRouteResolution) {
    $stage003ArchiveName = 'dev-pre-route-resolution.dump'
    $stage003BackupRoot = Join-Path $stage003BackupRoot 'pre-route-resolution'
}
if ($PreClaimScopedReconciliation) {
    $stage003ArchiveName = 'dev-pre-claim-scoped-reconciliation.dump'
    $stage003BackupRoot = Join-Path $stage003BackupRoot 'pre-claim-scoped-reconciliation'
}
if ($PreSimplifiedReconciliation) {
    $stage003ArchiveName = 'dev-pre-simplified-reconciliation.dump'
    $stage003BackupRoot = Join-Path $stage003BackupRoot 'pre-simplified-reconciliation'
}
$stage003Purpose = if ($PreSimplifiedReconciliation) { 'PRE_SIMPLIFIED_RECONCILIATION_CURRENT_DEV' } elseif ($PreClaimScopedReconciliation) { 'PRE_CLAIM_SCOPED_RECONCILIATION_CURRENT_DEV' } elseif ($PreRouteResolution) { 'PRE_ROUTE_RESOLUTION_CURRENT_DEV' } elseif ($PreAutomaticDeparture) { 'PRE_AUTOMATIC_DEPARTURE_CURRENT_DEV' } elseif ($PreFreeze) { 'POST003_INSTALLED_POLICY_PRE_FREEZE' } else { 'PRE003' }
. (Join-Path $PSScriptRoot 'backup_native_arguments.ps1')
if ($stage003CurrentCapture) { . (Join-Path $PSScriptRoot 'backup_current_state.ps1') }
if ($PreSimplifiedReconciliation) { . (Join-Path $PSScriptRoot 'backup_simplified_reconciliation.ps1') }
elseif ($PreRouteResolution -or $PreClaimScopedReconciliation) { . (Join-Path $PSScriptRoot 'backup_route_resolution.ps1') }

function Invoke-ArchiveVerification([string]$Directory) {
    $archive = Join-Path $Directory $stage003ArchiveName
    $roles = Join-Path $Directory 'roles-no-passwords.sql'
    $inventoryPath = Join-Path $Directory 'source-inventory.json'
    $capturePath = Join-Path $Directory 'capture-record.json'
    foreach ($requiredFile in @($archive,$roles,$inventoryPath,$capturePath)) {
        if (!(Test-Path -LiteralPath $requiredFile -PathType Leaf)) { throw "Missing backup component: $requiredFile" }
        if ((Get-Item -LiteralPath $requiredFile).Length -eq 0) { throw "Empty backup component: $requiredFile" }
    }
    $tocArguments = @(New-Stage003ClientArguments -Operation Toc -ArchivePath $archive)
    $toc = @(& (Join-Path $stage003Bin 'pg_restore.exe') @tocArguments)
    if ($LASTEXITCODE -ne 0) { throw 'Archive TOC failed.' }
    $toc | Set-Content -LiteralPath (Join-Path $Directory 'toc.txt') -Encoding UTF8
    # No --dbname: these two commands decode into local files/null device only.
    $decodeArguments = @(New-Stage003ClientArguments -Operation Decode -ArchivePath $archive)
    & (Join-Path $stage003Bin 'pg_restore.exe') @decodeArguments
    if ($LASTEXITCODE -ne 0) { throw 'Archive payload decode failed.' }
    $schemaPath = Join-Path $Directory 'schema.sql'
    $schemaArguments = @(New-Stage003ClientArguments -Operation Schema -DestinationPath $schemaPath -ArchivePath $archive)
    & (Join-Path $stage003Bin 'pg_restore.exe') @schemaArguments
    if ($LASTEXITCODE -ne 0) { throw 'Schema extraction failed.' }
    $inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    if ($capture.database_export_exit_code -ne 0 -or $capture.roles_export_exit_code -ne 0) { throw 'Successful export receipt missing.' }
    if ($inventory.database -ne 'postgres' -or $inventory.current_user -ne 'postgres' -or $inventory.session_user -ne 'postgres' -or $inventory.read_only -ne 'on') { throw 'Saved identity mismatch.' }
    $missing = New-Object 'System.Collections.Generic.List[string]'
    $tocText = $toc -join "`n"
    foreach ($schema in @('public','routing_private','fleet_private','auth','storage')) {
        # public can be pre-existing and appear only in ownership/comment/ACL
        # entries; its expected application tables are checked separately.
        if ($schema -ne 'public' -and $tocText -notmatch ('(?m)^\d+;.* SCHEMA - ' + [regex]::Escape($schema) + ' ')) { $missing.Add("SCHEMA $schema") }
    }
    foreach ($table in $inventory.tables) {
        $identity = [regex]::Escape($table.schema + ' ' + $table.name)
        $kind = if ($table.kind -eq 'm') { 'MATERIALIZED VIEW' } else { 'TABLE' }
        if ($tocText -notmatch ('(?m)^\d+;.* ' + $kind + ' ' + $identity + ' ')) { $missing.Add("$kind $($table.schema).$($table.name)") }
        # Partitioned parents have no own storage/data entry.
        if ($table.kind -ne 'p' -and $tocText -notmatch ('(?m)^\d+;.* ' + $kind + ' DATA ' + $identity + ' ')) { $missing.Add("$kind DATA $($table.schema).$($table.name)") }
    }
    $expected = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'expected-functions.json') -Raw | ConvertFrom-Json
    $expectedEntries = @($expected.baseline.PSObject.Properties)
    if ($PreFreeze -or $stage003CurrentCapture) { $expectedEntries += @($expected.post003.PSObject.Properties) }
    foreach ($entry in $expectedEntries) {
        $signature = $entry.Name
        $schema,$name = ($signature -replace '\(.*$','') -split '\.',2
        if ($tocText -notmatch ('(?m)^\d+;.* FUNCTION ' + [regex]::Escape("$schema $name") + '\(')) { $missing.Add("FUNCTION $signature") }
    }
    # Name presence is a coverage check; exact signatures/bodies/ACLs require
    # schema/catalog comparisons and a restored-copy comparison, not TOC alone.
    if ($missing.Count -gt 0) {
        $missing | Set-Content -LiteralPath (Join-Path $Directory 'coverage-missing.txt') -Encoding UTF8
        throw 'Coverage gaps detected. Inspect coverage-missing.txt; do not treat this archive as complete.'
    }
    if ($PreFreeze) {
        if ($inventory.graph_count -ne 0 -or @($inventory.routing_policies).Count -ne 1) { throw 'Pre-freeze source boundary mismatch.' }
        $policy = @($inventory.routing_policies)[0]
        if ($policy.policy_id -ne '80db858b-93e8-4a0a-94e2-dbe14940f0a1' -or !$policy.body_matches -or !$policy.digest_matches) { throw 'Installed approved policy mismatch.' }
        if ($tocText -notmatch 'TRIGGER public pickup_tasks routing_task_authority') { throw '003 authority trigger absent from archive TOC.' }
        # Local decode only. Never restore/connect; never print Auth or application data.
        $policyDataPath = Join-Path $Directory 'policy-data.sql'
        & (Join-Path $stage003Bin 'pg_restore.exe') --data-only --schema routing_private --table policies --file $policyDataPath $archive
        if ($LASTEXITCODE -ne 0) { throw 'Policy data decode failed.' }
        $policyRows = @(Get-Content -LiteralPath $policyDataPath | Where-Object { $_ -match '^[0-9a-f-]{36}\t' })
        if ($policyRows.Count -ne 1) { throw 'Expected exactly one archived policy row.' }
        $fields = $policyRows[0] -split "`t"
        if ($fields.Count -ne 5 -or $fields[0] -ne $policy.policy_id -or $fields[1] -ne $policy.request_id -or $fields[3] -ne $policy.digest) { throw 'Archived policy identity/digest mismatch.' }
        $archivedBody = $fields[2] | ConvertFrom-Json | ConvertTo-Json -Depth 12 -Compress
        $observedBody = $policy.body | ConvertTo-Json -Depth 12 -Compress
        if ($archivedBody -ne $observedBody) { throw 'Archived policy body mismatch.' }
    }
    if ($stage003CurrentCapture) { Test-CurrentArchive -Directory $Directory -Archive $archive -Inventory $inventory }
    $hashFiles = @($stage003ArchiveName,'roles-no-passwords.sql','source-inventory.json','capture-record.json','toc.txt','schema.sql')
    if ($PreFreeze) { $hashFiles += 'policy-data.sql' }
    if ($stage003CurrentCapture) { $hashFiles += @('routing-recovery-data.sql','current-state-verification.json','capture-manifest.json') }
    $hashes = foreach ($name in $hashFiles) {
        $path = Join-Path $Directory $name
        [pscustomobject]@{file=$name;bytes=(Get-Item -LiteralPath $path).Length;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    $hashPath = Join-Path $Directory 'sha256.json'
    if (Test-Path -LiteralPath $hashPath) {
        $old = Get-Content -LiteralPath $hashPath -Raw | ConvertFrom-Json
        foreach ($item in $old) {
            # Only compare immutable capture artifacts. TOC/schema extraction
            # may have transport line-ending differences across operator shells.
            if ($item.file -in @($stage003ArchiveName,'roles-no-passwords.sql','source-inventory.json','capture-record.json','capture-manifest.json','current-state-verification.json')) {
                $now = $hashes | Where-Object { $_.file -eq $item.file }
                if ($now.sha256 -ne $item.sha256) { throw "Checksum changed: $($item.file)" }
            }
        }
    } else { $hashes | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $hashPath -Encoding UTF8 }
    if ($stage003CurrentCapture) {
        # Extracts may contain fresh pg_restore restrict tokens. Keep the original
        # capture checksums; record hashes of this verification's extracts too.
        $hashes | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Directory 'verification-sha256.json') -Encoding UTF8
    }
    $result = [ordered]@{
        target_project='rcgyuwiidqvrgbxswhqj';verified_at_utc=[DateTime]::UtcNow.ToString('o')
        directory=$Directory;archive=$archive;roles=$roles
        purpose=$stage003Purpose
        current_state_archive_check=$(if ($stage003CurrentCapture) { 'PASS: see current-state-verification.json for checked scope' } else { 'not applicable' })
        installed_policy_archive_check=$(if ($PreFreeze) { 'PASS: exact observed policy ID/request/body/digest in archive' } else { 'not applicable' })
        archive_toc='PASS';full_payload_decode='PASS';schema_extraction='PASS'
        required_table_data_and_baseline_function_name_presence='PASS'
        inspected_application_tables=@($inventory.tables).Count
        checksum_comparison='PASS for available capture baseline; SHA-256 is not a restore test'
        role_membership_export='pg_dumpall --roles-only --no-role-passwords completed during capture'
        exact_definition_and_row_content_equivalence='NOT VERIFIED'
        extension_configuration_tables_and_provider_restore_coverage='Review full TOC/schema and extension configuration inventory; not a portable-restore PASS'
        restore_validation='NOT VERIFIED';supabase_external_service_recovery='NOT VERIFIED'
        source_inventory_snapshot_note='Catalog inventory and archive use separate read-only snapshots. No-writer/DDL window required for equality; otherwise differences require review.'
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Directory 'verification.json') -Encoding UTF8
    Write-Host "Backup artifacts and checks saved in: $Directory"
    Write-Host 'Archive coverage/readability checks PASS. Restorability and exact data equivalence remain NOT VERIFIED.'
}

if ($VerifyArchiveDirectory) {
    # Verification-only mode never connects to a database or prompts for a password.
    $stage003VerifyDir = (Resolve-Path -LiteralPath $VerifyArchiveDirectory).Path
    if (!$stage003VerifyDir.StartsWith($stage003BackupRoot + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Verification directory must be inside this workspace backups/stage-a003.' }
    Invoke-ArchiveVerification $stage003VerifyDir
    return
}

$stage003Profile = Get-Content -LiteralPath $stage003ServiceFile -Raw
if ($stage003CurrentCapture) {
    # Reject duplicate/extra service keys that could override the approved identity.
    $profileEntries = @($stage003Profile -split '\r?\n' | Where-Object { $_.Trim() -and $_ -notmatch '^\s*[#;]' })
    if ($profileEntries.Count -ne 9 -or @($profileEntries | Where-Object { $_ -match '^\[' }).Count -ne 1 -or @($profileEntries | Where-Object { $_ -eq 'connect_timeout=15' }).Count -ne 1) { throw 'Approved profile structure mismatch.' }
    if (!(Test-Path -LiteralPath 'C:/Users/User/Downloads/prod-ca-2021.crt' -PathType Leaf)) { throw 'Approved TLS CA missing.' }
}
foreach ($line in @('[geolock_dev_owner_export]','host=aws-0-ap-northeast-2.pooler.supabase.com','port=5432','dbname=postgres','user=postgres.rcgyuwiidqvrgbxswhqj','sslmode=verify-full','sslrootcert=C:/Users/User/Downloads/prod-ca-2021.crt','options=-c default_transaction_read_only=on')) {
    if ($stage003Profile -notmatch ('(?m)^' + [regex]::Escape($line) + '\r?$')) { throw "Approved export profile mismatch: $line" }
}
if ($stage003Profile -match '(?im)^\s*(password|passfile)\s*=') { throw 'Do not store a password or password-file reference in the repository profile.' }
foreach ($client in @('psql.exe','pg_dump.exe','pg_dumpall.exe','pg_restore.exe')) {
    $version = & (Join-Path $stage003Bin $client) --version
    if ($LASTEXITCODE -ne 0 -or $version -notmatch '17\.11\b') { throw "Unexpected tool version: $client" }
}
if ($PreRouteResolution -or $PreClaimScopedReconciliation -or $PreSimplifiedReconciliation) {
    $null = Get-RouteResolutionBackupBaseline
    if ($ValidateOnly) {
        $null = New-CurrentInventoryFields
        $probe = Join-Path $stage003BackupRoot ('VALIDATE_ONLY\'+$stage003ArchiveName)
        & git -C $stage003Root check-ignore --quiet -- $probe
        if ($LASTEXITCODE -ne 0) { throw 'Backup destination not Git-ignored.' }
        [ordered]@{status='LOCAL VALIDATION ONLY';connection_attempted=$false;purpose=$stage003Purpose;archive=$stage003ArchiveName;service='geolock_dev_owner_export';sslmode='verify-full';export='unfiltered custom format plus roles without passwords';restorability='NOT VERIFIED'} | ConvertTo-Json
        return
    }
    $stage003SavedPg = @{}
    foreach ($entry in @(Get-ChildItem Env:)) { if ($entry.Name -match '^PG') { $stage003SavedPg[$entry.Name]=$entry.Value; Remove-Item -LiteralPath ('Env:'+$entry.Name) } }
}
$env:PGSERVICEFILE = $stage003ServiceFile
# Native --password always prompts. Ignore inherited password/options and password-file
# settings; never read or write their secret contents. Approved profile pins options.
Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
Remove-Item Env:PGOPTIONS -ErrorAction SilentlyContinue
Remove-Item Env:PGPASSFILE -ErrorAction SilentlyContinue
$stage003Dir = Join-Path $stage003BackupRoot ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $stage003Dir -ErrorAction Stop | Out-Null
$stage003OwnsCapture = $true
$stage003Phase = 'private destination validation'
if ($stage003CurrentCapture) { Protect-CurrentCaptureDirectory -Directory $stage003Dir }
$stage003Phase = 'inventory'
[ordered]@{status='INCOMPLETE / NOT A VERIFIED BACKUP';phase=$stage003Phase} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage003Dir 'backup-status.json') -Encoding UTF8
Write-Host "Private backup destination: $stage003Dir"
Write-Host 'Enter the approved DEV owner password only at the native hidden PostgreSQL prompts.'

# Catalog inventory only. No application rows, role passwords or connection secrets.
function New-Stage003InventorySql {
param([switch]$ForFreeze, [string]$PolicyPath)
$stage003InventorySql = @'
BEGIN READ ONLY;
SET LOCAL statement_timeout='30s';
SELECT jsonb_build_object(
 'observed_at',clock_timestamp(),'database',current_database(),'current_user',current_user,
 'session_user',session_user,'read_only',current_setting('transaction_read_only'),
 'server_version_num',current_setting('server_version_num'),
 'ssl',(SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),
 'bypassrls',(SELECT rolbypassrls FROM pg_roles WHERE rolname=current_user),
 __PREFREEZE_FIELDS__
 'extensions',(SELECT jsonb_agg(jsonb_build_object('name',e.extname,'version',e.extversion,'schema',n.nspname)) FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace),
 'tables',(SELECT coalesce(jsonb_agg(jsonb_build_object('schema',n.nspname,'name',c.relname,'kind',c.relkind)),'[]'::jsonb)
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE c.relkind IN ('r','p','m') AND n.nspname NOT IN ('pg_catalog','information_schema')
 AND n.nspname NOT LIKE 'pg\_%' ESCAPE '\'
 AND NOT EXISTS(SELECT 1 FROM pg_depend d WHERE d.classid='pg_class'::regclass AND d.objid=c.oid AND d.refclassid='pg_extension'::regclass AND d.deptype='e')),
 'foreign_tables',(SELECT coalesce(jsonb_agg(jsonb_build_object('schema',n.nspname,'name',c.relname)),'[]'::jsonb) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relkind='f'),
 'large_object_count',(SELECT count(*) FROM pg_largeobject_metadata)
);
ROLLBACK;
'@
$stage003FreezeFields = ''
if ($ForFreeze) {
    $stage003PolicyJson = Get-Content -LiteralPath $PolicyPath -Raw
    if ((Get-FileHash -LiteralPath $PolicyPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne '30826f3fdb5c52bde2b29605e54b30b19692740fbbb97d098daf4b22a3c0b030') { throw 'Approved policy JSON drift.' }
    $stage003FreezeFields = @'
 'graph_count',(SELECT count(*) FROM routing_private.graphs),
 'routing_policies',(SELECT jsonb_agg(to_jsonb(p)||jsonb_build_object(
   'body_matches',body=$approved_policy$__POLICY_JSON__$approved_policy$::jsonb,
   'digest_matches',digest=encode(sha256(convert_to(body::text,'UTF8')),'hex')))
   FROM routing_private.policies p),
'@
    $stage003FreezeFields = $stage003FreezeFields.Replace('__POLICY_JSON__',$stage003PolicyJson)
}
$stage003InventorySql = $stage003InventorySql.Replace('__PREFREEZE_FIELDS__',$stage003FreezeFields)
return $stage003InventorySql
}
$stage003InventorySql = New-Stage003InventorySql -ForFreeze:$PreFreeze -PolicyPath (Join-Path $PSScriptRoot 'routing-initialization\policy.proposed.json')
if ($stage003CurrentCapture) {
    $currentFields = New-CurrentInventoryFields
    $stage003InventorySql = $stage003InventorySql.Replace(" 'extensions',",$currentFields + "`n 'extensions',")
}
# SQL/JSON must not cross Windows native argv quoting. Windows PowerShell 5.1
# legacy argument passing removes embedded double quotes in --command SQL.
# UTF-8 file input preserves exact dollar-quoted JSON; only its path crosses argv.
$stage003InventoryFile = Join-Path $stage003Dir 'inventory.readonly.sql'
[IO.File]::WriteAllText($stage003InventoryFile,$stage003InventorySql,(New-Object System.Text.UTF8Encoding($false)))
$stage003InventoryArguments = @('-X','--password','--quiet','--tuples-only','--no-align','--dbname','service=geolock_dev_owner_export','--set','ON_ERROR_STOP=1','--file',$stage003InventoryFile)
$stage003RawInventory = @(& (Join-Path $stage003Bin 'psql.exe') @stage003InventoryArguments)
if ($LASTEXITCODE -ne 0) { throw 'BACKUP_INVENTORY_FAILED:READ_ONLY_IDENTITY_CATALOG_QUERY' }
$stage003InventoryText = ($stage003RawInventory -join "`n").Trim()
$stage003Inventory = $stage003InventoryText | ConvertFrom-Json
if ($stage003Inventory.database -ne 'postgres') { throw "BACKUP_INVENTORY_FAILED:DATABASE_IDENTITY:$($stage003Inventory.database)" }
if ($stage003Inventory.current_user -ne 'postgres') { throw "BACKUP_INVENTORY_FAILED:CURRENT_USER:$($stage003Inventory.current_user)" }
if ($stage003Inventory.session_user -ne 'postgres') { throw "BACKUP_INVENTORY_FAILED:SESSION_USER:$($stage003Inventory.session_user)" }
if ($stage003Inventory.read_only -ne 'on') { throw "BACKUP_INVENTORY_FAILED:READ_ONLY_TRANSACTION:$($stage003Inventory.read_only)" }
if ([int]$stage003Inventory.server_version_num -ne 170011) { throw "BACKUP_INVENTORY_FAILED:POSTGRES_VERSION:$($stage003Inventory.server_version_num)" }
if ($stage003CurrentCapture) { Assert-CurrentInventory -Inventory $stage003Inventory }
if ($PreFreeze -and (!$stage003Inventory.ssl -or !$stage003Inventory.bypassrls -or $stage003Inventory.graph_count -ne 0 -or @($stage003Inventory.routing_policies).Count -ne 1)) { throw 'Pre-freeze TLS/RLS/state guard failed; no export started.' }
if ($PreFreeze) {
    $stage003InstalledPolicy = @($stage003Inventory.routing_policies)[0]
    if ($stage003InstalledPolicy.policy_id -ne '80db858b-93e8-4a0a-94e2-dbe14940f0a1' -or $stage003InstalledPolicy.request_id -ne '0b8db479-20c8-4595-9d41-d831650cba93' -or !$stage003InstalledPolicy.body_matches -or !$stage003InstalledPolicy.digest_matches) { throw 'Installed approved policy mismatch; no export started.' }
}
if (@($stage003Inventory.foreign_tables).Count -gt 0) { throw "BACKUP_INVENTORY_FAILED:FOREIGN_TABLES_PRESENT:$(@($stage003Inventory.foreign_tables).Count)" }
if ([int]$stage003Inventory.large_object_count -ne 0) { throw "BACKUP_INVENTORY_FAILED:LARGE_OBJECTS_PRESENT:$($stage003Inventory.large_object_count)" }
$stage003InventoryText | Set-Content -LiteralPath (Join-Path $stage003Dir 'source-inventory.json') -Encoding UTF8
$stage003ExportStarted = [DateTime]::UtcNow.ToString('o')
$stage003ArchivePath = Join-Path $stage003Dir $stage003ArchiveName
$stage003DumpArguments = @(New-Stage003ClientArguments -Operation Database -DestinationPath $stage003ArchivePath)
$stage003Phase = 'database export'
& (Join-Path $stage003Bin 'pg_dump.exe') @stage003DumpArguments
if ($LASTEXITCODE -ne 0) { throw 'Database export incomplete. Keep failure evidence; do not use the partial file for recovery.' }
$stage003RolesPath = Join-Path $stage003Dir 'roles-no-passwords.sql'
$stage003RoleArguments = @(New-Stage003ClientArguments -Operation Roles -DestinationPath $stage003RolesPath)
$stage003Phase = 'roles export'
& (Join-Path $stage003Bin 'pg_dumpall.exe') @stage003RoleArguments
if ($LASTEXITCODE -ne 0) { throw 'Role/global membership export incomplete; do not claim complete recovery scope.' }
[ordered]@{target_project='rcgyuwiidqvrgbxswhqj';service='geolock_dev_owner_export';purpose=$stage003Purpose;started_at_utc=$stage003ExportStarted;completed_at_utc=[DateTime]::UtcNow.ToString('o');database_export_exit_code=0;roles_export_exit_code=0;roles_passwords_included=$false;source_read_only=$true} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage003Dir 'capture-record.json') -Encoding UTF8
$stage003Phase = 'archive verification'
Invoke-ArchiveVerification $stage003Dir
[ordered]@{status='VERIFIED LOGICAL EXPORT / RESTORABILITY NOT VERIFIED';phase='complete'} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage003Dir 'backup-status.json') -Encoding UTF8

Restore-Stage003PgEnvironment
