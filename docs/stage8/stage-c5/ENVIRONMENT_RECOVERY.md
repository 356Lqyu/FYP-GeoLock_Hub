# Stage C.5 — environment recovery investigation

26 October 2026, Asia/Kuala_Lumpur. **NON-PARITY. Read-only investigation; recovery NOT TESTED.**

**Finding:** the observed startup failure maps to PostgreSQL's Windows restricted-token creation path, before launching the database server. A token interaction with the Codex sandbox account is the leading explanation. The precise Windows token/API incompatibility is not established. No evidence supports changing database SQL, installing software, granting privileges or repairing paths as the first response.

**Minimum proposed correction:** after separate approval, perform an environment-only smoke attempt from a user-opened, non-elevated Windows terminal under the normal Windows user, with a fresh user-owned data directory and the same private binary runtime. Keep PostgreSQL's own restricted-token handling enabled. This is a proposed controlled change of execution context, not a verified fix or approval to rerun C.5.

## 1. Scope and evidence preserved

Reviewed the attempt 01 process logs, failure/results/cleanup records, generated PostgreSQL configuration, frozen harness source, retained runtime files/ACLs, and current shell identity. Consulted official PostgreSQL 17.11 source, Microsoft Windows API/error documentation and official OpenAI Windows sandbox documentation.

No PostgreSQL executable was launched during this investigation, including version/status commands. No initdb, pg_ctl, server startup/restart, database connection, migration, test, software install, permission/security/service change or harness edit occurred. No Supabase tool or project was accessed. No remote database was contacted. Web access was limited to documentation/source inspection.

Attempt 01 remains at `results/stage-c5/nonparity-attempt-01/`. All **14 artifacts listed in its existing evidence index** still match their hashes. Its `postmaster.pid` and `server.log` are absent. The indexed-artifact check does not claim a checksum inventory of every initialized cluster file. The frozen harness SHA-256 remains:

`264374be4deeb2ccfe12c7da77dfdd33b022ccf8f5ef13a4382bdc4b4c3b5236`

## 2. Current Windows execution context

| Read-only observation | Result | Interpretation |
|---|---|---|
| `whoami /user` | `LAPTOP-SIR1D3LB\CodexSandboxOffline` | Actual shell token principal is the sandbox account |
| `whoami /groups` | CodexSandboxUsers, Users, interactive/authenticated groups; Medium Mandatory Level | Consistent with a bounded non-admin sandbox execution context |
| `whoami /priv` | Only SeChangeNotifyPrivilege listed, enabled | Do not infer that granting additional privileges is required |
| Environment variables | USERNAME=`User`, USERPROFILE=`C:\Users\User`, TEMP under that profile | Environment strings differ from the actual principal; do not use USERNAME to establish identity |
| Shell | PowerShell 7.6.5, AMD64; executable under the bundled Codex runtime | Native Windows PowerShell execution |
| OS API report | `Microsoft Windows NT 10.0.22621.0` | Reported build only, not independent verification of product edition/update state |
| Process/parent inspection using CIM | Access denied | Parent chain, job-object membership and full token restriction details remain unverified; no escalation attempted |
| COMSPEC | `C:\WINDOWS\system32\cmd.exe`, file exists | Current shell path exists; attempt 01 did not preserve COMSPEC, so historical equality is unknown |

