function Get-E2ListenerInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Port,
        [scriptblock]$ListenerQuery = { Get-NetTCPConnection -State Listen -ErrorAction Stop }
    )
    try {
        $allListeners = @(& $ListenerQuery)
    } catch {
        $queryError = $_
        $exceptionType = if ($queryError.Exception) { $queryError.Exception.GetType().FullName } else { 'unknown exception' }
        $exceptionMessage = if ($queryError.Exception) { $queryError.Exception.Message } else { [string]$queryError }
        $errorId = if ($queryError.FullyQualifiedErrorId) { $queryError.FullyQualifiedErrorId } else { 'unavailable' }
        throw "Recovery refused: TCP listener query failed ($exceptionType; FullyQualifiedErrorId=$errorId): $exceptionMessage"
    }
    $targetListeners = @()
    foreach ($listener in $allListeners) {
        $portProperty = $listener.PSObject.Properties['LocalPort']
        if (-not $portProperty -or $null -eq $portProperty.Value) {
            throw 'Recovery refused: TCP listener query returned a record without LocalPort; inventory is untrustworthy.'
        }
        if ([int]$portProperty.Value -eq $Port) { $targetListeners += $listener }
    }
    return $targetListeners
}

function Get-E2DatabaseInventoryState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$DatabaseRows,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$CustomRoles
    )
    $sortedDatabases = @($DatabaseRows | Sort-Object)
    $defaultDatabases = @('postgres|postgres','template0|postgres','template1|postgres')
    $e2Databases = @('geolock_e2|postgres','postgres|postgres','template0|postgres','template1|postgres')
    $sortedRoles = @($CustomRoles | Sort-Object)
    $e2Roles = @('anon','authenticated','service_role')
    if ($sortedDatabases.Count -eq 3 -and
        @(Compare-Object $sortedDatabases $defaultDatabases).Count -eq 0 -and
        $sortedRoles.Count -eq 0) {
        return 'RecoverableMissingE2Database'
    }
    if (@(Compare-Object $sortedDatabases $e2Databases).Count -eq 0 -and
        ($sortedRoles.Count -eq 0 -or @(Compare-Object $sortedRoles $e2Roles).Count -eq 0)) {
        return 'E2DatabasePresent'
    }
    throw "Recovery refused: database/role inventory is not a supported clean E2 setup state (databases=[$($sortedDatabases -join ', ')]; custom roles=[$($sortedRoles -join ', ')])."
}

function ConvertTo-E2CanonicalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $trimmedPath = $Path.Trim()
    if (-not [IO.Path]::IsPathRooted($trimmedPath)) {
        throw "Server identity mismatch: data_directory is not an absolute path: [$Path]."
    }
    try {
        return [IO.Path]::GetFullPath($trimmedPath).Replace('/','\').TrimEnd('\')
    } catch {
        throw "Server identity mismatch: data_directory could not be canonicalized: [$Path]. $($_.Exception.Message)"
    }
}

function Assert-E2ServerIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ActualAddress,
        [Parameter(Mandatory)][string]$ActualPort,
        [Parameter(Mandatory)][string]$ActualDataDirectory,
        [Parameter(Mandatory)][string]$ActualSystemIdentifier,
        [Parameter(Mandatory)][string]$ExpectedAddress,
        [Parameter(Mandatory)][int]$ExpectedPort,
        [Parameter(Mandatory)][string]$ExpectedDataDirectory,
        [Parameter(Mandatory)][string]$ExpectedSystemIdentifier
    )
    $actualAddressValue = $ActualAddress.Trim()
    if ($ExpectedAddress -cne '127.0.0.1' -or $actualAddressValue -cnotin @('127.0.0.1','127.0.0.1/32')) {
        throw "Connected server identity mismatch: address expected [$ExpectedAddress], actual [$ActualAddress]."
    }
    $parsedPort = 0
    if (-not [int]::TryParse($ActualPort.Trim(),[ref]$parsedPort) -or $parsedPort -ne $ExpectedPort) {
        throw "Connected server identity mismatch: port expected [$ExpectedPort], actual [$ActualPort]."
    }
    $actualCanonicalPath = ConvertTo-E2CanonicalPath $ActualDataDirectory
    $expectedCanonicalPath = ConvertTo-E2CanonicalPath $ExpectedDataDirectory
    if (-not $actualCanonicalPath.Equals($expectedCanonicalPath,[StringComparison]::OrdinalIgnoreCase)) {
        throw "Connected server identity mismatch: data_directory expected [$expectedCanonicalPath], actual [$actualCanonicalPath] (raw [$ActualDataDirectory])."
    }
    $actualIdentifier = $ActualSystemIdentifier.Trim()
    if ($actualIdentifier -cnotmatch '^\d{10,30}$' -or $actualIdentifier -cne $ExpectedSystemIdentifier) {
        throw "Connected server identity mismatch: system_identifier expected [$ExpectedSystemIdentifier], actual [$ActualSystemIdentifier]."
    }
    return $true
}

