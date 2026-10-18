-- GeoLock Hub lifecycle decision: COLLECTED is the terminal donation state.
-- Separate, narrowly scoped forward migration. Check for DELIVERED rows in the
-- exact target database immediately before applying; this migration refuses to
-- run if any exist. Preserve audit history and all other donation records.
-- NOT executed.

begin;

do $$
begin
  if exists (select 1 from public.donations where donation_status='DELIVERED') then
    raise exception 'DELIVERED_ROWS_EXIST: review and reconcile before retiring state';
  end if;
  if not exists (select 1 from pg_constraint where conrelid='public.donations'::regclass
      and conname='donations_donation_status_check') then
    raise exception 'EXPECTED_DONATION_STATUS_CONSTRAINT_MISSING';
  end if;
end $$;

alter table public.donations drop constraint donations_donation_status_check;
alter table public.donations add constraint donations_donation_status_check
  check (donation_status = any (array[
    'SUBMITTED'::text,'VALIDATED'::text,'READY_FOR_PICKUP'::text,
    'HUB_ASSIGNED'::text,'AT_HUB'::text,'BATCHED'::text,
    'PICKUP_IN_PROGRESS'::text,'COLLECTED'::text,'CANCELLED'::text
  ]));

create or replace function public.enforce_donation_transition()
returns trigger language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op='UPDATE' and new.donation_status is distinct from old.donation_status then
    if not (
      (old.donation_status='SUBMITTED' and new.donation_status in ('VALIDATED','CANCELLED'))
      or (old.donation_status='VALIDATED' and new.donation_status in ('READY_FOR_PICKUP','HUB_ASSIGNED','CANCELLED'))
      or (old.donation_status='READY_FOR_PICKUP' and new.donation_status in ('PICKUP_IN_PROGRESS','CANCELLED'))
      or (old.donation_status='HUB_ASSIGNED' and new.donation_status in ('AT_HUB','CANCELLED'))
      or (old.donation_status='AT_HUB' and new.donation_status='BATCHED')
      or (old.donation_status='BATCHED' and new.donation_status='PICKUP_IN_PROGRESS')
      or (old.donation_status='PICKUP_IN_PROGRESS' and new.donation_status='COLLECTED')
    ) then
      raise exception 'INVALID_DONATION_TRANSITION: % -> %',old.donation_status,new.donation_status;
    end if;
  end if;
  new.updated_at=clock_timestamp();
  return new;
end;
$$;

commit;