Official OpenAI documentation describes dedicated lower-privilege accounts and filesystem/network boundaries for its legacy elevated Windows sandbox. The measured account is consistent with that design, but no active-mode configuration or complete token dump was obtained; this report does not certify the exact sandbox implementation. [Official Windows sandbox documentation](https://learn.chatgpt.com/docs/windows/windows-sandbox).

Microsoft explicitly permits a restricted token as input to CreateRestrictedToken. Therefore “already restricted” alone does not prove an unsupported API call; identifying the exact rejected token property/parameter would require further approved diagnostics. [CreateRestrictedToken API](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-createrestrictedtoken).

## 3. Runtime, paths and file permissions

The recorded private runtime is:

`C:\Users\User\AppData\Local\Temp\geolock-spatial-runtime-24dbda5e04a04d48bd8d8dab0299d7eb\pgsql`

The runtime root and bin directory exist as ordinary directories, with no link/reparse target shown by the inspected properties. postgres.exe, initdb.exe and pg_ctl.exe file metadata reports product version **17.11**. Attempt 01 also recorded successful `postgres --version` output of 17.11. No executable was run to reconfirm that during this investigation.

| Inspected file | Current SHA-256 |
|---|---|
| bin/postgres.exe | `f5dbfd059f8088b9511a02fc014e659369996fc7d3e88e47658b1cfa2fbb02d2` |
| bin/pg_ctl.exe | `9885ac53af9d67c76c1ddde87c19e6b15539d7c482bca70cd5ead5dad0b7ce3c` |
| bin/initdb.exe | `d385519a50d2cd5e143e86c2c10acfe0d44d3039d714c8211b804011bca2409f` |
| bin/psql.exe | `c290c7f0a3335f290f8c18011a1e5afa03ee3cdd628697a5f3e767e5f1d3d10d` |

These are current observations for recovery review, not proof that the binary distribution was built from the cited source or independently authenticated.

The extension control files specify PostGIS **3.6.2** and pgRouting **4.0.1**. These are file declarations, not a current successful extension load. Actual extension versions remain unverified for C.5. Earlier B.1 environment evidence records successful loading of these versions historically; it does not prove that today's execution context can start the server or that all runtime bytes remain historically identical.

The runtime root/bin and attempt 01 data directory are owned by CodexSandboxOffline. Their inspected ACLs include Modify for CodexSandboxUsers and FullControl for the normal User, SYSTEM and Administrators, along with additional sandbox SIDs. ACL text is not a complete effective-access calculation under restricted tokens. It does show that no simple missing ordinary User allow entry was found. Attempt 01 actually created and populated the data directory, so a general inability to write there is not a sufficient explanation of that failure.

The data directory's PG_VERSION contains `17`; its configuration specifies loopback-only listening, a unique C.5 cluster marker, port supplied by the launcher, and max_connections=10. No evidence shows the server reached configuration parsing, socket binding, SQL, or extension loading. Do not attribute the observed token error to these later phases.

## 4. Failure mechanism and confidence

Attempt 01 recorded this sequence:

1. Binary version query succeeded.
2. initdb reported restricted-token error 87, then re-execution error 3, but continued and returned exit 0.
3. pg_ctl reported restricted-token error 87, then server-start error 3, and returned exit 1 in about 0.11 seconds.
4. There were zero SQL client invocations, no submitted SQL files, no server log and no postmaster.pid.

In upstream 17.11 `restricted_token.c`, the matching initdb diagnostic follows failed CreateRestrictedToken. The caller logs failed re-execution and can continue initialization instead of exiting; this explains why token errors and exit 0 can coexist. The follow-on error is read later through GetLastError. [PostgreSQL 17.11 restricted-token source](https://raw.githubusercontent.com/postgres/postgres/REL_17_11/src/common/restricted_token.c).

In upstream 17.11 pg_ctl, the matching token diagnostic likewise follows failed CreateRestrictedToken. The helper returns before CreateProcessAsUser and subsequent job-object operations. Its caller then emits the generic server-start error using a later GetLastError value. This localizes the failure before the server shell/process launch; a job-object assignment failure is not the demonstrated point of failure. These are source-to-log mappings, not a trace of the installed binary. [PostgreSQL 17.11 pg_ctl source](https://raw.githubusercontent.com/postgres/postgres/REL_17_11/src/bin/pg_ctl/pg_ctl.c).

Microsoft defines 87 as ERROR_INVALID_PARAMETER and 3 as ERROR_PATH_NOT_FOUND. However, the upstream error paths call cleanup routines and then query GetLastError again without preserving the original code throughout. Thus the secondary 3 is **not independent proof of a missing filesystem path**. The logs establish failed token creation; they do not identify which token parameter Windows rejected. [Windows system error codes](https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes--0-499-).

| Candidate explanation | Assessment |
|---|---|
| Windows token creation/launch interaction | **Strongly supported failure location** by matching diagnostics/source |
| Codex sandbox token/account interaction | **Leading hypothesis**, supported by actual principal and limited token context; no outside-sandbox comparison performed |
| Missing runtime executable/data directory | **Not supported as the primary failure**: files exist, version query worked and initialization wrote the cluster |
| COMSPEC, shell quoting or working-directory issue | **Not verified as a cause**; launch path was not reached in the matching source branch; historical COMSPEC not logged |
| Ordinary file ACL denial | **Not demonstrated**; restricted-token effective access remains incompletely characterized |
| Antivirus, domain policy, API interception or particular token/SID property | **Unknown**; no controlled reproduction, API trace or policy audit was performed |
| Database SQL, migrations, PostGIS/pgRouting incompatibility or port collision | **Not exercised at the failure point**; no compatibility verdict possible |

The investigation establishes a narrower, more useful result than “PostgreSQL cannot run on this machine”: the retained binary utilities fail while attempting their own token restriction under the measured Codex execution context. It does not prove which Windows/Codex component is defective.

## 5. Normal user terminal feasibility and minimum correction

A user-opened non-elevated terminal is a reasonable next controlled comparison. It should have the normal user's token rather than an agent-launched child's inherited sandbox token. Opening another PowerShell child from inside the sandbox is not that comparison. The ordinary User has an allow entry on the private runtime; nevertheless child restricted-token access and full library loading still need verification. Success is **plausible, not established**.

PostgreSQL documents running the server under its owning account and using explicit data-directory selection. Keep initialization, startup and cleanup under the same ordinary user with a fresh user-owned cluster. Do not reuse the CodexSandboxOffline-owned attempt 01 cluster or alter its ownership. [PostgreSQL server startup documentation](https://www.postgresql.org/docs/17/server-start.html).

The minimum change proposed is **execution context plus a new data directory**, with normal PostgreSQL protection retained. No administrator terminal, account/ACL/privilege changes, security exclusions, sandbox reconfiguration, service install, binary patch or new software is proposed. Do not set PG_RESTRICT_EXEC to suppress token handling; do not replace pg_ctl with a direct-server launch as an unreviewed workaround. Do not disable the Codex sandbox globally.

## 6. Proposed recovery procedure — separate approval required

This procedure is not an instruction to execute during this investigation. It requires a future environment-smoke approval and a reviewed environment-only runner. **Do not launch the present C.5 runner:** successful startup would proceed into schema assembly and migration testing, which is outside this investigation.

1. Review a revised environment-only runner in a new source artifact. Preserve the attempted harness and all attempt 01 evidence. Freeze the new runner, binary and dependency manifests before execution. Implement the immediate-stop rules below first.
2. The user opens Windows Terminal/PowerShell from the desktop/Start menu, without Run as administrator. Record `whoami /user`, groups and privileges there. Confirm it is the normal account rather than CodexSandboxOffline; do not rely on USERNAME. Confirm the user can read the unchanged runtime and owns the new evidence location; stop rather than changing permissions on failure.
3. Select a **new, nonexistent user-owned environment-smoke directory**, separate from attempt 01. Never use a service data directory. Use the same private binaries by absolute path, with verified hashes and bin-prefixed PATH; record COMSPEC and working directory. Scrub inherited connection settings/credentials and record only allowlisted, nonsecret environment fields.
4. Under separately approved smoke scope, initialize and start only that fresh cluster, with a unique marker, explicit loopback/random port, max_connections <=10 and bounded startup. Keep default PostgreSQL restricted-token logic. On any restricted-token/error diagnostic, stop immediately even with exit 0; preserve raw output and make no automatic retry or privilege change.
5. Only if separately authorized in that smoke scope, connect to that owned endpoint for identity/version/isolation checks; compare server address, port, marker, data directory, postgres session/current user and READ COMMITTED. No business schema or Stage A/B migration. Extension installation/loading/version probes must also be expressly within that future local smoke approval; file metadata alone does not verify them.
6. Stop only the verified owned cluster using its absolute data path and bounded shutdown. Record attempted/not-started/started/stopped/cleanup-uncertain states separately. Retain logs and confirm the matching PID is gone; do not stop any existing instance or delete evidence.
7. Compare outcomes without assuming causality: normal-user success with unchanged binaries supports an execution-context cause; the same token failure outside Codex weakens that hypothesis and requires a later Windows/token/binary investigation. Do not broaden diagnostics or change security settings automatically.
8. Stop and report the smoke result. Even a successful environment recovery does **not** authorize a C.5 rerun or complete its missing fixtures, database checks or correction-order scenarios. Obtain separate approval for those next steps.

All future results using 3.6.2/4.0.1 remain NON-PARITY. Exact-version parity remains BLOCKED. No DEV/shared/live connection, operational export or executable upgrade package belongs in recovery.

## 7. Proposed harness improvements — not applied

- Capture stdout and stderr separately into retained files, plus command, exit status, duration and allowlisted context. Flush diagnostics before raising, including on subprocess timeout/exception. Preserve both streams even if one contains a success message.
- Introduce a fail-closed startup result classifier. Any nonzero exit, restricted-token creation/re-execution message, process-launch error, fatal/panic or contradictory error/success output makes the environment unusable. Inspect both streams regardless of exit 0; for these utilities treat explicit initdb/pg_ctl error diagnostics as blockers. A success substring cannot override an earlier error.
- After initdb, run that classifier **before** writing configuration or invoking pg_ctl. The two saved initdb error lines from attempt 01 must yield BLOCKED and assert zero subsequent pg_ctl/psql calls. This can be verified with mocked subprocess records after approval, without launching PostgreSQL.
- Replace assertions for safety gates with explicit exceptions and typed outcomes. Python optimization must not disable endpoint ownership, input integrity or baseline gates. Label infrastructure failure ENVIRONMENT_BLOCKED; retain its underlying failing operation without calling it a migration failure.
- Separate environment-only mode from assembly/tests, with a positive stop/return after smoke completion. The default must not progress into migrations merely because startup succeeded. Accept no external DSN and retain the existing explicit loopback ownership checks and connection-environment scrub.
- Record actual Windows token principal, intended binary hashes, COMSPEC/PATH provenance and new-directory ownership before startup. Stop on ambiguous identity, stale paths, mismatched binaries or unavailable required diagnostics; never add privileges or repair ACLs automatically.
- Track startup attempted, process observed, identity verified and shutdown confirmed independently. Missing postmaster.pid alone is insufficient proof of cleanup after ambiguous partial startup. Ensure a try/finally retains diagnostics and records cleanup uncertainty without overriding the first error.
- Use monotonic whole-run/scenario deadlines and bounded subprocess calls. Do not implement automatic retry, fallback identity, PG_RESTRICT_EXEC override, source-guard weakening or extension-version substitution.

## 8. Decision

**Read-only investigation complete. Runtime recovery untested; Stage C.5 remains BLOCKED and incomplete; DEV remains NO-GO.** The recommended next approval is a normal-user-terminal, environment-only comparison with immediate diagnostic stop gates. No correction was applied and no testing is authorized by this report.
