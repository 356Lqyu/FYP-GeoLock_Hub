# DEV authentication after password reset — 27 October 2026 MYT

**New owner-reported result: native session-pooler psql17.11 PASS.** Follow [NATIVE_PASS_PYTHON_COMPARISON.md](NATIVE_PASS_PYTHON_COMPARISON.md) for the next single manual Python connection-only check. The conditional direct test below is no longer the recommended next step; the historical assessment remains preserved.

**Current verdict: authentication blocked; exact underlying cause unconfirmed. No live retry or database change by Codex.**

## Confirmed

Latest evidence `results/routing-connection-diagnostics/20261026T174046Z-f90cdc` records connect-phase OperationalError, null SQLSTATE and PASSWORD_AUTHENTICATION_FAILED. No BEGIN, identity query or export occurred. This proves the old classifier found an authentication-failure phrase; it does not prove the password was incorrect or identify whether Supavisor or PostgreSQL generated it.

Target matches the approved profile and the Dashboard values confirmed by the owner:

* DEV project `rcgyuwiidqvrgbxswhqj`.
* Session pooler `aws-0-ap-northeast-2.pooler.supabase.com:5432`, databasepostgres.
* Pooler login `postgres.rcgyuwiidqvrgbxswhqj`, intended database rolepostgres. `geolock_dev_owner_export` is the local profile alias. Because authentication has not succeeded, actual session/current_user is **not yet observed** for this connection.
* TLSverify-full, CA `C:/Users/User/Downloads/prod-ca-2021.crt`, startup `-c default_transaction_read_only=on`, connect_timeout15.
* Python reads the approved file directly, validates every field and passes explicit keywords plus the hidden prompted password. Source performs no password trimming, URL transformation or alternate credential lookup. Prior offline driver roundtrip preserved special characters. Six optional PostgreSQL environment variables were reported absent by the owner; no environment override is evidenced.

The user reports a completed DEV database password reset. Its exact completion time and new password acceptance by a direct PostgreSQL connection are not in the evidence. No password was requested/read by Codex.

## Hypotheses and useful discriminators

| Possibility | Status / evidence needed |
|---|---|
| Shared-pooler cached credentials after rotation | Plausible, documented behavior; direct PostgreSQL acceptance plus native pooler failure would support a pooler-specific discrepancy. Not confirmed from this receipt. |
| Pooler authentication circuit breaker | Possible with repeated failing clients, but **no circuit-breaker message is recorded**. Avoid loops; inspect DEV Pooler Logs if needed. |
| Password entry/source or reset/backend acceptance issue | Unresolved until the new literal password is accepted in an independent connection. A reported reset alone does not establish the cause of rejection. No further reset recommended. |
| Python/native client difference | psycopg3.3.6/libpq18.4 versus installed psql17.11. No concrete incompatibility found. One native-client test separates this path; native success alone does not prove a driver bug because password-entry events differ. |
| Classifier lost important context | Confirmed limitation: old code only kept fixed regex labels, with no server-severity/origin flags. A bare phrase could coexist with an unrecognized TLS/client error. Raw text cannot be reconstructed. |

