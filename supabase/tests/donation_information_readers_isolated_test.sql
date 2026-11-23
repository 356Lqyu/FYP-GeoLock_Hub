-- Minimal synthetic schema. Helpers stand in for deployed road/image decisions.
CREATE ROLE anon;
CREATE ROLE authenticated;
CREATE ROLE service_role;
ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO anon, service_role;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
CREATE FUNCTION public.fixture_id(i integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT lpad(i::text, 32, '0')::uuid
$$;
CREATE FUNCTION public.fixture_assert(ok boolean, scenario text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Failed: %', scenario; END IF;
END;
$$;
CREATE TABLE public.ngo_profiles(user_id uuid PRIMARY KEY, location_verified_at timestamptz, active_flag boolean);
CREATE TABLE public.donor_profiles(user_id uuid PRIMARY KEY);
CREATE TABLE public.coordination_config(singleton boolean PRIMARY KEY);
CREATE TABLE public.donations(
  donation_id uuid PRIMARY KEY, donor_user_id uuid, title text, description text,
  donation_status text, collection_path text, total_weight_kg numeric, created_at timestamptz DEFAULT now()
);
CREATE TABLE public.donation_items(
  item_id int PRIMARY KEY, donation_id uuid REFERENCES public.donations, quantity integer NOT NULL CHECK (quantity > 0)
);
CREATE INDEX ON public.donation_items(donation_id);
CREATE TABLE public.hub_batches(batch_id uuid PRIMARY KEY, batch_status text);
CREATE TABLE public.hub_batch_members(
  batch_id uuid, donation_id uuid, membership_status text, PRIMARY KEY (batch_id, donation_id)
);
CREATE UNIQUE INDEX ON public.hub_batch_members(donation_id) WHERE membership_status = 'ACTIVE';
CREATE TABLE public.listings(
  listing_id uuid PRIMARY KEY, source_type text, donation_id uuid, batch_id uuid,
  listing_status text, listing_weight_kg numeric, created_at timestamptz DEFAULT now(),
  listing_expires_at timestamptz
);
CREATE TABLE public.donation_images(donation_id uuid, display_order integer, storage_path text, owner_user_id uuid, is_primary boolean);
CREATE TABLE public.hub_batch_images(batch_id uuid, storage_path text, is_primary boolean);
CREATE TABLE public.donation_claims(claim_id uuid PRIMARY KEY, listing_id uuid, ngo_user_id uuid, claim_status text);
CREATE TABLE public.claim_leases(claim_id uuid PRIMARY KEY, lease_status text, expires_at timestamptz);
CREATE TABLE public.community_hubs(hub_id uuid PRIMARY KEY, hub_name text);
CREATE TABLE public.hub_inventory(donation_id uuid PRIMARY KEY, inventory_status text);
CREATE TABLE public.hub_reservations(reservation_id uuid PRIMARY KEY, hub_id uuid, donation_id uuid, reservation_status text, expires_at timestamptz, reserved_at timestamptz);
CREATE TABLE public.hub_receipts(reservation_id uuid PRIMARY KEY, receipt_status text);
ALTER TABLE public.donations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.donation_items ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.donations, public.donation_items TO anon, authenticated;

CREATE FUNCTION public.geolock_road_eligible_km(p_ngo uuid, p_listing uuid)
RETURNS double precision LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN p_ngo = public.fixture_id(100) AND p_listing <> public.fixture_id(16) THEN 5.2 END
$$;
CREATE FUNCTION public.can_read_geolock_donation_image(p_path text) RETURNS boolean LANGUAGE sql AS $$
  SELECT p_path LIKE 'allowed/%'
$$;
CREATE FUNCTION public.can_read_geolock_batch_image(p_path text) RETURNS boolean LANGUAGE sql AS $$
  SELECT p_path LIKE 'allowed/%'
$$;
REVOKE EXECUTE ON FUNCTION public.geolock_road_eligible_km(uuid, uuid) FROM PUBLIC, anon, authenticated;

\i :migration

INSERT INTO public.ngo_profiles VALUES
  (fixture_id(100), now(), true), (fixture_id(101), now(), true),
  (fixture_id(102), now(), false), (fixture_id(103), NULL, true);
INSERT INTO public.donor_profiles VALUES (fixture_id(200)), (fixture_id(201));
INSERT INTO public.coordination_config VALUES (true);
INSERT INTO public.donations (donation_id, donor_user_id, title, description, donation_status, collection_path, total_weight_kg)
SELECT fixture_id(i), fixture_id(CASE WHEN i = 3 THEN 201 ELSE 200 END), 'Donation ' || i,
       CASE WHEN i = 4 THEN E' \t\n' ELSE 'Saved text ' || i END,
       'AVAILABLE', 'DIRECT_PICKUP', 10
FROM generate_series(1, 6) AS i;
INSERT INTO public.donation_items VALUES
  (1, fixture_id(1), 2), (2, fixture_id(1), 6), (3, fixture_id(2), 3),
  (4, fixture_id(3), 9), (5, fixture_id(4), 99);
INSERT INTO public.hub_batches VALUES (fixture_id(20), 'PUBLISHED'), (fixture_id(21), 'PUBLISHED');
INSERT INTO public.hub_batch_members VALUES
  (fixture_id(20), fixture_id(2), 'ACTIVE'), (fixture_id(20), fixture_id(3), 'ACTIVE'),
  (fixture_id(20), fixture_id(4), 'RELEASED'), (fixture_id(21), fixture_id(5), 'ACTIVE');
INSERT INTO public.listings (listing_id, source_type, donation_id, batch_id, listing_status, listing_weight_kg)
VALUES (fixture_id(10), 'DIRECT_DONATION', fixture_id(1), NULL, 'AVAILABLE', 10),
       (fixture_id(11), 'HUB_BATCH', NULL, fixture_id(20), 'AVAILABLE', 20),
       (fixture_id(12), 'HUB_BATCH', NULL, fixture_id(21), 'AVAILABLE', 10),
       (fixture_id(13), 'DIRECT_DONATION', fixture_id(6), NULL, 'AVAILABLE', 10),
       (fixture_id(14), 'DIRECT_DONATION', fixture_id(1), NULL, 'CLAIMED', 10),
       (fixture_id(15), 'DIRECT_DONATION', fixture_id(4), NULL, 'AVAILABLE', 10),
       (fixture_id(16), 'DIRECT_DONATION', fixture_id(2), NULL, 'AVAILABLE', 10);
INSERT INTO public.donation_images VALUES
  (fixture_id(1), 1, 'allowed/main', fixture_id(200), true),
  (fixture_id(1), 2, 'allowed/extra', fixture_id(200), false),
  (fixture_id(2), 1, 'restricted/cover', fixture_id(200), true);
INSERT INTO public.hub_batch_images VALUES (fixture_id(20), 'allowed/batch', true);
INSERT INTO public.donation_claims VALUES (fixture_id(30), fixture_id(14), fixture_id(100), 'ACTIVE');
INSERT INTO public.claim_leases VALUES (fixture_id(30), 'ACTIVE', now() + interval '1 hour');

SELECT fixture_assert(
  (SELECT bool_and(NOT has_function_privilege('anon', reader, 'EXECUTE')
                   AND NOT has_function_privilege('service_role', reader, 'EXECUTE')
                   AND has_function_privilege('authenticated', reader, 'EXECUTE'))
   FROM unnest(ARRAY['discover_eligible_listing_cards_v2()', 'get_eligible_listing_constituents_v2(uuid)',
        'get_claimed_listing_constituents_v2(uuid)', 'get_my_donation_dashboard_v3()']) AS reader),
  'effective grants for all four RPCs');
SET ROLE anon;
DO $$ BEGIN
  PERFORM * FROM discover_eligible_listing_cards_v2();
  RAISE EXCEPTION 'Anonymous execution succeeded';
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
RESET ROLE;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', fixture_id(100)::text, false);
SELECT fixture_assert(
  (SELECT count(*) = 5 AND count(*) FILTER (WHERE listing_total_item_quantity IS NULL) = 2
     AND max(listing_total_item_quantity) FILTER (WHERE listing_id = fixture_id(10)) = 8
     AND max(listing_total_item_quantity) FILTER (WHERE listing_id = fixture_id(11)) = 12
     AND max(primary_image_path) FILTER (WHERE listing_id = fixture_id(10)) = 'allowed/main'
   FROM discover_eligible_listing_cards_v2()),
  'direct, active batch, missing items, multiple photos and discovery eligibility');
SELECT fixture_assert(
  (SELECT array_agg(donation_description ORDER BY donation_id) = ARRAY['Saved text 2', 'Saved text 3']
     AND count(primary_image_path) = 0
   FROM get_eligible_listing_constituents_v2(fixture_id(11))),
  'per-donation batch descriptions and image checks exclude released members');
SELECT fixture_assert(
  (SELECT count(*) = 1 AND count(donation_description) = 0
   FROM get_eligible_listing_constituents_v2(fixture_id(15))), 'whitespace description');
SELECT fixture_assert(
  (SELECT donation_description = 'Saved text 1'
   FROM get_claimed_listing_constituents_v2(fixture_id(30))), 'valid owned active claim');
SELECT set_config('request.jwt.claim.sub', fixture_id(101)::text, false);
SELECT fixture_assert((SELECT count(*) = 0 FROM discover_eligible_listing_cards_v2()), 'unrelated NGO discovery');
DO $$ BEGIN
  PERFORM * FROM get_claimed_listing_constituents_v2(fixture_id(30));
  RAISE EXCEPTION 'Unrelated claimant read succeeded';
EXCEPTION WHEN raise_exception THEN
  IF SQLERRM <> 'CLAIM_NOT_FOUND_OR_FORBIDDEN' THEN RAISE; END IF;
END $$;
DO $$ BEGIN
  PERFORM * FROM get_eligible_listing_constituents_v2(fixture_id(10));
  RAISE EXCEPTION 'Ineligible details read succeeded';
EXCEPTION WHEN raise_exception THEN
  IF SQLERRM <> 'LISTING_NOT_ELIGIBLE' THEN RAISE; END IF;
END $$;
SELECT set_config('request.jwt.claim.sub', fixture_id(103)::text, false);
DO $$ BEGIN
  PERFORM * FROM get_eligible_listing_constituents_v2(fixture_id(10));
  RAISE EXCEPTION 'Unverified details read succeeded';
EXCEPTION WHEN raise_exception THEN
  IF SQLERRM <> 'VERIFIED_NGO_ONLY' THEN RAISE; END IF;
END $$;

SELECT set_config('request.jwt.claim.sub', fixture_id(200)::text, false);
SELECT fixture_assert(
  (SELECT count(*) = 5
      AND max(item_count) FILTER (WHERE donation_id = fixture_id(1)) = 2
      AND max(total_item_quantity) FILTER (WHERE donation_id = fixture_id(1)) = 8
      AND count(total_item_quantity) FILTER (WHERE donation_id = fixture_id(6)) = 0
      AND count(*) FILTER (WHERE donation_id = fixture_id(3)) = 0
   FROM get_my_donation_dashboard_v3()), 'donor ownership, item entries and total units');
SELECT set_config('request.jwt.claim.sub', fixture_id(201)::text, false);
SELECT fixture_assert(
  (SELECT count(*) = 1 AND max(total_item_quantity) = 9 FROM get_my_donation_dashboard_v3()),
  'other donor sees only their own donation');
RESET ROLE;

UPDATE public.listings SET listing_expires_at = now() - interval '1 second' WHERE listing_id = fixture_id(14);
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', fixture_id(100)::text, false);
SELECT fixture_assert(
  (SELECT count(*) = 1 AND count(donation_description) = 0
   FROM get_claimed_listing_constituents_v2(fixture_id(30))), 'expired listing redaction');
RESET ROLE;
UPDATE public.listings SET listing_expires_at = NULL WHERE listing_id = fixture_id(14);
UPDATE public.ngo_profiles SET active_flag = false WHERE user_id = fixture_id(100);
SET ROLE authenticated;
SELECT fixture_assert(
  (SELECT count(*) = 1 AND count(donation_description) = 0
   FROM get_claimed_listing_constituents_v2(fixture_id(30))), 'inactive NGO redaction');
RESET ROLE;
UPDATE public.ngo_profiles SET active_flag = true WHERE user_id = fixture_id(100);
UPDATE public.claim_leases SET expires_at = now() - interval '1 second';
SET ROLE authenticated;
DO $$ BEGIN
  PERFORM * FROM get_claimed_listing_constituents_v2(fixture_id(30));
  RAISE EXCEPTION 'An elapsed active lease returned constituents';
EXCEPTION WHEN raise_exception THEN
  IF SQLERRM <> 'CLAIM_NOT_FOUND_OR_FORBIDDEN' THEN RAISE; END IF;
END $$;
RESET ROLE;

DO $claim_states$
DECLARE state text;
BEGIN
  FOREACH state IN ARRAY ARRAY['COMPLETED','RECONCILIATION_REQUIRED','RELEASED','EXPIRED','CANCELLED'] LOOP
    UPDATE public.donation_claims SET claim_status = state;
    SET LOCAL ROLE authenticated;
    IF state IN ('COMPLETED','RECONCILIATION_REQUIRED') THEN
      PERFORM fixture_assert(
        (SELECT count(*) = 1 AND count(donation_description) = 0
         FROM get_claimed_listing_constituents_v2(fixture_id(30))), state || ' retains rows without descriptions');
    ELSE
      BEGIN
        PERFORM * FROM get_claimed_listing_constituents_v2(fixture_id(30));
        RAISE EXCEPTION 'Historical state % returned constituents', state;
      EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'CLAIM_NOT_FOUND_OR_FORBIDDEN' THEN RAISE; END IF;
      END;
    END IF;
    RESET ROLE;
  END LOOP;
END;
$claim_states$;

SELECT 'PASS: donation reader SQL integration and authorization assertions' AS result;
