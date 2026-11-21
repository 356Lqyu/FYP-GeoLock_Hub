# Routing environments

The routing backend serves one Supabase project per process. `GEOLOCK_ENVIRONMENT` selects it, and **DEV is the default**: when the variable is unset, every DEV launch behaves exactly as before.

| | `DEV` (default) | `KLSEL` (NEW project) |
|---|---|---|
| Project | `rcgyuwiidqvrgbxswhqj` | `ppwmdsyoesvhgmqiaoxa` |
| Frozen graph | `eab1f7ee-a8e0-4bed-a0e1-2c4bff024936` | `19c44bd2-8871-4eca-bf6b-4262f1bf766d` |
| Content digest | `5e06dab0…04012a` | `6b62b365…9edc32` |
| Snapshot, nodes / edges | `OSM-OPS-20261018`, 926,414 / 2,145,828 | `OSM-OPS-20261018-KLSEL`, 205,524 / 454,178 |
| Local folder (`%LOCALAPPDATA%`) | `GeoLockHubRoutingDev` | `GeoLockHubRoutingKLSEL` |
| libpq service profile | tracked, hash-pinned (`docs/stage8/…/pg_service.proposed.conf`) | `GeoLockHubRoutingKLSEL\pg_service.conf`. Outside Git, password-free, written by `Save-WorkerConfig.ps1 -Environment KLSEL`, and checked field by field against `environment.py`. |
| Worker state (journal + graph cache) | `GeoLockHubRoutingDev\state` | `GeoLockHubRoutingKLSEL\state`. Stamped with `environment.json`; another environment's folder is refused. |

All identifiers live in `environment.py`. It contains no passwords, keys, tokens or DSNs.

## Safety properties

The rules below apply to non-DEV environments.

- **Project and graph.** `GEOLOCK_PROJECT_REF` and `GEOLOCK_GRAPH_ID` must equal the registry values. DSNs must target that project: the pooler user suffix or the `db.<ref>` host.
- **Graph cache.**
  - `GraphCache` checks the live manifest's graph ID, digest, snapshot, counts and speed profile.
  - It refuses a cache folder holding another graph's files (`FOREIGN_GRAPH_CACHE_PRESENT`), so DEV's cache can never be reused.
  - `Prepare-WorkerCache.ps1` stays DEV-only and refuses non-DEV folders.
- **NGO JWTs.** They are verified against the selected project's Supabase URL.
- **Scripts that stay DEV-only:**
  - `diagnostics/pilot_benchmark_probe.py` (refuses non-DEV);
  - `windows/Update-PlannerPublishableKey.ps1`;
  - `windows/create_worker_logins.manual.sql`;
  - `scripts/Run-ExactV3Pilot.py`, `scripts/Verify-ReconciliationHostedReads.py`, `scripts/Inspect-PhoneRoutingMetadata.py`.
- **Activation flag.** It keeps its historical name, `GEOLOCK_ROUTING_ALLOW_DEV_WRITES=APPROVED`, in every environment.
- **Validator build ID.** It hashes `contract.py`, `validator/validation.py` and `snapshot.py`. This change edits two of them, so the ID differs from the pre-change value in both environments. No database pins it: attestation requires only a non-empty value.

## Operator commands (Windows, repository root)

```powershell
backend\routing\windows\Save-WorkerConfig.ps1 -Environment KLSEL      # once; never overwrites
backend\routing\windows\Test-LocalRoutingSetup.ps1 -Environment KLSEL  # offline
backend\routing\windows\Start-Worker.ps1 -Environment KLSEL -Mode planner -CheckConfig
backend\routing\windows\Start-Worker.ps1 -Environment KLSEL -Mode planner -CheckConnection    # read-only
backend\routing\windows\Start-Worker.ps1 -Environment KLSEL -Mode validator -CheckConnection  # read-only
backend\routing\windows\Start-Worker.ps1 -Environment KLSEL -Mode planner -WarmGraph -ApprovalRef <ref>  # read-only cache build
```

Omit `-Environment` for DEV; DEV commands are unchanged.
