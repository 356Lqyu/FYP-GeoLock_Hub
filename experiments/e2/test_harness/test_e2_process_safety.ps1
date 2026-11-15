$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'e2_process_safety.ps1')

function Assert-Throws {
    param([scriptblock]$Action,[string]$Description)
    try { & $Action } catch { return }
    throw "Expected safety check to refuse: $Description"
}

function Assert-ThrowsContaining {
    param([scriptblock]$Action,[string]$ExpectedText,[string]$Description)
    try { & $Action } catch {
        if ($_.Exception.Message -notlike "*$ExpectedText*") {
            throw "Failure for '$Description' did not preserve expected diagnostic '$ExpectedText': $($_.Exception.Message)"
        }
        return
    }
    throw "Expected safety check to refuse: $Description"
}

$emptyInventory = @(Get-E2ListenerInventory -Port 55432 -ListenerQuery { @() })
if ($emptyInventory.Count -ne 0) { throw 'A successful empty TCP query must be treated as zero listeners.' }
$postgresServiceListener = [pscustomobject]@{ LocalAddress='::'; LocalPort=5432; OwningProcess=6596 }
$filteredSystemListener = @(Get-E2ListenerInventory -Port 55432 -ListenerQuery { @($postgresServiceListener) })
if ($filteredSystemListener.Count -ne 0) { throw 'A listener on the system PostgreSQL port 5432 must not count as an E2-port listener.' }
$e2PortListener = [pscustomobject]@{ LocalAddress='127.0.0.1'; LocalPort=55432; OwningProcess=9003 }
$filteredE2Listener = @(Get-E2ListenerInventory -Port 55432 -ListenerQuery { @($postgresServiceListener,$e2PortListener) })
if ($filteredE2Listener.Count -ne 1 -or $filteredE2Listener[0].LocalPort -ne 55432) {
    throw 'A listener on E2 port 55432 must be detected after filtering the successful all-listeners query.'
}
Assert-ThrowsContaining { Get-E2ListenerInventory -Port 55432 -ListenerQuery { throw [InvalidOperationException]::new('mock listener inventory failure') } } `
    'mock listener inventory failure' 'listener query failure details'
Write-Host 'PASS: empty, unrelated-port, occupied-E2-port, and failing listener queries are distinguished.'

$missingE2Database = Get-E2DatabaseInventoryState `
    -DatabaseRows @('postgres|postgres','template0|postgres','template1|postgres') -CustomRoles @()
if ($missingE2Database -ne 'RecoverableMissingE2Database') {
    throw 'A default-only cluster with no custom roles must be classified as a recoverable missing-E2-database state.'
}
$presentE2Database = Get-E2DatabaseInventoryState `
    -DatabaseRows @('geolock_e2|postgres','postgres|postgres','template0|postgres','template1|postgres') `
    -CustomRoles @('anon','authenticated','service_role')
