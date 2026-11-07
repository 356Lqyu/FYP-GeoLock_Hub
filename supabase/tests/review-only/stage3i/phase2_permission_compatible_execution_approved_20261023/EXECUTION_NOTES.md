# Human execution copy: Stage 3I Phase 2

**Completed historical execution copy. Do not rerun.** Stage 3I functional
recovery PASS and the paused final state are recorded in
[closure results](../closure/RESULTS.md). Permanent unattended recovery remains
NOT YET APPROVED. The instructions below describe the completed supervised test.

DEV rcgyuwiidqvrgbxswhqj only. Target claim:
8161392c-e1e1-4723-a954-c80b6b61a8c7. Operator: DEV Test Operator (myself).
Execution approval is recorded in operator_manifest.json and embedded in SQL.

Activation SHA-256:
4B80E7D9493E099B088E33077AFE3CC0B2E0B1F334F7BDD6E9E1B921DC77C824
Pause SHA-256:
834CA3455873EBF494A6D3F94D0357BB1F9DD22C5C6EEEC525BB74AB3E90DE86

Compared to the reviewed package, only execution_approved, approval_ref and the
first activation comment label changed. SQL statement bodies and every safety
guard are identical. All nine reviewed source checksums were checked first;
rendered checksums were independently verified. 106 offline contracts pass.
The prior 30 restricted-role isolated tests apply to unchanged SQL logic.

1. In a clean DEV SQL Editor session as postgres, keep competing application and
   cron/admin actions stopped. Keep eligibility jobs 1/2 running. Open the complete
   06_pause.sql in a separate ready tab. Review SELECT-only 01_preflight.sql,
   02_health.sql, 02b_custody.sql and 02c_permissions.sql from THIS folder.
2. Start your five-minute timer BEFORE Run. Run ALL of 03_activate.sql once,
   including BEGIN, standalone business locks, DO and COMMIT. Do not prepend
   queries inside its transaction or edit guards. Save activation_receipt and
   confirm COMMIT. No external three-minute deadline applies. The absolute UTC/MYT
   pause deadline is returned from the real activation-statement time plus 300s.
3. Poll 04_monitor.sql every 5-10 seconds. Execute ALL of 06_pause.sql immediately
   after the FIRST recovery outcome/error, or by the earlier of the timer and
   receipt deadline. Do not wait for Codex or eligibility completion. Missing
   receipt/unclear activation state means pause immediately. There is NO auto-pause.
4. Confirm pause COMMIT, job 3 inactive and no unfinished run. Run 05_verify.sql.
   Keep job 3 paused while eligibility generation 2 completes. Refresh Flutter
   read-only and report results. Retain the fixture/audits; no cleanup is authorized.

Stop on any failed guard, lock timeout/40001, extra recovery schedule, custody,
route/reconciliation evidence, wrong lifecycle/version/generation, missing or
duplicate audits, unrelated changes, unhealthy workers or lost supervision. Do
not bypass a guard or retry automatically. A paused job may still have an in-flight
run; pause does not undo committed recovery. If an old session is aborted, ROLLBACK
before further work. No new cancellation or corrective SQL is authorized here.

Remaining conditions: exclusive cron/admin coordination and continuous human
supervision are mandatory. Advisory locks protect participants only; job-3 row
locking is not a global cron freeze. Locks end at COMMIT before the async tick.
Native pg_cron scheduling/API implementation is not installed in the local fixture;
the approved review documents those test doubles and snapshot-time limitations.
The wrapper checks its supported-API row-lock postconditions before activation.

Codex performed no DEV access, writes, activation, recovery or deployments while
rendering this copy. Only the human operator executes the approved SQL.
