"""Builds 02_app_claim_layer.sql from the app's deployed functions.

claim_listing(), recover_expired_claims() and their helpers are copied word for word from the
Supabase export in deployed_snapshot/, so E2 runs the same SQL as the Flutter app. Additions:
  table columns the deployed functions need (from the deployed schema and the migrations)
  geolock_ngo_listing_road_check(): same decision order as the app, but the road distance comes
    from the benchmark instead of the app's road network cache
  routing_private and resolution_private: empty stand ins, because E2 never routes a claimed task
Only needed again when the app's functions change.
Run from the repository root: python experiments/e2/database/build_app_claim_layer.py
"""
import csv
import hashlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
MIG = ROOT / 'supabase' / 'migrations'
EXPORT = HERE / 'deployed_snapshot' / 'dev_public_functions_2026-11-09.csv'
OUT = HERE / '02_app_claim_layer.sql'

DEPLOYED = [
    ('enforce_donation_transition', ''),
    ('geolock_lock_listing_donations', 'p_listing uuid, p_states text[]'),
    ('geolock_transition_listing_donations', 'p_listing uuid, p_from text, p_to text, p_claim uuid, p_request uuid, p_reason text'),
    ('geolock_transition_listing_donations', 'p_listing uuid, p_from text, p_to text'),
    ('claim_listing', 'p_listing uuid, p_request uuid'),
    ('recover_expired_claims', 'p_limit integer'),
]

ALIGN = r'''
-- Align the E2-relevant tables with the deployed public schema (deployed_snapshot/dev_public_schema_2026-11-09.txt).
-- Status CHECK values of listings, donations, claims, leases, requests and tasks already match.
alter table public.donations add column if not exists updated_at timestamptz not null default now();
alter table public.listings add column if not exists eligibility_generation bigint not null default 0;
alter table public.ngo_profiles add column if not exists location_generation bigint not null default 0;
alter table public.ngo_profiles alter column latitude drop not null, alter column longitude drop not null,
  alter column operating_address drop not null;
'''

STUBS = r'''
-- TEST DOUBLES for schemas the deployed functions reference only when a task is on a route
-- (routing worker) or under route resolution. E2 never routes a task, so these stay empty.
create schema if not exists routing_private;
create schema if not exists resolution_private;
create table if not exists routing_private.items(route_id uuid, task_id uuid, released_at timestamptz,
  consumed_at timestamptz, collected_at timestamptz, release_xid xid8, complete_xid xid8);
create table if not exists routing_private.bindings(route_id uuid);
create table if not exists routing_private.deferred_release_permits(task_id uuid, transaction_id xid8);
create table if not exists routing_private.deferred_stops(task_id uuid, status text, resolved_at timestamptz);
create table if not exists resolution_private.cases(route_id uuid, status text);
create or replace function routing_private.lock_route_for_recovery(p_route uuid)
returns routing_private.bindings language plpgsql as $s$ begin raise exception 'E2_STUB_CALLED: lock_route_for_recovery'; end $s$;
create or replace function routing_private.release_expired_unstarted_stop(p_claim uuid, p_task uuid, p_ngo uuid, p_route uuid)
returns boolean language plpgsql as $s$ begin raise exception 'E2_STUB_CALLED: release_expired_unstarted_stop'; end $s$;
create or replace function resolution_private.release_allowed(p_donation uuid, p_status text)
returns boolean language sql as $s$ select false $s$;
create or replace function routing_private.coord_release_allowed(p_donation uuid, p_status text)
returns boolean language sql as $s$ select false $s$;
'''

