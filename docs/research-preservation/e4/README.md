# Published E4 evidence snapshots

Each ZIP contains one completed E4 run at its original repository-relative paths. It includes the original root and method manifests, all recorded sources and frozen inputs, and the 22 published artifacts. The ZIPs sit outside the routing package and the E4 source inventory.

| Run ID | Source revision | Recorded sources | ZIP SHA-256 |
| --- | --- | ---: | --- |
| [7f5ddab6c0f94b20adffc878d3a97217](e4-7f5ddab6c0f94b20adffc878d3a97217.zip) | `865542df74a94ef415847378030d3663d213f743` | 86 | `208425bce88e0ec37765aa0a04f004128adbea93313776cb0027342d0a7cd37b` |
| [ac1b77db93634b7d8da371ee59105679](e4-ac1b77db93634b7d8da371ee59105679.zip) | `cd3268a501819643b00e27e2b9e28abc7e041b0b` | 84 | `dbf4a3b7af0a5819e3efe3ffc7ba7f75082a3391110516743c93e3e614e674f6` |

## Verify an extracted run

Use Python 3.12 or newer. Verification uses the standard library and needs no package installation, Git checkout, database, or network connection. Run these commands from the directory containing the ZIPs. Select either run ID and use a fresh extraction directory.

```powershell
$runId = '7f5ddab6c0f94b20adffc878d3a97217'
$archive = "e4-$runId.zip"
Get-FileHash -LiteralPath $archive -Algorithm SHA256
$snapshot = Join-Path $env:TEMP ("e4-" + [guid]::NewGuid())
Expand-Archive -LiteralPath $archive -DestinationPath $snapshot
python -I -B (Join-Path $snapshot '_e4_snapshot\verify.py')
```

Compare the ZIP hash with the table before extracting. The verifier checks the original manifest digest, run ID, completion status, and every recorded source, input, and artifact hash. It resolves those files inside the extracted snapshot and exits nonzero if verification fails. Expect eight inputs and 22 artifacts for either run.

The original paper-run verifier, manifest checksum, and older hosted source copy are preserved at their original paths. On the `ac1b77db93634b7d8da371ee59105679` extraction, the original verifier can also be run independently.

```powershell
python -I -B (Join-Path $snapshot 'experiments\e4\experiment_result\published_provenance\verify.py')
```

Use the supplied snapshot verifier for `7f5ddab6c0f94b20adffc878d3a97217`. The original paper-run verifier is specific to the earlier run.

## Inspect or reproduce a run

Open `experiments/e4/experiment_result/summary.md` within the extraction to inspect the results. To reproduce the procedure, use a separate disposable extraction because the runner replaces its active result files on success. The recorded environment uses Windows x64 CPython **3.13.9**. Each ZIP contains the matching `experiments/e4/requirements.txt` with all dependency pins, including OR-Tools **9.15.6755**, NumPy **2.1.3**, SciPy **1.18.1**, and Matplotlib **3.11.2**.

From the root of the disposable extraction, check the interpreter version, install the pinned dependencies, and run preflight before running the driver.

```powershell
py -3.13 --version
py -3.13 -m venv .venv-e4
$e4Python = '.\.venv-e4\Scripts\python.exe'
& $e4Python -m pip install -r experiments/e4/requirements.txt
& $e4Python -m pip check
& $e4Python -B experiments/e4/run_e4.py --preflight-only
```

After confirming Python 3.13.9 and a successful preflight, `& $e4Python -B experiments/e4/run_e4.py` runs the three methods and publishes a new result set inside the disposable extraction. The archived results remain the reference for the published run. A reproduction generates a new run ID and execution timings.

## Byte reconstruction

The archives preserve the bytes recorded by each run rather than relying on checkout line-ending conversion. In both snapshots, `run_e4.py` uses CRLF on line 254 and LF elsewhere, and `test_harness/test_e4_publication.py` uses CRLF on line 148 and LF elsewhere. The earlier run also contains its matching older `backend/routing/hosted/frozen_benchmark.py`. Avoid saving or normalizing extracted files before verification.
