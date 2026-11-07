# Captured relation and default ACL inventory

Review only. Raw ACL strings and exploded grantor/grantee/privilege/grant-option entries are preserved in `captured/deployed-security-snapshot.json`.

All 36 public tables are owned by `postgres`, have RLS enabled and FORCE RLS disabled. Client grants below are explicit; no column ACLs, PUBLIC grants or inherited client role paths were found. None of the recorded client grants has a grant option.

| Table | Current anon and authenticated privileges | Proposed client privileges |
|---|---|---|
| `active_task_route_assignments` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `audit_events` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `claim_cancellation_requests` | none | none |
| `claim_leases` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `claim_reconciliation_cases` | none | none |
| `claim_reconciliation_evidence` | none | none |
| `claim_requests` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `community_hubs` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `coordination_config` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `donation_cancellation_requests` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `donation_categories` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `donation_claims` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `donation_create_requests` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `donation_images` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `donation_items` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `donations` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `donor_profiles` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `hub_accepted_categories` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `hub_admin_profiles` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `hub_batch_images` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `hub_batch_members` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `hub_batches` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `hub_inventory` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `hub_receipts` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `hub_reservations` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `listings` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `ngo_listing_road_eligibility` | none | none |
| `ngo_profiles` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `pickup_route_stops` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `pickup_routes` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `pickup_tasks` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `road_network_coverage` | none | none |
| `road_network_edges` | none | none |
| `road_network_nodes` | none | none |
| `user_profiles` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |
| `vehicles` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE | none |

## Sequence

`public.road_network_edges_edge_id_seq`, owner `postgres`; current raw ACL:

```text
{postgres=rwU/postgres,anon=rwU/postgres,authenticated=rwU/postgres,service_role=rwU/postgres}
```

Both clients lose USAGE, SELECT, UPDATE. `postgres` and `service_role` retain their exact existing entries. This is the identity sequence owned internally by `public.road_network_edges.edge_id`; no other public sequences or public views/materialized views/foreign tables were found.

## Default ACLs

No global pg_default_acl rows were present for these creators. The four table/sequence rows change; function defaults remain unchanged. ACL letters: a=INSERT, r=SELECT, w=UPDATE, d=DELETE, D=TRUNCATE, x=REFERENCES, t=TRIGGER, m=MAINTAIN, U=USAGE, X=EXECUTE. `grantee=privileges/grantor` records the source of each grant.

- Creator `postgres`, schema `public`, type `S` (remove only anon/authenticated entries):

  `{postgres=rwU/postgres,anon=rwU/postgres,authenticated=rwU/postgres,service_role=rwU/postgres}`

- Creator `postgres`, schema `public`, type `f` (unchanged):

  `{postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}`

- Creator `postgres`, schema `public`, type `r` (remove only anon/authenticated entries):

  `{postgres=arwdDxtm/postgres,anon=arwdDxtm/postgres,authenticated=arwdDxtm/postgres,service_role=arwdDxtm/postgres}`

- Creator `supabase_admin`, schema `public`, type `S` (remove only anon/authenticated entries):

  `{postgres=rwU/supabase_admin,anon=rwU/supabase_admin,authenticated=rwU/supabase_admin,service_role=rwU/supabase_admin}`

- Creator `supabase_admin`, schema `public`, type `f` (unchanged):

  `{postgres=X/supabase_admin,anon=X/supabase_admin,authenticated=X/supabase_admin,service_role=X/supabase_admin}`

- Creator `supabase_admin`, schema `public`, type `r` (remove only anon/authenticated entries):

  `{postgres=arwdDxtm/supabase_admin,anon=arwdDxtm/supabase_admin,authenticated=arwdDxtm/supabase_admin,service_role=arwdDxtm/supabase_admin}`
