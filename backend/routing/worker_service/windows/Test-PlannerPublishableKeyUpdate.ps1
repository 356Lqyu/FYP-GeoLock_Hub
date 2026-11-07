# Offline regression with synthetic values only. No real profiles or connections.
param([switch]$ConsolePasteTest,[string]$HelperDirectory=$PSScriptRoot)
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$source=Join-Path $HelperDirectory 'Update-PlannerPublishableKey.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Update script syntax failure.'}
foreach($name in @('Read-PublishableKeyHidden','Assert-PublishableKey','Get-KeyNode','Set-ProtectedPlannerKey')) {
    $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    Invoke-Expression $fn.Extent.Text
}
if ($ConsolePasteTest) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GeoLockConsoleModeTest {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr CreateFileW(string n,uint a,uint s,IntPtr p,uint c,uint f,IntPtr t);
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h,out uint m);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    public static uint Mode() {IntPtr h=CreateFileW("CONIN$",0xC0000000,3,IntPtr.Zero,3,0,IntPtr.Zero);uint m;
        try {if(!GetConsoleMode(h,out m))throw new InvalidOperationException("Private test console required");return m;}finally{CloseHandle(h);}}
}
'@
    $beforeMode=[GeoLockConsoleModeTest]::Mode()
    $key=$null;$plain=$null
    try {
        $key=Read-PublishableKeyHidden
        Assert-PublishableKey $key
        $plain=[Net.NetworkCredential]::new('',$key).Password
        $expected='sb_publishable_'+('X'*1024)+'_DUMMY_ONLY'
        if($plain -cne $expected) { throw 'Synthetic full-paste comparison failed.' }
        if([GeoLockConsoleModeTest]::Mode() -ne $beforeMode) {throw 'Original console input mode not restored.'}
        Write-Output 'CONSOLE_MODE_RESTORED'
        Write-Output 'SYNTHETIC_PASTE_PASS'
    } finally { $plain=$null;if($null -ne $key){$key.Dispose()} }
    return
}
$root=(Resolve-Path (Join-Path $HelperDirectory '../../../..')).Path
$directory=Join-Path $root ('results\worker-config-update-tests\'+[Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $directory)
$file=Join-Path $directory 'planner.synthetic.clixml'
$validator=Join-Path $directory 'validator.synthetic.clixml'
[pscustomobject]@{Project='SYNTHETIC';GraphId='UNCHANGED';
    GraphPassword=(ConvertTo-SecureString 'SYNTHETIC fake graph password' -AsPlainText -Force);
    PlannerPassword=(ConvertTo-SecureString 'SYNTHETIC fake planner password' -AsPlainText -Force);
    ValidatorToken=(ConvertTo-SecureString 'SYNTHETIC fake shared token' -AsPlainText -Force);
    PublishableKey=(ConvertTo-SecureString 'SYNTHETIC old key' -AsPlainText -Force)} | Export-Clixml -LiteralPath $file
'SYNTHETIC validator untouched' | Set-Content -LiteralPath $validator
$old=Get-Content -LiteralPath $file -Raw
$validatorBefore=Get-Content -LiteralPath $validator -Raw
foreach($bad in @('sb_secret_SYNTHETIC','sb_publishable_','sb_publishable_SYNTHETIC with spaces')) {
    $rejected=$false
    try { $null=Set-ProtectedPlannerKey $file (ConvertTo-SecureString $bad -AsPlainText -Force) } catch {$rejected=$true}
    if(!$rejected -or (Get-Content -LiteralPath $file -Raw) -cne $old) {throw 'Invalid-input preservation regression.'}
}
$key=ConvertTo-SecureString 'sb_publishable_SYNTHETIC_ONLY_NOT_A_REAL_KEY' -AsPlainText -Force
$backup=Set-ProtectedPlannerKey $file $key
if((Get-Content -LiteralPath $backup -Raw) -cne $old) {throw 'Original encrypted backup changed.'}
$after=New-Object Xml.XmlDocument;$after.PreserveWhitespace=$true;$after.Load($file)
$before=New-Object Xml.XmlDocument;$before.PreserveWhitespace=$true;$before.Load($backup)
(Get-KeyNode $before).InnerText='MASKED_KEY'
(Get-KeyNode $after).InnerText='MASKED_KEY'
if($before.OuterXml -cne $after.OuterXml) {throw 'Other encrypted credentials or fields changed.'}
$decoded=Import-Clixml -LiteralPath $file
Assert-PublishableKey $decoded.PublishableKey
if((Get-Content -LiteralPath $file -Raw).Contains('sb_publishable_SYNTHETIC_ONLY')) {throw 'Plaintext key persisted.'}
if((Get-Content -LiteralPath $validator -Raw) -cne $validatorBefore) {throw 'Validator profile changed.'}
$backupAgain=Set-ProtectedPlannerKey $file $key
if($backupAgain -eq $backup -or !(Test-Path -LiteralPath $backup)) {throw 'Backup overwrite regression.'}
[pscustomobject]@{Status='PASS';Scope='OFFLINE SYNTHETIC ONLY';
    Checks=@('invalid values rejected without modification','original encrypted backup preserved',
    'all other fields and encrypted credential blobs unchanged','only key updated and decryptable',
    'no plaintext key persisted','validator untouched','unique backups retained');EvidenceDirectory=$directory} | ConvertTo-Json -Depth 3
