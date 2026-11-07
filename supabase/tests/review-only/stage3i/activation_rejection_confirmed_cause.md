# Confirmed attribution: older expired manifest in SQL Editor

User reports failure around 2026-10-23 19:32 MYT, entire unedited SQL text executed,
and baseline_at from that actual SQL: 2026-10-23 11:26:29.48348+00.

Exact file/manifest comparison confirms this timestamp belongs to
phase2_final_refresh_20261023_112629, NOT phase2_final_refresh_20261023_113154.
The two activation files differ only in their embedded baseline_at values.

| Package | Baseline UTC | Readiness expiry MYT | Activation SHA-256 |
|---|---|---|---|
| 112629 | 2026-10-23 11:26:29.483480 | 2026-10-23 19:29:29.483480 | 86D4E2A5E6F1C526B07DE030F2F53D4464A6CAB56BCE8A8A59446CB5B9E6E824 |
| 113154 | 2026-10-23 11:31:54.423718 | 2026-10-23 19:34:54.423718 | 1D79F008BC1640F7CDC7D787055D18439B1D8107EC42FB3AA6BE92CD4C49AD6E |

At the reported approximate 19:32 attempt, the executed older baseline was about
5m30s old. Its exact failing freshness condition was:

```sql
(v_manifest->>'baseline_at')::timestamptz < clock_timestamp()-interval '3 minutes'
```

The older package had already expired about 2m30s earlier. The reported baseline
therefore establishes older-manifest execution and explains the combined guard
error. The complete pasted bytes were not independently captured/hashes verified
in SQL Editor; attribution of the manifest is exact, while attribution of every
byte to the older file relies on the user's unedited-copy confirmation. No error
timestamp log was available; approximate execution time is user-supplied.

No missing operator field or NULL stop_at correction is indicated. Operator and
maintenance were already populated, and final wrapper computes stop_at at runtime.
Later SQL Editor diagnostics confirm postgres/postgres and UTC. The local 113154
file genuinely contained its newer baseline, and all its predicates passed in
our 19:34:47 check; there is no inconsistency once different manifests are identified.

The guard correctly rejected stale evidence before cron.alter_job. No guard defect
or safety bypass is indicated. No fields should be hand-edited to revive an expired
package. Both packages are now obsolete for execution.

Live SELECT-only check at 2026-10-23 11:41:22.696119 UTC: job 3 inactive, exactly
12 succeeded historical runs, zero unfinished/new recovery run; target remains
ACTIVE/ACTIVE, task CONFIRMED, listing/donation CLAIMED, version 2/generation 1,
original lease deadline unchanged. Previous read-only full scoped snapshot check
also matched Phase 1. No activation/recovery persistent effect was found.

No new execution package was prepared, no guard was modified, no DEV mutation,
recovery, cron operation, migration or shared-project access occurred. Wait for
separate explicit approval before preparing another attempt. For that future review,
replace the SQL Editor tab's entire content with one newly reviewed file, confirm
its embedded baseline/checksum against the same package, and never reuse an old
tab or change only baseline_at. These are future review instructions, not approval.
