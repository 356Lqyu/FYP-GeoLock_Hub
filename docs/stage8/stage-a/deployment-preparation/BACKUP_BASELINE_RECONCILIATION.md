# DEV backup baseline reconciliation

Read-only comparison for DEV project `rcgyuwiidqvrgbxswhqj`. No hosted writes, backup export or restore were performed during this comparison.

## Function body comparison

The backup inventory hashes `md5(replace(pg_proc.prosrc, CRLF, LF))`. Hashes reported from `md5(prosrc)` on DEV are raw CRLF hashes and must not be compared directly to those LF-normalized baseline values.

| Function | Earlier expected | DEV raw CRLF | DEV normalized | Approved source |
|---|---|---|---|---|
| `public.authorize_my_routing_candidate(uuid,uuid,timestamptz)` | `1c3c880e27da261a9a95a95730640196` | `2b8915723a7e64da22cf15ec3e80bc20` | `e383a34bfadba383cf71ac07b0854a47` | `20261104_routing_automatic_departure.sql`; its precondition is the earlier hash and its resulting body matches the normalized DEV body and local through-11/08 fingerprint. |
| `public.get_my_authorized_route(uuid)` | `5e6583e6092daf191eeca066f0b06ebe` | `0596290ef818cee486c0361fd1531471` | `d2e9e87bda5611f0a4afe2013a8f9235` | `20261108_per_stop_reconciliation.sql`; it starts from the pinned pre-deferral body `df7eb088b25c083673b223f164b7dcfd` and creates the resulting local/DEV body. |

These two differences are approved migration changes plus line-ending representation, not source drift. The normal current-state helper has been updated to the post-migration normalized values. The historical `route_resolution_backup_baseline.json` remains a source-capture artifact and is not rewritten to claim that its older capture observed later definitions.

The full function comparison found seven body differences. Six match the approved through-11/08 local chain and DEV: `fleet_private.route_vehicle_guard`, `public.enforce_donation_transition`, `public.get_my_authorized_route`, `public.submit_claim_reconciliation`, `routing_private.check_remaining`, and `routing_private.task_guard`. Those six values are recorded as a separately attributed Stage 8 baseline refresh; the original source capture hash remains historical. Nine route-resolution function fingerprints were also added from the disposable PostgreSQL 17 route-resolution test artifact and matched read-only DEV bodies and metadata.

`public.get_eligible_hubs(uuid)` remains unexplained. DEV normalized body MD5 is `1444c3c9a1cee2700426558ed95fdf58` (958 characters). Approved migration 20261020/local Stage 8 has `073ab402c8a196a36321e459f680c9cb` (3,670 characters). The DEV body delegates to `public.geolock_assert_donor_hub_choice` and `public.geolock_hub_candidates`, and includes an AI recommendation comment. The donor-choice helper checks for hub receipt, inventory, active batch membership, and active reservations, so custody checks in that helper are present. However, no approved migration defining this replacement body or `geolock_hub_candidates` was found in `supabase/migrations` or the Stage 8 forward chain. A read-only proposal file records an observed fingerprint; it is not an approved migration or authority to accept the body. DEV also grants `service_role` EXECUTE on `get_eligible_hubs`; the approved 20261018 grant contract grants authenticated and revokes PUBLIC/anon, with no service-role grant. These body and ACL differences are unexpected drift and backup blockers; no hash or grant is silently accepted.

## Other backup assertions

The inspected DEV graph digest/counts, policy ID/digest, preserved V2 route fields, and completed V3 route/receipt/audit fields match the script's pinned checks. The enabled routing authority trigger and routing-policy digest check also pass.

The historical `-PreRouteResolution` mode correctly requires `resolution_private` and nine route-resolution functions to be absent. Read-only DEV inspection found the schema and all nine functions. That mode is inapplicable to current DEV. A separate `-PreClaimScopedReconciliation` mode was added for the actual pre-20261109 state; it requires the legacy schema and all nine functions to be present, pins their local PostgreSQL 17 fingerprints, and retains route, vehicle, policy, and data guards. It does not weaken or relabel the historical mode.

## Error reporting and retry

`Assert-CurrentInventory` now emits a stable `BACKUP_INVENTORY_FAILED:<condition>` code, including the function signature and expected/observed normalized hashes for function mismatches. The checks remain fail-closed. No security, TLS, identity, role, coverage, schema-state or data-state assertion was removed.

The prepared command for the correct backup phase is:

```powershell
& '.\docs\stage8\stage-a\deployment-preparation\backup_pre003.ps1' -PreClaimScopedReconciliation
```

**Do not run it yet.** It should stop before archive export on the unexplained `get_eligible_hubs` body or ACL mismatch. Resolve this with an approved source/migration and permissions review, or a separately reviewed forward correction. Do not bless it by observation alone. Preserve every failed timestamped directory and its failure receipt.
