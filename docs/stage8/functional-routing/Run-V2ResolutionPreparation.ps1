# LOCAL validation by default. Operator-run explicit read-only execution only.
[CmdletBinding()]
param([switch]$ValidateOnly, [switch]$ExecuteReadOnly, [string]$ConnectionApprovalRef)
$ErrorActionPreference='Stop'
if ($ValidateOnly -and $ExecuteReadOnly) { throw 'Choose validation or execution, not both.' }
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$profile=Join-Path $repo 'backups\stage-a003\pg_service.conf'
$psql='C:\Program Files\PostgreSQL\17\bin\psql.exe'
$sql=Join-Path $PSScriptRoot 'v2_resolution_preparation.readonly.sql'
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
$hash=(Get-FileHash -LiteralPath $sql -Algorithm SHA256).Hash.ToLowerInvariant()
if (!$ExecuteReadOnly) {
    [ordered]@{status='LOCAL VALIDATION PASS / DEV RESULTS UNVERIFIED';connection_attempted=$false;client=$version;service='geolock_dev_owner_export';project_ref='rcgyuwiidqvrgbxswhqj';sslmode='verify-full';sql_sha256=$hash} | ConvertTo-Json
    return
}
if ([string]::IsNullOrWhiteSpace($ConnectionApprovalRef)) { throw 'Explicit connection approval reference required. No connection attempted.' }
$directory=Join-Path $repo ('results\v2-resolution-preparation\'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'-native-'+[guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
$raw=Join-Path $directory 'capture.jsonl'
$native+=@('--output',$raw)
$saved=@{}
foreach ($entry in @(Get-ChildItem Env:)) {
    if ($entry.Name -match '^PG') { $saved[$entry.Name]=$entry.Value;Remove-Item -LiteralPath ('Env:'+$entry.Name) }
}
$exitCode=$null
try {
    $env:PGSERVICEFILE=$profile
    $env:PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=15000 -c lock_timeout=2000 -c idle_in_transaction_session_timeout=60000'
    Write-Host 'Enter the approved DEV owner-export password only at the native hidden prompt. One connection; no retries.'
    & $psql @native
    $exitCode=$LASTEXITCODE
} finally {
    foreach ($entry in @(Get-ChildItem Env:)) { if ($entry.Name -match '^PG') { Remove-Item -LiteralPath ('Env:'+$entry.Name) } }
    foreach ($name in $saved.Keys) { Set-Item -LiteralPath ('Env:'+$name) -Value $saved[$name] }
    [ordered]@{status=$(if ($exitCode -eq 0) {'CAPTURE COMPLETE / REVIEW REQUIRED'} else {'FAILURE / INCOMPLETE CHECKS UNVERIFIED'});psql_exit_code=$exitCode;project_ref='rcgyuwiidqvrgbxswhqj';service='geolock_dev_owner_export';connection_approval_ref=$ConnectionApprovalRef;sql_sha256=$hash;business_writes=$false;rollback_expected=$true;synthetic_dev_demonstration=$true;observed_at=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'capture-status.json') -Encoding UTF8
    Write-Host ('Read-only evidence: '+$directory)
}
if ($exitCode -ne 0) { throw 'Read-only capture failed. Preserve evidence; no retry or alternate profile.' }
Write-Host 'Capture completed including ROLLBACK. Review each VERIFIED/FAILURE section; no business operation was performed.'
