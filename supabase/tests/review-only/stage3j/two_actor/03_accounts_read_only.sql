-- SELECT ONLY, DEV rcgyuwiidqvrgbxswhqj. No auth emails, JWTs, private photos or coordinates.
SELECT statement_timestamp() AS checked_at,n.user_id,n.active_flag,
 n.location_verified_at IS NOT NULL AS has_technical_verification,
 n.road_node_id IS NOT NULL AS has_road_node,
 (SELECT count(*) FROM public.listings WHERE listing_status='AVAILABLE') AS available_listing_count
FROM public.ngo_profiles n ORDER BY n.user_id;
-- These flags do not establish eligibility for a specific test listing.
-- The runner additionally verifies /auth/v1/user and authorized discovery.
