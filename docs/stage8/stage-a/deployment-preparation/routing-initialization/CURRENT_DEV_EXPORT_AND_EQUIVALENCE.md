# Current DEV road export and storage-equivalence verification

Prepared 27 October 2026 MYT. **READ ONLY. No policy installation, freeze, activation, recovery, fixtures or migration.**

**Hold the full-export command below.** Latest post-reset diagnostic `20261026T174046Z-f90cdc` still reported an authentication-failure phrase before any SQL. See [POST_RESET_AUTHENTICATION_REVIEW.md](POST_RESET_AUTHENTICATION_REVIEW.md) for the next **manual independent native-client test** and qualified pooler/cache/client hypotheses. No full export or automatic authentication retry is authorized here.

## Actual result now

**Full current-DEV equivalence: NOT VERIFIED — no current export has been captured or compared.** The approved account needs a password entered in your local console. No password was obtained from the environment, repository or chat, and no export connection was attempted by Codex.

Completed preparation/evidence:

* Approved `geolock_dev_owner_export` profile matches the intended project `rcgyuwiidqvrgbxswhqj`, session pooler `aws-0-ap-northeast-2.pooler.supabase.com:5432`, database postgres, project-scoped approved export login, `sslmode=verify-full`, supplied CA certificate and `default_transaction_read_only=on`. Certificate file is present. These are local checks; the exporter's actual TLS/account check happens before exporting.
* Available Python client: psycopg3.3.6 / libpq18.4. This is a protocol/COPY client compatible with server17, not pg_dump; pg_dump's server-major export restriction does not apply. The exporter checks actual server major17 before copying.
* All three reference files match their prior pinned SHA-256. A new offline full reference scan checked 926414 node records and 2145828 directed edges, strict unique key order and the expected REAL-output precision. This is reference preparation, not a current-DEV comparison.
* Six in-memory/local-source checks passed, including exact halfway rounding, a decimal above a halfway point that would suffer double rounding, wrong edge direction/missing keys, and routing precision rejection. No database or fixture files were created by these tests.
* A small explicit READ ONLY MCP query, observed **01:01:25 MYT on 27 October**, checked seven REAL conversions and the single coverage relation. Canonical binary32 expectations match SQL for all seven values. Actual active/approved OPERATIONAL coverage, provenance, counts, 500m snap limit, valid two-dimensional MULTIPOLYGON/SRID4326 and full coverage WKB match the pinned import SQL. Geometry WKB SHA-256: `4fbceda7f5d5c6196c484719d1c7b982a237b1f76d921e66cfecaf6adeb64361`. No nodes/edges scan or pgRouting computation was run through MCP.

Evidence lives under `results/routing-initialization-preparation/`: `export-preparation.json`, `reference-storage-check.json`, `read-only-conversion-and-coverage.sql/.json`, and `export-equivalence-preparation.json`.

## Exact local command

Run this in your own normal Windows PowerShell console. It requests the approved export-account password with hidden input. Do not paste it into chat. The Python entry point avoids changing Windows PowerShell execution policy.

```powershell
Set-Location 'C:\Users\User\Downloads\FYP-GeoLock_Hub'
& '.\.venv-stage8\Scripts\python.exe' -B '.\docs\stage8\stage-a\deployment-preparation\routing-initialization\export_current_dev.py' --export
if ($LASTEXITCODE -ne 0) { throw 'Export/comparison did not PASS. Preserve the reported directory and inspect its evidence.' }
```

No additional write authorization is needed for this read-only export. It cannot install anything. It parses the exact existing approved profile and supplies those connection values explicitly; the password is passed only in process memory to libpq, never in arguments, environment, files or reports. Do not use an installer/graph profile or change the account to overcome failure. A real console is required so a hidden prompt cannot fall back to echoed input.

Safe local preparation-only invocation, requiring no password/connection:

```powershell
& '.\.venv-stage8\Scripts\python.exe' -B '.\docs\stage8\stage-a\deployment-preparation\routing-initialization\export_current_dev.py' --prepare-only
```

## Exactly what happens

1. Recheck pinned reference inputs, unchanged policy hash/request, exact approved profile and CA. Create a **new** `results/routing-current-export/<UTC timestamp>-<random>/` directory only when executing the export; never overwrite or reuse an old directory.
2. Connect with the secure prompt, with read-only default enforced by connection options. Begin one `REPEATABLE READ READ ONLY` transaction. Set only transaction-local timeouts (statement60s, lock5s), UTC and `extra_float_digits=0`.
3. Before copying, check database/session identity, read-only mode, actual SSL, server major, SELECT/RLS coverage on the three road tables, and the relevant REAL/double/integer storage types. Abort on mismatch. Target attribution uses the exact project-scoped TLS connection plus identity evidence; there is no invented SQL project-id field.
4. Capture coverage metadata and WKB hash in that same MVCC snapshot. Stream both complete relations with `COPY (SELECT ...) TO STDOUT`; this writes **local files only**. Nodes ordered by OSM ID; edges by directed `(source_node,target_node)` primary key, avoiding server graph computation. No filters, cropped graph, temp tables, ANALYZE, DDL or DML. Store float8 coordinate and float4 cost network-order hex alongside profile0 text to avoid losing storage bits in CSV formatting.
5. ROLLBACK the read-only transaction. Record successful completion only after both streams, file hashes and rollback succeed. Preserve source identity/snapshot, types/access/coverage, exact query source hashes, file sizes/SHA-256 and receipt. Failure preserves partial files and an INCOMPLETE receipt; those files cannot produce PASS.
6. Automatically launch `verify_current_export.py` offline, with **no credentials or DB connection**. Reports are timestamped and never overwrite a previous comparison. If the local comparison hits its 180-second budget or terminates early, it records NOT VERIFIED/INCOMPLETE, never PASS.

