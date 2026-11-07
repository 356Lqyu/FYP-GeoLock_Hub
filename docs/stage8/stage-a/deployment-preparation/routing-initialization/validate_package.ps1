$ErrorActionPreference = 'Stop'
$package = $PSScriptRoot
$hashes = Get-Content (Join-Path $package 'approval-file-hashes.json') -Raw | ConvertFrom-Json
foreach ($entry in $hashes.PSObject.Properties) {
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $package $entry.Name)).Hash.ToLowerInvariant()
    if ($actual -ne $entry.Value) { throw "Package hash mismatch: $($entry.Name)" }
}
$document = Get-Content (Join-Path $package 'APPROVAL_PACKAGE.md') -Raw
$blocks = [regex]::Matches($document, '(?s)```powershell\s*\r?\n(.*?)```')
foreach ($block in $blocks) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($block.Groups[1].Value,[ref]$tokens,[ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
}
foreach ($name in @('install_routing_policy','freeze_routing_graph')) {
    $sql = Get-Content (Join-Path $package ($name+'.proposed.sql')) -Raw
    if ([regex]::Matches($sql,'(?m)^SELECT public\.').Count -ne 1) { throw 'Unexpected RPC count' }
    if ($sql -notmatch ('SELECT public\.'+$name+'\(')) { throw 'Wrong RPC' }
    if ($sql -match '(?im)^\s*(CREATE|ALTER|DROP|INSERT|UPDATE|DELETE|TRUNCATE|GRANT|REVOKE)\b') { throw 'Unexpected direct DDL/DML' }
    if ($sql -notmatch 'SET LOCAL ROLE geolock_graph_worker;' -or $sql -notmatch 'ON_ERROR_STOP on' -or $sql -notmatch '(?m)^COMMIT;') { throw 'Missing transaction/role safeguards' }
}
Write-Output "Local validation PASS: package hashes, $($blocks.Count) PowerShell command blocks parsed, two bounded RPC wrappers statically inspected. No database connection or RPC execution."
