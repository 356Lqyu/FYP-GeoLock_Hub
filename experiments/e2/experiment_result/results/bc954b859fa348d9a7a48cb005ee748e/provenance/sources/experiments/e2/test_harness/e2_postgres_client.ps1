function Invoke-E2Native {
    param([string]$Executable, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $output = @(& $Executable @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $detail = $output -join [Environment]::NewLine
        throw "E2 command failed ($([IO.Path]::GetFileName($Executable)), exit $exitCode). $detail"
    }
    return $output
}

function Invoke-E2PostgresClient {
    param([string]$Executable, [string[]]$Arguments, [switch]$ReadOnly)
    $settings = @{
        PGHOSTADDR = '127.0.0.1'
        PGCONNECT_TIMEOUT = '5'
        PGOPTIONS = '-c statement_timeout=120000 -c lock_timeout=5000'
    }
    if ($ReadOnly) {
        $settings.PGOPTIONS = '-c statement_timeout=10000 -c lock_timeout=5000 -c default_transaction_read_only=on'
    }
    $previous = @{}
    try {
        foreach ($name in $settings.Keys) {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $settings[$name])
        }
        Invoke-E2Native $Executable (@('-w') + $Arguments)
    } finally {
        foreach ($name in $previous.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previous[$name])
        }
    }
}
