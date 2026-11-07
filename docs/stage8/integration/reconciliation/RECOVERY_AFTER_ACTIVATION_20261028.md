# DEV recovery after activation: PASS for both investigated releases

Read-only inspection on 28 October 2026, 13:56–14:00 MYT. Confirmed project
rcgyuwiidqvrgbxswhqj, database postgres, supabase_read_only_user, READ ONLY.
No recovery invocation, business write, cron edit, role change or Flutter change.

## Cron outcome

Job 3 active, one matching recovery job, schedule '* * * * *', postgres/postgres.
Command unchanged: lock_timeout 5s, statement_timeout 50s, recovery(1), historical
Stage3I comment. Current recovery normalized body MD5 remains
89e01f42d5ec23bfcbcdc47c1f4fd4e5, ACL postgres/service_role only.

Six consecutive runs 13:51–13:56 MYT succeeded, each lasting approximately
0.26–0.56 seconds. Committed LEASE_RECOVERY audits independently establish one
safe release per minute, in expiry order: dd1be70f..., b4bea793..., ca8eb131...,
988b92f7..., 26265510... (test c), 84879ced... (Test 10). Zero overdue ACTIVE/ACTIVE
pairs remain. No failed job-3 runs since 13:45 MYT. No evidence of permission,
lock timeout, statement timeout or transaction failure preventing these releases.
Successful run output '1 row' alone was NOT used to infer processed counts.

## Exact targets

| Field | Test 10 | test c |
|---|---|---|
| Donation ID | 9505c1ad-2116-42cf-961f-8b883cf1aa62 | a09b3502-4113-4f5b-b74d-2eb7b01b6649 |
| Listing ID | 71d2e224-6fa8-487b-9b12-2eb8cbc29ad3 | 267369c2-d638-46be-9389-fa6347ed24dd |
| Claim ID | 84879ced-16b5-441e-9e3b-308283edf7be | 26265510-e487-4587-9557-f1a8bee6cc19 |
| Lease ID | 6fd552cc-4032-4300-9f93-a1c16b8fb07d | e46dd829-005d-4537-8dab-400fdef2c28f |
| Task ID | d7cdf0d8-72b5-41d0-b75d-f20fe8bae3f4 | 8ad61585-d5c2-41bf-829a-7f2cd13990e8 |
| Claim / lease | RELEASED / RELEASED | RELEASED / RELEASED |
| Listing / donation | AVAILABLE / AVAILABLE | AVAILABLE / AVAILABLE |
| Old task | STALE | STALE |
| Listing expiry | NULL | NULL |
| Lease expiry MYT, 28 October | 08:34:55.644637 | 08:34:51.414531 |
| Recovery audit MYT, 28 October | 13:56:00.420086 | 13:55:00.687403 |
| Recovery event ID | 2bd796e6-cc19-43ce-9eb0-0ba3cb3f3c9e | ef546198-8d76-4b79-a203-b10d7792de8c |
| Audit outcome / reason | SUCCESS / EXPIRED_SAFE_RELEASE | SUCCESS / EXPIRED_SAFE_RELEASE |
| Reconciliation cases | None | None |
| Snapshots / candidates referencing task | None / none via snapshot | None / none via snapshot |
| Route stops / assignments / private items | None | None |

Each also has its committed DONATION_STATUS_CHANGED -> AVAILABLE audit. Listing
version now 5, eligibility generation 3. All uncertainty guards allowed release:
uncollected DIRECT_PICKUP custody, no route evidence, no open case, no listing
deadline. Historical snapshots are not checked by recovery and did not block the
older three claims either. Existing four historical snapshots/one candidate were
not deleted by this investigation or recovery's release path.

## Discovery and another NGO

Generation-3 listing eligibility refresh completed successfully for test c at
13:56:01.438600 MYT and Test 10 at 13:57:03.439965 MYT. This is a separate
asynchronous step after recovery, so discovery need not update on the recovery tick.
Both listing/donation statuses and expiry now pass publication conditions.

Other active NGO 743cf8c1-12db-4c7d-8768-e584bae29c0e has location verified,
generation-1 NGO refresh COMPLETED and matching current road-node cache entries:
test c 0.569720km; Test 10 0.615690km, both ELIGIBLE within configured 20km radius
on OSM-OPS-20261018. The current owner's entries are also ELIGIBLE at 0.941550km
and 0.476330km respectively. Reviewed discover_eligible_listing_cards and
claim_listing source retains live status, expiry, identity, generation and road
eligibility checks. No test claim was attempted and no authenticated session was
impersonated. Actual future success remains subject to concurrent claim checks.

The read-only role is denied direct EXECUTE on geolock_road_eligible_km. This is
not a recovery/NGO permission failure. No grant or alternative credential was
used: conclusions above use catalog definitions and read-only underlying rows,
not a claimed successful authenticated discovery RPC. No expensive routing query.

## Flutter display and root cause

The reported pending state was valid until the fifth/sixth scheduled ticks.
Recovery was draining older claims first, one per minute; enabling cron is not
an immediate all-backlog release. Both are now definitively released in DEV.

Current source get_my_claim_cards includes historical claims. V2 returns actual
claim/lease states; lease_is_expired remains true on historical released rows,
but lease_recovery_pending is false because it requires ACTIVE/ACTIVE.
ClaimCard.displayStatus prioritizes reconciliation, then terminal claim states,
including RELEASED, before expired ACTIVE classification. These rows must render
Released in History/All after a successful fresh read, never Recovery Pending.

ClaimCardsController refreshes on pull-to-refresh; page initialization, auth
events, app resume and dashboard tab refresh signals also initiate a read. It
does not subscribe to realtime recovery changes or periodically poll already
expired claims. Its deadline timer watches only valid active claims; after it
fetches expired-pending rows it can retain them while the page remains open.
This explains a stale visible card after cron runs. The physical device's newest
RPC response was not captured in this investigation, so persistent error after
an actual fresh read is NOT yet proven or attributed to a particular APK.

Next read-only action: pull down My Claims to refresh, then select History or
All. Expected both badges Released; refresh Discover separately. If a successful
fresh read still shows pending, capture that timestamp, claim status/lease status
and pending flag (without tokens), and verify installed APK provenance before
changing code. Do not clear app data or operation IDs.

No SQL fix is indicated. Optional smallest UX improvement for separate approval:
bounded foreground read-only polling only while expired-pending cards exist,
cancelled on dispose/background/account change, with no recovery RPC or inferred
status transition; test pending->released, reconciliation, errors and cleanup.
No production changes or new lifecycle tests were made in this investigation.
