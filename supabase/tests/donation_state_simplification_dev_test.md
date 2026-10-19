# Donation state simplification — isolated DEV acceptance checks

Run only in a disposable development project after applying
`20261019_remove_validated_donation_state.sql`. Do not point these checks at the
shared project. Use synthetic donor, NGO, hub, and image fixtures.

## Required cases

1. Submit valid donations weighing 9.9 kg, 10.0 kg, and 10.1 kg through
   `create_donation_with_images()` with one to three staged photos. Confirm the
   committed states are respectively `SUBMITTED`, `READY_FOR_PICKUP`, and
   `READY_FOR_PICKUP`; paths are `HUB_COLLECTION`, `DIRECT_PICKUP`, and
   `DIRECT_PICKUP`; only the direct donations receive one `AVAILABLE` listing
   with `listing_expires_at IS NULL`.
2. Submit a missing, empty, or whitespace-only description; missing/invalid
   items; inactive categories; invalid weights; missing photos; and mismatched
   staged-photo metadata. Each request must fail without a committed donation,
   item, listing, or photo metadata record.
3. Replay the same creation request and payload. It must return the same
   donation ID and leave row counts unchanged. Reuse the request ID with a
   different payload; it must be rejected.
4. Reserve a compatible hub for a <10 kg donation. Confirm one active
   reservation, `HUB_ASSIGNED`, correct capacity accounting, and a reservation
   expiry based on the configured 120-minute duration. Confirm receipt only
   while that reservation is active; expired reservations must be rejected.
5. Expire and reassign a reservation. The former reservation must remain
   `EXPIRED`, a new `ACTIVE` reservation must be created, and only one active
   reservation may exist. Verify hub capacity before and after reassignment.
6. Cancel an unreserved hub donation, an actively reserved hub donation, an
   expired-reservation hub donation, and an available direct donation. Verify
   each allowed result, reservation release/retention, listing cancellation,
   and audit event. Rejected cancellation after receipt, active claim, or
   uncertain handover must leave operational rows unchanged.
7. Attempt invalid status changes, including `SUBMITTED -> COLLECTED`,
   `READY_FOR_PICKUP -> AVAILABLE`, and any transition involving `VALIDATED`
   or `DELIVERED`. Each must fail. Confirm claim, lease, recovery, and pickup
   behavior remains unchanged.
8. Force an error after parent/item or listing creation inside a transaction.
   Confirm no partial operational or photo records commit.
9. After every committed operation, compare donation, item, listing,
   reservation, receipt, inventory, capacity, and audit rows. Do not use the
   HTTP/RPC response alone as evidence of commit.

## Post-deployment state checks

```sql
select donation_status, count(*)
from public.donations
group by donation_status
order by donation_status;

select count(*) as forbidden_status_rows
from public.donations
where donation_status in ('VALIDATED', 'DELIVERED');

select d.donation_id, d.donation_status, d.collection_path,
       d.total_weight_kg, l.listing_status, l.listing_expires_at
from public.donations d
left join public.listings l
  on l.donation_id = d.donation_id and l.source_type = 'DIRECT_DONATION'
where d.created_at >= now() - interval '1 day'
order by d.created_at;
```

These are manual integration checks; no DEV database test was run while
preparing this change.
