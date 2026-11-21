# Local configuration only. No database connections, SQL or worker activation.
# Windows DPAPI encrypts SecureString fields for this Windows user on this PC.
# -Environment DEV (default) is unchanged. -Environment KLSEL writes a separate folder
# (GeoLockHubRoutingKLSEL) for the NEW project, including its password-free pg_service.conf.
[CmdletBinding()]
param([ValidateSet('DEV','KLSEL')][string]$Environment = 'DEV')
$ErrorActionPreference = 'Stop'
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

if ($Environment -eq 'DEV') {
    $pooled = (Read-Host 'Use DEV Session pooler on port 5432? [Y/n]') -notmatch '^[Nn]$'
} else {
    $pooled = $true  # the native runtime connects through the session pooler only
}
$dbHost = 'db.' + $project + '.supabase.co'
if ($pooled) {
    $dbHost = (Read-Host ('Paste ONLY the host from ' + $label + ' Connect > Session pooler')).Trim()
    if ([Uri]::CheckHostName($dbHost) -ne [UriHostNameType]::Dns -or
        -not $dbHost.EndsWith('.pooler.supabase.com')) { throw 'Invalid Supabase session-pooler host.' }
}
if ($Environment -eq 'DEV') {
    $ca = (Read-Host 'DEV database CA certificate full path, or Enter for system trust').Trim()
} else {
    $ca = (Read-Host ($label + ' database CA certificate full path (required, e.g. prod-ca-2021.crt)')).Trim()
    if (-not $ca) { throw 'A CA certificate file is required for verify-full TLS.' }
}
if (-not $ca) { $ca = 'system' }
elseif (-not (Test-Path -LiteralPath $ca -PathType Leaf)) { throw 'CA certificate file not found.' }
else { $ca = (Resolve-Path -LiteralPath $ca).Path }
if ($Environment -ne 'DEV') { $ca = $ca.Replace('\', '/') }
$graph = Read-Host -AsSecureString 'Password set with password geolock_graph_login'
$planner = Read-Host -AsSecureString 'Password set with password geolock_planner_login'
$validator = Read-Host -AsSecureString 'Password set with password geolock_validator_login'
$publishable = Read-Host -AsSecureString ($label + ' sb_publishable_ key (masked; NOT a service-role key)')
if ($Environment -eq 'DEV') {
    $graphId = (Read-Host 'Existing approved frozen graph UUID, or Enter if not initialized').Trim()
    if ($graphId) {
        $parsed = [Guid]::Empty
        if (-not [Guid]::TryParse($graphId, [ref]$parsed)) { throw 'Graph ID must be an existing graph UUID.' }
    }
} else {
    $graphId = $selected.GraphId  # the new project's frozen graph; never DEV's
    $serviceFile = Join-Path $directory 'pg_service.conf'
    if (Test-Path -LiteralPath $serviceFile) { throw 'pg_service.conf already exists. Keep it; this setup will not overwrite it.' }
    $serviceText = "# Password-free libpq profile for the GeoLock graph login on " + $project + ". Written by Save-WorkerConfig.ps1.`n" +
        '[' + $selected.Service + "]`nhost=" + $dbHost + "`nport=5432`ndbname=postgres`nuser=geolock_graph_login." + $project +
        "`nsslmode=verify-full`nsslrootcert=" + $ca + "`noptions=-c default_transaction_read_only=off`nconnect_timeout=15`n"
    [IO.File]::WriteAllText($serviceFile, $serviceText, (New-Object System.Text.UTF8Encoding $false))
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
Write-Host ('Saved encrypted ' + $label + ' planner/validator profiles in ' + $directory + ' (outside Git). No database calls or activation occurred.')
