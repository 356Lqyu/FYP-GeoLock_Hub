-- Minimal Supabase Auth compatibility for the disposable local E2 cluster only.
-- Apply only to the newly created geolock_e2 database by setup_local_e2.ps1.
-- This preserves the request.jwt.claims contract used by E2; it is not a hosted
-- Auth replacement and must not be applied to the GeoLock Hub application DB.

begin;

create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;

create schema auth authorization postgres;
create table auth.users (
  id uuid primary key,
  email text not null unique
);

create function auth.uid()
returns uuid
language sql stable
set search_path = pg_catalog
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
  )::uuid
$$;

create function auth.role()
returns text
language sql stable
set search_path = pg_catalog
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
    current_user
  )
$$;

revoke all on schema auth from public;
revoke all on auth.users from public, anon, authenticated, service_role;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
grant execute on function auth.role() to anon, authenticated, service_role;

create schema extensions;
create extension pgcrypto;
create extension postgis with schema extensions;

commit;
