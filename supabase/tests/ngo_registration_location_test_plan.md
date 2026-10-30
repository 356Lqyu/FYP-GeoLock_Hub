# Role onboarding and trusted location test plan

These are future tests for a disposable isolated DEV database only. Never run
them against the shared project `mffccmlimmbrgasgfnnq`. Do not create synthetic
road nodes or weaken location/claim authorization to make a scenario pass.

The revised flow creates the NGO account and role profile without an operating
location. After email verification and login, the user previews a location with
the authenticated `preview_location_routing()` RPC; the mutation RPC resolves
the node again and refreshes eligibility in the same transaction.

## Registration and onboarding

| Case | Expected result |
|---|---|
| DONOR registration | User, role and donor profile are committed; no location is requested or stored. Donor dashboard opens after login. |
| NGO registration without location | User and NGO identity fields are committed with nullable location fields; login succeeds and SessionRouter shows location setup. Discovery/claims remain unavailable. |
| HUB_ADMIN registration | User and hub-admin profile are committed without manual approval; login succeeds and SessionRouter shows hub registration. |
| Immutable role | A second `register_role_profile()` call for the same user is rejected; update RPC cannot change `user_profiles.role`. |
| Missing role metadata | Login succeeds but no profile is silently created; the app shows the missing-profile path. |

## NGO operating location

Use eligible route points chosen from the approved operational graph; never
trust a client-supplied road node.

| Case | Expected result |
|---|---|
| Valid point | `set_ngo_operating_location()` stores the resolver's node, timestamp and address; eligibility refresh and audit commit in the same transaction. |
| Invalid coordinates | RPC rejects; prior profile and eligibility remain unchanged. |
| Outside coverage / no node within 500 m | Preview reports unavailable or unroutable; authoritative RPC rejects without partial updates. |
| Client node tampering | No road-node parameter is accepted by the setter; stored node comes from `geolock_resolve_road_node()`. |
| Active claim | Location change rejects while claim/lease is ACTIVE. |
| Unresolved expired claim | An expired lease whose claim is still active, or any reconciliation case, blocks location change until safe recovery/reconciliation. |
| Properly released/expired claim | Matching terminal claim and lease states do not block location change. |
| Completed claim | Matching completed claim and lease do not block location change. |
| Claim/location race | Compete `claim_listing()` and location change for the same NGO. The NGO profile row lock serializes both; a successful claim prevents the location update, while a location update that wins is revalidated by the later claim. |
| Eligibility refresh failure | In a disposable database only, force the refresh dependency to fail; the location update, audit and cache changes must roll back together. |

## Hub onboarding and editing

| Case | Expected result |
|---|---|
| Valid hub | Hub location resolves server-side within 500 m; capacity 50–250 kg; hub becomes active only after validation. |
| Invalid/uncovered hub | Registration rejects atomically; no active or partial hub remains. |
| Client road-node tampering | Supplied `p_road_node` is ignored; the trigger/resolver determines the stored node. |
| Location/capacity edit with no commitments | Database revalidates changed road location and accepts allowed capacity. |
| Active stored inventory | Location or capacity change rejects. Name-only edit may proceed. |
| Active reservation, including expired-but-still-ACTIVE row | Location or capacity change rejects until reservation lifecycle resolves it. |
| Active batch membership or DRAFT/PUBLISHED/CLAIMED batch | Location or capacity change rejects. |
| Concurrent reservation/receipt/batch writer | Hub row lock serializes the edit with those writers; after the winner commits, the edit either sees the commitment and rejects or safely applies first. |

## Profile editing and profile reads

- Donor may update full name and phone only.
- NGO may update full name, phone, NGO name, registration number, and operating location through the protected location RPC.
- Hub admin may update full name, phone and permitted hub details through protected RPCs.
- Email and role are not update RPC parameters.
- `get_my_profile()` returns onboarding status with no road resolver, route-cost, or eligibility-refresh calls.
- Measure the query under an authenticated session and confirm it completes within the DEV statement timeout; the local source review cannot establish live query timing.

## Safe execution sequence

1. Confirm the migration version and read-only readiness results in isolated DEV.
2. Create fresh, disposable Auth users through Supabase Auth. Do not copy users or profile data from another project.
3. Use authenticated sessions for role registration, location previews, setup RPCs and profile updates.
4. Verify committed rows and audit entries through read-only queries after each successful or rejected attempt.
5. Keep forced rollback and concurrency tests in a disposable branch/database; never install test failpoints in the shared project.

No database integration test in this plan has been executed by the local source checks.
