-- Provision the target UUID for the dedicated local E2 database.
\if :{?e2_target_id}
\else
  \quit 3
\endif

begin;
create table public.e2_disposable_target (
  singleton boolean primary key default true check (singleton),
  target_id uuid not null unique,
  project_ref text unique check (project_ref is null or project_ref ~ '^[a-z0-9]{20}$'),
  provisioned_at timestamptz not null default clock_timestamp()
);
insert into public.e2_disposable_target(singleton, target_id, project_ref)
values (true, :'e2_target_id'::uuid, null);
revoke all on public.e2_disposable_target from public, anon, authenticated;
commit;
