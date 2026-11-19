# Local encrypted configuration only. No database/HTTP connections or activation.
[CmdletBinding()]
param([switch]$CheckOnly)
$ErrorActionPreference='Stop'

function Read-PublishableKeyHidden {
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
    Write-Host 'Paste ONLY the complete DEV sb_publishable_ key (hidden; press Enter): ' -NoNewline
    try { return [GeoLockHubHiddenConsoleLineV1]::Read() }
    finally { Write-Host '' }
}

function Assert-PublishableKey([Security.SecureString]$Value) {
    $plain=$null
    try {
        if ($null -eq $Value) { throw 'Missing DEV publishable key.' }
        $plain=[Net.NetworkCredential]::new('', $Value).Password
        if (!$plain.StartsWith('sb_publishable_') -or $plain.Length -le 15 -or $plain -match '\s') {
            throw 'Expected the complete DEV sb_publishable_ key without whitespace. No configuration changed.'
        }
    } finally { $plain=$null }
}

function Get-KeyNode([xml]$Document) {
    $nodes=@($Document.SelectNodes("//*[local-name()='SS' and @N='PublishableKey']"))
    if ($nodes.Count -ne 1) { throw 'Expected exactly one protected PublishableKey field. STOP.' }
    return $nodes[0]
}

function Set-ProtectedPlannerKey([string]$PlannerFile,[Security.SecureString]$Value) {
    Assert-PublishableKey $Value
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
    Assert-PublishableKey $verified.PublishableKey
    $current=New-Object Xml.XmlDocument
    $current.PreserveWhitespace=$true;$current.Load($PlannerFile)
    if ($current.OuterXml -cne $original.OuterXml) { throw 'Planner profile changed during update. Preserved; STOP.' }
    # Atomic replacement keeps the previous encrypted profile as a separate backup.
    [IO.File]::Replace($staging,$PlannerFile,$backup)
    return $backup
}

function Test-LocalReadiness([string]$Directory) {
    $p=Import-Clixml -LiteralPath (Join-Path $Directory 'planner.clixml')
    $v=Import-Clixml -LiteralPath (Join-Path $Directory 'validator.clixml')
    $keyValid=$true
    try { Assert-PublishableKey $p.PublishableKey } catch { $keyValid=$false }
    $pt=$null;$vt=$null
    try {
        $pt=[Net.NetworkCredential]::new('', $p.ValidatorToken).Password
        $vt=[Net.NetworkCredential]::new('', $v.ValidatorToken).Password
        $ports=@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | ForEach-Object {$_.Port})
        return [ordered]@{
            DevProjectMatches=($p.Project -eq 'rcgyuwiidqvrgbxswhqj' -and $v.Project -eq $p.Project)
            ApprovedPoolerMatches=($p.Pooled -eq $true -and $v.Pooled -eq $true -and $p.DbHost -eq 'aws-0-ap-northeast-2.pooler.supabase.com' -and $v.DbHost -eq $p.DbHost)
            CaFilesExist=((Test-Path -LiteralPath $p.Ca -PathType Leaf) -and (Test-Path -LiteralPath $v.Ca -PathType Leaf))
            PublishableKeyFormatValid=$keyValid
            SharedValidatorTokenMatches=($pt -ceq $vt -and $pt.Length -ge 32)
            PlannerPortAvailable=($ports -notcontains 8787)
            ValidatorPortAvailable=($ports -notcontains 8788)
            PreparedGraphCachePresent=((Test-Path -LiteralPath (Join-Path $Directory 'state\graphs\eab1f7ee-a8e0-4bed-a0e1-2c4bff024936.jsonl')) -and (Test-Path -LiteralPath (Join-Path $Directory 'state\graphs\eab1f7ee-a8e0-4bed-a0e1-2c4bff024936.sha256')))
        }
    } finally {$pt=$null;$vt=$null;$p=$null;$v=$null}
}

$directory=Join-Path $env:LOCALAPPDATA 'GeoLockHubRoutingDev'
$plannerFile=Join-Path $directory 'planner.clixml'
$backup=$null;$key=$null
try {
    $profile=Import-Clixml -LiteralPath $plannerFile
    if ($profile.Project -ne 'rcgyuwiidqvrgbxswhqj') { throw 'DEV planner profile required.' }
    $profile=$null
    if (!$CheckOnly) {
        $key=Read-PublishableKeyHidden
        $backup=Set-ProtectedPlannerKey $plannerFile $key
    }
    $checks=Test-LocalReadiness $directory
    # Run actual startup CONFIG paths only; neither switch activates a service.
    foreach ($mode in @('validator','planner')) {
        & (Join-Path $PSScriptRoot 'Start-Worker.ps1') -Mode $mode -GraphId 'eab1f7ee-a8e0-4bed-a0e1-2c4bff024936' -CheckConfig
    }
    $passed=$true
    foreach ($flag in $checks.Values) { if ($flag -ne $true) {$passed=$false} }
    $report=[ordered]@{Status=$(if ($passed) {'PASS / LOCAL ACTIVATION CONFIGURATION'} else {'FAIL / LOCAL ACTIVATION CONFIGURATION'});
        Checks=$checks;StartupModes='DISABLED';UpdatedField=$(if ($CheckOnly) {$null} else {'planner.PublishableKey'});
        EncryptedBackup=$backup;DatabaseConnections=0;BusinessWrites=$false;ServiceActivation=$false;
        GraphIdForStartup='eab1f7ee-a8e0-4bed-a0e1-2c4bff024936';
        Limitation='Offline format/configuration check; key project ownership and live Auth require pilot verification.'}
    $evidence=Join-Path $directory ('publishable-key-readiness-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,6)+'.json')
    $report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $evidence -Encoding UTF8
    $report | ConvertTo-Json -Depth 4
    Write-Host ('Sanitized readiness report: '+$evidence)
    if (!$passed) { throw 'Local configuration readiness FAIL. No service activated. Review reported flags.' }
} finally {
    if ($null -ne $key) { $key.Dispose() }
    $key=$null
}
