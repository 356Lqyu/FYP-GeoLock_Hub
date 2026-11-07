# Route Resolution — prepared release controls (29 October 2026)

**LOCAL PREPARATION ONLY. NO-GO for migration execution until the controls below
are completed and separately approved. No new DEV connection, backup, pause,
grant, deployment or activation was performed during this preparation.**

## Configuration gates completed — do not repeat inspection

Reviewed existing operator captures only; no new DEV connection during review.
TimeZone PASS: addendum `20261029T123148Z-cc7dd0`, all 41 values UTC.
Cron-command PASS: equality capture `20261029T124544Z-88f173` at
2026-10-29 20:45:59 MYT, exit0, identity guard1, explicit READ ONLY and ROLLBACK.
One job3, expected name, postgres/postgres, active, every minute; exact known
command matches: batch1, lock5s, statement50s, no explicit BEGIN/COMMIT wrapper.
The trailing Stage3I comment caused the earlier whitelist rejection and has no
execution effect. Batch1 does not guarantee one successful release per minute.
Machine-readable local review and capture hashes: corresponding `review.json`.

**Fresh backup integrity/scoped-coverage gate is now PASS**; see the completed
capture below. Migration execution remains NO-GO until recovery-risk disposition
and operational release controls are satisfied. Do not rerun either capture.

## Completed read-only addendum procedure (reference only; do not rerun)

Historical operator command, already executed once:

```powershell
& '.\docs\stage8\functional-routing\Run-RouteResolutionPreflight.ps1' -Addendum
```

Uses only `geolock_dev_owner_export`, native psql17.11 and its hidden password
prompt; TLS verify-full with the approved CA. One connection, no fallback/retry.
SQL: `route_resolution_dev_addendum.readonly.sql`; SHA-256
`b0a4d712723956ef5c90385d04dbd82339b2ba8ba8139c5fe528e0fcf14fdad9`.
REPEATABLE READ, READ ONLY; statement15s / lock2s; explicit ROLLBACK.

Only captures case-insensitive TimeZone settings (41 expected from prior evidence)
and job3/name, actual batch argument or function default, timeout SETs and wrapper.
The command is disclosed only if it matches the narrow timeout/recovery whitelist;
unknown text stays redacted and requires review. The command is never executed.
Evidence goes to a new `results/route-resolution-dev-addendum/<UTC>-<suffix>/`.
Review exit status, identity, actual returned values, job identity/schedule and
command before clearing this gate. No existing full preflight is repeated.

## Fresh backup — completed and independently reviewed

Approved operator capture: `pre-route-resolution/20261029T124943Z-b031c5`.
Database and password-free roles export exit0; completed 2026-10-29 20:53:00 MYT.
Independent local review confirmed both hash manifests, nine files' sizes/hashes,
native pg_restore TOC/full decoding, 88 catalog relations and 143 function-name
entries without gaps, 143 function bodies against the fresh baseline and archive,
and nine routing-table metadata comparisons. One approved policy/graph, five
snapshots, two matrices/candidates/validations, one binding/request and three items.
Preserved route remains IN_PROGRESS, V2 version/binding and three assignments match
the captured inventory. This is coverage evidence, not a new live state inspection.
Review: `results/route-resolution-backup-review/20261029T124943Z-b031c5/review.json`.
Archive SHA-256:
`79393fc25bb89e90c7f3b8b1a3806c763f41aa0321b81ac58633324a1784fbc7`.
Restore readiness, exact full-row equivalence and external recovery remain NOT
VERIFIED. No restore, new backup, DEV access, ACL change or pause occurred during
independent review. Commands below are retained as procedure reference only.

```powershell
& '.\docs\stage8\stage-a\deployment-preparation\backup_pre003.ps1' -PreRouteResolution
```

The historical runner filename is retained; **do not use -PreFreeze, default
PRE003 mode or -PreAutomaticDeparture for this release**. The new purpose is
`PRE_ROUTE_RESOLUTION_CURRENT_DEV`. New private, Git-ignored directory:
`backups/stage-a003/pre-route-resolution/<UTC>-<suffix>/`, containing
`dev-pre-route-resolution.dump`, `roles-no-passwords.sql`, inventory, capture
receipt, TOC/schema, verification reports and SHA-256/file-size manifests.

Native PG17.11 only: unfiltered custom-format pg_dump, 5s lock wait; pg_dumpall
roles/memberships without passwords. Enter the approved owner-export password
only at each native hidden prompt. No password arguments, files, chat or logging;
no execution-policy bypass. Existing approved profile/CA are required; mismatches
stop rather than trying another profile. Previous backups remain untouched.

