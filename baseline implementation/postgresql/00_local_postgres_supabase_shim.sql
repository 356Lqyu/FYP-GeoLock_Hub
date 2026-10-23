-- STEP 0 — PLAIN POSTGRESQL ONLY. Do NOT run this on a Supabase project or on Supabase
-- CLI (`supabase start`): they already provide everything below.
--
-- The GeoLock schema was written for Supabase. A plain PostgreSQL server lacks four
-- Supabase objects the schema and the claim functions use. This file creates the
-- smallest stand-ins, with the same names and behaviour:
--   * roles anon, authenticated, service_role
--   * schema auth with table auth.users(id)
--   * auth.uid()  -> the user id ("sub") of the current request
--   * auth.role() -> the role of the current request
-- Supabase sets the request identity in the setting `request.jwt.claims` (JSON).
-- The E2 baseline driver sets the same setting, so the claim functions run unchanged.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin; end if;
end $$;

create schema if not exists auth;
create table if not exists auth.users (
  id    uuid primary key,
  email text
);

create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', '')::uuid
$$;

create or replace function auth.role() returns text
language sql stable as $$
  select nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'
$$;

grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.role() to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;
