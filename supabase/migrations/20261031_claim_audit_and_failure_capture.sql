-- LOCAL SOURCE ONLY. Not deployed. DEV rcgyuwiidqvrgbxswhqj only.
-- No lifecycle, eligibility, lease-duration or ownership policy change.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';
SET LOCAL search_path=pg_catalog,pg_temp;
DO $source_guard$ BEGIN
 IF current_user<>'postgres' OR session_user<>'postgres' THEN RAISE EXCEPTION 'POSTGRES_SESSION_REQUIRED'; END IF;
 IF md5(replace((SELECT prosrc FROM pg_proc WHERE oid=to_regprocedure('public.claim_listing(uuid,uuid)')),E'\r\n',E'\n'))
   IS DISTINCT FROM 'a883341a6dd72ccb08991a7f89dffa9a'
 OR md5(replace((SELECT prosrc FROM pg_proc WHERE oid=to_regprocedure('public.geolock_transition_listing_donations(uuid,text,text)')),E'\r\n',E'\n'))
   IS DISTINCT FROM 'c7f2124b18d75e5af2d7785daeeaa890'
 THEN RAISE EXCEPTION 'CLAIM_AUDIT_SOURCE_DRIFT'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE oid=to_regprocedure('public.claim_listing(uuid,uuid)')
   AND proowner='postgres'::regrole AND prosecdef)
 THEN RAISE EXCEPTION 'CLAIM_SECURITY_DRIFT'; END IF;
 IF EXISTS(SELECT 1 FROM (VALUES
  ('public.start_pickup(uuid)','d374a029251fd2ba3786d6c5f6a03ca6'),
  ('public.complete_pickup(uuid,boolean)','13b97b3cf16e6b8750b8289a22acfcb3'),
  ('public.cancel_claim(uuid,uuid)','5c94a13f00460fdfb8228864d3eaf75e'),
  ('public.recover_expired_claims(integer)','5ff6d8719db9681aae6f444b89dfbaee'),
  ('public.submit_claim_reconciliation(uuid,boolean,uuid)','9e0cdc7d246309222f7ac88d54cb4b96'),
  ('public.get_authorized_audit_events(text,uuid)','cc241b3797fab8ebd7e2f57143dcaacd')) expected(signature,body_md5)
  LEFT JOIN pg_proc p ON p.oid=to_regprocedure(expected.signature)
  WHERE p.oid IS NULL OR p.proowner<>'postgres'::regrole OR NOT p.prosecdef
   OR md5(replace(p.prosrc,E'\r\n',E'\n')) IS DISTINCT FROM expected.body_md5)
 THEN RAISE EXCEPTION 'AUDIT_CALLER_OR_RETRIEVAL_SOURCE_DRIFT'; END IF;
 IF to_regprocedure('public.geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text)') IS NOT NULL
 THEN RAISE EXCEPTION 'AUDIT_CONTEXT_HELPER_ALREADY_EXISTS'; END IF;
END $source_guard$;
create table if not exists public.operation_failure_events (
 failure_id uuid primary key default gen_random_uuid(),
 request_id uuid,
 actor_user_id uuid,
 actor_role text,
 operation_name text not null,
 donation_id uuid,
 listing_id uuid,
 claim_id uuid,
 reason_code text not null,
 occurred_at timestamptz not null default clock_timestamp(),
 details jsonb not null default '{}'::jsonb
);
DO $audit_schema_guard$
DECLARE e record; a record; v_default text;
BEGIN
 FOR e IN SELECT * FROM (VALUES
  ('public.operation_failure_events','failure_id','uuid',true),
  ('public.operation_failure_events','request_id','uuid',false),
  ('public.operation_failure_events','actor_user_id','uuid',false),
  ('public.operation_failure_events','actor_role','text',false),
  ('public.operation_failure_events','operation_name','text',true),
  ('public.operation_failure_events','donation_id','uuid',false),
  ('public.operation_failure_events','listing_id','uuid',false),
  ('public.operation_failure_events','claim_id','uuid',false),
  ('public.operation_failure_events','reason_code','text',true),
  ('public.operation_failure_events','occurred_at','timestamp with time zone',true),
  ('public.operation_failure_events','details','jsonb',true),
  ('public.audit_events','event_id','uuid',true),
  ('public.audit_events','actor_user_id','uuid',false),
  ('public.audit_events','actor_role','text',false),
  ('public.audit_events','entity_type','text',true),
  ('public.audit_events','entity_id','uuid',false),
  ('public.audit_events','event_type','text',true),
  ('public.audit_events','request_id','uuid',false),
  ('public.audit_events','claim_id','uuid',false),
  ('public.audit_events','lease_id','uuid',false),
  ('public.audit_events','correlation_id','uuid',false),
  ('public.audit_events','previous_state','text',false),
  ('public.audit_events','requested_state','text',false),
  ('public.audit_events','resulting_state','text',false),
  ('public.audit_events','reason_code','text',false),
  ('public.audit_events','outcome','text',true),
  ('public.audit_events','details','jsonb',true),
  ('public.audit_events','software_version','text',false),
  ('public.audit_events','configuration_version','text',false),
  ('public.audit_events','occurred_at','timestamp with time zone',true)) expected(relation_name,column_name,type_name,not_null)
 LOOP
  SELECT at.*,format_type(at.atttypid,at.atttypmod) AS actual_type INTO a
  FROM pg_attribute at WHERE at.attrelid=to_regclass(e.relation_name)
   AND at.attname=e.column_name AND at.attnum>0 AND NOT at.attisdropped;
  IF NOT FOUND OR a.actual_type IS DISTINCT FROM e.type_name OR a.attnotnull IS DISTINCT FROM e.not_null
  THEN RAISE EXCEPTION 'AUDIT_SCHEMA_DRIFT: %.%',e.relation_name,e.column_name; END IF;
 END LOOP;
 IF NOT EXISTS(SELECT 1 FROM pg_class WHERE oid='public.operation_failure_events'::regclass
   AND relkind='r' AND relowner='postgres'::regrole)
 OR NOT EXISTS(SELECT 1 FROM pg_constraint k WHERE k.conrelid='public.operation_failure_events'::regclass
   AND k.contype='p' AND k.conkey=ARRAY[(SELECT attnum FROM pg_attribute
     WHERE attrelid=k.conrelid AND attname='failure_id')]::smallint[])
 THEN RAISE EXCEPTION 'FAILURE_AUDIT_TABLE_OR_PRIMARY_KEY_DRIFT'; END IF;
 FOR e IN SELECT * FROM (VALUES ('failure_id','gen_random_uuid()'),
   ('occurred_at','clock_timestamp()'),('details','''{}''::jsonb')) defaults(column_name,expected_default)
 LOOP
  SELECT regexp_replace(pg_get_expr(d.adbin,d.adrelid),'pg_catalog[.]','','g') INTO v_default
  FROM pg_attrdef d JOIN pg_attribute a0 ON a0.attrelid=d.adrelid AND a0.attnum=d.adnum
  WHERE d.adrelid='public.operation_failure_events'::regclass AND a0.attname=e.column_name;
  IF v_default IS DISTINCT FROM e.expected_default
  THEN RAISE EXCEPTION 'FAILURE_AUDIT_DEFAULT_DRIFT: %',e.column_name; END IF;
 END LOOP;
 IF EXISTS(SELECT 1 FROM pg_attribute at WHERE at.attrelid='public.operation_failure_events'::regclass
  AND at.attnum>0 AND NOT at.attisdropped AND at.attnotnull AND NOT at.atthasdef
  AND at.attidentity='' AND at.attgenerated='' AND at.attname NOT IN ('operation_name','reason_code'))
 THEN RAISE EXCEPTION 'FAILURE_AUDIT_REQUIRED_EXTRA_COLUMN'; END IF;
 FOR e IN SELECT * FROM (VALUES ('event_id','gen_random_uuid()'),
   ('occurred_at','clock_timestamp()'),('details','''{}''::jsonb')) defaults(column_name,expected_default)
 LOOP
  SELECT regexp_replace(pg_get_expr(d.adbin,d.adrelid),'pg_catalog[.]','','g') INTO v_default
  FROM pg_attrdef d JOIN pg_attribute a0 ON a0.attrelid=d.adrelid AND a0.attnum=d.adnum
  WHERE d.adrelid='public.audit_events'::regclass AND a0.attname=e.column_name;
  IF v_default IS DISTINCT FROM e.expected_default THEN RAISE EXCEPTION 'AUDIT_DEFAULT_DRIFT: %',e.column_name; END IF;
 END LOOP;
 IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.audit_events'::regclass
   AND tgname='trg_audit_append_only' AND tgenabled='O'
   AND tgfoid=to_regprocedure('public.prevent_audit_mutation()'))
 THEN RAISE EXCEPTION 'AUDIT_APPEND_ONLY_GUARD_REQUIRED'; END IF;
END $audit_schema_guard$;
alter table public.operation_failure_events enable row level security;
revoke all on public.operation_failure_events from public,anon,authenticated;
-- Existing duplicates deliberately abort installation; never delete historical audit rows.
CREATE UNIQUE INDEX IF NOT EXISTS operation_failure_claim_request_unique
 ON public.operation_failure_events(actor_user_id,request_id,listing_id,operation_name,reason_code)
 WHERE operation_name='claim_listing' AND actor_user_id IS NOT NULL
  AND request_id IS NOT NULL AND listing_id IS NOT NULL;

DO $failure_index_guard$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_index i WHERE i.indexrelid=to_regclass('public.operation_failure_claim_request_unique')
  AND i.indrelid='public.operation_failure_events'::regclass AND i.indisunique AND i.indisvalid AND i.indisready
  AND i.indnkeyatts=5 AND i.indnatts=5
  AND (SELECT array_agg(a.attname::text ORDER BY k.ordinality) FROM unnest(i.indkey) WITH ORDINALITY k(attnum,ordinality)
    JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=k.attnum)
    =ARRAY['actor_user_id','request_id','listing_id','operation_name','reason_code']
  AND lower(regexp_replace(pg_get_expr(i.indpred,i.indrelid),'[()[:space:]]','','g'))=
    'operation_name=''claim_listing''::textandactor_user_idisnotnullandrequest_idisnotnullandlisting_idisnotnull')
 THEN RAISE EXCEPTION 'FAILURE_AUDIT_IDEMPOTENCY_INDEX_DRIFT'; END IF;