if ($presentE2Database -ne 'E2DatabasePresent') { throw 'A complete E2 database inventory must be recognized.' }
Assert-Throws { Get-E2DatabaseInventoryState `
    -DatabaseRows @('postgres|postgres','template0|postgres','template1|postgres','application|postgres') -CustomRoles @() } `
    'unexpected database is not recoverable'
Assert-Throws { Get-E2DatabaseInventoryState `
    -DatabaseRows @('postgres|postgres','template0|postgres','template1|postgres') -CustomRoles @('authenticated') } `
    'roles without E2 database are inconsistent'
Write-Host 'PASS: missing geolock_e2 is recoverable only with the exact default database/empty role inventory.'

$expectedE2Data = 'C:\Users\User\AppData\Local\GeoLockHub\E2\cluster\data'
if (-not (Assert-E2ServerIdentity -ActualAddress ' 127.0.0.1 ' -ActualPort '55432' `
        -ActualDataDirectory 'C:/Users/User/AppData/Local/GeoLockHub/E2/cluster/data/' `
        -ActualSystemIdentifier ' 7707119756798008108 ' -ExpectedAddress '127.0.0.1' -ExpectedPort 55432 `
        -ExpectedDataDirectory $expectedE2Data -ExpectedSystemIdentifier '7707119756798008108')) {
    throw 'Equivalent Windows path formatting must pass E2 server identity validation.'
}
foreach ($mismatch in @(
    @{ Address='127.0.0.2'; Port='55432'; Data=$expectedE2Data; System='7707119756798008108'; Field='address' },
    @{ Address='127.0.0.1/24'; Port='55432'; Data=$expectedE2Data; System='7707119756798008108'; Field='address' },
    @{ Address='::1'; Port='55432'; Data=$expectedE2Data; System='7707119756798008108'; Field='address' },
    @{ Address='127.0.0.1'; Port='55433'; Data=$expectedE2Data; System='7707119756798008108'; Field='port' },
    @{ Address='127.0.0.1'; Port='55432'; Data='C:\Other\cluster\data'; System='7707119756798008108'; Field='data_directory' },
    @{ Address='127.0.0.1'; Port='55432'; Data=$expectedE2Data; System='9999999999999999999'; Field='system_identifier' }
)) {
    Assert-ThrowsContaining {
        Assert-E2ServerIdentity -ActualAddress $mismatch.Address -ActualPort $mismatch.Port `
            -ActualDataDirectory $mismatch.Data -ActualSystemIdentifier $mismatch.System `
            -ExpectedAddress '127.0.0.1' -ExpectedPort 55432 -ExpectedDataDirectory $expectedE2Data `
            -ExpectedSystemIdentifier '7707119756798008108'
    } $mismatch.Field "server identity rejects mismatched $($mismatch.Field)"
}
Assert-E2ServerIdentity -ActualAddress '127.0.0.1/32' -ActualPort '55432' `
    -ActualDataDirectory $expectedE2Data -ActualSystemIdentifier '7707119756798008108' `
    -ExpectedAddress '127.0.0.1' -ExpectedPort 55432 -ExpectedDataDirectory $expectedE2Data `
    -ExpectedSystemIdentifier '7707119756798008108' | Out-Null
Write-Host 'PASS: server identity canonicalizes equivalent Windows paths and rejects each genuine field mismatch.'

$programFilesRoot = 'C:\Program Files'
$pgBin = 'C:\Program Files\PostgreSQL\17\bin'
$e2Data = 'C:\Users\User\AppData\Local\GeoLockHub\E2\cluster\data'
$serviceData = 'C:\Program Files\PostgreSQL\17\data'
$service = [pscustomobject]@{
    Name='postgresql-x64-17'; State='Running'; ProcessId=4764
    PathName='"C:\Program Files\PostgreSQL\17\bin\pg_ctl.exe" runservice -N "postgresql-x64-17" -D "C:\Program Files\PostgreSQL\17\data" -w'
}
$serviceProcesses = @(
    [pscustomobject]@{ Name='pg_ctl.exe'; ProcessId=4764; ParentProcessId=1000; CommandLine=$null },
    [pscustomobject]@{ Name='postgres.exe'; ProcessId=6596; ParentProcessId=4764; CommandLine=$null },
    [pscustomobject]@{ Name='postgres.exe'; ProcessId=7001; ParentProcessId=6596; CommandLine=$null },
    [pscustomobject]@{ Name='postgres.exe'; ProcessId=7002; ParentProcessId=6596; CommandLine=$null }
)

# The actual production check function accepts mocked inventories so this test
# exercises the same service validation and ancestry walk without CIM or sockets.
Assert-E2ProcessSafety -PgCtlStatusCode 3 -DataDir $e2Data -PgBin $pgBin `
    -ProgramFilesRoot $programFilesRoot -Port 55432 -Processes $serviceProcesses `
    -Services @($service) -Listeners @()
Write-Host 'PASS: verified unrelated service descendants with inaccessible command lines are exempted.'

$unknownProcess = [pscustomobject]@{ Name='postgres.exe'; ProcessId=9001; ParentProcessId=1; CommandLine='postgres.exe -D C:\Other\data' }
Assert-Throws { Assert-E2ProcessSafety -PgCtlStatusCode 3 -DataDir $e2Data -PgBin $pgBin `
    -ProgramFilesRoot $programFilesRoot -Port 55432 -Processes ($serviceProcesses + $unknownProcess) `
    -Services @($service) -Listeners @() } 'unknown PostgreSQL process'

$unknownWithoutCommandLine = [pscustomobject]@{ Name='postgres.exe'; ProcessId=9002; ParentProcessId=1; CommandLine=$null }
Assert-Throws { Assert-E2ProcessSafety -PgCtlStatusCode 3 -DataDir $e2Data -PgBin $pgBin `
    -ProgramFilesRoot $programFilesRoot -Port 55432 -Processes ($serviceProcesses + $unknownWithoutCommandLine) `
    -Services @($service) -Listeners @() } 'unknown process with hidden command line'

$wrongService = $service.PSObject.Copy()
$wrongService.PathName = '"C:\Program Files\PostgreSQL\17\bin\pg_ctl.exe" runservice -N "postgresql-x64-17" -D "C:\Application\data" -w'
Assert-Throws { Assert-E2ProcessSafety -PgCtlStatusCode 3 -DataDir $e2Data -PgBin $pgBin `
    -ProgramFilesRoot $programFilesRoot -Port 55432 -Processes $serviceProcesses `
    -Services @($wrongService) -Listeners @() } 'service configured for a different data directory'

Assert-Throws { Assert-E2ProcessSafety -PgCtlStatusCode 3 -DataDir $e2Data -PgBin $pgBin `
    -ProgramFilesRoot $programFilesRoot -Port 55432 -Processes $serviceProcesses `
    -Services @($service) -Listeners $filteredE2Listener } 'unexpected E2 port listener'

Assert-Throws { Assert-E2ProcessSafety -PgCtlStatusCode 3 -DataDir $e2Data -PgBin $pgBin `
    -ProgramFilesRoot $programFilesRoot -Port 55432 -Processes ($serviceProcesses + $unknownProcess) `
    -Services @($service) -Listeners @() -RecordedPostmasterPid '9001' } 'recorded PID still exists'

Assert-Throws { Assert-E2ProcessSafety -PgCtlStatusCode 0 -DataDir $e2Data -PgBin $pgBin `
    -ProgramFilesRoot $programFilesRoot -Port 55432 -Processes $serviceProcesses `
    -Services @($service) -Listeners @() } 'pg_ctl reports running'

$activeE2Process = [pscustomobject]@{ Name='postgres.exe'; ProcessId=9003; ParentProcessId=1; CommandLine='postgres.exe -D C:\Users\User\AppData\Local\GeoLockHub\E2\cluster\data' }
$activeE2Listener = [pscustomobject]@{ LocalAddress='127.0.0.1'; LocalPort=55432; OwningProcess=9003 }
Assert-E2ProcessSafety -PgCtlStatusCode 0 -DataDir $e2Data -PgBin $pgBin `
    -ProgramFilesRoot $programFilesRoot -Port 55432 -Processes ($serviceProcesses + $activeE2Process) `
    -Services @($service) -Listeners @($activeE2Listener) -RecordedPostmasterPid '9003' -E2PostmasterPid '9003'
Assert-Throws { Assert-E2ProcessSafety -PgCtlStatusCode 0 -DataDir $e2Data -PgBin $pgBin `
    -ProgramFilesRoot $programFilesRoot -Port 55432 -Processes ($serviceProcesses + $activeE2Process) `
    -Services @($service) -Listeners @($activeE2Listener) -RecordedPostmasterPid '9003' -E2PostmasterPid '9003' -RequireStopped } `
    'running cluster prohibited for stale PID quarantine'
Write-Host 'PASS: a verified running E2 cluster is attachable while stopped-only actions still refuse it.'

$wrongServiceRoot = $serviceProcesses | Where-Object { $_.ProcessId -ne 4764 }
Assert-Throws { Assert-E2ProcessSafety -PgCtlStatusCode 3 -DataDir $e2Data -PgBin $pgBin `
    -ProgramFilesRoot $programFilesRoot -Port 55432 -Processes $wrongServiceRoot `
    -Services @($service) -Listeners @() } 'service PID has no matching pg_ctl process'

Write-Host 'PASS: unknown processes, mismatched service config, active listeners, recorded PIDs, and running clusters are refused.'