Supabase documents brief shared-pooler credential caching after rotation, recommends direct verification to distinguish database acceptance, and provider escalation if a direct-success/pooler-failure discrepancy persists. This is a hypothesis here, not a diagnosed cache fault. [Official reset/cache guidance](https://supabase.com/kb/troubleshooting/supavisor-error-password-authentication-failed-after-password-rotation).

Repeated failed clients can also trigger a separate temporary pooler circuit breaker. No such response is confirmed here; do not run retry loops. [Official circuit-breaker guidance](https://supabase.com/kb/troubleshooting/supavisor-error-circuit-breaker-open-after-password-rotation).

## Minimal diagnostic improvement implemented locally

`export_diagnostics.py` now preserves fixed boolean flags for structured auth SQLSTATE, a server-style FATAL authentication message, bare auth phrase, TLS markers and connection markers. Mixed auth/TLS messages remain explicitly mixed; generic TLS handshake and pooler circuit-breaker failures have separate codes. No raw text, hashes of secret-bearing messages, password, token or arbitrary substring is retained.

`SERVER_OR_POOLER_STYLE_FATAL_AUTH_REJECTION` means the client reported that message style; it does not establish PostgreSQL versus Supavisor origin or prove password correctness. Existing evidence is not relabeled. The old classifier version pinned by the receipt remains a historical artifact. Client/profile/TLS/query/timeouts were not changed. Local mocked tests cover this improvement; no live connection test was executed.

## Next test: one manual native psql session-pooler connection

First keep the current reset password; do not reset again. Avoid simultaneous failing-client attempts. No worker needs activation for a connection test. The following is a **manual single test**, not an automatic retry, and does not run the Python exporter or its classifier.

Use your installed PostgreSQL17.11 client. These explicit **non-secret** connection settings match the supplied Dashboard session settings and approved read-only security settings. The password is requested by native `-W`; it is not embedded in the command, environment, a URI, report or file. Use the literal new DEV postgres database password. No transcripts or raw-error redirection are required.

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
$psql = 'C:\Program Files\PostgreSQL\17\bin\psql.exe'
$probe = Join-Path (Get-Location).Path 'docs\stage8\stage-a\deployment-preparation\routing-initialization\independent-connection.readonly.sql'
$pooler = "host=aws-0-ap-northeast-2.pooler.supabase.com port=5432 dbname=postgres user=postgres.rcgyuwiidqvrgbxswhqj sslmode=verify-full sslrootcert='C:/Users/User/Downloads/prod-ca-2021.crt' options='-c default_transaction_read_only=on' connect_timeout=15"
& $psql --no-psqlrc --password --dbname $pooler --set ON_ERROR_STOP=1 --file $probe
$LASTEXITCODE
```

The probe uses BEGIN READ ONLY, a ten-second local query bound, SELECT identity/SSL, client conninfo and ROLLBACK only. Expected success: exit0, databasepostgres, current_user/session_userpostgres, read_onlyon, ssltrue and ROLLBACK. Neither exit0 alone nor connecting is road-data equivalence. If failure occurs before SQL, native psql shows its own libpq error locally, independently of our classifier. Report only outcome, timestamp, error category/SQLSTATE if present and the expected non-secret identity; do not send passwords or a connection URL containing one.

**Stop after this result.** If native pooler succeeds, compare its evidence with the failed Python attempt before deciding another Python test. If native pooler fails, use the conditional direct test below to separate pooler and database acceptance, or record that direct access is unavailable. Do not loop or automatically switch modes.

## Conditional independent direct test — same DEV project only

This is an additional **manual diagnostic**, not a replacement export connection. In the Dashboard for this exact project, inspect **Connect → Direct connection**. Use the literal hostname below only if it exactly matches that dialog. Direct IPv6 connectivity or an already available IPv4 endpoint is required; do not buy/enable an add-on or change project settings. If direct networking is unavailable, record NOT TESTABLE and stop; network/TLS failures do not establish password validity.

Unlike the shared pooler, the direct connection uses userpostgres without the project suffix. Verify Dashboard values before this one attempt; no production or other project endpoint is permitted.

```powershell
# Only after the pooler test failed and Dashboard direct settings match.
$direct = "host=db.rcgyuwiidqvrgbxswhqj.supabase.co port=5432 dbname=postgres user=postgres sslmode=verify-full sslrootcert='C:/Users/User/Downloads/prod-ca-2021.crt' options='-c default_transaction_read_only=on' connect_timeout=15"
& $psql --no-psqlrc --password --dbname $direct --set ON_ERROR_STOP=1 --file $probe
$LASTEXITCODE
```

Do not weaken TLS if the direct test fails certificate validation. Certificate/route/DNS failures are separate, inconclusive results for authentication. Do not test6543 as an independent bypass: it uses the shared pooler too.

| Observed results | Supported conclusion / next action |
|---|---|
| Native pooler PASS, prior Python FAIL | Pooler accepts that native attempt. Investigate entry/client differences before blaming the driver; do not start the export. |
| Native pooler authentication FAIL, direct PASS | New password accepted by PostgreSQL; pooler-path discrepancy supported. Inspect DEV Pooler Logs and escalate a persistent discrepancy to Supabase; no reset/restart/role changes. |
| Both independently report authentication rejection | Not isolated to Python or only the shared pooler. Database credential/backend acceptance or entry remains unresolved; seek owner/provider verification without another reset. |
| Direct DNS/IPv6/TCP/TLS failure | Direct password validity UNKNOWN. Record exact non-secret category; provider logs/support may be needed. |
| Circuit breaker response | Distinct temporary rejection. Stop probes; have the owner identify known old-credential reconnecting clients. Do not activate, restart or edit services as part of this task. |

For provider review, correlate DEV Pooler Logs around **2026-10-26 17:40:46 UTC / 27 October01:40:46 MYT**, plus the actual reset-completion time supplied privately by the operator. Pooler logs can distinguish client auth, upstream postgres rejection and credential-refresh errors; [Supabase documents the read-only log surface](https://supabase.com/docs/guides/database/supavisor). Prepare only non-secret timestamps, project/endpoint/user identity, native-client versions and outcomes for support. No support message was sent by Codex.

No automatic authentication retries, database writes, full export, policy installation, graph freeze, recovery or worker activation were performed. Equivalence remains NOT VERIFIED.
