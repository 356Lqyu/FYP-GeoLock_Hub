# Windows operator configuration

The administrator supplies the exact approved PostgreSQL service profile bytes, the public CA file or bundle and an independently verified SHA-256 for that entire CA file. The digest must be reviewed and pinned in `APPROVED_CA_SHA256` in the team source before deployment. The approved DEV CA file digest is pinned in source. An unset pin fails closed. There is no operator checksum override.

## Prepare and validate offline

1. Install Python 3.12 and the approved libpq 17.11 client as described in the README.
2. Place the administrator's exact profile at `%LOCALAPPDATA%\GeoLockHubRoutingDev\pg_service.proposed.conf` in a directory protected from other users. Preserve its bytes and line endings. It establishes the approved endpoint and role policy. Its legacy CA path is replaced at runtime by the independently verified local CA path.
3. Store the administrator-approved public CA file in a protected local folder of your choice. Use an absolute local path. Spaces are supported. Keep both files outside Git.
4. From the checkout root, set `$ca` to the absolute CA path and `$dbHost` to the exact approved session-pooler hostname, then run:

```powershell
.\backend\routing\worker_service\windows\Test-LocalRoutingSetup.ps1 -ValidateOnly -CaPath $ca -DbHost $dbHost
```

`Save-WorkerConfig.ps1 -ValidateOnly -CaPath $ca -DbHost $dbHost` runs the same offline check. Neither validation command connects, starts a worker, prompts for passwords or writes operator settings. The full disabled startup check can also take `-CaPath` and `-DbHost`. Local validation establishes byte identity and PEM parsing. Server certificate verification takes place during a separately approved connection with TLS `verify-full`.

## Save settings and obtain authorization

After validation passes, run `Save-WorkerConfig.ps1 -CaPath $ca -DbHost $dbHost`. It saves local Windows settings and generates a private token for the paired planner and validator. Existing profiles are preserved. If migrating an existing operator, arrange an approved local backup and reconfiguration before replacing profiles. The wizard leaves database password entry to the native hidden prompts at worker startup.

The administrator must provision separate graph, planner and validator scopes, the approved graph UUID and live session approval. The current login names are fixed. If separately revocable operator credentials require different database LOGIN names, obtain a separate approved mapping and provisioning change. Do not share personal database passwords. Flutter users sign in with their own authorized accounts. Follow the README for separately approved activation.

[Credential-free checklist](../config/operator.example.json)
