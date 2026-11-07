# Native PASS → next controlled Python diagnostic

**Superseded next action:** Python attempt `20261026T175647Z-c59e3e` again reported a server-style FATAL auth rejection. Do not repeat the live test below. Follow [PASSWORD_INPUT_AND_NATIVE_EXPORT_REVIEW.md](PASSWORD_INPUT_AND_NATIVE_EXPORT_REVIEW.md) for an **offline-only** comparison and native export fallback assessment. Psycopg may perform per-address attempts inside one connect call; the earlier single-attempt wording was too broad.

Prepared27 October2026 MYT. **No live authentication attempt or database change by Codex. No full export authorized.**

## Confirmed findings

The owner reports successful native psql17.11 connection through the approved session pooler, actual current_user/session_userpostgres, databasepostgres, read_onlyon, SSLtrue/TLSv1.3, server17.11 and completed ROLLBACK. This establishes new-password acceptance by that pooler path **at that successful attempt**. It does not retroactively identify the cause of the earlier Python failures. A separate raw native execution log/time was not supplied; the PASS is owner-reported evidence, not a fabricated local capture.

The reviewed native command and Python's eight approved connection fields agree:

| Field | Native test command / Python profile |
|---|---|
| Host | aws-0-ap-northeast-2.pooler.supabase.com |
| Port / mode | 5432 / shared session pooler |
| Database | postgres |
| Username | postgres.rcgyuwiidqvrgbxswhqj; intended rolepostgres |
| SSL | verify-full |
| CA | C:/Users/User/Downloads/prod-ca-2021.crt |
| Startup option | -c default_transaction_read_only=on |
| Connect timeout | 15 seconds |

No confirmed identity, CA, option or parameter-quoting error was found. Python reads the approved profile and explicitly passes these fields. Psql used the explicit equivalent non-secret connection string. Optional PostgreSQL environment variables were previously reported absent by the owner. Neither path embeds a password in a URI or a command argument.

## Differences reviewed

| Area | Observed difference / implication |
|---|---|
| Client | Native psql17.11 versus Python3.12.14, psycopg3.3.6, libpq18.4. Different implementations remain a possible factor; no incompatibility or driver bug has been demonstrated. No installation/upgrade/downgrade is recommended yet. |
| Password input | Native psql hidden console prompt versus Python Windows getpass. Python's installed source uses Unicode getwch, handles Enter/backspace/Ctrl+C, and otherwise appends characters; arrow/navigation/control-key sequences are not normal line editing. This creates a possible entry-path difference, not evidence it occurred. Neither a password nor its length/content was inspected. |
| Password transformation | Python applies no trim, normalization, URL encoding/decoding or secret lookup. Offline dummy input containing quotes/backslash/reserved characters/spaces survives actual psycopg conninfo construction/parsing unchanged. This validates escaping, not actual input events. |
| SSL | Requested mode and CA match. Native success verifies that native TLS path at that time; Python's linked SSL/client behavior is independently unverified. Python's standard-library ssl version must not be mistaken for libpq's SSL build version. |
| Transaction | Native probe begins READ ONLY, while Python begins REPEATABLE READ READ ONLY and later sets transaction-local limits. These occur **after authentication**, so they cannot cause the preserved connect-phase failure. |
| Timeouts | Both connect limits15s. Native identity-query limit10s versus Python60s is also post-authentication, irrelevant to the prior connect failure. |
| Timing | Native PASS occurred after earlier Python failures. Transient reset/pooler state may have settled between attempts. Reset/native-test exact times are not established here; persistent failure is not assumed. |

## Preserved Python evidence and classifier interpretation

Earlier Python receipts reported connect-phase OperationalError, null SQLSTATE and an authentication-failure phrase; there were no CSVs or identity results. These attempts predate the latest classifier metadata. Their raw message was not retained, so we cannot reconstruct server severity, structured28P01, mixed messages or PostgreSQL-versus-pooler origin.

The old label must not be interpreted as proof that the verified password is wrong or that Python is incompatible. It proves only the matcher found the phrase. The current classifier adds structured-SQLSTATE/FATAL/bare-phrase/TLS/connection flags, explicit mixed-message handling and circuit-breaker codes; it still saves no raw text, password or secret-derived hash. These richer flags apply **only to a new attempt**, not a retrospective rewrite of prior evidence.

Existing local checks passed: exact public-parameter comparison, dummy password roundtrip, and previously recorded16 unit tests for diagnostic control flow/secret non-disclosure/classification and storage-comparison helpers. No code change is necessary for this next stage.

## Smallest safe next action

**Yes: use the existing `--diagnose-connection` mode once, manually, with the same verified current database password.** It prompts locally, uses the same profile, begins a read-only snapshot, checks identity/TLS, rolls back and stops. It does not copy road tables, invoke the verifier, initialize routing or retry automatically.

Run in a normal interactive PowerShell console, without piping input or starting a transcript:

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
& '.\.venv-stage8\Scripts\python.exe' -B '.\docs\stage8\stage-a\deployment-preparation\routing-initialization\export_current_dev.py' --diagnose-connection
```

Enter the same literal password privately, without extra quotes/URI encoding. Avoid arrow/navigation keys in Python's hidden prompt. If entry must be abandoned, Ctrl+C before submission aborts the local prompt; it is not permission for authentication loops. Do not share the password, length, character details or clipboard contents.

Stop after one completed attempt and retain the printed new diagnostic directory:

| Result | Supported next conclusion |
|---|---|
| DIAGNOSTIC_PASS, correct identity/TLS/read_only and rollback | Python now also works through the pooler. Historical cause remains unresolved; transient state or entry differences remain possible. This is not full export/equivalence or write approval. |
| Same rejection with server-style FATAL or structured auth flags | A fresh discrepancy remains after native PASS. Review the new fixed flags and timestamps before deciding a client-isolation change; do not keep retrying, downgrade drivers or reset credentials. |
| TLS or mixed failure flags | Investigate the specific client/TLS path, preserving verify-full; the auth phrase alone is insufficient. |
| UNCLASSIFIED/bare phrase only | Origin remains unverified. Preserve evidence; do not convert that uncertainty into a password/driver diagnosis. |

Provide only the new directory path, status, phase, failure_domain/evidence_flags if present and non-secret native success time if available. No database writes, account changes, policy/graph operations, worker activation or full export are part of this controlled action.
