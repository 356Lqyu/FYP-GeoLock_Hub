-- REVIEW/ISOLATED TEST ONLY. Not approved or deployed. No owner/ACL changes.
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

    -- An existing unresolved case is custody evidence even if stored statuses drift.
    v_uncertain := exists(select 1 from public.claim_reconciliation_cases rc
        where rc.claim_id=v_c.claim_id and rc.case_status in ('OPEN','MANUAL_REVIEW'))
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
          case when v_l.source_type='DIRECT_DONATION' then 'AVAILABLE' else 'BATCHED' end);
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
