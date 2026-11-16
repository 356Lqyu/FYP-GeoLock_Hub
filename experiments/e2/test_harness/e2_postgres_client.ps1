function Assert-E2LocalRootInventory {
    param([string]$Root, [switch]$Recovery, [switch]$ConfiguredRecovery)

    if (-not (Test-Path -LiteralPath $Root)) { return }
    foreach ($item in (Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop)) {
        $linked = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType
        $regularFile = $item -is [IO.FileInfo] -and -not $linked -and
            -not ($item.Attributes -band [IO.FileAttributes]::Device)
        if ($item.Name -ieq 'hosted.json' -and $regularFile) { continue }
        if ($Recovery) {
            if ($item.Name -ieq 'cluster' -and $item -is [IO.DirectoryInfo] -and -not $linked) { continue }
            if ($item.Name -ieq 'postgresql.log' -and $regularFile) { continue }
            if ($ConfiguredRecovery -and $regularFile -and $item.Name -iin @('local.json','run.lock')) { continue }
        }
        throw "E2 local setup or recovery refused: unexpected or unsafe entry '$($item.Name)' under '$Root'. Nothing was removed."
    }
}

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
