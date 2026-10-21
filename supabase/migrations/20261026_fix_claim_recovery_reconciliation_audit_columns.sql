-- REVIEW ONLY: isolated DEV rcgyuwiidqvrgbxswhqj. Not applied.
-- Audit-schema correction only: preserve deployed recovery/reconciliation logic,
-- locks, request replay behavior, function contracts and EXECUTE grants.
-- Remove unsupported audit columns; retain all related IDs in details JSON.
-- Accepted evidence is an audit SUCCESS even while reconciliation is waiting
-- or requires review. Preserve the business outcome in details, not outcome.
-- Rejected evidence keeps its existing REJECTED audit events and early returns.
begin;
do $$
begin
  if current_user <> 'postgres' then raise exception 'MIGRATION_REQUIRES_POSTGRES'; end if;
  if to_regprocedure('public.recover_expired_claims(integer)') is null
     or to_regprocedure('public.submit_claim_reconciliation(uuid,boolean,uuid)') is null then
    raise exception 'CLAIM_RECOVERY_RECONCILIATION_DEPENDENCY_MISSING';
  end if;
  if (select count(*) from information_schema.columns
      where table_schema='public' and table_name='audit_events'
        and column_name in ('actor_user_id','actor_role','entity_type','entity_id',
          'event_type','request_id','claim_id','lease_id','correlation_id',
          'previous_state','requested_state','resulting_state','reason_code',
          'outcome','software_version','configuration_version','details')) <> 17 then
    raise exception 'AUDIT_EVENTS_CONTRACT_MISMATCH';
  end if;
end;
$$;

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

    v_uncertain := v_l.listing_id is null
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
        where d.donation_id=v_l.donation_id and d.donation_status='READY_FOR_PICKUP');
    elsif v_l.source_type='HUB_BATCH' then
      v_uncertain:=v_uncertain
        or not exists(select 1 from public.hub_batch_members m
          where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE')
        or exists(select 1 from public.hub_batch_members m join public.donations d using(donation_id)
          where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE'
            and d.donation_status<>'BATCHED')
        or exists(select 1 from public.hub_batch_members m join public.hub_inventory hi using(donation_id)
          where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE'
            and hi.inventory_status<>'BATCHED');
    end if;
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
  v_result jsonb; v_cfg text; v_did uuid;
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

  select count(*),count(*) filter(where e.handover_confirmed)
    into v_values,v_true from public.claim_reconciliation_evidence e where e.case_id=v_case.case_id;
  if v_values<2 then
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
              where d.donation_id=v_l.donation_id and d.donation_status='READY_FOR_PICKUP'))
         or (v_l.source_type='HUB_BATCH'
             and exists(select 1 from public.hub_batch_members m
               where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE')
             and not exists(select 1 from public.hub_batch_members m join public.donations d using(donation_id)
               where m.batch_id=v_l.batch_id and m.membership_status='ACTIVE'
                 and d.donation_status<>'BATCHED')
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
      'reconciliation_status',v_result->>'outcome'));
  return v_result;
end;
$function$;

-- CREATE OR REPLACE retains postgres ownership and existing EXECUTE grants:
-- recovery: postgres/service_role; reconciliation: postgres/authenticated/service_role.
-- No tables, constraints, policies, triggers or historical audit records change.
commit;

