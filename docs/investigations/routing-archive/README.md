# Historical Render routing archive

The [Windows routing guide](../../LOCAL_ROUTING_WINDOWS.md) is the operational setup guide. This archive holds the inactive [Render and Docker implementation](backend/routing/hosted/) and the [historical worker test receipt](backend/routing/worker_service/test-results.json). Files retain their original relative paths under this archive. The archived hosted README and blueprint retain their original links and paths for use in a restored repository layout.

## Restore a historical verification checkout

Use a separate disposable directory for historical commands. The Git command below selects LF output explicitly because the Windows Git configuration can otherwise convert archived text to CRLF. Run it from the repository root to restore the Render implementation baseline.

```powershell
$revision = '74729b00'
$restore = Join-Path $env:TEMP ("routing-history-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $restore | Out-Null
$export = Join-Path $restore 'source.zip'
git -c core.autocrlf=false -c core.eol=lf archive --format=zip --output=$export $revision
if ($LASTEXITCODE -ne 0) { throw 'Historical Git export failed.' }
Expand-Archive -LiteralPath $export -DestinationPath (Join-Path $restore 'checkout')
```

For the later hosted test layout, use revision `865542df74a94ef415847378030d3663d213f743`, which predates the archive and contains the original hosted journal test. Use the applicable historical checksum inventory with the chosen revision. The Render implementation inventory's 18 hosted files match Git revision `74729b00`. In particular, the older `frozen_benchmark.py` differs from the copy in this archive. Use the earlier Git blob when checking that inventory.

Inside the restored checkout, compare each required path against the relevant saved SHA-256 inventory before using the historical tools. Use the [Render implementation inventory](../routing-render-implementation/IMPLEMENTATION_SHA256.json) for the implementation baseline, or the [Docker validation inventory](../routing-render-docker-validation/SHA256.json) for the later evidence, including the hosted journal test. Use the original repository root as the Docker context for historical builds because the definitions reference repository-relative source paths. The hosted packaging and disabled-bootstrap tests, compact graph tests, and synthetic recovery rehearsals belong in that restored layout.

The historical evidence sealer expects additional original fixtures and receipts, including a local graph export. A source-only Git archive does not supply that export. Use the original sealed inputs if reproducing the full historical verification, and keep the existing receipts intact.

For published E4 verification, use the [exact-byte E4 snapshots](../../research-preservation/e4/README.md). Those bundles restore each run's own source paths and mixed line endings.
