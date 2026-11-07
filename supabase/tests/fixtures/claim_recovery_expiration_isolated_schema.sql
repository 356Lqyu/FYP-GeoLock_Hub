-- Disposable PostgreSQL fixture ONLY. Never execute in Supabase.
-- Reduced tables and auth stubs, not a copy of the complete production schema.
create role anon;
create role authenticated;
create role service_role;
create schema auth;
create schema extensions;
create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
create function auth.role() returns text language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.role',true),'') $$;
create table public.user_profiles(user_id uuid primary key,role text);
create table public.coordination_config(singleton boolean primary key,config_version text,claim_lease_minutes integer check(claim_lease_minutes=360));
insert into public.coordination_config values(true,'isolated',360);
create table public.donations(
  donation_id uuid primary key,collection_path text not null,
  donation_status text not null,total_weight_kg numeric not null,
  updated_at timestamptz default clock_timestamp(),
  check(collection_path in('DIRECT_PICKUP','HUB_COLLECTION')),
  check(donation_status in('SUBMITTED','AVAILABLE','HUB_ASSIGNED','AT_HUB','BATCHED','CLAIMED','PICKUP_IN_PROGRESS','COLLECTED','CANCELLED'))
);
create table public.hub_batches(batch_id uuid primary key,hub_id uuid not null,batch_status text not null,batch_donation_count integer not null);
create table public.listings(
  listing_id uuid primary key,source_type text not null,donation_id uuid references public.donations,
  batch_id uuid references public.hub_batches,listing_status text not null,
  listing_expires_at timestamptz,listing_version integer not null default 1,
  check(listing_status in('AVAILABLE','CLAIMED','CLOSED','CANCELLED')),
  check((source_type='DIRECT_DONATION' and donation_id is not null and batch_id is null)
     or (source_type='HUB_BATCH' and batch_id is not null and donation_id is null))
);
create table public.donation_claims(
  claim_id uuid primary key,listing_id uuid not null references public.listings,
  claim_status text not null,claimed_at timestamptz not null default clock_timestamp(),
  closed_at timestamptz,close_reason text,
  check(claim_status in('ACTIVE','RELEASED','EXPIRED','COMPLETED','CANCELLED','RECONCILIATION_REQUIRED'))
);
create unique index ux_active_claim on public.donation_claims(listing_id)
  where claim_status in('ACTIVE','RECONCILIATION_REQUIRED');
create table public.claim_leases(
  lease_id uuid primary key,claim_id uuid unique not null references public.donation_claims,
  lease_status text not null,issued_at timestamptz not null,expires_at timestamptz not null,
  closed_at timestamptz,release_reason text,
  check(expires_at>issued_at),
  check(lease_status in('ACTIVE','EXPIRED','RELEASED','COMPLETED','RECONCILIATION_REQUIRED'))
);
create table public.pickup_tasks(
  task_id uuid primary key,claim_id uuid unique not null references public.donation_claims,
  listing_id uuid not null references public.listings,task_status text not null,
  route_snapshot text not null default 'unchanged-fixture-snapshot',
  check(task_status in('CONFIRMED','PLANNED','DISPATCHED','COLLECTED','CANCELLED','STALE'))
);
create table public.hub_batch_members(batch_id uuid references public.hub_batches,
  donation_id uuid references public.donations,membership_status text not null,
  primary key(batch_id,donation_id));
create table public.hub_inventory(donation_id uuid primary key references public.donations,
  hub_id uuid not null,inventory_status text not null);
create table public.active_task_route_assignments(task_id uuid primary key references public.pickup_tasks);
create table public.pickup_route_stops(task_id uuid primary key references public.pickup_tasks);
create table public.claim_reconciliation_cases(
  case_id uuid primary key default gen_random_uuid(),claim_id uuid unique references public.donation_claims,
  listing_id uuid references public.listings,donation_id uuid references public.donations,
  source_type text,case_status text not null
);
create table public.audit_events(
  event_id uuid primary key default gen_random_uuid(),occurred_at timestamptz default clock_timestamp(),
  actor_user_id uuid,actor_role text,entity_type text,entity_id uuid,event_type text,
  claim_id uuid,lease_id uuid,correlation_id uuid,previous_state text,requested_state text,
  resulting_state text,reason_code text,outcome text check(outcome in('SUCCESS','REJECTED','ERROR')),
  software_version text,configuration_version text,details jsonb
);