Before export, check actual identity/TLS/BYPASSRLS/SELECT coverage, the fresh
143-function body baseline, approved graph/policy and preserved route/V2 boundary.
The reviewed baseline file is hash-pinned to the successful existing DEV capture.
Verification requires exit0 for both exports, nonempty artifacts, TOC relation/data
coverage, full payload decoding to NUL, schema extraction, SHA-256 and scoped
function/policy/routing metadata comparison across nine routing tables. Failed
attempts receive FAILED status and are not verified recovery points.

After successful capture, optionally repeat **local-only** verification:

```powershell
& '.\docs\stage8\stage-a\deployment-preparation\backup_pre003.ps1' -PreRouteResolution -VerifyArchiveDirectory '<actual new full directory>'
```

The archive is one consistent DB snapshot; catalog and globals use separate
snapshots. No writers or cron are paused by this command. Concurrent changes can
cause comparison failure; stop/review, never auto-repair/retry. Record the eventual
capture-to-cutover gap. Private ACLs/Git exclusion are not encryption.

Included: database-resident Auth/Storage records, application data, functions,
policies, triggers, grants, graph and routing evidence. NOT included: Storage
object bytes, role passwords, Auth/provider service secrets/configuration, worker
credentials/journals, extension binaries and hosted infrastructure. Supabase-managed
roles/extensions require a compatible recovery environment. Decode/coverage PASS
does not prove restoration, complete row equality or managed-service recovery.
Require either separately approved isolated restore validation or a new explicit
DEV-only acceptance of these unresolved limitations; no restore is run here.

## Installation approval checklist (all mandatory)

- DONE: TimeZone and cron-command gates PASS from the captures above. No repeat requested.
- DONE: fresh backup integrity/scoped-coverage review PASS. Still required: this
  release's recovery-risk disposition, including restore deferral and cutover gap.
- Confirm named deployment/recovery operator (proposed: user), MYT window and
  approved `geolock_dev_installer` profile resolving to postgres in this DEV project.
  Owner-export access is not installation authority. No new identity is needed for
  default-disabled installation; no resolver login/operator mapping is created now.
- Explicitly approve and verify app-writer pause. **Account for active job3**:
  recommended short separately approved cron pause during cutover, record prior
  active state, wait for any in-flight run/other writer transaction to finish.
  Do not change schedule/command, create another job or terminate transactions.
  If a pause is declined, require a reviewed keep-active contention/state-change plan.
- Record current held-route/claims/audits baseline after the pause; execution guards
  must still match. No assumption that an idle sample proves writers paused.
- Accept UNKNOWN manual application history for this release, or supply history
  evidence. Existing evidence proves 143 function bodies/ownership/volatility,
  four migration guards and checked dependencies, not an audited migration ledger.
  Do not fabricate ledger records.
- Separately approve the exact migration and installer command after controls pass:
  `20261106_route_interruption_resolution.sql`, SHA-256
  `a8fc83b18da4ae13d771ae7ce513d5596a24cfbfdd8633d049da7da4db424020`.

Installation replaces donation/fleet guards and enables audit/task triggers
immediately, despite resolution config=false. Preserve existing role defaults,
verify explicit grants/revokes and compare unaffected functions postflight.
Existing migration transaction/5s lock/90s statement bounds fail closed. Error means
rollback; uncertain COMMIT means read-only inspection before any retry. No blind
DROP/down migration. A committed regression requires continued pause and separately
reviewed forward correction or separately approved recovery; never restore over DEV
automatically. Resume prior writer/cron states only after postflight and approval.

## Later gates — NOT default-disabled installation requirements

Exact synthetic fixture manifest and discovery isolation (acceptance55), restricted
resolver login/operator mapping, feature enablement, synthetic provenance registration,
pilot writes, Flutter build/install and institutional retention approval are separate
decisions. Keep config=false, mappings/registry empty and resolver NOLOGIN on install.
Installation never resolves the preserved route or releases V2. Existing recovery
function/schedule and frozen graph remain unchanged.

## Offline validation actually performed

Both `-ValidateOnly` modes PASS (connection_attempted=false); approved PG17.11,
service/CA, Git exclusion, baseline and unchanged migration hash validated.
11 synthetic Python tests PASS: old/new archive scope, composite duplicates,
missing/truncated COPY, body mismatches, purpose guards and addendum whitelist.
PowerShell parsing and pure native argument/inventory construction also checked.
No server execution, new backup integrity or restore result is claimed.
