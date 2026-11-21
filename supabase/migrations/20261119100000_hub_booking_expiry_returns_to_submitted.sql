-- Hub booking expiry returns the donation to SUBMITTED (Figure 4.7).
-- Target: DEV project geolock_test (rcgyuwiidqvrgbxswhqj). Run in the SQL Editor as one script.
-- Preflight: supabase/tests/hub_booking_expiry_readiness.sql
--
-- Why: HUB_ASSIGNED means a hub is holding space. When a booking expires at the hub's last
-- closing time on the drop-off day, no hub holds space any more, but the donation stayed
-- HUB_ASSIGNED (2 live donations were in that state on 19 Nov 2026). After this migration the
-- donation returns to SUBMITTED, where the donor chooses a hub and day again.
--
-- What changes (nothing else):
--   A1  enforce_donation_transition: one new rule, HUB_ASSIGNED -> SUBMITTED, only when the
--       donation has no ACTIVE booking and no hub receipt.
--   A2  new function expire_hub_bookings() and a pg_cron job every minute (same pattern as the
--       existing eligibility and claim recovery jobs), plus a one-off backfill.
--   A3  cancel_donation: a SUBMITTED donation may be cancelled when its old bookings are only
--       EXPIRED or RELEASED (it still refuses ACTIVE or CONSUMED).
-- A1 and A3 edit the live function text in place: each edit must match exactly once or the
-- whole script stops and nothing is changed. Running the script twice changes nothing more.
-- Not changed: reserve_hub_capacity, geolock_assert_donor_hub_choice and get_my_hub_dropoff
-- already let a SUBMITTED donation book again (checked on the live database, 19 Nov 2026).

BEGIN;

DO $migration$
DECLARE
  v_def text; v_new text; v_anchor text; v_hits integer;
BEGIN
  -- ------------------------------------------------------------------ A1 trigger rule
  v_def := pg_get_functiondef('public.enforce_donation_transition()'::regprocedure);
  IF v_def ~ 'old\.donation_status=''HUB_ASSIGNED''\s+and\s+new\.donation_status=''SUBMITTED''' THEN
    RAISE NOTICE 'A1 already applied';
  ELSE
    v_anchor := 'or (old.donation_status=''PICKUP_IN_PROGRESS'' and new.donation_status=''COLLECTED'')';
    v_hits := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'A1: expected the COLLECTED rule once in enforce_donation_transition, found %', v_hits;
    END IF;
    v_new := replace(v_def, v_anchor, v_anchor || chr(10) ||
      '    -- booking expired or released: no hub holds space, the donor chooses again' || chr(10) ||
      '    or (old.donation_status=''HUB_ASSIGNED'' and new.donation_status=''SUBMITTED''' || chr(10) ||
      '      and new.collection_path=''HUB_COLLECTION''' || chr(10) ||
      '      and not exists(select 1 from public.hub_reservations r' || chr(10) ||
      '        where r.donation_id=old.donation_id and r.reservation_status=''ACTIVE'')' || chr(10) ||
      '      and not exists(select 1 from public.hub_receipts hr where hr.donation_id=old.donation_id))');
    EXECUTE v_new;
  END IF;

  -- ------------------------------------------------------------------ A3 cancel_donation
  v_def := pg_get_functiondef('public.cancel_donation(uuid,uuid)'::regprocedure);
  IF v_def ~ 'r\.donation_id=p_donation\s+and r\.reservation_status in \(''ACTIVE'',''CONSUMED''\)\) then\s+v_reason:=''HUB_RESERVATION_STATE_INCONSISTENT''' THEN
    RAISE NOTICE 'A3 already applied';
  ELSE
    SELECT count(*) INTO v_hits FROM regexp_matches(v_def,
      'and exists\(select 1 from public\.hub_reservations r where r\.donation_id=p_donation\)( then\r?\n\s*v_reason:=''HUB_RESERVATION_STATE_INCONSISTENT'')', 'g');
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'A3: expected the SUBMITTED booking check once in cancel_donation, found %', v_hits;
    END IF;
    v_new := regexp_replace(v_def,
      'and exists\(select 1 from public\.hub_reservations r where r\.donation_id=p_donation\)( then\r?\n\s*v_reason:=''HUB_RESERVATION_STATE_INCONSISTENT'')',
      'and exists(select 1 from public.hub_reservations r where r.donation_id=p_donation' || chr(10) ||
      '          and r.reservation_status in (''ACTIVE'',''CONSUMED''))\1');
    EXECUTE v_new;
  END IF;
END
$migration$;

