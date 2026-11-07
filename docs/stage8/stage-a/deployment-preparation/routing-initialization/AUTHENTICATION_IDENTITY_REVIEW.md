# Authentication identity review — 27 October 2026 MYT

**New evidence after owner-reported password reset:** see [POST_RESET_AUTHENTICATION_REVIEW.md](POST_RESET_AUTHENTICATION_REVIEW.md). The next useful test is a single manual independent native-client probe, not repeated Python attempts. The historical review below is retained; no additional reset is recommended.

**Result: configured identity MATCHES the approved DEV export profile. Authentication rejected; entered secret cannot be verified from retained evidence. No correction to connection settings is indicated. No authentication attempted by Codex.**

Evidence examined: `results/routing-connection-diagnostics/20261026T172911Z-cc17e4/receipt.json` and `queries.sql`, current exporter/query/classifier sources, the approved profile and the successful pre003 backup capture record. The diagnostic failed at `psycopg.connect`, before BEGIN/identity/data export. Its pinned classifier identified `password authentication failed`; raw exception text was deliberately not retained. This is evidence of an authentication rejection, not proof of which password was entered or that an existing password changed.

## Exact non-secret identity

| Setting | Actual script / receipt / approved profile |
|---|---|
| Supabase project | rcgyuwiidqvrgbxswhqj — intended DEV |
| Local service/profile name | geolock_dev_owner_export — an alias, **not a PostgreSQL account** |
| Host | aws-0-ap-northeast-2.pooler.supabase.com |
| Port / method | 5432 / shared session pooler, PostgreSQL protocol |
| Database | postgres |
| Pooler username | postgres.rcgyuwiidqvrgbxswhqj |
| Underlying PostgreSQL role | postgres |
| SSL mode | verify-full |
| Root certificate | C:/Users/User/Downloads/prod-ca-2021.crt |
| Startup options | -c default_transaction_read_only=on |
| Connect timeout | 15 seconds |
| Driver | psycopg3.3.6 / libpq18.4; explicit keyword parameters |

Shared session pooling uses `postgres.<project-ref>` on port5432, consistent with [Supabase's documented connection format](https://supabase.com/docs/guides/database/connecting-to-postgres). Direct connections use a different endpoint/username format; do not switch modes or strip the suffix. Verify the exact host/index in this project's Dashboard **Connect → Session pooler**; host indexes cannot be inferred from region alone. This inspection confirms agreement with the approved profile, not independent access to today's dashboard values.

## Which password to enter

Use the **current password for the DEV project's PostgreSQL `postgres` role**—the database credential associated with this project's connection string and the same account used for the successful approved export. Obtain/confirm it privately through your existing trusted credential record or its owner. Do not reset anything as part of this investigation. If it is unknown, stop rather than guess.

The local alias does not have its own password. Supabase website login, NGO application login, anon/publishable/service-role keys, access tokens, MCP OAuth and graph/planner/validator role passwords are different credentials and cannot authenticate this account.

At the hidden prompt enter the **literal password**, without URI percent-encoding, wrapping quotes, a full connection URL or a `password=` prefix. Preserve any characters that actually belong to the password. The Supabase URI instructions require escaping when embedding a password in a URI; this script passes it separately as a keyword. It performs no `.strip()`, URL encoding/decoding or credential lookup, and never prints/stores it.

## How Python uses the profile and overrides

The successful backup used PostgreSQL CLI `service=geolock_dev_owner_export` with the approved PG service file. Python reads the same exact file/section using `ConfigParser(interpolation=None)`, asserts equality with the eight approved public fields and passes that dictionary to `psycopg.connect(**params,password=password,autocommit=True)`. No alternate DSN, role substitution or database URL is used. Autocommit is a psycopg control flag; subsequent SQL explicitly begins READ ONLY.

All receipt values and profile bytes match. Receipt source hashes for the exporter, query contract and classifier match inspected files. Offline libpq conninfo construction/parsing preserved every explicit identity field and a dummy password containing reserved characters/quotes/backslash/spaces. No real password or connection was used in that check.

[PostgreSQL parameter precedence](https://www.postgresql.org/docs/18/libpq-envars.html) makes explicit parameters take precedence over corresponding environment defaults. Therefore PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD/PGSSLMODE/PGSSLROOTCERT/PGOPTIONS cannot replace the explicitly supplied corresponding nonempty values. The prompted password is supplied explicitly; a stored passfile is not selected instead of it. The helper does not use PGSERVICEFILE to select which profile file it manually reads.

**Qualification:** unspecified optional libpq settings can still come from the operator process environment. The receipt did not capture them. PGHOSTADDR can supply a separate destination IP; PGSERVICE can supply additional defaults. PGCHANNELBINDING/PGREQUIREAUTH/PGSSLNEGOTIATION can affect negotiation. A PGSERVICEFILE variable by itself does not change the manually parsed dictionary. There is no evidence yet that these optional settings caused this rejection, and Codex's shell is not evidence of the operator terminal's environment.

## Next step without another authentication attempt

Verify the non-secret dashboard identity and the correct database-password source privately. Then inspect only presence of optional defaults in the **same PowerShell window** used for the failed command:

```powershell
'PGHOSTADDR','PGSERVICE','PGSERVICEFILE','PGCHANNELBINDING','PGREQUIREAUTH','PGSSLNEGOTIATION' | ForEach-Object {
    [pscustomobject]@{ Name = $_; Present = (Test-Path -LiteralPath ('Env:' + $_)) }
}
```

This prints names/booleans only, reads no password value, changes no environment setting and makes no network/authentication attempt. Do not send an environment dump or credential contents. If flags are present, review their purpose before deciding whether any local setting needs a separate correction; do not remove them blindly.

Only after confirming the dashboard identity and **known current literal database password**, one deliberate connection-only check can be made:

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
& '.\.venv-stage8\Scripts\python.exe' -B '.\docs\stage8\stage-a\deployment-preparation\routing-initialization\export_current_dev.py' --diagnose-connection
```

Do not run both repeated guesses or a full export. If the same known credential still fails, stop and retain the new diagnostic; distinguishing a provider/pooler/backend credential-state issue from entry/source mismatch would require further evidence. Do not reset passwords, change roles, switch credentials/drivers/ports, weaken TLS or disable the read-only option to force success. A changed/old password, wrong credential source, URI-escaped input, inadvertent quoting or keyboard/paste error are possibilities—not established facts.

No script, profile, database, permissions, password or policy changes were made for this review. Existing diagnostic files are preserved. Full export/equivalence and all routing writes remain blocked/pending.
