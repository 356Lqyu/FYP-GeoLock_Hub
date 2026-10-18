-- Stage 2 of the photo rollout. Apply only after clients have moved to
-- create_donation_with_images(uuid,...,jsonb). Existing rows are not scanned or
-- changed; only donations inserted after this trigger is enabled are affected.
-- The deferred check lets the creation RPC insert the donation/listing and its
-- 1–3 photo metadata in one transaction, while blocking zero-photo commits.

begin;

do $$
begin
  if to_regprocedure('public.create_donation_with_images(uuid,text,text,text,double precision,double precision,jsonb,text,jsonb)') is null
     or to_regclass('public.donation_images') is null then
    raise exception 'Deploy the photo transition migration before enforcing required photos';
  end if;
end $$;

create or replace function public.require_donation_photo_before_commit()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,pg_temp
as $$
begin
  if not exists(select 1 from public.donation_images i where i.donation_id=new.donation_id) then
    raise exception 'DONATION_REQUIRES_AT_LEAST_ONE_PHOTO';
  end if;
  return null;
end;
$$;

revoke all on function public.require_donation_photo_before_commit() from public,anon,authenticated;
drop trigger if exists donations_require_photo_at_commit on public.donations;
create constraint trigger donations_require_photo_at_commit
after insert on public.donations
deferrable initially deferred
for each row execute function public.require_donation_photo_before_commit();

commit;