-- -------------------------------------------------------------------- A2 expiry job
CREATE OR REPLACE FUNCTION public.expire_hub_bookings(p_limit integer DEFAULT 200)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare v_n integer := 0; r record;
begin
  -- A booking that reached the hub's last closing time with no receipt has expired.
  -- Rows a donor or hub admin is changing right now are skipped and picked up next minute.
  for r in
    select res.reservation_id, res.donation_id, res.hub_id
    from public.hub_reservations res
    join public.donations d on d.donation_id = res.donation_id
    where res.reservation_status = 'ACTIVE'
      and res.expires_at <= clock_timestamp()
      and d.donation_status = 'HUB_ASSIGNED'
      and not exists (select 1 from public.hub_receipts hr where hr.reservation_id = res.reservation_id)
    order by res.expires_at, res.reservation_id
    limit greatest(coalesce(p_limit, 200), 1)
    for update of d, res skip locked
  loop
    update public.hub_reservations set reservation_status = 'EXPIRED'
     where reservation_id = r.reservation_id and reservation_status = 'ACTIVE';
    update public.donations set donation_status = 'SUBMITTED'
     where donation_id = r.donation_id and donation_status = 'HUB_ASSIGNED';
    insert into public.audit_events(actor_user_id, actor_role, entity_type, entity_id, event_type,
      previous_state, requested_state, resulting_state, reason_code, outcome, correlation_id,
      details, configuration_version)
    select null, 'SYSTEM', 'HUB_RESERVATION', r.reservation_id, 'EXPIRE_HUB_RESERVATION',
      'ACTIVE', 'EXPIRED', 'EXPIRED', 'RESERVATION_TIMEOUT', 'SUCCESS', r.reservation_id,
      jsonb_build_object('donation_id', r.donation_id, 'hub_id', r.hub_id), c.config_version
    from public.coordination_config c where c.singleton;
    insert into public.audit_events(actor_user_id, actor_role, entity_type, entity_id, event_type,
      previous_state, requested_state, resulting_state, reason_code, outcome, correlation_id,
      details, configuration_version)
    select null, 'SYSTEM', 'DONATION', r.donation_id, 'DONATION_STATUS_CHANGED',
      'HUB_ASSIGNED', 'SUBMITTED', 'SUBMITTED', 'RESERVATION_TIMEOUT', 'SUCCESS', r.reservation_id,
      jsonb_build_object('reservation_id', r.reservation_id, 'hub_id', r.hub_id), c.config_version
    from public.coordination_config c where c.singleton;
    v_n := v_n + 1;
  end loop;
  return v_n;
end
$function$;

REVOKE ALL ON FUNCTION public.expire_hub_bookings(integer) FROM PUBLIC;
DO $grants$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON FUNCTION public.expire_hub_bookings(integer) FROM anon; END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    REVOKE ALL ON FUNCTION public.expire_hub_bookings(integer) FROM authenticated; END IF;
END $grants$;

-- One-off backfill 1: bookings already past closing time (2 live donations on 19 Nov 2026).
SELECT public.expire_hub_bookings(10000) AS expired_now;

-- One-off backfill 2: donations left HUB_ASSIGNED whose bookings were already marked EXPIRED.
WITH stuck AS (
  SELECT d.donation_id FROM public.donations d
  WHERE d.donation_status = 'HUB_ASSIGNED' AND d.collection_path = 'HUB_COLLECTION'
    AND NOT EXISTS (SELECT 1 FROM public.hub_reservations r
                    WHERE r.donation_id = d.donation_id AND r.reservation_status = 'ACTIVE')
    AND NOT EXISTS (SELECT 1 FROM public.hub_receipts hr WHERE hr.donation_id = d.donation_id)
), moved AS (
  UPDATE public.donations d SET donation_status = 'SUBMITTED'
  FROM stuck s WHERE d.donation_id = s.donation_id
  RETURNING d.donation_id
)
INSERT INTO public.audit_events(actor_user_id, actor_role, entity_type, entity_id, event_type,
  previous_state, requested_state, resulting_state, reason_code, outcome, details, configuration_version)
SELECT null, 'SYSTEM', 'DONATION', m.donation_id, 'DONATION_STATUS_CHANGED',
  'HUB_ASSIGNED', 'SUBMITTED', 'SUBMITTED', 'RESERVATION_TIMEOUT', 'SUCCESS',
  jsonb_build_object('migration', '20261119100000_hub_booking_expiry_returns_to_submitted'),
  c.config_version
FROM moved m CROSS JOIN public.coordination_config c WHERE c.singleton;

-- Schedule every minute (replaces the job if it already exists).
DO $schedule$ BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'geolock-hub-booking-expiry') THEN
    PERFORM cron.unschedule('geolock-hub-booking-expiry');
  END IF;
  PERFORM cron.schedule('geolock-hub-booking-expiry', '* * * * *',
    $cmd$set lock_timeout = '5s'; set statement_timeout = '50s'; select public.expire_hub_bookings(200);$cmd$);
END $schedule$;

COMMIT;

-- After running, these should show 0 and the new job:
-- select count(*) from public.donations d where d.donation_status='HUB_ASSIGNED'
--   and not exists(select 1 from public.hub_reservations r where r.donation_id=d.donation_id
--                  and r.reservation_status='ACTIVE' and r.expires_at>now());
-- select jobname, schedule, active from cron.job where jobname='geolock-hub-booking-expiry';