END $failure_index_guard$;

CREATE OR REPLACE FUNCTION public.geolock_transition_listing_donations(
  p_listing uuid,p_from text,p_to text,p_claim uuid,p_request uuid,p_reason text)
returns void language plpgsql
set search_path to 'pg_catalog','public','pg_temp'
as $function$
declare v_l public.listings%rowtype; v_id uuid; v_claim uuid; v_lease uuid; v_request uuid; v_correlation uuid:=coalesce(p_request,gen_random_uuid());
begin
  if not public.geolock_lock_listing_donations(p_listing,array[p_from]) then
    raise exception 'LISTING_DONATION_SET_STATE_MISMATCH';
  end if;
  select * into v_l from public.listings where listing_id=p_listing;
  -- Explicit context comes only from protected callers, never "latest historical claim".
  if p_claim is not null then
    select c.claim_id,le.lease_id into strict v_claim,v_lease
    from public.donation_claims c join public.claim_leases le using(claim_id)
    where c.claim_id=p_claim and c.listing_id=p_listing;
  elsif p_request is not null then
    raise exception 'AUDIT_REQUEST_WITHOUT_CLAIM_CONTEXT';
  end if;
  if p_reason is null then raise exception 'AUDIT_REASON_REQUIRED'; end if;
  v_request:=p_request; -- NULL when the caller API has no operation request ID.

  for v_id in
    select d.donation_id from public.donations d
    where (v_l.source_type='DIRECT_DONATION' and d.donation_id=v_l.donation_id)
      or (v_l.source_type='HUB_BATCH' and exists(select 1 from public.hub_batch_members m
        where m.batch_id=v_l.batch_id and m.donation_id=d.donation_id and m.membership_status='ACTIVE'))
    order by d.donation_id
  loop
    update public.donations set donation_status=p_to where donation_id=v_id and donation_status=p_from;
    if not found then raise exception 'LISTING_DONATION_SET_CHANGED'; end if;
    insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
      claim_id,lease_id,previous_state,requested_state,resulting_state,outcome,details,
      request_id,correlation_id,reason_code,software_version,configuration_version)
    values(auth.uid(),case when auth.uid() is null then 'SYSTEM'
      else (select role from public.user_profiles where user_id=auth.uid()) end,
      'DONATION',v_id,'DONATION_STATUS_CHANGED',v_claim,v_lease,p_from,p_to,p_to,'SUCCESS',
      jsonb_build_object('listing_id',p_listing,'donation_id',v_id,
        'ngo_id',(select ngo_user_id from public.donation_claims where claim_id=v_claim),
        'transaction_id',pg_current_xact_id()::text,'claim_context_available',p_claim is not null),v_request,v_correlation,
      p_reason,
      'geolock-claim-audit-v1',(select config_version from public.coordination_config where singleton));
  end loop;
end;
$function$;

CREATE OR REPLACE FUNCTION public.geolock_transition_listing_donations(p_listing uuid,p_from text,p_to text)
RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,public,pg_temp AS $compat$
BEGIN
 -- Compatibility for unreviewed/future callers: no guessed claim, lease or request IDs.
 PERFORM public.geolock_transition_listing_donations(p_listing,p_from,p_to,NULL,NULL,'STATE_TRANSITION_ACCEPTED');
END $compat$;
REVOKE ALL ON FUNCTION public.geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text)
 FROM PUBLIC,anon,authenticated,service_role;
DO $private_helper_acl$ DECLARE r record; BEGIN
 FOR r IN SELECT rolname FROM pg_roles WHERE rolname IN ('geolock_graph_worker','geolock_planner','geolock_validator') LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION public.geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text) FROM %I',r.rolname);
 END LOOP;
END $private_helper_acl$;


