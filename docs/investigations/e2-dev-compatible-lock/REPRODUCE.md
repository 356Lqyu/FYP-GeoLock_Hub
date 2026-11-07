# DEV-compatible candidate: local reproduction only

Use the existing frozen v3.3 package and recorded Python 3.12.14/psycopg 3.3.6/PG17.11 runtime. Custody setup uses the existing local synthetic routing fixture and OR-Tools; no hosted worker is activated. Paths/dependencies are detailed in ../e2-shared-lock-review/REPRODUCE_LOCAL_E2.md. No remote DSN argument is accepted.

`acl-fixture.sql` is **disposable test setup only**, never a DEV deployment script. The controllers apply it only in newly created loopback databases to reproduce the captured three DEV ACLs. The forward/rollback candidates themselves contain no permission-changing statements; only their three metadata expectations differ from the original SQL.

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
$py = '.venv-stage8/Scripts/python.exe'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$receipt = 'docs/investigations/e2-dev-compatible-lock/custody-tests.json'
if (Test-Path $receipt) {
  $archive = "docs/investigations/e2-dev-compatible-lock/custody-tests-preserved-$stamp.json"
  if (Test-Path $archive) { throw 'Use a new timestamp' }
  Copy-Item -LiteralPath $receipt -Destination $archive
}
& $py experiments/e2_atomic_claiming/dev_acl_custody_tests.py
if ($LASTEXITCODE -ne 0) { throw 'Custody failed; do not benchmark' }
& $py experiments/e2_atomic_claiming/run_dev_acl_full.py --focused-only --output "experiments/e2_atomic_claiming/results/dev-acl-focus-$stamp"
if ($LASTEXITCODE -ne 0) { throw 'Focused checks failed' }
& $py experiments/e2_atomic_claiming/run_dev_acl_full.py --output "experiments/e2_atomic_claiming/results/dev-acl-full-$stamp"
if ($LASTEXITCODE -ne 0) { throw 'Full benchmark incomplete' }
& $py experiments/e2_atomic_claiming/summarize_corrected.py --run "experiments/e2_atomic_claiming/results/dev-acl-full-$stamp"
```

Output directories must be new. Optimized Python is rejected. Every full run repeats focused checks and requires the custody pass before the 275 formal scenarios. Deliberate fault/drift checks remain separate from benchmark errors. Old candidate rejection, function metadata preservation, raw cases/requests/committed claims, completion/shutdown and source/input hashes are retained. No old benchmark or candidate is overwritten.

The rollback candidate requires the corrected source hashes and reviewed DEV ACLs. It preserves permissions but restores the original deadlock-prone source; it is not data recovery and must not erase claims, leases or evidence. Any future DEV use requires separate preflight, verified current backup/isolated recovery, a reviewed unused version/manual receipt and explicit deployment approval.
