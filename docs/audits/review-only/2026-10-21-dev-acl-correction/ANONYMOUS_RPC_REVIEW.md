# Anonymous EXECUTE: separate authorization review

No function privileges or function defaults are changed by this package. EXECUTE does not prove that body-level authorization permits an operation.

## Flutter-called RPCs with explicit anon EXECUTE (30)

- `add_hub_batch_image(uuid,text,text,integer)`
- `cancel_donation(uuid,uuid)`
- `complete_pickup(uuid,boolean)`
- `confirm_hub_receipt(uuid,numeric)`
- `create_donation_with_images(uuid,text,text,text,double precision,double precision,jsonb,text,jsonb)`
- `discover_eligible_listing_cards()`
- `geolock_app_capabilities()`
- `get_active_donation_categories()`
- `get_claimed_listing_constituents(uuid)`
- `get_claimed_listing_detail(uuid)`
- `get_donation_images(uuid)`
- `get_eligible_hubs(uuid)`
- `get_eligible_listing_constituents(uuid)`
- `get_hub_batch_details(uuid,uuid)`
- `get_hub_dashboard(uuid)`
- `get_hub_donation_covers(uuid)`
- `get_my_claim_cards()`
- `get_my_claims()`
- `get_my_donation_dashboard_v2()`
- `get_my_donation_detail(uuid)`
- `get_my_hub_batches_dashboard(uuid)`
- `get_my_hub_inventory(uuid)`
- `get_my_hub_reservations(uuid)`
- `get_my_hubs()`
- `get_my_profile()`
- `publish_whole_donation_batch(uuid,uuid[])`
- `register_community_hub(text,text,double precision,double precision,numeric,text)`
- `register_role_profile(text,text,text,text,text,text,double precision,double precision,text)`
- `reserve_hub_capacity(uuid,uuid)`
- `start_pickup(uuid)`

## Other application functions/helpers/trigger functions with anon EXECUTE

Trigger-returning functions are catalog grants, not ordinary callable RPC endpoints.

- `add_donation_image(uuid,text,text,integer)` (returns `uuid`; SECURITY DEFINER=true)
- `assign_task_to_route(uuid,uuid,integer)` (returns `void`; SECURITY DEFINER=true)
- `can_read_geolock_batch_image(text)` (returns `boolean`; SECURITY DEFINER=true)
- `can_read_geolock_donation_image(text)` (returns `boolean`; SECURITY DEFINER=true)
- `create_and_validate_donation(text,text,text,double precision,double precision,jsonb,text,timestamp with time zone,timestamp with time zone)` (returns `uuid`; SECURITY DEFINER=true)
- `discover_eligible_listings()` (returns `TABLE(listing_id uuid, source_type text, listing_weight_kg numeric, listing_created_at timestamp with time zone)`; SECURITY DEFINER=true)
- `enforce_donation_transition()` (returns `trigger`; SECURITY DEFINER=false)
- `enforce_listing_transition()` (returns `trigger`; SECURITY DEFINER=false)
- `get_batch_images(uuid)` (returns `TABLE(image_id uuid, storage_path text, is_cover boolean, content_type text)`; SECURITY DEFINER=true)
- `get_my_donation_dashboard()` (returns `TABLE(donation_id uuid, title text, donation_status text, collection_path text, total_weight_kg numeric, created_at timestamp with time zone, hub_name text, reservation_status text, listing_status text, receipt_status text, inventory_status text, item_count bigint, primary_image_path text)`; SECURITY DEFINER=true)
- `get_my_donations()` (returns `TABLE(donation_id uuid, title text, donation_status text, collection_path text, total_weight_kg numeric, created_at timestamp with time zone, hub_name text, reservation_status text, listing_routing_status text)`; SECURITY DEFINER=true)
- `guard_batch_immutability()` (returns `trigger`; SECURITY DEFINER=false)
- `guard_donation_items()` (returns `trigger`; SECURITY DEFINER=false)
- `prevent_audit_mutation()` (returns `trigger`; SECURITY DEFINER=false)
- `prevent_role_change()` (returns `trigger`; SECURITY DEFINER=false)
- `require_donation_photo_before_commit()` (returns `trigger`; SECURITY DEFINER=true)

Future function defaults remain unchanged, including PostgreSQL's implicit global PUBLIC EXECUTE. Review separately; a schema-level default revoke cannot subtract a global default grant.
