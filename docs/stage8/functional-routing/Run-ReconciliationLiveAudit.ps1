# Operator-run ONLY. Native hidden prompt; no stored credential or fallback profile.
[CmdletBinding()]
param([switch]$ValidateOnly, [switch]$ExecuteReadOnly, [string]$ConnectionApprovalRef)
$Addendum=$false
$ReconciliationPair=$true
$ErrorActionPreference='Stop'
if ($ValidateOnly -and $ExecuteReadOnly) { throw 'Choose local validation or separately approved execution, not both.' }
if ($Addendum -and $ReconciliationPair) { throw 'Choose the scoped pair preflight or the historical addendum, not both.' }
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$profile=Join-Path $repo 'backups\stage-a003\pg_service.conf'
$psql='C:\Program Files\PostgreSQL\17\bin\psql.exe'
$sql=Join-Path $PSScriptRoot 'reconciliation_live_dev_audit.readonly.sql'
$expectedSql='eacb6ed287cef727533439f7eab47e900599efee6c9b9fa9657b23ac230ff965'
if ((Get-FileHash -LiteralPath $sql -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedSql) { throw 'Reviewed read-only SQL checksum mismatch. STOP.' }
$migration=Join-Path $repo 'docs\stage8\stage-a\forward-migrations\20261106_route_interruption_resolution.sql'
$expected='a9fe7713fe2ffd65816743b52abd43695d63d1ecbb45fd216983c4a952eca557'
if ((Get-FileHash -LiteralPath $migration -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw 'Migration checksum mismatch. STOP.' }
$readerExpected='aacfdffb658ef66017995d6ab85e9cd747fcf6125f1d74f940f3121eb367b652'
$backupGuardHashes=$null
if ($ReconciliationPair) {
    $reader=Join-Path $repo 'docs\stage8\stage-a\forward-migrations\20261107_donor_route_resolution_read.sql'
    if ((Get-FileHash -LiteralPath $reader -Algorithm SHA256).Hash.ToLowerInvariant() -ne $readerExpected) { throw 'Donor-reader migration checksum mismatch. STOP.' }
    # Control hashes are evidence only; audit does not repin or clear the backup guard.
    $guard=Join-Path $repo 'docs\stage8\stage-a\deployment-preparation\backup_route_resolution.ps1'
    $guardBaseline=Join-Path $repo 'docs\stage8\stage-a\deployment-preparation\route_resolution_backup_baseline.json'
    $backupGuardHashes=[ordered]@{status='HOLD UNCHANGED';helper_sha256=(Get-FileHash -LiteralPath $guard -Algorithm SHA256).Hash.ToLowerInvariant();baseline_sha256=(Get-FileHash -LiteralPath $guardBaseline -Algorithm SHA256).Hash.ToLowerInvariant();hub_catalog_inspection_authorized=$true;backup_executed=$false}
}
$entries=@(Get-Content -LiteralPath $profile | Where-Object { $_.Trim() -and $_ -notmatch '^\s*[#;]' })
$required=@('[geolock_dev_owner_export]','host=aws-0-ap-northeast-2.pooler.supabase.com','port=5432','dbname=postgres','user=postgres.rcgyuwiidqvrgbxswhqj','sslmode=verify-full','sslrootcert=C:/Users/User/Downloads/prod-ca-2021.crt','options=-c default_transaction_read_only=on','connect_timeout=15')
if ($entries.Count -ne $required.Count) { throw 'Approved profile structure mismatch. No fallback.' }
foreach ($line in $required) {
    if (@($entries | Where-Object { $_ -ceq $line }).Count -ne 1) { throw 'Approved profile identity/options mismatch. No fallback.' }
}
if (!(Test-Path -LiteralPath 'C:/Users/User/Downloads/prod-ca-2021.crt' -PathType Leaf)) { throw 'Approved CA missing.' }
$version=& $psql --version
if ($LASTEXITCODE -ne 0 -or $version -notmatch '17\.11\b') { throw 'PostgreSQL17.11 client required.' }
. (Join-Path $repo 'docs\stage8\stage-a\deployment-preparation\backup_native_arguments.ps1')
$native=@(New-Stage003ClientArguments -Operation Inventory -Sql 'READONLY_FILE_PLACEHOLDER')
if ($native[-2] -ne '--command' -or $native[-1] -ne 'READONLY_FILE_PLACEHOLDER') { throw 'Reviewed argument template mismatch.' }
$native[-2]='--file';$native[-1]=$sql
if (!$ExecuteReadOnly) {
    [ordered]@{audit_scope='LIVE_FULL_CATALOG';status='LOCAL CONFIG VALIDATED / NO DEV INSPECTION';addendum=[bool]$Addendum;reconciliation_pair=[bool]$ReconciliationPair;connection_attempted=$false;client=$version;service='geolock_dev_owner_export';project_ref='rcgyuwiidqvrgbxswhqj';sslmode='verify-full';migration_sha256=$expected;reader_migration_sha256=$(if ($ReconciliationPair) {$readerExpected} else {$null});sql_sha256=(Get-FileHash -LiteralPath $sql -Algorithm SHA256).Hash.ToLowerInvariant();backup_guard=$backupGuardHashes} | ConvertTo-Json -Depth 4
    return
}
if ([string]::IsNullOrWhiteSpace($ConnectionApprovalRef)) { throw 'Explicit read-only connection approval reference required. No connection attempted.' }
$captureRoot='results\reconciliation-live-dev-compatibility-audit\'
$directory=Join-Path $repo ($captureRoot+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
# Raw function bodies and business identifiers are private operator evidence.
$privateAcl=New-Object System.Security.AccessControl.DirectorySecurity
$privateAcl.SetAccessRuleProtection($true,$false)
foreach ($sid in @([System.Security.Principal.WindowsIdentity]::GetCurrent().User, [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
    $rule=[System.Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
    $privateAcl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $directory -AclObject $privateAcl -ErrorAction Stop

$raw=Join-Path $directory 'capture.jsonl'
$native+=@('--output',$raw)
$saved=@{}
foreach ($entry in @(Get-ChildItem Env:)) {
    if ($entry.Name -match '^PG') { $saved[$entry.Name]=$entry.Value;Remove-Item -LiteralPath ('Env:'+$entry.Name) }
}
$exitCode=$null
$captureComplete=$false
$stopGates=@()
try {
    $env:PGSERVICEFILE=$profile
    $env:PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=15000 -c lock_timeout=2000 -c idle_in_transaction_session_timeout=60000'
    Write-Host 'Enter the approved DEV owner-export database password only at the native hidden prompt. One connection; no retries.'
    & $psql @native
    $exitCode=$LASTEXITCODE
} finally {
    foreach ($entry in @(Get-ChildItem Env:)) { if ($entry.Name -match '^PG') { Remove-Item -LiteralPath ('Env:'+$entry.Name) } }
    foreach ($name in $saved.Keys) { Set-Item -LiteralPath ('Env:'+$name) -Value $saved[$name] }
    if ($ReconciliationPair -and (Test-Path -LiteralPath $raw)) {
        try {
            $records=@(Get-Content -LiteralPath $raw | Where-Object { $_.StartsWith('{') } | ForEach-Object { $_ | ConvertFrom-Json })
            $stopGates=@($records | Where-Object { $_.section -eq 'stop' } | ForEach-Object { $_.gate })
            $captureComplete=($exitCode -eq 0 -and $stopGates.Count -eq 0 -and @($records | Where-Object { $_.section -eq 'capture_complete' -and $_.read_only -eq 'on' }).Count -eq 1)
        } catch { $captureComplete=$false }
    } elseif (!$ReconciliationPair) { $captureComplete=($exitCode -eq 0) }
    [ordered]@{audit_scope='LIVE_FULL_CATALOG';status=$(if ($captureComplete) {'CAPTURE COMPLETE / REVIEW REQUIRED'} else {'FAILED / NO PREFLIGHT PASS'});psql_exit_code=$exitCode;addendum=[bool]$Addendum;reconciliation_pair=[bool]$ReconciliationPair;stop_gates=$stopGates;capture_complete_marker_verified=$captureComplete;connection_approval_ref=$ConnectionApprovalRef;project_ref='rcgyuwiidqvrgbxswhqj';service='geolock_dev_owner_export';migration_sha256=$expected;reader_migration_sha256=$(if ($ReconciliationPair) {$readerExpected} else {$null});sql_sha256=(Get-FileHash -LiteralPath $sql -Algorithm SHA256).Hash.ToLowerInvariant();backup_guard=$backupGuardHashes;writes_authorized=$false;rollback_expected=$true;observed_at=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $directory 'capture-status.json') -Encoding UTF8
    Write-Host ('Read-only evidence: '+$directory)
}
if ($exitCode -ne 0) { throw 'Read-only capture failed. Preserve evidence; no retry or alternate profile.' }
if (!$captureComplete) { throw ('Read-only safety/dependency gate stopped capture. Preserve evidence; no retry. Gates: '+($stopGates -join ', ')) }
Write-Host 'Capture completed, including ROLLBACK. Catalog review still required; no deployment GO is implied.'
