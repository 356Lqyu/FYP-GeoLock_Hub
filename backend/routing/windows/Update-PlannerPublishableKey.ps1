# Local encrypted configuration only. No database/HTTP connections or activation.
# -Environment DEV (default) is unchanged. -Environment KLSEL updates ONLY the PublishableKey
# field of %LOCALAPPDATA%\GeoLockHubRoutingKLSEL\planner.clixml (NEW project); every other
# field and encrypted blob (graph/planner passwords, validator token) is preserved verbatim.
[CmdletBinding()]
param([switch]$CheckOnly,[ValidateSet('DEV','KLSEL')][string]$Environment='DEV')
$ErrorActionPreference='Stop'
$Environment=$Environment.ToUpperInvariant()  # ValidateSet is case-insensitive

function Read-PublishableKeyHidden([string]$Label='DEV') {
    # Read-Host -AsSecureString delegates paste/key handling to the PS host.
    # Use the Windows console's cooked Unicode line reader instead: one complete
    # line through Enter, echo disabled, with no character-by-character host loop.
    if (-not ('GeoLockHubHiddenConsoleLineV1' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Security;
public static class GeoLockHubHiddenConsoleLineV1 {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetConsoleMode(IntPtr handle, out uint mode);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetConsoleMode(IntPtr handle, uint mode);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool ReadConsoleW(IntPtr handle,
        [Out, MarshalAs(UnmanagedType.LPArray, ArraySubType=UnmanagedType.U2, SizeParamIndex=2)] char[] buffer,
        uint size, out uint read, IntPtr control);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern bool FlushConsoleInputBuffer(IntPtr handle);
    public static SecureString Read() {
        IntPtr input=CreateFileW("CONIN$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        uint original=0; bool changed=false, delivered=false;
        char[] buffer=new char[4096]; SecureString value=new SecureString();
        try {
            if(input==new IntPtr(-1) || !GetConsoleMode(input,out original))
                throw new InvalidOperationException("Use an interactive Windows PowerShell console for hidden input.");
            // ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT; disable ECHO and VT
            // input. Restore every original mode bit before returning.
            uint hidden=(original | 3U) & ~(4U | 0x200U);
            if(!SetConsoleMode(input,hidden)) throw new InvalidOperationException("Cannot establish hidden console input.");
            changed=true; uint read;
            if(!ReadConsoleW(input,buffer,(uint)buffer.Length,out read,IntPtr.Zero) || read==0)
                throw new InvalidOperationException("Hidden input interrupted. No configuration changed.");
            int length=(int)read;
            if(length==buffer.Length || (buffer[length-1]!='\r' && buffer[length-1]!='\n'))
                throw new InvalidOperationException("Complete hidden line required. No configuration changed.");
            while(length>0 && (buffer[length-1]=='\r' || buffer[length-1]=='\n')) length--;
            for(int i=0;i<length;i++) value.AppendChar(buffer[i]);
            value.MakeReadOnly(); delivered=true; return value;
        } finally {
            Array.Clear(buffer,0,buffer.Length);
            if(changed) {
                // Discard queued extra lines rather than exposing them at the
                // next shell prompt after a multiline/oversize paste.
                FlushConsoleInputBuffer(input);
                if(!SetConsoleMode(input,original)) {
                    value.Dispose(); CloseHandle(input);
                    throw new InvalidOperationException("Console mode restoration failed; close this console.");
                }
            }
            if(input!=new IntPtr(-1)) CloseHandle(input);
            if(!delivered) value.Dispose();
        }
    }
}
'@
    }
    Write-Host ('Paste ONLY the complete '+$Label+' sb_publishable_ key (hidden; press Enter): ') -NoNewline
    try { return [GeoLockHubHiddenConsoleLineV1]::Read() }
    finally { Write-Host '' }
}

function Assert-PublishableKey([Security.SecureString]$Value,[string]$Label='DEV') {
    $plain=$null
    try {
        if ($null -eq $Value) { throw ('Missing '+$Label+' publishable key.') }
        $plain=[Net.NetworkCredential]::new('', $Value).Password
        # The character-set rule also rejects control characters (e.g. a captured Ctrl+V, U+0016).
        if (!$plain.StartsWith('sb_publishable_') -or $plain.Length -le 15 -or $plain -match '\s' -or
            $plain -cnotmatch '^sb_publishable_[A-Za-z0-9_-]+$') {
            throw ('Expected the complete '+$Label+' sb_publishable_ key without whitespace. No configuration changed.')
        }
    } finally { $plain=$null }
}

function Get-KeyNode([xml]$Document) {
    $nodes=@($Document.SelectNodes("//*[local-name()='SS' and @N='PublishableKey']"))
    if ($nodes.Count -ne 1) { throw 'Expected exactly one protected PublishableKey field. STOP.' }
    return $nodes[0]
}

function Set-ProtectedPlannerKey([string]$PlannerFile,[Security.SecureString]$Value,[string]$Label='DEV') {
    Assert-PublishableKey $Value $Label
    $original=New-Object Xml.XmlDocument
    $original.PreserveWhitespace=$true
    $original.Load($PlannerFile)
    $updated=$original.CloneNode($true)
    # Replace only this serialized DPAPI field, preserving all OTHER encrypted
    # credential blobs and properties verbatim. No profile recreation/re-encryption.
    (Get-KeyNode $updated).InnerText=(ConvertFrom-SecureString -SecureString $Value)
    $before=$original.CloneNode($true);$after=$updated.CloneNode($true)
    (Get-KeyNode $before).InnerText='KEY_FIELD_ONLY'
    (Get-KeyNode $after).InnerText='KEY_FIELD_ONLY'
    if ($before.OuterXml -cne $after.OuterXml) { throw 'Unexpected configuration change: STOP.' }
    $suffix=[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,6)
    $backup=$PlannerFile+'.before-publishable-key-'+$suffix
    $staging=$PlannerFile+'.'+$suffix+'.staging'
    if ((Test-Path -LiteralPath $backup) -or (Test-Path -LiteralPath $staging)) { throw 'Unique backup/staging path unavailable.' }
    $updated.Save($staging) # Only encrypted XML is written, inside protected directory.
    $verified=Import-Clixml -LiteralPath $staging
    Assert-PublishableKey $verified.PublishableKey $Label
    $current=New-Object Xml.XmlDocument
    $current.PreserveWhitespace=$true;$current.Load($PlannerFile)
    if ($current.OuterXml -cne $original.OuterXml) { throw 'Planner profile changed during update. Preserved; STOP.' }
    # Atomic replacement keeps the previous encrypted profile as a separate backup.
    [IO.File]::Replace($staging,$PlannerFile,$backup)
    return $backup
}

function Test-LocalReadiness([string]$Directory,[hashtable]$Selected) {
    if ($null -eq $Selected) { $Selected=$environments['DEV'] }
    $p=Import-Clixml -LiteralPath (Join-Path $Directory 'planner.clixml')
    $v=Import-Clixml -LiteralPath (Join-Path $Directory 'validator.clixml')
    $keyValid=$true
    try { Assert-PublishableKey $p.PublishableKey $Selected.Label } catch { $keyValid=$false }
    $pt=$null;$vt=$null
    try {
        $pt=[Net.NetworkCredential]::new('', $p.ValidatorToken).Password
        $vt=[Net.NetworkCredential]::new('', $v.ValidatorToken).Password
        $ports=@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | ForEach-Object {$_.Port})
        $checks=[ordered]@{}
        $checks[$Selected.ProjectCheck]=($p.Project -eq $Selected.Project -and $v.Project -eq $p.Project)
        $checks['ApprovedPoolerMatches']=($p.Pooled -eq $true -and $v.Pooled -eq $true -and $p.DbHost -eq $Selected.PoolerHost -and $v.DbHost -eq $p.DbHost)
        $rest=[ordered]@{
            CaFilesExist=((Test-Path -LiteralPath $p.Ca -PathType Leaf) -and (Test-Path -LiteralPath $v.Ca -PathType Leaf))
            PublishableKeyFormatValid=$keyValid
            SharedValidatorTokenMatches=($pt -ceq $vt -and $pt.Length -ge 32)
            PlannerPortAvailable=($ports -notcontains 8787)
            ValidatorPortAvailable=($ports -notcontains 8788)
            PreparedGraphCachePresent=((Test-Path -LiteralPath (Join-Path $Directory ('state\graphs\'+$Selected.GraphId+'.jsonl'))) -and (Test-Path -LiteralPath (Join-Path $Directory ('state\graphs\'+$Selected.GraphId+'.sha256'))))
        }
        foreach ($name in $rest.Keys) { $checks[$name]=$rest[$name] }
        return $checks
    } finally {$pt=$null;$vt=$null;$p=$null;$v=$null}
}

$environments=@{
    DEV  =@{Project='rcgyuwiidqvrgbxswhqj';Directory='GeoLockHubRoutingDev';Label='DEV';ProjectCheck='DevProjectMatches'
            GraphId='eab1f7ee-a8e0-4bed-a0e1-2c4bff024936';PoolerHost='aws-0-ap-northeast-2.pooler.supabase.com'}
    KLSEL=@{Project='ppwmdsyoesvhgmqiaoxa';Directory='GeoLockHubRoutingKLSEL';Label='NEW (KL/Selangor)';ProjectCheck='ProjectMatches'
            GraphId='19c44bd2-8871-4eca-bf6b-4262f1bf766d';PoolerHost=$null}
}
$selected=$environments[$Environment]
$directory=Join-Path $env:LOCALAPPDATA $selected.Directory
$plannerFile=Join-Path $directory 'planner.clixml'
if ($Environment -ne 'DEV') {
    # KLSEL's pooler host is the one in its own password-free pg_service.conf (written by Save-WorkerConfig).
    $serviceFile=Join-Path $directory 'pg_service.conf'
    if (!(Test-Path -LiteralPath $serviceFile -PathType Leaf)) { throw ('pg_service.conf missing in '+$directory+'. STOP.') }
    $hostLines=@(Get-Content -LiteralPath $serviceFile | Where-Object { $_ -match '^host=' })
    if ($hostLines.Count -ne 1 -or -not $hostLines[0].Substring(5).EndsWith('.pooler.supabase.com')) { throw 'Unexpected pg_service.conf host. STOP.' }
    $selected.PoolerHost=$hostLines[0].Substring(5)
}
$backup=$null;$key=$null
try {
    $profile=Import-Clixml -LiteralPath $plannerFile
    if ($profile.Project -ne $selected.Project) { throw ($selected.Label+' planner profile required.') }
    $profile=$null
    if (!$CheckOnly) {
        $key=Read-PublishableKeyHidden $selected.Label
        $backup=Set-ProtectedPlannerKey $plannerFile $key $selected.Label
    }
    $checks=Test-LocalReadiness $directory $selected
    $informational=[ordered]@{}
    if ($Environment -ne 'DEV') {
        # The KLSEL cache is created later by Start-Worker -WarmGraph; report it, do not require it.
        $informational['PreparedGraphCachePresent']=$checks['PreparedGraphCachePresent']
        $checks.Remove('PreparedGraphCachePresent')
    }
    # Run actual startup CONFIG paths only; neither switch activates a service.
    foreach ($mode in @('validator','planner')) {
        if ($Environment -eq 'DEV') {
            & (Join-Path $PSScriptRoot 'Start-Worker.ps1') -Mode $mode -GraphId 'eab1f7ee-a8e0-4bed-a0e1-2c4bff024936' -CheckConfig
        } else {
            & (Join-Path $PSScriptRoot 'Start-Worker.ps1') -Environment $Environment -Mode $mode -CheckConfig
        }
    }
    $passed=$true
    foreach ($flag in $checks.Values) { if ($flag -ne $true) {$passed=$false} }
    $report=[ordered]@{Status=$(if ($passed) {'PASS / LOCAL ACTIVATION CONFIGURATION'} else {'FAIL / LOCAL ACTIVATION CONFIGURATION'});
        Checks=$checks;StartupModes='DISABLED';UpdatedField=$(if ($CheckOnly) {$null} else {'planner.PublishableKey'});
        EncryptedBackup=$backup;DatabaseConnections=0;BusinessWrites=$false;ServiceActivation=$false;
        GraphIdForStartup=$selected.GraphId;
        Limitation='Offline format/configuration check; key project ownership and live Auth require pilot verification.'}
    if ($Environment -ne 'DEV') { $report['Environment']=$Environment; $report['Informational']=$informational }
    $evidence=Join-Path $directory ('publishable-key-readiness-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,6)+'.json')
    $report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $evidence -Encoding UTF8
    $report | ConvertTo-Json -Depth 4
    Write-Host ('Sanitized readiness report: '+$evidence)
    if (!$passed) { throw 'Local configuration readiness FAIL. No service activated. Review reported flags.' }
} finally {
    if ($null -ne $key) { $key.Dispose() }
    $key=$null
}