ROAD_CHECK = r'''
-- TEST DOUBLE: deployed geolock_ngo_listing_road_check() decision order and outcome codes; the road
-- distance comes from the benchmark directed road matrix instead of the app's pgRouting cache.
create schema if not exists e2_bench;
create table if not exists e2_bench.road_km(from_node text, to_node text, km double precision, primary key(from_node, to_node));
create or replace function public.geolock_ngo_listing_road_check(p_ngo uuid, p_listing uuid)
returns jsonb language plpgsql security definer set search_path to 'public','extensions','pg_temp' as $f$
declare v_n public.ngo_profiles%rowtype; v_l public.listings%rowtype; v_radius integer; v_km double precision;
begin
  select * into v_n from public.ngo_profiles where user_id = p_ngo;
  select * into v_l from public.listings where listing_id = p_listing;
  select geofence_radius_m into v_radius from public.coordination_config where singleton;
  if v_n.user_id is null or v_n.location_verified_at is null or v_n.latitude is null or v_n.longitude is null then
    return jsonb_build_object('outcome', 'ELIGIBILITY_UNDETERMINED');
  end if;
  if v_n.road_node_id is null or v_l.pickup_road_node_id is null then
    return jsonb_build_object('outcome', 'ROUTE_UNAVAILABLE');
  end if;
  if not extensions.ST_DWithin(
       extensions.ST_SetSRID(extensions.ST_MakePoint(v_n.longitude, v_n.latitude), 4326)::extensions.geography,
       extensions.ST_SetSRID(extensions.ST_MakePoint(v_l.pickup_longitude, v_l.pickup_latitude), 4326)::extensions.geography,
       v_radius) then
    return jsonb_build_object('outcome', 'OUTSIDE_GEOFENCE');
  end if;
  select r.km into v_km from e2_bench.road_km r where r.from_node = v_n.road_node_id and r.to_node = v_l.pickup_road_node_id;
  if v_km is null then return jsonb_build_object('outcome', 'ROUTE_UNAVAILABLE'); end if;
  return jsonb_build_object('outcome', case when v_km * 1000 <= v_radius then 'ELIGIBLE' else 'OUTSIDE_GEOFENCE' end,
                            'road_distance_km', round(v_km::numeric, 3));
end $f$;
'''


def lines(name, a, b):
    """Copy a range of lines from a migration file."""
    t = (MIG / name).read_text(encoding='utf-8').splitlines()
    return f'-- source: supabase/migrations/{name} lines {a}-{b}\n' + '\n'.join(t[a - 1:b]) + '\n'


def deployed():
    """The deployed definitions of the functions E2 copies."""
    csv.field_size_limit(10 ** 9)
    with EXPORT.open(encoding='utf-8-sig', newline='') as f:
        rows = list(csv.DictReader(f))
    out = []
    for name, args in DEPLOYED:
        hit = [r for r in rows if r['function_name'] == name and r['arguments'] == args]
        if len(hit) != 1:
            raise SystemExit(f'deployed export: expected one {name}({args}), found {len(hit)}')
        d = hit[0]['definition'].replace('\r\n', '\n').rstrip()
        d = d if d.endswith(';') else d + ';'
        out.append(f"-- deployed (Supabase DEV export 2026-11-09): public.{name}({args})\n"
                   f"-- md5 of definition: {hashlib.md5(d.encode()).hexdigest()}\n{d}\n")
    return out


def main():
    """Write 02_app_claim_layer.sql."""
    t = (MIG / '20261031_claim_audit_and_failure_capture.sql').read_text(encoding='utf-8').splitlines()
    i = next(n for n, l in enumerate(t) if 'CREATE UNIQUE INDEX IF NOT EXISTS operation_failure_claim_request_unique' in l)
    j = next(n for n in range(i, len(t)) if t[n].rstrip().endswith(';'))
    parts = ['-- E2 app claim layer (generated by build_app_claim_layer.py; do not edit by hand).',
             '-- Applied after 01_geolock_v3_schema.sql by test_harness/e2_harness.py.',
             'begin;',
             ALIGN,
             lines('20261019_stage1_claim_recovery_and_reconciliation.sql', 27, 40),
             '''alter table public.claim_reconciliation_cases
  add column if not exists evidence_round integer not null default 1 check (evidence_round > 0),
  add column if not exists evidence_version bigint not null default 1 check (evidence_version > 0),
  add column if not exists review_requested_by uuid, add column if not exists review_context text;''',
             lines('20261031_claim_audit_and_failure_capture.sql', 31, 43),
             lines('20261031_claim_audit_and_failure_capture.sql', i + 1, j + 1),
             '-- current donation lifecycle (AVAILABLE / CLAIMED ...)',
             lines('20261027_persisted_donation_lifecycle.sql', 87, 89),
             lines('20261027_persisted_donation_lifecycle.sql', 120, 122),
             STUBS, ROAD_CHECK]
    parts += deployed()
    parts += [lines('20261027_persisted_donation_lifecycle.sql', 229, 230),
              'grant execute on function public.claim_listing(uuid,uuid) to authenticated;',
              'grant execute on function public.recover_expired_claims(integer) to service_role;',
              'grant usage on schema routing_private, resolution_private to service_role, authenticated;',
              'grant select on all tables in schema routing_private to service_role, authenticated;',
              'grant select on all tables in schema resolution_private to service_role, authenticated;',
              'commit;']
    OUT.write_text('\n'.join(parts) + '\n', encoding='utf-8')
    print(OUT.name, hashlib.sha256(OUT.read_bytes()).hexdigest()[:16])


if __name__ == '__main__':
    main()
