# Password input / libpq discrepancy — offline next stage

Prepared27 October2026 MYT. **No live authentication attempt, full export, database change or password inspection by Codex.**

## Confirmed findings

Latest Python evidence: `results/routing-connection-diagnostics/20261026T175647Z-c59e3e`, timestamp `2026-10-26T17:56:47.518948Z`. It reports connect-phase OperationalError, null SQLSTATE, server-style FATAL password rejection, with no recognized TLS/connection marker. No SQL or CSV export occurred. The approved parameters still match. Native psql17.11 session-pooler identity/TLS/read-only/rollback PASS remains owner-reported evidence; the successful process's actual password bytes were never captured and cannot be recovered here.

The richer Python flags make a simple unrecognized TLS error less supported, but still cannot tell whether the peer's FATAL came from Supavisor or PostgreSQL. They do not prove the supplied bytes matched the successful native attempt. No known libpq18.4 incompatibility is established by this response alone.

## Input path: an actual implementation difference

1. Exporter's installed Windows getpass uses `msvcrt.getwch()` and returns a Unicode string. Apart from Enter/backspace/Ctrl+C, characters are appended. Invisible input, cursor-key sequences and visually identical Unicode sequences can therefore matter. This is a possible mechanism, not evidence that the owner entered a different password.
2. The script passes that string directly as the explicit password keyword: no trim, normalization, URI encoding/decoding or environment/password-file replacement. Psycopg escapes the conninfo value; the inspected installed generator uses `conninfo.encode()` (UTF-8) before libpq. Dummy punctuation/quotes/backslash tests preserve the value. Actual credential content was not examined.
3. PostgreSQL17 Windows prompt source uses line-processed input, disables echo and reads console-input-code-page bytes through the C runtime. This differs from Python's Unicode path. [PostgreSQL17 prompt implementation](https://raw.githubusercontent.com/postgres/postgres/REL_17_STABLE/src/common/sprompt.c).
4. Byte differences may affect authentication, but SCRAM's SASLprep rules can normalize some UTF-8 passwords. Therefore raw-byte inequality alone is not a complete authentication diagnosis. [PostgreSQL SCRAM encoding rules](https://www.postgresql.org/docs/18/sasl-authentication.html).

No normalization, character stripping or console code-page change has been introduced into the actual exporter. Changing a known working credential to accommodate a client would not be justified.

## Negotiation and address selection

Host/port/database/pooler username, verify-full, CA, read-only startup option and15s connect bound match the reviewed native command. Server17.11 and native TLSv1.3 are confirmed by the owner. Client18.4 is a difference, not proof of failure.

