# Stage 3I fixture creation: application workflows only, approval required

Prepared only. No DEV fixture exists or was created by this task. Never run local
fixture/schema scripts against DEV. No direct timestamp-update alternative is
offered: the normal protected claim workflow already supports a 360-minute lease.

1. Obtain approval for one disposable DEV test donation, its owner donor account,
   claiming NGO account and test location/photos. Use accounts already approved
   for DEV testing; do not borrow another user's session, impersonate auth.uid(),
   install a fake NGO profile or bypass real routing/eligibility.
2. Keep job 3 inactive; leave workers 1/2 active. Record the unique test title
   `STAGE3I-E2E-<new UUID>` and test account IDs. Use a donor-controlled, valid
   location within real directed-road eligibility of the chosen NGO. Do not edit
   graph data or relax the 20km directed route policy to make a test pass.
3. In the DEV Flutter app as the donor, create exactly one donation with that title,
   description identifying disposable DEV test data, one active category and a
   valid 20kg total (e.g. one item quantity 1, unit weight 20kg), and 1-3 benign
   test photos as required by the current app. Do not upload personal/sensitive
   images. If current configured threshold differs, stop and review; do not edit it.
4. The current app calls create_donation_with_images, which preserves photo
   security/idempotency and invokes the seven-argument creation function. No
   availability dates are added. Expected committed result: DIRECT_PICKUP donation
   AVAILABLE and DIRECT_DONATION listing AVAILABLE, NULL listing_expires_at, with
   normal item/photo/create audit and async eligibility processing.
5. Wait for real eligibility refresh completion. Sign in as the selected active
   and verified NGO; discover and claim ONLY this test listing in the app. This
   invokes claim_listing(listing_id,request_id), using a stable UUID per claim
   attempt. A rejected action is not permission to force-write states: investigate
   and stop or retry only through the normal workflow with correct idempotency.
6. Capture returned claim ID and actual lease/listing/donation/task IDs. Verify
   ACTIVE/ACTIVE, CONFIRMED task, CLAIMED listing and donation; no route, pickup,
   custody or reconciliation action. Verify claim expiry is approximately 360m
   after issued_at, with configuration still 360; snapshot its exact deadline.
7. Leave this claim alone and job 3 paused for at least its full six-hour lease.
   Use PostgreSQL statement_timestamp() for readiness. Do not alter issued_at,
   expires_at, claim/lease status, config, clocks, RPC body or listing expiry.
   Countdown/device time is not authorization or proof that expiry occurred.
8. When server time reaches the exact stored deadline, Flutter should show
   Expired - Recovery Pending. Do not press Start Pickup, cancel, assign a route,
   create another claim for this listing or invoke manual recovery.
9. Begin the separately approved short maintenance window. No other claim/recovery
   actions, fixture creation, cron edits or privileged coordination writes during
   the scheduler test. Resolve any other active/overdue claim by a separate review,
   never by including an existing user's record in this test.
10. Run rendered preflight with the actual IDs. Save its complete output externally.
    Merge proposed_manifest values into the local manifest; preserve account IDs,
    exact unique title and deadlines. Do not treat the suggested JSON as approval.
    The final baseline must be <=3m old at activation. Set stop_at to <=5m after
    the intended activation, identify the present operator and reference approval.
    Render fresh SQL copies, hash them, and review before activation.

Optional SELECT-only ID lookup after approved creation (replace exact title):

```sql
SELECT d.donation_id,d.donor_user_id,d.title,l.listing_id,c.claim_id,c.ngo_user_id,
       le.lease_id,le.issued_at,le.expires_at,t.task_id,
       statement_timestamp() AS server_now
FROM public.donations d
JOIN public.listings l ON l.donation_id=d.donation_id AND l.source_type='DIRECT_DONATION'
JOIN public.donation_claims c ON c.listing_id=l.listing_id
JOIN public.claim_leases le USING(claim_id)
JOIN public.pickup_tasks t USING(claim_id)
WHERE d.title='STAGE3I-E2E-REPLACE-WITH-EXACT-APPROVED-UUID';
```

If waiting six hours is unacceptable, this plan is NO-GO until an alternative is
separately justified and approved. No direct SQL shortening or 360-minute policy
change has been prepared, and no external/device clock override is acceptable.