function Assert-E2ProcessSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$PgCtlStatusCode,
        [Parameter(Mandatory)][string]$DataDir,
        [Parameter(Mandatory)][string]$PgBin,
        [Parameter(Mandatory)][string]$ProgramFilesRoot,
        [Parameter(Mandatory)][int]$Port,
        [object[]]$Processes = @(),
        [object[]]$Services = @(),
        [object[]]$Listeners = @(),
        [string]$RecordedPostmasterPid = '',
        [string]$E2PostmasterPid = '',
        [switch]$RequireStopped
    )

    if ($PgCtlStatusCode -notin @(0,3)) { throw "Recovery refused: pg_ctl status is inconclusive (exit $PgCtlStatusCode)." }
    if ($PgCtlStatusCode -eq 0 -and (-not $E2PostmasterPid -or $E2PostmasterPid -cne $RecordedPostmasterPid)) {
        throw 'Recovery refused: pg_ctl reports a running cluster but there is no matching E2 postmaster.pid identity.'
    }
    if ($PgCtlStatusCode -eq 0 -and $RequireStopped) {
        throw 'Recovery refused: this action requires the E2 cluster to be stopped; an active postmaster PID file will not be quarantined.'
    }
    if ($PgCtlStatusCode -eq 3 -and $E2PostmasterPid) {
        throw 'Recovery refused: a PID file was supplied as active although pg_ctl reports no running server.'
    }
    if ($RecordedPostmasterPid) {
        $recordedPidProcesses = @($Processes | Where-Object { [string]$_.ProcessId -eq $RecordedPostmasterPid })
        if ($recordedPidProcesses.Count -gt 0 -and $RecordedPostmasterPid -cne $E2PostmasterPid) {
            throw "Recovery refused: PID $RecordedPostmasterPid is still assigned to a process. Do not handle postmaster.pid."
        }
    }

    $normalizedDataDir = [IO.Path]::GetFullPath($DataDir).TrimEnd('\').Replace('/','\')
    $trustedServiceProcessIds = @{}
    $trustedE2ProcessIds = @{}
    $serviceName = 'postgresql-x64-17'
    $serviceDataDir = [IO.Path]::GetFullPath((Join-Path $ProgramFilesRoot 'PostgreSQL\17\data')).TrimEnd('\')
    $expectedServicePgCtl = [IO.Path]::GetFullPath((Join-Path $PgBin 'pg_ctl.exe'))
    $serviceMatches = @($Services | Where-Object { $_.Name -eq $serviceName })
    if ($serviceMatches.Count -gt 1) { throw 'Recovery refused: duplicate Windows service records make process ownership uncertain.' }
    if ($serviceMatches.Count -eq 1) {
        $service = $serviceMatches[0]
        $serviceCommand = [string]$service.PathName
        $serviceDataMatch = [regex]::Match($serviceCommand,'(?i)(?:^|\s)-D\s+(?:"([^"]+)"|''([^'']+)''|(\S+))')
        $recordedServiceDataDir = if ($serviceDataMatch.Success) {
            if ($serviceDataMatch.Groups[1].Success) { $serviceDataMatch.Groups[1].Value }
            elseif ($serviceDataMatch.Groups[2].Success) { $serviceDataMatch.Groups[2].Value }
            else { $serviceDataMatch.Groups[3].Value }
        } else { '' }
        $serviceExeMatch = [regex]::Match($serviceCommand,'(?i)^\s*(?:"([^"]+pg_ctl\.exe)"|(.+?pg_ctl\.exe))\s+runservice\b')
        $recordedServiceExe = if ($serviceExeMatch.Success) {
            if ($serviceExeMatch.Groups[1].Success) { $serviceExeMatch.Groups[1].Value }
            else { $serviceExeMatch.Groups[2].Value }
        } else { '' }
        $serviceExeMatches = $false
        if ($recordedServiceExe) {
            $serviceExeMatches = [IO.Path]::GetFullPath($recordedServiceExe).Equals(
                $expectedServicePgCtl,[StringComparison]::OrdinalIgnoreCase)
        }
        $serviceDataMatches = $false
        if ($recordedServiceDataDir) {
            $serviceDataMatches = [IO.Path]::GetFullPath($recordedServiceDataDir).TrimEnd('\').Equals(
                $serviceDataDir,[StringComparison]::OrdinalIgnoreCase)
        }
        $serviceConfigVerified = $service.Name -eq $serviceName -and $serviceExeMatches -and
            $serviceCommand -match '(?i)-N\s+"?postgresql-x64-17"?' -and $serviceDataMatches -and
            -not $serviceDataDir.Equals($normalizedDataDir,[StringComparison]::OrdinalIgnoreCase)
        if (-not $serviceConfigVerified) {
            if ($service.State -eq 'Running') {
                throw 'Recovery refused: the PostgreSQL Windows service is running but its executable/name/data directory cannot be positively verified as unrelated to E2.'
            }
        } elseif ($service.State -eq 'Running') {
            $serviceProcessId = [int]$service.ProcessId
            if ($serviceProcessId -le 0) { throw 'Recovery refused: the verified PostgreSQL service has no valid process ID.' }
            $serviceRootProcesses = @($Processes | Where-Object { [int]$_.ProcessId -eq $serviceProcessId })
            if ($serviceRootProcesses.Count -ne 1 -or $serviceRootProcesses[0].Name -ine 'pg_ctl.exe') {
                throw 'Recovery refused: service PID does not identify the expected pg_ctl.exe service process.'
            }
            $trustedServiceProcessIds[$serviceProcessId] = $true
            $treeChanged = $true
            while ($treeChanged) {
                $treeChanged = $false
                foreach ($process in $Processes) {
                    $processId = [int]$process.ProcessId
                    $parentProcessId = [int]$process.ParentProcessId
                    if ($trustedServiceProcessIds.ContainsKey($parentProcessId) -and
                        -not $trustedServiceProcessIds.ContainsKey($processId)) {
                        $trustedServiceProcessIds[$processId] = $true
                        $treeChanged = $true
                    }
                }
            }
            foreach ($process in @($Processes | Where-Object {
                $_.Name -ieq 'postgres.exe' -and $trustedServiceProcessIds.ContainsKey([int]$_.ProcessId)
            })) {
                if ($process.CommandLine -and $process.CommandLine.Replace('/','\').IndexOf(
                    $normalizedDataDir,[StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    throw 'Recovery refused: a PostgreSQL process in the service tree references the E2 data directory.'
                }
            }
        }
    }
    if ($E2PostmasterPid) {
        $e2RootProcesses = @($Processes | Where-Object { [string]$_.ProcessId -eq $E2PostmasterPid })
        if ($e2RootProcesses.Count -ne 1 -or $e2RootProcesses[0].Name -ine 'postgres.exe') {
            throw 'Recovery refused: the active E2 postmaster PID does not identify exactly one postgres.exe process.'
        }
        $e2CommandLine = [string]$e2RootProcesses[0].CommandLine
        if ($e2CommandLine) {
            $e2DataMatch = [regex]::Match($e2CommandLine,'(?i)(?:^|\s)-D\s+(?:"([^"]+)"|''([^'']+)''|(\S+))')
            if ($e2DataMatch.Success) {
                $recordedE2DataDir = if ($e2DataMatch.Groups[1].Success) { $e2DataMatch.Groups[1].Value }
                    elseif ($e2DataMatch.Groups[2].Success) { $e2DataMatch.Groups[2].Value }
                    else { $e2DataMatch.Groups[3].Value }
                if (-not [IO.Path]::GetFullPath($recordedE2DataDir).TrimEnd('\').Equals(
                    $normalizedDataDir,[StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Recovery refused: active E2 postmaster command line references a different data directory.'
                }
            }
        }
        $trustedE2ProcessIds[[int]$E2PostmasterPid] = $true
        $treeChanged = $true
        while ($treeChanged) {
            $treeChanged = $false
            foreach ($process in $Processes) {
                $processId = [int]$process.ProcessId
                $parentProcessId = [int]$process.ParentProcessId
                if ($trustedE2ProcessIds.ContainsKey($parentProcessId) -and -not $trustedE2ProcessIds.ContainsKey($processId)) {
                    $trustedE2ProcessIds[$processId] = $true
                    $treeChanged = $true
                }
            }
        }
        if ($Listeners.Count -eq 0) { throw 'Recovery refused: the active E2 cluster has no listener on its configured port.' }
        foreach ($listener in $Listeners) {
            if (-not $trustedE2ProcessIds.ContainsKey([int]$listener.OwningProcess)) {
                throw 'Recovery refused: the E2 port listener is not owned by the verified E2 PostgreSQL process tree.'
            }
            if ([string]$listener.LocalAddress -notin @('127.0.0.1','::1','::ffff:127.0.0.1')) {
                throw 'Recovery refused: the E2 PostgreSQL listener is not bound to loopback.'
            }
        }
    } elseif ($PgCtlStatusCode -eq 3 -and $Listeners.Count -gt 0) {
        $owners = ($Listeners | ForEach-Object { "PID $($_.OwningProcess) at $($_.LocalAddress):$($_.LocalPort)" }) -join ', '
        throw "Recovery refused: port $Port has an active listener while the E2 cluster is stopped ($owners)."
    }
    foreach ($process in @($Processes | Where-Object { $_.Name -ieq 'postgres.exe' })) {
        if (-not $trustedServiceProcessIds.ContainsKey([int]$process.ProcessId) -and
            -not $trustedE2ProcessIds.ContainsKey([int]$process.ProcessId)) {
            if (-not $process.CommandLine) {
                throw 'Recovery refused: an unverified postgres.exe process has no inspectable command line; ownership is uncertain.'
            }
            throw 'Recovery refused: a PostgreSQL process exists outside the positively verified unrelated service tree.'
        }
    }
    if ($Listeners.Count -gt 0 -and -not $E2PostmasterPid) {
        $owners = ($Listeners | ForEach-Object { "PID $($_.OwningProcess) at $($_.LocalAddress):$($_.LocalPort)" }) -join ', '
        throw "Recovery refused: port $Port has an active listener ($owners). No PID file will be changed."
    }
}