CREATE OR REPLACE FUNCTION public.claim_listing(p_listing uuid, p_request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_actor uuid:=auth.uid(); v_ngo public.ngo_profiles%rowtype;
  v_req public.claim_requests%rowtype; v_l public.listings%rowtype;
  v_digest text; v_reason text; v_claim uuid; v_lease uuid; v_mins integer;
  v_success boolean:=false; v_outcome text;
  v_configuration text; v_sqlstate text; v_failure uuid; v_error_message text;
  v_failure_reason text;
  v_transaction text:=pg_current_xact_id()::text;
  v_software constant text:='geolock-claim-audit-v1';
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_ngo from public.ngo_profiles
   where user_id=v_actor and active_flag for share;
  if not found then raise exception 'ACTIVE_NGO_ONLY'; end if;
  if p_request is null or p_listing is null then raise exception 'REQUEST_AND_LISTING_REQUIRED'; end if;

  -- Serialize identical authenticated request keys, including failed retries.
  -- Actor derives from auth.uid(), never from a client-supplied NGO identity.
  perform pg_advisory_xact_lock(hashtextextended('claim-request:'||v_actor::text||':'||p_request::text,0));
  begin -- Claim subtransaction: all original claim writes/audits roll back on error.
  v_digest:=md5(p_listing::text||':'||v_actor::text);
  insert into public.claim_requests(request_id,listing_id,ngo_user_id,request_digest)
  values(p_request,p_listing,v_actor,v_digest) on conflict(request_id) do nothing;
  select * into v_req from public.claim_requests where request_id=p_request for update;
  if v_req.request_digest<>v_digest or v_req.listing_id<>p_listing or v_req.ngo_user_id<>v_actor then
    raise exception 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
  end if;
  if v_req.outcome is not null then
    return jsonb_build_object('outcome',v_req.outcome,'claim_id',v_req.result_claim_id,
      'reason_code',v_req.reason_code,'replayed',true);
  end if;
  select config_version into v_configuration from public.coordination_config where singleton;
  if v_configuration is null then raise exception 'CLAIM_CONFIGURATION_NOT_AVAILABLE'; end if;
  select * into v_l from public.listings where listing_id=p_listing for update;
  if not found then v_reason:='LISTING_NOT_FOUND';
  elsif v_l.listing_status<>'AVAILABLE' then v_reason:='CLAIM_CONFLICT';
  elsif v_l.listing_expires_at is not null and v_l.listing_expires_at<=clock_timestamp() then v_reason:='LISTING_EXPIRED';
  elsif v_ngo.location_verified_at is null or v_ngo.road_node_id is null then v_reason:='ELIGIBILITY_UNDETERMINED';
  elsif public.geolock_ngo_listing_road_check(v_actor,p_listing)->>'outcome'<>'ELIGIBLE'
    then v_reason:=public.geolock_ngo_listing_road_check(v_actor,p_listing)->>'outcome';
  elsif v_l.source_type='DIRECT_DONATION' and not exists(
    select 1 from public.donations d where d.donation_id=v_l.donation_id and d.donation_status='AVAILABLE')
    then v_reason:='DONATION_NOT_READY';
  elsif v_l.source_type='HUB_BATCH' and not exists(
    select 1 from public.hub_batches b where b.batch_id=v_l.batch_id and b.batch_status='PUBLISHED')
    then v_reason:='BATCH_NOT_PUBLISHED';
  elsif not public.geolock_lock_listing_donations(p_listing,
    array[case when v_l.source_type='DIRECT_DONATION' then 'AVAILABLE' else 'BATCHED' end])
    then v_reason:='DONATION_SET_NOT_READY';
  else
    select claim_lease_minutes into v_mins from public.coordination_config where singleton;
    if v_mins is null then raise exception 'CLAIM_LEASE_NOT_CONFIGURED'; end if;
    insert into public.donation_claims(listing_id,ngo_user_id,request_id)
      values(p_listing,v_actor,p_request) returning claim_id into v_claim;
    insert into public.claim_leases(claim_id,expires_at)
      values(v_claim,clock_timestamp()+make_interval(mins=>v_mins)) returning lease_id into v_lease;
    update public.listings set listing_status='CLAIMED',listing_version=listing_version+1
      where listing_id=p_listing;
    insert into public.pickup_tasks(claim_id,listing_id,ngo_user_id,pickup_road_node_id,load_kg)
      values(v_claim,p_listing,v_actor,v_l.pickup_road_node_id,v_l.listing_weight_kg);
    perform public.geolock_transition_listing_donations(p_listing,
      case when v_l.source_type='DIRECT_DONATION' then 'AVAILABLE' else 'BATCHED' end,'CLAIMED',v_claim,p_request,'CLAIM_ACCEPTED');
    v_success:=true;
  end if;
  v_outcome:=case when v_success then 'SUCCESS'
    when v_reason in ('OUTSIDE_GEOFENCE','ROUTE_UNAVAILABLE') then 'INELIGIBLE' else 'CONFLICT' end;
  update public.claim_requests set outcome=v_outcome,result_claim_id=v_claim,
    reason_code=v_reason,completed_at=clock_timestamp() where request_id=p_request;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
    request_id,claim_id,lease_id,previous_state,requested_state,resulting_state,
    reason_code,outcome,details,configuration_version,correlation_id,software_version)
  values(v_actor,'NGO','LISTING',p_listing,'CLAIM_ATTEMPT',p_request,v_claim,v_lease,
    v_l.listing_status,'CLAIMED',case when v_success then 'CLAIMED' else v_l.listing_status end,
    coalesce(v_reason,'CLAIM_ACCEPTED'),case when v_success then 'SUCCESS' else 'REJECTED' end,
    jsonb_build_object('ngo_id',v_actor,'listing_id',p_listing,'donation_id',v_l.donation_id,
      'batch_id',v_l.batch_id,'donation_ids',case when v_l.source_type='DIRECT_DONATION'
        then jsonb_build_array(v_l.donation_id) else coalesce((select jsonb_agg(m.donation_id order by m.donation_id)
          from public.hub_batch_members m where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE'),'[]'::jsonb) end,
      'transaction_id',v_transaction),v_configuration,p_request,v_software);
  return jsonb_build_object('outcome',v_outcome,'claim_id',v_claim,
    'reason_code',v_reason,'replayed',false);
  exception when others then
    -- PostgreSQL has rolled back ONLY the claim subtransaction at this point.
    -- Cancellation/assertion failures are not caught by OTHERS and stay unconfirmed.
    get stacked diagnostics v_sqlstate=returned_sqlstate,v_error_message=message_text;
    v_failure_reason:=case when v_sqlstate='P0001'
      and v_error_message='IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD'
      then 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD'
      else 'CLAIM_TRANSACTION_ROLLED_BACK' end;
  end;
  -- No client report or inferred network outcome can reach this trusted path.
  -- Clear rolled-back generated IDs; rejected/failed attempts have no new lease.
  v_claim:=null; v_lease:=null;
  if v_l.listing_id is null then
    select * into v_l from public.listings where listing_id=p_listing;
  end if;
  if v_configuration is null then
    select config_version into v_configuration from public.coordination_config where singleton;
  end if;
  insert into public.operation_failure_events(request_id,actor_user_id,actor_role,
    operation_name,donation_id,listing_id,claim_id,reason_code,details)
  values(p_request,v_actor,'NGO','claim_listing',v_l.donation_id,p_listing,null,
    v_failure_reason,jsonb_build_object('sqlstate',v_sqlstate,
      'ngo_id',v_actor,'donation_id',v_l.donation_id,'batch_id',v_l.batch_id,
      'donation_ids',case when v_l.source_type='DIRECT_DONATION' then jsonb_build_array(v_l.donation_id)
        else coalesce((select jsonb_agg(m.donation_id order by m.donation_id) from public.hub_batch_members m
          where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE'),'[]'::jsonb) end,
      'previous_state',v_l.listing_status,'requested_state','CLAIMED',
      'resulting_state',(select listing_status from public.listings where listing_id=p_listing),
      'lease_id',null,'outcome','ERROR','rollback_confirmed',true,
      'correlation_id',p_request,'transaction_id',v_transaction,
      'software_version',v_software,'configuration_version',v_configuration))
  on conflict(actor_user_id,request_id,listing_id,operation_name,reason_code)
    where operation_name='claim_listing' and actor_user_id is not null
      and request_id is not null and listing_id is not null
  do nothing returning failure_id into v_failure;
  if v_failure is null then
    select failure_id into strict v_failure from public.operation_failure_events
    where actor_user_id=v_actor and request_id=p_request and listing_id=p_listing
      and operation_name='claim_listing' and reason_code=v_failure_reason;
  end if;
  -- If audit persistence fails this outer transaction aborts; no confirmed failure is returned.
  return jsonb_build_object('outcome','ERROR','claim_id',null,
    'reason_code',v_failure_reason,'replayed',false,
    'rollback_confirmed',true,'failure_audit_id',v_failure);
end;
$function$;

-- Audit-context-only caller revisions; original coordination behavior retained.
CREATE OR REPLACE FUNCTION public.start_pickup(p_claim uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_actor uuid:=auth.uid();v_c public.donation_claims%rowtype;
 v_l public.listings%rowtype;v_lease public.claim_leases%rowtype;
begin
 select * into v_c from public.donation_claims where claim_id=p_claim for update;
 if not found or v_c.ngo_user_id is distinct from v_actor or v_c.claim_status<>'ACTIVE'
 then raise exception 'NOT_ACTIVE_CLAIM_HOLDER'; end if;
 select * into v_lease from public.claim_leases where claim_id=p_claim for update;
 if not found or v_lease.lease_status<>'ACTIVE' or v_lease.expires_at<=clock_timestamp()
 then raise exception 'STALE_OR_EXPIRED_LEASE'; end if;
 select * into v_l from public.listings where listing_id=v_c.listing_id for update;
 if v_l.listing_status<>'CLAIMED' then raise exception 'LISTING_NOT_CLAIMED'; end if;
 update public.pickup_tasks set task_status='DISPATCHED'
 where claim_id=p_claim and task_status in ('CONFIRMED','PLANNED');
 if not found then raise exception 'PICKUP_TASK_NOT_DISPATCHABLE'; end if;
 perform public.geolock_transition_listing_donations(v_l.listing_id,'CLAIMED','PICKUP_IN_PROGRESS',p_claim,NULL,'PICKUP_STARTED');
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
 claim_id,lease_id,requested_state,resulting_state,outcome)
 values(v_actor,'NGO','CLAIM',p_claim,'START_PICKUP',p_claim,v_lease.lease_id,
 'PICKUP_IN_PROGRESS','PICKUP_IN_PROGRESS','SUCCESS');
end $function$;

CREATE OR REPLACE FUNCTION public.complete_pickup(p_claim uuid, p_handover_confirmed boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare v_actor uuid:=auth.uid();v_c public.donation_claims%rowtype;
 v_l public.listings%rowtype;v_lease public.claim_leases%rowtype;
begin
 select * into v_c from public.donation_claims where claim_id=p_claim for update;
 if not found or v_c.ngo_user_id is distinct from v_actor or v_c.claim_status<>'ACTIVE'
 then raise exception 'NOT_ACTIVE_CLAIM_HOLDER'; end if;
 select * into v_lease from public.claim_leases where claim_id=p_claim for update;
 if not found or v_lease.lease_status<>'ACTIVE' or v_lease.expires_at<=clock_timestamp()
 then raise exception 'STALE_OR_EXPIRED_LEASE'; end if;
 if p_handover_confirmed is distinct from true then raise exception 'HANDOVER_NOT_CONFIRMED'; end if;
 select * into v_l from public.listings where listing_id=v_c.listing_id for update;
 if v_l.listing_status<>'CLAIMED' then raise exception 'LISTING_NOT_CLAIMED'; end if;
 update public.pickup_tasks set task_status='COLLECTED'
 where claim_id=p_claim and task_status='DISPATCHED';
 if not found then raise exception 'PICKUP_NOT_STARTED'; end if;
 perform public.geolock_transition_listing_donations(v_l.listing_id,'PICKUP_IN_PROGRESS','COLLECTED',p_claim,NULL,'PICKUP_COLLECTED');
 if v_l.source_type='HUB_BATCH' then
  update public.hub_inventory set inventory_status='COLLECTED'
  where donation_id in(select donation_id from public.hub_batch_members
    where batch_id=v_l.batch_id and membership_status='ACTIVE');
  update public.hub_batches set batch_status='COLLECTED' where batch_id=v_l.batch_id;
 end if;
 update public.listings set listing_status='CLOSED',listing_version=listing_version+1
 where listing_id=v_l.listing_id;
 update public.donation_claims set claim_status='COMPLETED',closed_at=clock_timestamp()
 where claim_id=p_claim;
 update public.claim_leases set lease_status='COMPLETED',closed_at=clock_timestamp()
 where claim_id=p_claim;
 insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
 claim_id,lease_id,requested_state,resulting_state,outcome)
 values(v_actor,'NGO','CLAIM',p_claim,'COMPLETE_PICKUP',p_claim,v_lease.lease_id,
 'COLLECTED','COLLECTED','SUCCESS');
end $function$;

CREATE OR REPLACE FUNCTION public.cancel_claim(p_claim uuid, p_request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_role text;
  v_c public.donation_claims%rowtype;
  v_l public.listings%rowtype;
  v_le public.claim_leases%rowtype;
  v_t public.pickup_tasks%rowtype;
  v_req public.claim_cancellation_requests%rowtype;
  v_fingerprint text;
  v_result jsonb;
  v_reason text;
  v_safe boolean := false;
  v_version text;
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_claim is null or p_request is null then raise exception 'CLAIM_AND_REQUEST_REQUIRED'; end if;
  select c.* into v_c from public.donation_claims c where c.claim_id=p_claim;
  if not found or v_c.ngo_user_id is distinct from v_actor
     or not exists(select 1 from public.ngo_profiles n where n.user_id=v_actor and n.active_flag) then
    raise exception 'CLAIM_NOT_FOUND_OR_FORBIDDEN';
  end if;
  select p.role into v_role from public.user_profiles p where p.user_id=v_actor;
  v_fingerprint := v_actor::text || ':' || p_claim::text;
  insert into public.claim_cancellation_requests(request_id,claim_id,actor_user_id,request_fingerprint)
    values(p_request,p_claim,v_actor,v_fingerprint) on conflict(request_id) do nothing;
  select r.* into v_req from public.claim_cancellation_requests r
    where r.request_id=p_request for update;
  if v_req.request_fingerprint is distinct from v_fingerprint then
    insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
      request_id,claim_id,correlation_id,requested_state,resulting_state,reason_code,outcome,details)
    values(v_actor,v_role,'CLAIM',p_claim,'CANCEL_CLAIM',p_request,p_claim,p_request,
      'RELEASED',null,'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD','REJECTED',
      jsonb_build_object('request_id',p_request));
    return jsonb_build_object('outcome','REJECTED','claim_id',p_claim,
      'reason_code','IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD');
  end if;
  if v_req.response is not null then return v_req.response; end if;

  -- Keep the deployed pickup lock prefix exactly: claim, lease, listing, task.
  select c.* into v_c from public.donation_claims c where c.claim_id=p_claim for update;
  if not found then raise exception 'CLAIM_NOT_FOUND'; end if;
  select le.* into v_le from public.claim_leases le where le.claim_id=p_claim for update;
  if not found then raise exception 'LEASE_MISSING_REQUIRES_RECONCILIATION'; end if;
  select l.* into v_l from public.listings l where l.listing_id=v_c.listing_id for update;
  if not found then raise exception 'LISTING_MISSING_REQUIRES_RECONCILIATION'; end if;
  select t.* into v_t from public.pickup_tasks t where t.claim_id=p_claim for update;

  if v_t.task_id is null then v_reason := 'PICKUP_TASK_MISSING_REQUIRES_RECONCILIATION';
  elsif not public.geolock_lock_listing_donations(v_l.listing_id,array['CLAIMED']) then
    v_reason := 'DONATION_SET_REQUIRES_RECONCILIATION';
  elsif v_c.claim_status <> 'ACTIVE' then v_reason := 'CLAIM_NOT_ACTIVE';
  elsif v_le.lease_status <> 'ACTIVE' then v_reason := 'LEASE_NOT_ACTIVE';
  elsif v_le.expires_at <= clock_timestamp() then v_reason := 'LEASE_EXPIRED_USE_RECOVERY';
  elsif v_l.listing_status <> 'CLAIMED' then v_reason := 'LISTING_NOT_CLAIMED';
  elsif v_t.task_status <> 'CONFIRMED' then v_reason := 'PICKUP_ALREADY_STARTED_OR_CLOSED';
  elsif v_l.source_type='DIRECT_DONATION' and not exists(select 1 from public.donations d
      where d.donation_id=v_l.donation_id and d.donation_status='CLAIMED') then
    v_reason := 'DONATION_STATE_REQUIRES_RECONCILIATION';
  elsif v_l.source_type='HUB_BATCH' and (
      not exists(select 1 from public.hub_batch_members m
        where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE')
      or exists(select 1 from public.hub_batch_members m join public.donations d using(donation_id)
        where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE' and d.donation_status<>'CLAIMED')
      or exists(select 1 from public.hub_batch_members m
        where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE'
          and not exists(select 1 from public.hub_inventory hi
            where hi.donation_id=m.donation_id and hi.inventory_status='BATCHED'))) then
    v_reason := 'BATCH_CUSTODY_STATE_REQUIRES_RECONCILIATION';
  elsif exists(select 1 from public.active_task_route_assignments a where a.task_id=v_t.task_id)
     or exists(select 1 from public.pickup_route_stops s
      join public.pickup_routes r using(route_id)
      where s.task_id=v_t.task_id and r.route_status not in ('CANCELLED','STALE')) then
    v_reason := 'TASK_HAS_ROUTE_ACTIVITY';
  elsif v_l.listing_expires_at is not null and v_l.listing_expires_at <= clock_timestamp() then
    v_reason := 'LISTING_EXPIRED';
  else
    v_safe := true;
  end if;

  if v_safe then
    update public.donation_claims set claim_status='RELEASED',closed_at=clock_timestamp(),
      close_reason='NGO_CANCELLED_BEFORE_PICKUP' where claim_id=p_claim;
    update public.claim_leases set lease_status='RELEASED',closed_at=clock_timestamp(),
      release_reason='NGO_CANCELLED_BEFORE_PICKUP' where lease_id=v_le.lease_id;
    update public.pickup_tasks set task_status='STALE' where task_id=v_t.task_id;
    update public.listings set listing_status='AVAILABLE',listing_version=listing_version+1
      where listing_id=v_l.listing_id and listing_status='CLAIMED';
    perform public.geolock_transition_listing_donations(v_l.listing_id,'CLAIMED',
      case when v_l.source_type='DIRECT_DONATION' then 'AVAILABLE' else 'BATCHED' end,p_claim,p_request,'NGO_CANCELLED_BEFORE_PICKUP');
    v_reason := 'NGO_CANCELLED_BEFORE_PICKUP';
  end if;
  v_result := jsonb_build_object('outcome',case when v_safe then 'SUCCESS' else 'REJECTED' end,
    'claim_id',p_claim,'listing_id',v_c.listing_id,'reason_code',v_reason,
    'claim_status',case when v_safe then 'RELEASED' else v_c.claim_status end,
    'resulting_listing_status',case when v_safe then 'AVAILABLE' else v_l.listing_status end);
  update public.claim_cancellation_requests set response=v_result,completed_at=clock_timestamp()
    where request_id=p_request;
  select c.config_version into v_version from public.coordination_config c where c.singleton;
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
    request_id,claim_id,lease_id,correlation_id,previous_state,requested_state,resulting_state,
    reason_code,outcome,software_version,configuration_version,details)
  values(v_actor,v_role,'CLAIM',p_claim,'CANCEL_CLAIM',p_request,p_claim,v_le.lease_id,
    p_request,
    v_c.claim_status,'RELEASED',case when v_safe then 'RELEASED' else v_c.claim_status end,
    v_reason,case when v_safe then 'SUCCESS' else 'REJECTED' end,
    'geolock-stage1-2026-10-19',v_version,
    jsonb_build_object('donation_id',v_l.donation_id,
      'listing_id',v_c.listing_id,'task_id',v_t.task_id));
  return v_result;
end;
$function$;

CREATE OR REPLACE FUNCTION public.recover_expired_claims(p_limit integer DEFAULT 100)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_rec record; v_c public.donation_claims%rowtype; v_le public.claim_leases%rowtype;
  v_l public.listings%rowtype; v_t public.pickup_tasks%rowtype;
  v_uncertain boolean; v_count integer:=0; v_did uuid; v_cfg text;
begin
  if auth.role() is distinct from 'service_role' and session_user <> 'postgres' then
    raise exception 'TRUSTED_SCHEDULER_ONLY';
  end if;
  for v_rec in
    select c.claim_id,cl.lease_id,cl.expires_at from public.donation_claims c
    join public.claim_leases cl using(claim_id)
    where c.claim_status='ACTIVE' and cl.lease_status='ACTIVE' and cl.expires_at<=clock_timestamp()
    order by cl.expires_at,c.claim_id
    for update of c skip locked
    limit greatest(1,least(coalesce(p_limit,100),1000))
  loop
    select c.* into v_c from public.donation_claims c where c.claim_id=v_rec.claim_id;
    -- Current row lock was obtained on claim above; follow V3 writer order.
    select le.* into v_le from public.claim_leases le where le.lease_id=v_rec.lease_id for update;
    if v_c.claim_status<>'ACTIVE' or v_le.lease_status<>'ACTIVE'
       or v_le.expires_at>clock_timestamp() then continue; end if;
    select l.* into v_l from public.listings l where l.listing_id=v_c.listing_id for update;
    select t.* into v_t from public.pickup_tasks t where t.claim_id=v_c.claim_id for update;

    -- Unresolved custody evidence for this claim or listing fences reopening.
    v_uncertain := exists(select 1 from public.claim_reconciliation_cases rc
        where (rc.claim_id=v_c.claim_id or rc.listing_id=v_l.listing_id)
          and rc.case_status in ('OPEN','MANUAL_REVIEW'))
      or v_l.listing_id is null
      or v_t.task_id is null
      or v_l.listing_status<>'CLAIMED'
      or v_t.task_status<>'CONFIRMED'
      or exists(select 1 from public.active_task_route_assignments a where a.task_id=v_t.task_id)
      or exists(select 1 from public.pickup_route_stops s
        where s.task_id=v_t.task_id)
      or (v_l.source_type='DIRECT_DONATION' and exists(select 1 from public.donations d
        where d.donation_id=v_l.donation_id and d.donation_status in ('PICKUP_IN_PROGRESS','COLLECTED','DELIVERED')))
      or (v_l.source_type='HUB_BATCH' and exists(select 1 from public.hub_batch_members m
        join public.donations d using(donation_id) where m.batch_id=v_l.batch_id
        and m.membership_status='ACTIVE' and d.donation_status in ('PICKUP_IN_PROGRESS','COLLECTED','DELIVERED')));
    if v_l.source_type='DIRECT_DONATION' then
      v_uncertain:=v_uncertain or not exists(select 1 from public.donations d
        where d.donation_id=v_l.donation_id and d.donation_status='CLAIMED');
    elsif v_l.source_type='HUB_BATCH' then
      v_uncertain:=v_uncertain
        or not exists(select 1 from public.hub_batch_members m
          where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE')
        or exists(select 1 from public.hub_batch_members m join public.donations d using(donation_id)
          where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE'
            and d.donation_status<>'CLAIMED')
        or exists(select 1 from public.hub_batch_members m join public.hub_inventory hi using(donation_id)
          where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE'
            and hi.inventory_status<>'BATCHED');
    end if;
    if v_l.listing_id is not null then
      v_uncertain:=not public.geolock_lock_listing_donations(v_l.listing_id,array['CLAIMED']) or v_uncertain;
    end if;
    -- Decide listing expiry only after acquiring the donation/batch lock set.
    -- An expired listing cannot be safely reopened; retain custody for reconciliation.
    v_uncertain:=v_uncertain
      or (v_l.listing_expires_at is not null and v_l.listing_expires_at<=clock_timestamp());
    if v_uncertain then
      update public.claim_leases set lease_status='RECONCILIATION_REQUIRED' where lease_id=v_le.lease_id;
      update public.donation_claims set claim_status='RECONCILIATION_REQUIRED' where claim_id=v_c.claim_id;
      if v_l.listing_id is not null then
        insert into public.claim_reconciliation_cases(claim_id,listing_id,donation_id,source_type,case_status)
          values(v_c.claim_id,v_l.listing_id,v_l.donation_id,v_l.source_type,'OPEN')
          on conflict(claim_id) do nothing;
      end if;
    else
      update public.claim_leases set lease_status='RELEASED',closed_at=clock_timestamp(),release_reason='EXPIRED_SAFE_RELEASE'
        where lease_id=v_le.lease_id;
      update public.donation_claims set claim_status='RELEASED',closed_at=clock_timestamp(),close_reason='EXPIRED_SAFE_RELEASE'
        where claim_id=v_c.claim_id;
      update public.pickup_tasks set task_status='STALE' where task_id=v_t.task_id;
      if v_l.listing_status='CLAIMED' and (v_l.listing_expires_at is null or v_l.listing_expires_at>clock_timestamp()) then
        update public.listings set listing_status='AVAILABLE',listing_version=listing_version+1
          where listing_id=v_l.listing_id and listing_status='CLAIMED';
        perform public.geolock_transition_listing_donations(v_l.listing_id,'CLAIMED',
          case when v_l.source_type='DIRECT_DONATION' then 'AVAILABLE' else 'BATCHED' end,v_c.claim_id,NULL,'EXPIRED_SAFE_RELEASE');
      else
        raise exception 'RECOVERY_LISTING_REOPEN_PRECONDITION_CHANGED';
      end if;
    end if;
    select c.config_version into v_cfg from public.coordination_config c where c.singleton;
    insert into public.audit_events(actor_role,entity_type,entity_id,event_type,claim_id,lease_id,
      correlation_id,previous_state,requested_state,resulting_state,reason_code,outcome,
      software_version,configuration_version,details)
    values('SYSTEM','CLAIM',v_c.claim_id,'LEASE_RECOVERY',v_c.claim_id,v_le.lease_id,
      gen_random_uuid(),'ACTIVE',case when v_uncertain then 'RECONCILIATION_REQUIRED' else 'RELEASED' end,
      case when v_uncertain then 'RECONCILIATION_REQUIRED' else 'RELEASED' end,
      case when v_uncertain then 'HANDOVER_OR_ROUTE_ACTIVITY_UNCERTAIN' else 'EXPIRED_SAFE_RELEASE' end,
      'SUCCESS','geolock-stage1-2026-10-19',v_cfg,
      jsonb_build_object('donation_id',v_l.donation_id,
        'listing_id',v_l.listing_id,'task_id',v_t.task_id));
    v_count:=v_count+1;
  end loop;
  return v_count;
end;
$function$;

CREATE OR REPLACE FUNCTION public.submit_claim_reconciliation(p_claim uuid, p_handover_confirmed boolean, p_request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid(); v_role text; v_case public.claim_reconciliation_cases%rowtype;
  v_c public.donation_claims%rowtype; v_l public.listings%rowtype;
  v_le public.claim_leases%rowtype; v_t public.pickup_tasks%rowtype;
  v_d public.donations%rowtype; v_counterpart uuid; v_allowed boolean := false;
  v_prior public.claim_reconciliation_evidence%rowtype; v_values integer; v_true integer;
  v_result jsonb; v_cfg text; v_did uuid; v_batch_states text[];
begin
  if v_actor is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_claim is null or p_request is null or p_handover_confirmed is null then
    raise exception 'CLAIM_EVIDENCE_REQUIRED'; end if;
  -- Same lock prefix as start/complete/recovery.
  select c.* into v_c from public.donation_claims c where c.claim_id=p_claim for update;
  if not found then raise exception 'CLAIM_NOT_FOUND'; end if;
  select le.* into v_le from public.claim_leases le where le.claim_id=p_claim for update;
  if not found then raise exception 'LEASE_NOT_FOUND'; end if;
  select l.* into v_l from public.listings l where l.listing_id=v_c.listing_id for update;
  if not found then raise exception 'LISTING_NOT_FOUND'; end if;
  select t.* into v_t from public.pickup_tasks t where t.claim_id=p_claim for update;
  if not found then raise exception 'PICKUP_TASK_NOT_FOUND'; end if;
  if v_c.claim_status<>'RECONCILIATION_REQUIRED'
     or v_le.lease_status<>'RECONCILIATION_REQUIRED'
     or v_l.listing_status<>'CLAIMED' then
    raise exception 'RECONCILIATION_STATE_MISMATCH';
  end if;
  select p.role into v_role from public.user_profiles p where p.user_id=v_actor;
  select * into v_case from public.claim_reconciliation_cases c
    where c.claim_id=p_claim and c.case_status in ('OPEN','MANUAL_REVIEW') for update;
  if not found then raise exception 'RECONCILIATION_NOT_OPEN'; end if;

  if v_actor=v_c.ngo_user_id and v_role='NGO' then v_allowed:=true; end if;
  if v_l.source_type='DIRECT_DONATION' then
    select d.donor_user_id into v_counterpart from public.donations d where d.donation_id=v_l.donation_id;
    if v_actor=v_counterpart and v_role='DONOR' then v_allowed:=true; end if;
  elsif v_l.source_type='HUB_BATCH' then
    select h.admin_user_id into v_counterpart from public.hub_batches b
      join public.community_hubs h using(hub_id) where b.batch_id=v_l.batch_id;
    if v_actor=v_counterpart and v_role='HUB_ADMIN' then v_allowed:=true; end if;
  end if;
  if not v_allowed then raise exception 'RECONCILIATION_PARTICIPANT_ONLY'; end if;

  select * into v_prior from public.claim_reconciliation_evidence e where e.request_id=p_request;
  if found then
    if v_prior.case_id<>v_case.case_id or v_prior.actor_user_id<>v_actor
       or v_prior.handover_confirmed<>p_handover_confirmed then
      select c.config_version into v_cfg from public.coordination_config c where c.singleton;
      insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
        request_id,claim_id,lease_id,correlation_id,
        previous_state,requested_state,resulting_state,reason_code,outcome,
        software_version,configuration_version,details)
      values(v_actor,v_role,'CLAIM',p_claim,'CLAIM_RECONCILIATION_EVIDENCE',p_request,p_claim,
        v_le.lease_id,p_request,v_c.claim_status,
        case when p_handover_confirmed then 'COLLECTED' else 'RELEASED' end,
        v_c.claim_status,'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD','REJECTED',
        'geolock-stage1-2026-10-19',v_cfg,jsonb_build_object('donation_id',v_l.donation_id,
        'listing_id',v_l.listing_id,'case_id',v_case.case_id));
      return jsonb_build_object('outcome','REJECTED','reason_code','IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD');
    end if;
    if v_prior.response is not null then return v_prior.response; end if;
  else
    if exists(select 1 from public.claim_reconciliation_evidence e
        where e.case_id=v_case.case_id and e.actor_user_id=v_actor) then
      select c.config_version into v_cfg from public.coordination_config c where c.singleton;
      insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
        request_id,claim_id,lease_id,correlation_id,
        previous_state,requested_state,resulting_state,reason_code,outcome,
        software_version,configuration_version,details)
      values(v_actor,v_role,'CLAIM',p_claim,'CLAIM_RECONCILIATION_EVIDENCE',p_request,p_claim,
        v_le.lease_id,p_request,v_c.claim_status,
        case when p_handover_confirmed then 'COLLECTED' else 'RELEASED' end,
        v_c.claim_status,'EVIDENCE_ALREADY_SUBMITTED','REJECTED',
        'geolock-stage1-2026-10-19',v_cfg,jsonb_build_object('donation_id',v_l.donation_id,
        'listing_id',v_l.listing_id,'case_id',v_case.case_id));
      return jsonb_build_object('outcome','REJECTED','reason_code','EVIDENCE_ALREADY_SUBMITTED');
    end if;
    insert into public.claim_reconciliation_evidence(request_id,case_id,actor_user_id,handover_confirmed)
      values(p_request,v_case.case_id,v_actor,p_handover_confirmed);
  end if;

  -- Lock and validate the complete immutable member set before finalizing evidence.
  if not public.geolock_lock_listing_donations(v_l.listing_id,
    array['CLAIMED','PICKUP_IN_PROGRESS','COLLECTED']) then
    raise exception 'RECONCILIATION_DONATION_SET_REQUIRES_REVIEW';
  end if;
  -- The complete immutable member set is locked above. A partially progressed
  -- batch is inconsistent custody, even if both participants report handover.
  if v_l.source_type='HUB_BATCH' then
    select array_agg(distinct d.donation_status order by d.donation_status)
      into v_batch_states
    from public.hub_batch_members m join public.donations d using(donation_id)
    where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE';
  end if;
  select count(*),count(*) filter(where e.handover_confirmed)
    into v_values,v_true from public.claim_reconciliation_evidence e where e.case_id=v_case.case_id;
  if cardinality(v_batch_states)>1 then
    update public.claim_reconciliation_cases set case_status='MANUAL_REVIEW',
      resolution_reason='MIXED_BATCH_DONATION_STATES' where case_id=v_case.case_id;
    v_result:=jsonb_build_object('outcome','RECONCILIATION_REQUIRED','case_id',v_case.case_id,
      'reason_code','MIXED_BATCH_DONATION_STATES');
  elsif v_values<2 then
    v_result:=jsonb_build_object('outcome','AWAITING_COUNTERPART','case_id',v_case.case_id,
      'reason_code','SECOND_PARTY_CONFIRMATION_REQUIRED');
  elsif v_true not in (0,2) then
    update public.claim_reconciliation_cases set case_status='MANUAL_REVIEW',
      resolution_reason='PARTY_EVIDENCE_CONFLICT' where case_id=v_case.case_id;
    v_result:=jsonb_build_object('outcome','RECONCILIATION_REQUIRED','case_id',v_case.case_id,
      'reason_code','PARTY_EVIDENCE_CONFLICT');
  elsif v_true=2 then
    if v_t.task_status not in ('DISPATCHED','COLLECTED') then
      update public.claim_reconciliation_cases set case_status='MANUAL_REVIEW',
        resolution_reason='HANDOVER_EVIDENCE_CONFLICTS_WITH_TASK_STATE' where case_id=v_case.case_id;
      v_result:=jsonb_build_object('outcome','RECONCILIATION_REQUIRED','case_id',v_case.case_id,
        'reason_code','HANDOVER_EVIDENCE_CONFLICTS_WITH_TASK_STATE');
    else
      if v_l.source_type='DIRECT_DONATION' then
        select d.* into v_d from public.donations d where d.donation_id=v_l.donation_id for update;
        if v_d.donation_status not in ('PICKUP_IN_PROGRESS','COLLECTED') then raise exception 'DONATION_STATE_REQUIRES_REVIEW'; end if;
        if v_d.donation_status='PICKUP_IN_PROGRESS' then
          update public.donations set donation_status='COLLECTED' where donation_id=v_d.donation_id;
        end if;
      else
        for v_did in select m.donation_id from public.hub_batch_members m
          where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE' order by m.donation_id loop
          select d.* into v_d from public.donations d where d.donation_id=v_did for update;
          if v_d.donation_status not in ('PICKUP_IN_PROGRESS','COLLECTED') then raise exception 'BATCH_DONATION_STATE_REQUIRES_REVIEW'; end if;
          if v_d.donation_status='PICKUP_IN_PROGRESS' then
            update public.donations set donation_status='COLLECTED' where donation_id=v_did;
          end if;
        end loop;
        update public.hub_inventory set inventory_status='COLLECTED'
          where donation_id in(select m.donation_id from public.hub_batch_members m
            where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE');
        update public.hub_batches set batch_status='COLLECTED' where batch_id=v_l.batch_id;
      end if;
      update public.pickup_tasks set task_status='COLLECTED' where task_id=v_t.task_id;
      update public.listings set listing_status='CLOSED',listing_version=listing_version+1 where listing_id=v_l.listing_id;
      update public.donation_claims set claim_status='COMPLETED',closed_at=clock_timestamp(),close_reason='RECONCILED_HANDOVER_CONFIRMED' where claim_id=p_claim;
      update public.claim_leases set lease_status='COMPLETED',closed_at=clock_timestamp() where lease_id=v_le.lease_id;
      update public.claim_reconciliation_cases set case_status='RESOLVED_COLLECTED',resolved_at=clock_timestamp(),
        resolution_reason='BOTH_PARTIES_CONFIRMED_HANDOVER' where case_id=v_case.case_id;
      v_result:=jsonb_build_object('outcome','SUCCESS','case_id',v_case.case_id,
        'claim_status','COMPLETED','donation_status','COLLECTED','reason_code','HANDOVER_CONFIRMED');
    end if;
  else
    if v_t.task_status='CONFIRMED'
       and v_l.listing_status='CLAIMED'
       and (v_l.listing_expires_at is null or v_l.listing_expires_at>clock_timestamp())
       and ((v_l.source_type='DIRECT_DONATION' and exists(select 1 from public.donations d
              where d.donation_id=v_l.donation_id and d.donation_status='CLAIMED'))
         or (v_l.source_type='HUB_BATCH'
             and exists(select 1 from public.hub_batch_members m
               where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE')
             and not exists(select 1 from public.hub_batch_members m join public.donations d using(donation_id)
               where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE'
                 and d.donation_status<>'CLAIMED')
              and not exists(select 1 from public.hub_batch_members m
                where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE'
                  and not exists(select 1 from public.hub_inventory hi
                    where hi.donation_id=m.donation_id and hi.inventory_status='BATCHED'))))
       and not exists(select 1 from public.active_task_route_assignments a where a.task_id=v_t.task_id)
       and not exists(
      select 1 from public.pickup_route_stops s join public.pickup_routes r using(route_id)
      where s.task_id=v_t.task_id and r.route_status not in ('CANCELLED','STALE')) then
      update public.donation_claims set claim_status='RELEASED',closed_at=clock_timestamp(),close_reason='RECONCILED_NO_HANDOVER' where claim_id=p_claim;
      update public.claim_leases set lease_status='RELEASED',closed_at=clock_timestamp(),release_reason='RECONCILED_NO_HANDOVER' where lease_id=v_le.lease_id;
      update public.pickup_tasks set task_status='STALE' where task_id=v_t.task_id;
      update public.listings set listing_status='AVAILABLE',listing_version=listing_version+1 where listing_id=v_l.listing_id;
      perform public.geolock_transition_listing_donations(v_l.listing_id,'CLAIMED',
        case when v_l.source_type='DIRECT_DONATION' then 'AVAILABLE' else 'BATCHED' end,p_claim,p_request,'RECONCILED_NO_HANDOVER');
      update public.claim_reconciliation_cases set case_status='RESOLVED_RELEASED',resolved_at=clock_timestamp(),
        resolution_reason='BOTH_PARTIES_CONFIRMED_NO_HANDOVER' where case_id=v_case.case_id;
      v_result:=jsonb_build_object('outcome','SUCCESS','case_id',v_case.case_id,
        'claim_status','RELEASED','reason_code','NO_HANDOVER_CONFIRMED');
    else
      update public.claim_reconciliation_cases set case_status='MANUAL_REVIEW',
        resolution_reason='NO_HANDOVER_CONFIRMED_AFTER_PICKUP_STARTED' where case_id=v_case.case_id;
      v_result:=jsonb_build_object('outcome','RECONCILIATION_REQUIRED','case_id',v_case.case_id,
        'reason_code','NO_HANDOVER_AFTER_PICKUP_STARTED_REQUIRES_REVIEW');
    end if;
  end if;

  update public.claim_reconciliation_evidence set response=v_result where request_id=p_request;
  select c.config_version into v_cfg from public.coordination_config c where c.singleton;
  -- This path accepted the evidence; waiting/manual review is a workflow state,
  -- not a failed database operation. Earlier rejection paths remain REJECTED.
  insert into public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
    request_id,claim_id,lease_id,correlation_id,previous_state,requested_state,resulting_state,
    reason_code,outcome,software_version,configuration_version,details)
  values(v_actor,v_role,'CLAIM',p_claim,'CLAIM_RECONCILIATION_EVIDENCE',p_request,p_claim,
    v_le.lease_id,p_request,v_c.claim_status,
    case when p_handover_confirmed then 'COLLECTED' else 'RELEASED' end,
    coalesce(v_result->>'claim_status',v_c.claim_status),v_result->>'reason_code','SUCCESS',
    'geolock-stage1-2026-10-19',v_cfg,jsonb_build_object('donation_id',v_l.donation_id,
        'listing_id',v_l.listing_id,'case_id',v_case.case_id,
      'handover_confirmed',p_handover_confirmed,
      'reconciliation_status',v_result->>'outcome',
      'batch_donation_states',to_jsonb(v_batch_states)));
  return v_result;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_authorized_audit_events(p_entity_type text, p_entity_id uuid)
 RETURNS SETOF public.audit_events
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare v_user uuid:=auth.uid(); v_role text; v_allowed boolean:=false;
begin
  if v_user is null then raise exception 'UNAUTHENTICATED'; end if;
  select p.role into v_role from public.user_profiles p where p.user_id=v_user;
  if v_role='DONOR' then
    v_allowed:=exists(select 1 from public.donations d where d.donor_user_id=v_user
      and (d.donation_id=p_entity_id or exists(select 1 from public.listings l
      where l.donation_id=d.donation_id and l.listing_id=p_entity_id)));
  elsif v_role='NGO' then
    v_allowed:=exists(select 1 from public.donation_claims c join public.listings l using(listing_id)
      where c.ngo_user_id=v_user and (c.claim_id=p_entity_id or l.listing_id=p_entity_id or l.donation_id=p_entity_id or (l.source_type='HUB_BATCH' and exists(
        select 1 from public.hub_batch_members bm where bm.batch_id=l.batch_id and bm.donation_id=p_entity_id))))
      or exists(select 1 from public.claim_requests q where q.ngo_user_id=v_user and q.listing_id=p_entity_id)
      or exists(select 1 from public.operation_failure_events f where f.operation_name='claim_listing'
        and f.details->>'rollback_confirmed'='true' and f.details->>'software_version'='geolock-claim-audit-v1'
        and f.actor_user_id=v_user and (f.listing_id=p_entity_id or f.donation_id=p_entity_id
          or f.details->'donation_ids' @> jsonb_build_array(p_entity_id)));
  elsif v_role='HUB_ADMIN' then
    v_allowed:=exists(select 1 from public.community_hubs h where h.admin_user_id=v_user
      and (h.hub_id=p_entity_id or exists(select 1 from public.hub_reservations r
      where r.hub_id=h.hub_id and r.donation_id=p_entity_id) or exists(select 1 from public.hub_inventory i
      where i.hub_id=h.hub_id and i.donation_id=p_entity_id)));
  end if;
  if not v_allowed then raise exception 'AUDIT_NOT_FOUND_OR_FORBIDDEN'; end if;
  return query select events.* from (select a.* from public.audit_events a
    where (a.entity_id=p_entity_id or a.details->>'donation_id'=p_entity_id::text
      or a.details->>'listing_id'=p_entity_id::text or a.claim_id=p_entity_id
      or a.details->'donation_ids' @> jsonb_build_array(p_entity_id))
      and (v_role<>'NGO' or (a.event_type<>'DONOR_PRIVATE_DATA' and
       (a.actor_user_id=v_user or exists(select 1 from public.donation_claims own
         where own.claim_id=a.claim_id and own.ngo_user_id=v_user))))

  -- Read-only projection of confirmed rollback evidence; historical rows stay in their original ledger.
  -- NGO access is actor-scoped; no claim ownership is inferred from a failed request.
  union all select (jsonb_populate_record(null::public.audit_events,jsonb_build_object(
    'event_id',f.failure_id,'actor_user_id',f.actor_user_id,'actor_role',f.actor_role,
    'entity_type','LISTING','entity_id',f.listing_id,'event_type','CLAIM_FAILURE',
    'request_id',f.request_id,'claim_id',f.claim_id,'lease_id',null,
    'correlation_id',case when f.details->>'correlation_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then f.details->>'correlation_id' else null end,
    'previous_state',f.details->>'previous_state','requested_state',f.details->>'requested_state',
    'resulting_state',f.details->>'resulting_state','reason_code',f.reason_code,'outcome','ERROR',
    'details',f.details||jsonb_build_object('audit_source','operation_failure_events',
      'donation_id',f.donation_id,'listing_id',f.listing_id,'ngo_id',f.actor_user_id),
    'software_version',f.details->>'software_version','configuration_version',f.details->>'configuration_version',
    'occurred_at',f.occurred_at))).*
  from public.operation_failure_events f where f.operation_name='claim_listing'
   and f.details->>'rollback_confirmed'='true' and f.details->>'software_version'='geolock-claim-audit-v1'
   and (f.listing_id=p_entity_id or f.donation_id=p_entity_id or f.claim_id=p_entity_id
     or f.details->'donation_ids' @> jsonb_build_array(p_entity_id))
   and (v_role<>'NGO' or f.actor_user_id=v_user)
  ) events order by events.occurred_at,events.event_id;
end;
$function$;
COMMIT;
