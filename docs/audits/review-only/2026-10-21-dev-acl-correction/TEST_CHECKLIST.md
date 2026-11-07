# DEV validation and acceptance checklist

No stateful test, RPC operation, object creation, Storage operation, migration or rollback was run during package preparation. Only catalog SELECTs and offline package checks ran.

## Before execution approval

- [x] Capture exact 36-table/one-sequence ACLs, applicable creator defaults, raw/exploded entries and grant options.
- [x] Check all PUBLIC/column/inherited-role paths; none preserves current client direct access. Review global vs schema-specific default privileges.
- [x] Verify exact 36 Flutter signatures, trusted owners, SECURITY DEFINER, search paths, authenticated/service_role EXECUTE and anonymous EXECUTE.
- [x] Review deployed helper/trigger/Storage dependencies and local test roles.
- [x] Run the exact SELECT-only preflight against DEV: all 12 sections match.
- [x] Validate all five future verification queries as reads before application; expected baseline differences are explicitly labeled.
- [x] Replay generated forward/rollback permission statements offline; exact semantic restoration passes, preserving other security sections.
- [ ] Review and accept the statements and intentional denial of direct client table/sequence operations, including metadata SELECT.
- [ ] Confirm a supported authorized supabase_admin execution path; postgres cannot perform that part.
- [ ] Confirm teammate/external consumers have no required direct client access; freeze DDL and future object creation.
- [ ] Recapture/compare immediately before execution; investigate all drift.
- [ ] Establish DEV baseline behavior for the functional cases below using existing synthetic fixtures. Read-only cases may be demonstrated separately; stateful cases need separate authorization. Do not run fixtures/legacy scripts automatically.
- [ ] Obtain explicit user approval to apply this package. Preparation approval does not authorize execution.

No full PostgreSQL DDL/PLpgSQL syntax/runtime validation has occurred. A schema-only disposable local clone could provide an additional dry run after separately authorized setup, but no local stack or clone was created and no changes were sent to DEV “just to roll them back”.

## After separately approved execution, before acceptance

Catalog checks:

- [ ] `11_verify_after_postgres.sql` passes after step 10; `30_postchange_verify.sql` passes after both parts. Save every result set, not just the final one.
- [ ] Both client roles have false for SELECT/INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER/MAINTAIN on all 36 public tables and USAGE/SELECT/UPDATE on the sequence.
- [ ] Owner and service_role privileges are unchanged; all 36 authenticated RPC grants remain true.
- [ ] All function definitions, owners, search paths and ACLs — including every anonymous grant — match the captured baseline.
- [ ] All role memberships, schema ACLs, RLS flags, triggers, Storage relation ACLs and policies are unchanged.
- [ ] No future public table/sequence defaults grant access through clients/PUBLIC/inherited roles for either creator; function defaults remain identical.
- [ ] No column ACL grants can preserve client data access.

Functional regressions with synthetic identities and fixtures:

| Area | Required outcome |
|---|---|
| Auth/onboarding/profile | Existing donor/NGO registration behavior and profile/dashboard RPCs match baseline; signed-in identities use the same ownership/role checks. No new registration policy is expected. |
| Donor/photo creation | Pending image upload → list/read/signed URL → create_donation_with_images → history/details/image RPCs still succeed for the owner. Missing/invalid mandatory photos still fail with baseline behavior. |
| Storage isolation | Authenticated unrelated identity and anonymous access to another owner's object remain denied. Required hub/claimed-donation photo access still succeeds; unattached own-image cleanup succeeds; attached-object deletion and UPDATE/upsert remain denied where policy requires. Run against the Storage API, not DELETE FROM storage.objects. |
| Hub flows | Eligible hubs, reservation, receipt, hub dashboard/inventory/reservation/batch reads, publish and batch image attachment follow baseline behavior. Invoker triggers retain required config/parent-lock access through trusted writers. |
| NGO flows | Discovery, constituents, claim, claim cards/details, pickup start/completion and reconciliation/audit reads follow baseline behavior and reject foreign identities as before. |
| Atomicity | A focused fresh-listing claim/replay and representative cancellation/receipt interaction produce complete committed artifacts/audit or the expected atomic rejection, with no permission-denied error inside nested triggers/helpers. |
| Trusted verification | service_role can still read committed public state through the supported API; postgres-controlled fixture/lock checks retain access. No service credential is used in Flutter. |
| Administrative road operations | Confirm permissions through catalog checks; no road import, graph activation or sequence increment is necessary just to test this ACL package. A future real import needs separate authorization and a retained trusted role. |

Direct-client negatives:

- Test anonymous/authenticated REST SELECT against a protected table and an image metadata table using zero-row/limited projections. Expect permission denial, not merely an RLS-filtered empty array.
- Catalog `has_table_privilege` / `has_sequence_privilege` checks are the acceptance evidence for INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER/MAINTAIN and sequence operations. **Do not execute TRUNCATE, trigger creation, maintenance, sequence nextval/setval or destructive writes to demonstrate denial.**
- If a client SQL-session permission probe is separately authorized, use only SELECT with zero-row predicates and rollback the test session. Do not spoof identities or expose JWTs in logs.

Use the current guarded `supabase/tests/claim_concurrency_test.py` (2/10 clients), recovery and hub runners only when their required fixtures and stateful execution are separately approved. Full fault injection, bulk fixture setup and 50-way concurrency are outside this ACL correction unless requested separately.

## Baseline discrepancies and failure handling

Some older readiness/preflight SQL files assert no anonymous RPC EXECUTE. This first correction deliberately leaves 30 Flutter RPC anon grants and other helper grants unchanged, so existing mismatches in those files remain. Treat them as separate authorization findings, not permission-restoration reasons.

The old recovery fixture setup contains VALIDATED transitions that may not match current deployed lifecycle constraints. Do not run it unchanged simply to satisfy this checklist. External routing consumers and legacy experiments need their own role/configuration confirmation.

A new permission-denied error on an intended RPC/Storage flow is an ACL regression until explained. Stop acceptance, preserve sanitized evidence and choose a narrowly reviewed fix or separately approved exact rollback. Do not restore blanket grants automatically.

## Offline reproduction

These commands read local captures/source and regenerate or validate review artifacts; neither connects to Supabase:

```powershell
python docs/audits/review-only/2026-10-21-dev-acl-correction/build_review_package.py
python docs/audits/review-only/2026-10-21-dev-acl-correction/validate_review_package.py
```

Run the builder only while preparing/reviewing a version, not after approval against a different capture. `CHECKSUMS.sha256` records the delivered package. Regeneration requires renewed review/checksums.
