# Offline regression check: argv echo plus PostgreSQL service-lookup failures
# against an empty local configuration. Never connects or runs the backup runner.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'backup_native_arguments.ps1')
$validationRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
$python = Join-Path $validationRoot '.venv-stage8\Scripts\python.exe'
$probe = Join-Path $PSScriptRoot 'backup_argv_probe.py'
if (!(Test-Path -LiteralPath $probe)) { throw 'Missing offline native argv probe.' }
foreach ($file in @('backup_pre003.ps1','backup_native_arguments.ps1','validate_backup_arguments.ps1')) {
    $parseTokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $file),[ref]$parseTokens,[ref]$parseErrors) | Out-Null
    if ($parseErrors.Count) { throw "PowerShell syntax error: $file" }
}
$fakeDirectory = 'C:\Offline validation only\Backup path with spaces'
$archive = Join-Path $fakeDirectory 'dev-pre003.dump'
$schema = Join-Path $fakeDirectory 'schema.sql'
$roles = Join-Path $fakeDirectory 'roles-no-passwords.sql'
$sql = "BEGIN READ ONLY;`nSELECT 'offline argument validation only';`nROLLBACK;"
$cases = @(
    @{Operation='Inventory';Sql=$sql;Expected=@('-X','--password','--quiet','--tuples-only','--no-align','--dbname','service=geolock_dev_owner_export','--set','ON_ERROR_STOP=1','--command',$sql)},
    @{Operation='Database';DestinationPath=$archive;Expected=@('--password','--dbname','service=geolock_dev_owner_export','--format','custom','--lock-wait-timeout','5s','--file',$archive)},
    @{Operation='Roles';DestinationPath=$roles;Expected=@('--password','--dbname','service=geolock_dev_owner_export','--roles-only','--no-role-passwords','--file',$roles)},
    @{Operation='Toc';ArchivePath=$archive;Expected=@('--list',$archive)},
    @{Operation='Decode';ArchivePath=$archive;Expected=@('--file','NUL',$archive)},
    @{Operation='Schema';DestinationPath=$schema;ArchivePath=$archive;Expected=@('--schema-only','--file',$schema,$archive)}
)
foreach ($case in $cases) {
    $parameters = @{Operation=$case.Operation}
    foreach ($key in @('Sql','DestinationPath','ArchivePath')) { if ($case.ContainsKey($key)) { $parameters[$key]=$case[$key] } }
    $nativeArguments = @(New-Stage003ClientArguments @parameters)
    $actual = (& $python $probe @nativeArguments) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $actual.Count -ne $case.Expected.Count) { throw "Argument count mismatch: $($case.Operation)" }
    for ($index=0;$index -lt $actual.Count;$index++) {
        if ($actual[$index] -cne $case.Expected[$index]) { throw "Argument mismatch: $($case.Operation) at $index" }
    }
}
# Check the installed client's semantic distinction, not argv echo alone.
$dumpallHelp = (& 'C:\Program Files\PostgreSQL\17\bin\pg_dumpall.exe' --help) -join "`n"
if ($LASTEXITCODE -ne 0 -or $dumpallHelp -notmatch '--dbname=CONNSTR' -or $dumpallHelp -notmatch '--database=DBNAME') { throw 'Installed pg_dumpall connection option contract changed.' }
$rolesArguments = @(New-Stage003ClientArguments -Operation Roles -DestinationPath $roles)
if ($rolesArguments -contains '--database' -or $rolesArguments -notcontains '--dbname') { throw 'pg_dumpall must receive service=... through --dbname, not --database.' }
# Prove the actual installed clients parse service=... as a connection string.
# Isolate BOTH service-file lookup locations; an intentionally missing service
# must fail before host resolution/network/password access. No output files.
$previousServiceFile = $env:PGSERVICEFILE
$previousSystemDirectory = $env:PGSYSCONFDIR
try {
    $env:PGSERVICEFILE = Join-Path $PSScriptRoot 'offline_service_validation.conf'
    $env:PGSYSCONFDIR = $PSScriptRoot
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'pg_service.conf')) { throw 'Offline fixture must have no system service file.' }
    $offlineService = 'service=stage003_intentionally_missing_offline_validation_service'
    foreach ($client in @('psql.exe','pg_dump.exe','pg_dumpall.exe')) {
        $clientArguments = @('--no-password','--dbname',$offlineService)
        if ($client -eq 'psql.exe') { $clientArguments = @('-X') + $clientArguments + @('--command','SELECT 1') }
        if ($client -eq 'pg_dumpall.exe') { $clientArguments += @('--roles-only','--no-role-passwords') }
        $savedErrorPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $response = (& (Join-Path 'C:\Program Files\PostgreSQL\17\bin' $client) @clientArguments 2>&1) | Out-String
            $clientExit = $LASTEXITCODE
        } finally { $ErrorActionPreference = $savedErrorPreference }
        if ($clientExit -eq 0 -or $response -notmatch 'definition of service.*not found') { throw "Expected local service-lookup failure missing: $client" }
    }
} finally {
    $env:PGSERVICEFILE = $previousServiceFile
    $env:PGSYSCONFDIR = $previousSystemDirectory
}
# Reproduce the original defect against the echo process only.
$broken = (& $python $probe --file=(Join-Path $fakeDirectory 'dev-pre003.dump')) | ConvertFrom-Json
if ($broken.Count -ne 2 -or $broken[0] -ne '--file=' -or $broken[1] -ne $archive) { throw 'Original defect reproduction changed; inspect parser behavior.' }
Write-Output ('PASS: PowerShell ' + $PSVersionTable.PSVersion.ToString() + '; 3 syntax checks; 6 native argv cases; pg_dumpall option semantics; 3 installed-client offline service-lookup tests; original file-argument defect reproduced. No database/network/export/restore executed.')