Files: `nodes.csv`, `edges.csv`, `queries.sql` (query audit only; not a runnable installation), `receipt.json`, `equivalence-<UTC>.json`. Set aside roughly 0.5–1GB free disk and several hundred MB of local RAM. Source COPYs have 60s-per-statement bounds; actual remote transfer duration is unmeasured. A timeout is a stop, not permission to increase bounds automatically.

## Comparison criteria

| Area | Required evidence for scoped PASS |
|---|---|
| Capture | COMPLETE receipt, completed ROLLBACK, expected project/profile/identity/read-only/TLS, exact file checksums and recorded exporter/query-contract versions |
| Node IDs | Every pinned import ID present exactly once, no extras; count926414; exact snapshot/component/active metadata |
| Coordinates | Actual float8 storage bits equal conversion of original coordinate text to binary64; finite and in legal geographic ranges. No impossible exact-decimal requirement |
| Directed edge keys | Every `(source,target)` pair present exactly once, no extras/reversed substitutions; count2145828. Input and export order checked before streaming merge |
| Edge IDs | Current IDs positive, integer-range, unique; exact current ID→directed-pair mapping SHA-256 recorded. **Import CSV does not contain edge_id**, so historical ID equality is UNKNOWN, not guessed from row numbers or a 1..N assumption |
| Endpoints/coverage | Every current endpoint exists among current active nodes of the intended snapshot. Coverage full WKB/provenance/metadata matches the pinned SQL; active approved OPERATIONAL with intended counts/SRID/500m rule |
| Distance and time | Compare each directional field's actual float4 hex to the exact original decimal→binary32 nearest/ties-even conversion. No arbitrary epsilon, source-decimal equality, cost recomputation or rounding repair |
| Routing projection | Both values finite/positive. Actual serialized text agrees numerically with profile0 six-significant-digit REAL output and passes the real C.2 `numeric` validator: exact representation at <=6 fractional decimals |
| Reachability | Offline BFS on the **complete current exported directed graph**, all six distinct ordered journeys between the three stored diagnostic nodes, plus zero-hop self reachability. No cropped-search no-path assertions |

Costs use an integer-ratio conversion to avoid an intermediate binary64 double-rounding error. The imported decimal and expected binary32 value will usually differ: the reference scan found nonzero representational differences in **2145122 distance values** and **2142748 time values**. These are expected local conversion effects, **not observed DEV mismatches**. The report counts them separately and records maximum expected errors in km/minutes. Only a different actual storage bit pattern is a cost mismatch; no tolerance can hide it.

All mismatches are counted by category; first30 examples retained, without truncating mismatch totals. Missing/extra keys, type/header/order errors, failed hashes or interrupted scans cannot PASS. A comparison may complete with FAIL; a stopped comparison is NOT VERIFIED with progress/exception evidence. Successful export alone is not equivalence success.

To rerun offline only, preserving prior reports:

```powershell
$export = 'C:\Users\User\Downloads\FYP-GeoLock_Hub\results\routing-current-export\<actual-directory-printed-by-exporter>'
& '.\.venv-stage8\Scripts\python.exe' -B '.\docs\stage8\stage-a\deployment-preparation\routing-initialization\verify_current_export.py' --export-dir $export
```

Do not literally use the placeholder path. Share the completed directory path and reported verdict, never a password. Codex can review the receipt/report locally after the export.

## Limitations and next gate

Current DEV equivalence/reachability remains **NOT VERIFIED until this actual export and comparison finish**. Narrow coverage/conversion checks and reference scans must not be promoted into that verdict. Preserve all existing failed/successful backup directories.

A future PASS proves scoped road-data storage equivalence and the three diagnostic node pairs at the exported MVCC snapshot. It does not reconstruct the missing import builder, verify historical generated edge IDs, prove all roads/addresses covered, recompute every matrix/shortest-path time, establish live worker performance, validate restorability or authorize graph freeze. Generated geog/index/schema/ACL invariants are not re-audited by the CSV comparison. Receipt hashes are operator evidence, not signed remote attestation. Freeze approval must account for any network changes **after** export; pause maintenance or refresh evidence before cutover. The expired diagnostic claims remain ineligible and untouched.

Next: run the secure local read-only export, assess its exact report, then decide the separate policy and graph approvals. No write is implied by export success.
