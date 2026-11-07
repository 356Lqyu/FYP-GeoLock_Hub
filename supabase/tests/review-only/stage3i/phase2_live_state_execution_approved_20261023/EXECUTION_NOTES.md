# Stage 3I supervised human execution copy

Explicit user approval to prepare executable SQL is recorded in the manifest.
Operator: DEV Test Operator (myself). DEV project: rcgyuwiidqvrgbxswhqj only.
Target claim: 8161392c-e1e1-4723-a954-c80b6b61a8c7.

The manifest differs from the reviewed copy only in execution_approved=true and
approval_ref. Reversing those two parameters restores every generated SQL byte
to the reviewed copy. All safety guards and statement bodies remain identical.
Timestamp strings are preserved exactly. Original review comments/phase label
remain unchanged; explicit approval is recorded in the two approval parameters.
The two health readers and pause SQL are byte-identical to the reviewed package.

Activation SHA-256:
60B919B6CF9719F996E15361E43069CBB65A7E0831AC9D55F821D3CC6924D6D2

Pause SHA-256:
834CA3455873EBF494A6D3F94D0357BB1F9DD22C5C6EEEC525BB74AB3E90DE86

Only the human operator may execute the approved SQL. Codex has made no DEV
database calls or state changes while rendering this execution copy. The existing
99 offline contracts passed. Prior 19 isolated wrapper tests remain applicable:
only approval parameters changed, no SQL logic changed or recovery source edited.

1. Open DEV Supabase SQL Editor as postgres. Stop competing application/admin
   actions, retain supervision, and keep jobs 1/2 running.
2. Open the complete 06_pause.sql in a separate ready tab. Open 03_activate.sql
   from THIS folder in a NEW tab. Verify its checksum. Do not use an older tab.
3. Run SELECT-only 01_preflight.sql, 02_health.sql and 02b_custody.sql for review.
   Stop on drift or unexpected evidence. Do not edit a failed guard to proceed.
4. Start a five-minute timer BEFORE clicking Run. Execute the COMPLETE 03 file
   once, including BEGIN and COMMIT. It performs fresh checks under NOWAIT locks;
   there is no external three-minute expiration to extend or bypass.
5. Save activation_receipt. Confirm COMMIT and job 3 active using SELECT-only
   monitoring. Receipt includes the actual activation-statement UTC timestamp
   and absolute pause deadline in UTC/MYT, exactly 300 seconds later. This anchor
   precedes ALTER/COMMIT, making the deadline conservative. Receipt alone is not
   commit proof; committed=false denotes its generation before COMMIT.
6. Run 04_monitor.sql every 5-10 seconds. Execute ALL of 06_pause.sql immediately
   after the FIRST outcome or error, or at the earlier of the receipt deadline
   and the timer started before Run. Do not wait for eligibility completion or
   Codex. If receipt/commit status is unclear, pause immediately. No automatic
   pause exists. If rejected, do not retry blindly; inspect read-only first.
7. Confirm pause COMMIT and job 3 inactive. Check for an unfinished run: pausing
   prevents new scheduling but does not cancel a running worker or undo recovery.
   Run 05_verify.sql and health queries. Keep recovery paused while eligibility
   generation 2 completes. Preserve fixture/audits and report results to Codex.

Expected: claim/lease RELEASED with EXPIRED_SAFE_RELEASE; task STALE; donation and
listing AVAILABLE; version 3/generation 2; correct two target-scoped audits; no
new reconciliation; unrelated records unchanged; generation-2 refresh COMPLETED.

Stop/pause on custody, routes, another candidate, reconciliation, worker errors,
unexpected states, missing/duplicate audits, unrelated changes, unhealthy jobs
1/2, lost supervision or unclear results. No manual recovery or corrective writes
are authorized by this copy. A guard failure leaves activation rolled back; if
the session remains in an aborted transaction, ROLLBACK before further work.

Locks end at COMMIT, before the asynchronous cron tick. Keep all competing actions
stopped for the whole window. This authorizes one supervised activation, not
permanent/unattended recovery or a guarantee of exactly one scheduler invocation.
The one-use command comment prevents reactivation with this same package after
pause. Detailed limitations remain in the reviewed package's README.md.