Potential factors include SSL/SCRAM/channel-binding implementation/build defaults, pooler node/timing, and entry bytes. Profile values do not force a special authentication method or a newer frontend protocol. PostgreSQL documents default SSL negotiation aspostgres, channel binding asprefer for SSL builds, and protocol3.0 unless a newer feature requires otherwise. Actual failed negotiated authentication method/channel binding was not retained. Do not disable channel binding, weaken verify-full, force a different mechanism or upgrade/downgrade clients speculatively. [Official libpq connection options](https://www.postgresql.org/docs/18/libpq-connect.html).

**Correction to earlier descriptions:** the script makes one `psycopg.connect()` call, but the inspected psycopg3.3.6 implementation resolves hostnames, builds per-address attempts and loops over errors. It may aggregate several failures into one exception. One diagnostic invocation is therefore not necessarily one TCP/authentication attempt. The native libpq path also has address-selection behavior; actual selected IPs for the successful/failed sessions were not captured. No live DNS/authentication probe was run for this review. Further Python network trials are on HOLD.

## Next controlled action: offline input comparison

Tool: `compare_hidden_input_offline.py`. It makes **zero connections**, imports no export runner, writes no files and accepts no password argument/environment/file. Its local hidden prompts are optional and were not run with credentials by Codex. It prints only equality booleans and the public console code-page number. It never prints password characters, length, encodings/bytes, fingerprints or hashes. Secrets necessarily exist transiently in process memory; immutable Python copies cannot be promised secure zeroization.

The reference reader uses Windows `ReadConsoleA` with the same line-input/processed/echo-off principle as native psql and restores the prior console mode in finally. It checks echo is off before reading, and fails closed if no normal console is available. This is a **native-style proxy**, not instrumentation of the installed psql binary or reconstruction of the earlier successful input.

Within this one offline process it compares:

* Fresh native-style console bytes versus Python getpass input encoded asUTF-8.
* Native-style bytes decoded using the current input code page versus Python text, to separate a prospective text mismatch from same-text/different-byte behavior.
* Actual local psycopg conninfo construction/parsing of the Python value versus its originalUTF-8 bytes.

Equality uses comparison only, not credential hashing. No SQL, network, clipboard access, psql process injection or memory dump is involved. Buffer wipes are best effort. Do not start a transcript, redirect inputs, pipe secrets or run this under a debugger that captures locals.

Run locally in the same normal PowerShell/terminal context as the earlier tests:

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
& '.\.venv-stage8\Scripts\python.exe' -B '.\docs\stage8\stage-a\deployment-preparation\routing-initialization\compare_hidden_input_offline.py' --compare-offline
```

It offers two hidden local entries for the same verified value, first native-style and then Python. No credential needs to be shared in chat. **Stop after the booleans; do not follow with another connection attempt.** Exit0 means only this offline comparison agreed. Exit2 means one comparison/context check differed; exit1 means cancelled/unsupported/error. Empty entries or unavailable echo-off input cannot produce equivalence.

| Offline result | Interpretation / stop condition |
|---|---|
| Decoded text equal, bytes unequal | Current native-style/UTF-8 representation differs. Encoding path is implicated for these prospective inputs, but historical bytes and full SCRAM behavior remain unproven. No authentication retry or auto-reencoding. |
| Text and bytes unequal | Entry, invisible characters or code-page conversion loss may differ; do not guess which or send character details. Stop. |
| Conninfo roundtrip unequal | Construction/parsing problem observed locally. Stop; no network trial. |
| Console code page changed, read unsupported, cancellation/error | Comparison is not usable. Stop; do not enable echo or change the console code page to force success. |
| All comparisons true | Fresh inputs agree under this proxy and current terminal. Earlier native bytes, actual auth exchange, pooler node and driver compatibility remain unverified. Do not call this network equivalence PASS. |

Return only status and boolean names/values, not typed text, password length or character descriptions. The program creates no credential/equality report file; Codex can record the non-secret outcome only if the owner supplies it.

## Native psql export alternative

**Yes: reusing the already successful native17.11 connection path is the preferable operational fallback if Python authentication remains unexplained.** It avoids changing the password, privileges, TLS policy or Python auth dependencies, and keeps the protocol/password-input path that actually passed. This is an assessment, not authority to export now.

The native capture package must still be prepared/reviewed before use:

1. Existing approved service/profile and native hidden `-W` prompt; no password in arguments, environment, URI, passfile, repository or transcript.
2. One explicit REPEATABLE READ READ ONLY transaction, identity/TLS/SELECT/RLS/type checks before any COPY, same timeouts and profile0 projection.
3. `\copy (SELECT...) TO` new local files only, preserving full float4/float8 hex, node metadata, directed keys and actual generated edge IDs; no full-network server graph algorithm.
4. Metadata/coverage/source snapshot, sizes, hashes, success/rollback receipt and failure evidence in a fresh directory. Psql exit0 alone is insufficient.
5. Review a native-receipt contract in the offline verifier. The present verifier pins the Python capture implementation; do not forge a Python COMPLETE receipt or bypass provenance checks for native files.
6. Run the existing storage/precision/directed-reachability comparison offline only after an actual complete native capture. The superseded text-only export SQL is insufficient.

No native export command is supplied or run at this checkpoint. The next command above is offline only. If its outcome is unhelpful, prepare the native capture package rather than continue blind authentication attempts, credential resets or security changes. StageA003 stays closed; policy/graph/worker/recovery operations remain prohibited. **Current DEV network equivalence remains NOT VERIFIED.**
