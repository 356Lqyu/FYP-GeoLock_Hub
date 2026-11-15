# Paper-run provenance

This evidence is for hosted E2 run `bc954b859fa348d9a7a48cb005ee748e` on Supabase PostgreSQL 17.11. The [run manifest](../run_manifest.json) records the exact Python environment and all source and input hashes.

- `sources/` preserves the 19 files used for the paper run, at their original repository-relative paths. These are historical copies. Use the active E2 runner for new runs. The active runner and harness differ from the snapshot in result-directory handling.
- [Original result checksums](original-result-sha256.json) preserve the original 31-entry SHA-256 inventory. The original Figure 1 and Figure 3 were restored from byte-identical copies using these hashes. The [comparison summary](../comparison/summary.md) still links to the original figures and retains its original bytes.
- The [duplicate-ownership PNG](../comparison/e2_fig1_duplicate_owners_wilson_ci.png) and [lease-recovery PNG](../comparison/e2_fig3_lease_recovery_wilson_ci.png) are derivative paper exports. They add numerical Wilson interval labels to the same results. Their [checksums](paper-export-sha256.json) are separate from the original inventory. The previous vector PDF exports were unavailable in this checkout.
- The shared benchmark CSVs and generation manifest live in the repository's `benchmark dataset/dataset/` directory. Keep that directory in the handoff.

Run the verifier from the repository root. It uses only the Python standard library, this run directory, and the shared frozen dataset.

```powershell
py -3.12 -B experiments/e2/experiment_result/results/bc954b859fa348d9a7a48cb005ee748e/provenance/verify.py
```
