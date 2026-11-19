# Local configuration only. No database connections, SQL or worker activation.
# Windows DPAPI encrypts SecureString fields for this Windows user on this PC.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$project = 'rcgyuwiidqvrgbxswhqj'
$directory = Join-Path $env:LOCALAPPDATA 'GeoLockHubRoutingDev'
$plannerFile = Join-Path $directory 'planner.clixml'
$validatorFile = Join-Path $directory 'validator.clixml'
if ((Test-Path -LiteralPath $plannerFile) -or (Test-Path -LiteralPath $validatorFile)) {
    throw 'Encrypted profiles already exist. Keep them; this setup will not overwrite credentials.'
}
[void](New-Item -ItemType Directory -Path $directory -Force)
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetOwner($sid)
$acl.SetAccessRuleProtection($true, $false)
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.AddAccessRule($rule)
Set-Acl -LiteralPath $directory -AclObject $acl

$pooled = (Read-Host 'Use DEV Session pooler on port 5432? [Y/n]') -notmatch '^[Nn]$'
$dbHost = 'db.' + $project + '.supabase.co'
if ($pooled) {
    $dbHost = (Read-Host 'Paste ONLY the host from DEV Connect > Session pooler').Trim()
    if ([Uri]::CheckHostName($dbHost) -ne [UriHostNameType]::Dns -or
        -not $dbHost.EndsWith('.pooler.supabase.com')) { throw 'Invalid Supabase session-pooler host.' }
}
$ca = (Read-Host 'DEV database CA certificate full path, or Enter for system trust').Trim()
if (-not $ca) { $ca = 'system' }
elseif (-not (Test-Path -LiteralPath $ca -PathType Leaf)) { throw 'CA certificate file not found.' }
else { $ca = (Resolve-Path -LiteralPath $ca).Path }
$graph = Read-Host -AsSecureString 'Password set with password geolock_graph_login'
$planner = Read-Host -AsSecureString 'Password set with password geolock_planner_login'
$validator = Read-Host -AsSecureString 'Password set with password geolock_validator_login'
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
    Project = $project; DbHost = $dbHost; Pooled = $pooled; Ca = $ca
    GraphPassword = $graph; PlannerPassword = $planner
    ValidatorToken = $token; PublishableKey = $publishable; GraphId = $graphId
} | Export-Clixml -LiteralPath $plannerFile
[pscustomobject]@{
    Project = $project; DbHost = $dbHost; Pooled = $pooled; Ca = $ca
    ValidatorPassword = $validator; ValidatorToken = $token
} | Export-Clixml -LiteralPath $validatorFile
Write-Host 'Saved encrypted planner/validator profiles outside Git. No database calls or activation occurred.'
