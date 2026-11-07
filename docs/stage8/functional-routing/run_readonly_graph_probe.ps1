# Native hidden password prompt; no credentials in arguments/files/logs.
# Default is an offline configuration check. -Run invokes ONLY the read-only probe.
[CmdletBinding()]
param([switch]$Run, [switch]$ConnectionDiagnostic, [switch]$PasswordTransportCheck, [switch]$NativeServiceDiagnostic, [switch]$NativeServiceProbe)
$ErrorActionPreference = 'Stop'
if ($Run -and $ConnectionDiagnostic) { throw 'Choose connection diagnostic OR full probe, never both.' }
if ($PasswordTransportCheck -and ($Run -or $ConnectionDiagnostic)) { throw 'Offline password check cannot be combined with a live operation.' }
if ($NativeServiceDiagnostic -and ($Run -or $ConnectionDiagnostic -or $PasswordTransportCheck)) { throw 'Choose only the bounded native-service diagnostic.' }
if ($NativeServiceProbe -and ($Run -or $ConnectionDiagnostic -or $PasswordTransportCheck -or $NativeServiceDiagnostic)) { throw 'Native full probe must be invoked separately.' }

function New-GraphProbeDsn([string]$Password) {
    # libpq keyword/value quoting, NOT URI or Windows command-line quoting.
    $escaped = $Password.Replace('\','\\').Replace("'","\'")
    return "host=aws-0-ap-northeast-2.pooler.supabase.com port=5432 dbname=postgres user=geolock_graph_login.rcgyuwiidqvrgbxswhqj sslmode=verify-full sslrootcert='C:/Users/User/Downloads/prod-ca-2021.crt' password='$escaped'"
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$profile = Join-Path $repo 'docs\stage8\stage-a\deployment-preparation\routing-initialization\pg_service.proposed.conf'
if ((Get-FileHash -LiteralPath $profile -Algorithm SHA256).Hash.ToLowerInvariant() -ne '01882460fe521e0ea1a50082a3d576c9b2a20208dd4d3ef943b0741cc5adb745') { throw 'Approved graph reference profile changed: STOP' }
if (!(Test-Path -LiteralPath 'C:\Users\User\Downloads\prod-ca-2021.crt' -PathType Leaf)) { throw 'Approved CA certificate missing: STOP' }
$python = Join-Path $repo '.venv-stage8\Scripts\python.exe'
if (!(Test-Path -LiteralPath $python -PathType Leaf)) { throw 'Stage8 Python missing: STOP' }
$info = New-Object System.Diagnostics.ProcessStartInfo
$info.FileName = $python
$info.WorkingDirectory = $repo
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
if ($PasswordTransportCheck) { $info.CreateNoWindow = $false } # inherit interactive console; never opens a new window
if ($NativeServiceDiagnostic) { $info.CreateNoWindow = $false }
if ($NativeServiceProbe) { $info.CreateNoWindow = $false }
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
# Discard ambient database/worker settings in the child only. Parent environment
# remains untouched; no installer service/options or write activation is inherited.
foreach ($key in @($info.EnvironmentVariables.Keys)) {
    if ($key -match '^(PG|GEOLOCK_)') { $info.EnvironmentVariables.Remove($key) }
}
$secure = $null; $ptr = [IntPtr]::Zero; $plain = $null; $dsn = $null; $process = $null
if ($PasswordTransportCheck) { Write-Host 'OFFLINE equality check only: enter the same value twice. No network/authentication or saved report.' }
try {
    if ($NativeServiceProbe) {
        $info.Arguments = '-B -m backend.routing.worker_service.native_service_probe --run --matrix --timeout-seconds 600 --max-memory-mb 4096'
    } elseif ($NativeServiceDiagnostic) {
        # No PowerShell password conversion or DSN environment variable at all.
        $info.Arguments = '-B -m backend.routing.worker_service.native_service_diagnostic'
    } elseif ($Run -or $ConnectionDiagnostic -or $PasswordTransportCheck) {
        $secure = Read-Host 'Dedicated geolock_graph_login database password (hidden)' -AsSecureString
        if ($secure.Length -eq 0) { throw 'Empty password: no connection attempted' }
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        $dsn = New-GraphProbeDsn -Password $plain
        $info.EnvironmentVariables['GEOLOCK_GRAPH_DSN'] = $dsn
        if ($PasswordTransportCheck) {
            $info.EnvironmentVariables['GEOLOCK_PASSWORD_REFERENCE'] = $plain
            $info.Arguments = '-B -m backend.routing.worker_service.connection_diagnostic_native17 --password-transport-check'
        } elseif ($ConnectionDiagnostic) {
            $info.Arguments = '-B -m backend.routing.worker_service.connection_diagnostic_native17'
        } else {
            $info.Arguments = '-B -m backend.routing.worker_service.readonly_pilot_probe --run --matrix --timeout-seconds 300'
        }
    } else {
        # Synthetic placeholder is used only for local conninfo parsing; never connects.
        $info.EnvironmentVariables['GEOLOCK_GRAPH_DSN'] = New-GraphProbeDsn -Password 'OFFLINE_PLACEHOLDER_NEVER_AUTHENTICATE'
        $info.Arguments = '-B -m backend.routing.worker_service.readonly_pilot_probe'
    }
    if (!$PasswordTransportCheck) {
        Write-Host 'Target: DEV rcgyuwiidqvrgbxswhqj; session pooler 5432; geolock_graph_login; TLS verify-full.'
        Write-Host 'Write activation absent; probe transactions READ ONLY; no service/API startup.'
    }
    $process = [Diagnostics.Process]::Start($info)
    $outputTask = $process.StandardOutput.ReadToEndAsync()
    $errorTask = $process.StandardError.ReadToEndAsync()
    # Child owns its short-lived environment; release launcher copies immediately.
    $info.EnvironmentVariables.Remove('GEOLOCK_GRAPH_DSN')
    $info.EnvironmentVariables.Remove('GEOLOCK_PASSWORD_REFERENCE')
    $dsn = $null; $plain = $null
    if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr); $ptr = [IntPtr]::Zero }
    if ($secure) { $secure.Dispose(); $secure = $null }
    $process.WaitForExit()
    if ($outputTask.Result) { Write-Host $outputTask.Result.Trim() }
    if ($process.ExitCode -ne 0) {
        if ($PasswordTransportCheck) { throw 'Offline comparison differs/incomplete: STOP. No authentication or evidence file was created.' }
        throw 'Probe failed/incomplete: preserve its result.json; STOP, do not retry automatically.'
    }
} finally {
    $info.EnvironmentVariables.Remove('GEOLOCK_GRAPH_DSN')
    $info.EnvironmentVariables.Remove('GEOLOCK_PASSWORD_REFERENCE')
    $dsn = $null; $plain = $null
    if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    if ($secure) { $secure.Dispose() }
    if ($process) { $process.Dispose() }
}
