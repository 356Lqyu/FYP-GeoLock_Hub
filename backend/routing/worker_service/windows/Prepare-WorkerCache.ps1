# Local file preparation only. No Python, database connection, HTTP or activation.
[CmdletBinding()]
param([string]$StateDirectory=(Join-Path $env:LOCALAPPDATA 'GeoLockHubRoutingDev\state'))
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
$graph='eab1f7ee-a8e0-4bed-a0e1-2c4bff024936'
$digest='5e06dab0fb4d2b97ac53fd9a1178dc46aa6b98811aefbaef96528c604a04012a'
$expectedSeal='a525f79eada8fc65ce0568fd0cdba66237f1e5e6e3009bb4fa0e7482fc70accb'
$evidence=Join-Path $root 'results\worker-readiness\20261027T083653Z-5f56bb'
$report=Get-Content -LiteralPath (Join-Path $evidence 'result.json') -Raw | ConvertFrom-Json
if ($report.status -ne 'READ_ONLY PROBE PASS' -or $report.graph_id -ne $graph -or
    $report.content_digest -ne $digest -or $report.nodes -ne 926414 -or $report.edges -ne 2145828 -or
    $report.database_writes -ne $false -or $report.activation -ne $false) { throw 'Approved probe evidence mismatch: STOP.' }
$source=Join-Path $evidence ('graphs\'+$graph+'.jsonl')
$sealFile=Join-Path $evidence ('graphs\'+$graph+'.sha256')
if ((Get-Content -LiteralPath $sealFile -Raw).Trim() -ne $expectedSeal -or
    (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedSeal) {
    throw 'Source cache seal mismatch: STOP. No copy performed.'
}
$destination=Join-Path ([IO.Path]::GetFullPath($StateDirectory)) 'graphs'
[void](New-Item -ItemType Directory -Path $destination -Force)
$cache=Join-Path $destination ($graph+'.jsonl')
$seal=Join-Path $destination ($graph+'.sha256')
if ((Test-Path -LiteralPath $cache) -or (Test-Path -LiteralPath $seal)) {
    if (!(Test-Path -LiteralPath $cache) -or !(Test-Path -LiteralPath $seal) -or
        (Get-Content -LiteralPath $seal -Raw).Trim() -ne $expectedSeal -or
        (Get-FileHash -LiteralPath $cache -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedSeal) {
        throw 'Existing runtime cache differs or is incomplete. Preserved; no overwrite.'
    }
} else {
    # Unique staging file, no overwrites; seal is published last. Interrupted
    # copies cannot appear to GraphCache as a sealed, complete cache.
    $staged=Join-Path $destination ($graph+'.'+[Guid]::NewGuid().ToString('N')+'.staging')
    [IO.File]::Copy($source,$staged,$false)
    if ((Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedSeal) {
        throw 'Staged cache checksum failed; evidence retained, no seal published.'
    }
    [IO.File]::Move($staged,$cache)
    [IO.File]::Copy($sealFile,$seal,$false)
}
[pscustomobject]@{Status='SEALED CACHE PREPARED / NO CONNECTION OR ACTIVATION';Directory=$destination;
    GraphId=$graph;CacheSha256=$expectedSeal;Bytes=(Get-Item -LiteralPath $cache).Length} | ConvertTo-Json
