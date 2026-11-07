# Local configuration only. No database connections, SQL or worker activation.
# Windows DPAPI encrypts SecureString fields for this Windows user on this PC.
[CmdletBinding()]
param(
    [switch]$ValidateOnly,
    [string]$CaPath,
    [string]$DbHost
)
$ErrorActionPreference = 'Stop'
$checker = Join-Path $PSScriptRoot 'Test-LocalRoutingSetup.ps1'
if ($ValidateOnly) {
    & $checker -ValidateOnly -CaPath $CaPath -DbHost $DbHost
    return
}
$project = 'rcgyuwiidqvrgbxswhqj'
$directory = Join-Path $env:LOCALAPPDATA 'GeoLockHubRoutingDev'
$plannerFile = Join-Path $directory 'planner.clixml'
$validatorFile = Join-Path $directory 'validator.clixml'
if ((Test-Path -LiteralPath $plannerFile) -or (Test-Path -LiteralPath $validatorFile)) {
    throw 'Encrypted profiles already exist. Keep them; this setup will not overwrite credentials.'
}
if (-not $CaPath) { $CaPath = (Read-Host 'Approved local public CA certificate full path').Trim() }
if (-not $DbHost) { $DbHost = (Read-Host 'Exact administrator-approved DEV Session pooler host').Trim() }
if (-not $CaPath -or -not $DbHost) { throw 'Approved CA path and database host are required.' }
& $checker -ValidateOnly -CaPath $CaPath -DbHost $DbHost
$ca = (Resolve-Path -LiteralPath $CaPath).Path

[void](New-Item -ItemType Directory -Path $directory -Force)
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetOwner($sid)
$acl.SetAccessRuleProtection($true, $false)
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.AddAccessRule($rule)
Set-Acl -LiteralPath $directory -AclObject $acl

$publishable = Read-Host -AsSecureString 'DEV sb_publishable_ key (masked; NOT a service-role key)'
$graphId = (Read-Host 'Existing approved frozen graph UUID, or Enter if not initialized').Trim()
if ($graphId) {
    $parsed = [Guid]::Empty
    if (-not [Guid]::TryParse($graphId, [ref]$parsed)) { throw 'Graph ID must be an existing graph UUID.' }
}

# Generate a shared internal service secret without printing/copying it.
$bytes = New-Object byte[] 32
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
$plainToken = [Convert]::ToBase64String($bytes)
$token = ConvertTo-SecureString $plainToken -AsPlainText -Force
$plainToken = $null
[Array]::Clear($bytes, 0, $bytes.Length)

[pscustomobject]@{
    Project = $project; DbHost = $DbHost; Pooled = $true; Ca = $ca
    ValidatorToken = $token; PublishableKey = $publishable; GraphId = $graphId
} | Export-Clixml -LiteralPath $plannerFile
[pscustomobject]@{
    Project = $project; DbHost = $DbHost; Pooled = $true; Ca = $ca
    ValidatorToken = $token
} | Export-Clixml -LiteralPath $validatorFile
Write-Host 'Saved encrypted planner/validator profiles outside Git. No database calls or activation occurred.'
