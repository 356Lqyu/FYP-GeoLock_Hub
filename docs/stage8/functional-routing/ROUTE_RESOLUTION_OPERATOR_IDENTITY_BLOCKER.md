# LOCAL security hold — restricted resolver audit attribution

**Historical hold; resolved locally by the subsequently approved D02 correction.**
See ROUTE_RESOLUTION_RELEASE_GATE.md for current hashes and results: 79 disposable
SQL tests, 150 Python tests and 97 Flutter tests PASS; no remaining test failures.
The original failing evidence below is preserved. Deployment remains HOLD, with
fixture visibility still an unresolved acceptance gate. No DEV action occurred.

29 October 2026. **NOT READY. Implementation stopped under the user's explicit
security-issue STOP condition. No DEV access or deployment occurred.**

## Confirmed defect

`resolution_private.operator_key()` authorizes the native resolver using trusted
`session_user` membership and an active named mapping. However,
`resolution_private.audit()` chooses actor_user_id/actor_role from `auth.uid()`
and records operator_principal only when auth.uid() is NULL.

A native PostgreSQL caller can set custom JWT GUCs. The dedicated, correctly
mapped LOCAL resolver set request.jwt.claim.sub to the synthetic owning NGO. With
all normal custody/consent/version checks satisfied, finalization committed in
the disposable database. The ROUTE_ABANDONED_RECONCILED audit event recorded:

- actor_role: NGO
- actor_user_id: the supplied synthetic NGO
- operator_principal: NULL, instead of geolock_local_resolver

This violates approved D02 trusted operator attribution. It does **not** demonstrate
unauthorized finalization or bypass of two-party evidence: the caller remained a
valid restricted resolver and all release checks still ran. The private receipt
actor key still identifies the resolver; the defect is incorrect audit attribution,
including the risk of misattributed legacy donation-transition audit events.

## Actual evidence

- Regression: test_resolver_session_cannot_spoof_audit_actor in
  C:/Users/User/Downloads/FYP-GeoLock_Hub/supabase/tests/route_resolution_api_isolated_test.py
- Evidence directory:
  C:/Users/User/Downloads/FYP-GeoLock_Hub/results/automatic-routing-local/20261029T091549Z-8d842f
- resolution-operator-identity-gap.json: confirmed observed values above.
- resolution-api-bridge-summary.json: FAIL, 1 test, 1 failure, 0 errors.
- cluster-stop.json: stopped=true, remote_connections=0.
- input-integrity-final.json: no input drift.

The test is deliberately failing, not skipped or marked expectedFailure. Current
default bridge suite includes this regression and must not be represented as PASS.
Earlier three positive adapter/isolation tests passed against identical SQL/API
implementation bytes before this additional test was added.

## Smallest proposed correction — NOT APPLIED

1. Reject mixed native-resolver/JWT identity context in the shared restricted
   operator helper **before receipt replay, locks or writes**. Cover both legacy
   request.jwt.claim.sub and JSON request.jwt.claims forms; invalid context must
   fail closed. Do not merely clear arbitrary caller context and continue silently.
2. Derive resolver audit attribution explicitly from the trusted database login
   and active mapping, independent of caller-supplied JWT GUCs. Keep participant
   JWT attribution for ordinary authenticated NGO/source operations.
3. Verify existing donation-transition audit helpers cannot inherit a forged NGO
   subject during finalization. Do not weaken guards or rewrite historical audits.
4. Extend rejection/receipt-replay/no-write/audit tests, then rerun the 70-scenario
   suite, API bridge and applicable regressions. Repin this same LOCAL forward
   migration and function fingerprints; do not create a duplicate migration.

No change to the recovery function/scheduler, lease deadlines, frozen graph,
algorithms, NGO finalization permissions or live data is needed or authorized.

## Required next decision

Approve the narrow LOCAL-only operator-context rejection and trusted audit-identity
correction above, plus disposable regressions. The user explicitly required STOP
on a security issue; that is why the approved implementation was not silently
changed further. No deployment or existing-route action is requested or permitted.
