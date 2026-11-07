# Explicit operator stages only. Default validates locally without connecting.
[CmdletBinding()]
param([ValidateSet('ValidateOnly','Setup','Password','VerifyNative')][string]$Stage='ValidateOnly')
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$psql='C:\Program Files\PostgreSQL\17\bin\psql.exe'
$installerProfile=Join-Path $repo 'backups\stage-a003\pg_installer_service.conf'
$resolverProfile=Join-Path $PSScriptRoot 'pg_resolver_service.PROPOSAL.conf'
$hashes=@{
    'reconciliation_resolver_setup.PROPOSAL.sql'='38ac01914ce47a725b19b3b7603b9b506fd455aadee000307f2fee77bb8e13e6'
    'reconciliation_activation_verification.readonly.sql'='2b2e603a5f8e2f297b238205c1b4a7f4175a53b856cce7513a67e8f7a62070fc'
    'resolver_installer_identity.readonly.sql'='35380a91ab0eb547981e3d24fb6b4dccb0e34c3d280c84446a45b83ae532110b'
    'resolver_password_prompt.psql'='457142686cb9f9ed05aa38d8ecaa1956238f0029577e1f0a663591cefdcade99'
    'resolver_native_identity.readonly.sql'='a984b144e4051b33cb156d2cabdbad7b73142ffb603b08271168377861ff475e'
    'pg_resolver_service.PROPOSAL.conf'='45e72d5aa1f3adac5404583478772c5f97a211c38c88b47ded0a1430f7951a19'
}
foreach ($name in $hashes.Keys) {
    if ((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hashes[$name]) { throw 'Reviewed resolver source/profile checksum mismatch. No connection.' }
}
function Assert-ApprovedProfile([string]$Path,[string]$Service,[string]$User,[string]$ReadOnly) {
    $entries=@(Get-Content -LiteralPath $Path | Where-Object {$_.Trim() -and $_ -notmatch '^\s*[#;]'})
    $required=@(('['+$Service+']'),'host=aws-0-ap-northeast-2.pooler.supabase.com','port=5432','dbname=postgres',('user='+$User),'sslmode=verify-full','sslrootcert=C:/Users/User/Downloads/prod-ca-2021.crt',('options=-c default_transaction_read_only='+$ReadOnly),'connect_timeout=15')
    if ($entries.Count -ne $required.Count) { throw 'Approved profile structure mismatch. No fallback.' }
    foreach ($line in $required) { if (@($entries | Where-Object {$_ -ceq $line}).Count -ne 1) { throw 'Approved DEV target/TLS/profile mismatch. No fallback.' } }
}
Assert-ApprovedProfile $installerProfile 'geolock_dev_installer' 'postgres.rcgyuwiidqvrgbxswhqj' 'off'
Assert-ApprovedProfile $resolverProfile 'geolock_dev_resolver' 'geolock_resolution_operator_login.rcgyuwiidqvrgbxswhqj' 'on'
if (!(Test-Path -LiteralPath 'C:/Users/User/Downloads/prod-ca-2021.crt' -PathType Leaf)) { throw 'Approved CA missing.' }
$version=& $psql --version
if ($LASTEXITCODE -ne 0 -or $version -notmatch '17\.11\b') { throw 'PostgreSQL17.11 client required.' }
if ($Stage -eq 'ValidateOnly') {
    [ordered]@{status='LOCAL CONFIG VALIDATED';connection_attempted=$false;role='geolock_resolution_operator_login';backend_activation=$false;client=$version;source_hashes=$hashes} | ConvertTo-Json -Depth 4
    return
}
. (Join-Path $repo 'docs\stage8\stage-a\deployment-preparation\backup_native_arguments.ps1')
$native=@(New-Stage003ClientArguments -Operation Inventory -Sql 'FILE_PLACEHOLDER')
if ($native[6] -ne 'service=geolock_dev_owner_export' -or $native[-2] -ne '--command') { throw 'Reviewed native argument layout changed. No connection.' }
$native[6]=if ($Stage -eq 'VerifyNative') {'service=geolock_dev_resolver'} else {'service=geolock_dev_installer'}
$native[-2]='--file'
$native[-1]=Join-Path $PSScriptRoot $(if ($Stage -eq 'VerifyNative') {'resolver_native_identity.readonly.sql'} else {'resolver_installer_identity.readonly.sql'})
if ($Stage -eq 'Setup') {
    $native+=@('--file',(Join-Path $PSScriptRoot 'reconciliation_resolver_setup.PROPOSAL.sql'),'--file',(Join-Path $PSScriptRoot 'reconciliation_activation_verification.readonly.sql'))
} elseif ($Stage -eq 'Password') {
    $native+=@('--file',(Join-Path $PSScriptRoot 'resolver_password_prompt.psql'))
}
$directory=Join-Path $repo ('results\reconciliation-resolver-setup\'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'-'+$Stage+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
# Password stage deliberately has no output capture/transcript.
$raw=if ($Stage -eq 'Password') {$null} else {Join-Path $directory 'capture.txt'}
if ($raw) {$native+=@('--output',$raw)}
$saved=@{}
foreach ($entry in @(Get-ChildItem Env:)) { if ($entry.Name -match '^PG') { $saved[$entry.Name]=$entry.Value;Remove-Item -LiteralPath ('Env:'+$entry.Name) } }
$exitCode=$null
try {
    $env:PGSERVICEFILE=if ($Stage -eq 'VerifyNative') {$resolverProfile} else {$installerProfile}
    Write-Host ('Approved resolver stage: '+$Stage+'. Native hidden prompts only. No retries or activation.')
    if ($Stage -eq 'Password') { Write-Host 'Enter existing installer password first, then set/repeat ONLY the new resolver password. Do not record/transcribe this terminal.' }
    & $psql @native
    $exitCode=$LASTEXITCODE
} finally {
    foreach ($entry in @(Get-ChildItem Env:)) {if ($entry.Name -match '^PG') {Remove-Item -LiteralPath ('Env:'+$entry.Name)}}
    foreach ($name in $saved.Keys) {Set-Item -LiteralPath ('Env:'+$name) -Value $saved[$name]}
    [ordered]@{stage=$Stage;status=$(if ($exitCode -eq 0) {'STAGE COMPLETED / REVIEW EVIDENCE'} else {'FAILED OR UNCERTAIN / STOP / NO RETRY'});psql_exit_code=$exitCode;project_ref='rcgyuwiidqvrgbxswhqj';backend_activation=$false;business_operations=$false;password_output_captured=$false;source_hashes=$hashes;observed_at=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $directory 'status.json') -Encoding UTF8
    Write-Host ('Evidence: '+$directory)
}
if ($exitCode -ne 0) {throw 'Resolver stage failed or outcome is uncertain. Preserve evidence; no retry, alternate profile or repair.'}
Write-Host 'Stage completed. Backend remains disabled by this procedure; no V2/V3 writes or finalization. Review captured results.'
