# Exact deployed Flutter RPC inventory

Review only; captured 2026-10-21T13:46:09.519787Z.

All 36 have one deployed signature, owner `postgres` (BYPASSRLS), SECURITY DEFINER, authenticated/service_role EXECUTE. No PUBLIC EXECUTE entry was captured on these functions. Definitions and raw grants are in the JSON snapshot. An explicit search path is configuration evidence, not a full security proof.

| Signature | Configuration | anon EXECUTE | authenticated EXECUTE | service_role EXECUTE |
|---|---|---|---|---|
| `add_hub_batch_image(uuid,text,text,integer)` | `search_path=pg_catalog, public, pg_temp` | true | true | true |
| `cancel_claim(uuid,uuid)` | `search_path=pg_catalog, public, pg_temp` | false | true | true |
| `cancel_donation(uuid,uuid)` | `search_path=pg_catalog, public, pg_temp` | true | true | true |
| `claim_listing(uuid,uuid)` | `search_path=public, extensions, pg_temp` | false | true | true |
| `complete_pickup(uuid,boolean)` | `search_path=public, extensions, pg_temp` | true | true | true |
| `confirm_hub_receipt(uuid,numeric)` | `search_path=public, extensions, pg_temp` | true | true | true |
| `create_donation_with_images(uuid,text,text,text,double precision,double precision,jsonb,text,jsonb)` | `search_path=pg_catalog, public, extensions, storage, pg_temp` | true | true | true |
| `discover_eligible_listing_cards()` | `search_path=pg_catalog, public, extensions, pg_temp` | true | true | true |
| `geolock_app_capabilities()` | `search_path=pg_catalog, public, pg_temp` | true | true | true |
| `get_active_donation_categories()` | `search_path=pg_catalog, public, pg_temp` | true | true | true |
| `get_authorized_audit_events(text,uuid)` | `search_path=pg_catalog, public, pg_temp` | false | true | true |
| `get_claimed_listing_constituents(uuid)` | `search_path=pg_catalog, public, pg_temp` | true | true | true |
| `get_claimed_listing_detail(uuid)` | `search_path=pg_catalog, public, pg_temp` | true | true | true |
| `get_donation_images(uuid)` | `search_path=pg_catalog, public, pg_temp` | true | true | true |
| `get_eligible_hubs(uuid)` | `search_path=pg_catalog, public, pg_temp` | true | true | true |
| `get_eligible_listing_constituents(uuid)` | `search_path=pg_catalog, public, extensions, pg_temp` | true | true | true |
| `get_hub_batch_details(uuid,uuid)` | `search_path=pg_catalog, public, pg_temp` | true | true | true |
| `get_hub_dashboard(uuid)` | `search_path=pg_catalog, public, pg_temp` | true | true | true |
| `get_hub_donation_covers(uuid)` | `search_path=pg_catalog, public, pg_temp` | true | true | true |
| `get_my_claim_cards()` | `search_path=pg_catalog, public, pg_temp` | true | true | true |
| `get_my_claims()` | `search_path=pg_catalog, public, pg_temp` | true | true | true |
| `get_my_donation_dashboard_v2()` | `search_path=pg_catalog, public, pg_temp` | true | true | true |
| `get_my_donation_detail(uuid)` | `search_path=pg_catalog, public, pg_temp` | true | true | true |
| `get_my_hub_batches_dashboard(uuid)` | `search_path=pg_catalog, public, pg_temp` | true | true | true |
| `get_my_hub_inventory(uuid)` | `search_path=pg_catalog, public, pg_temp` | true | true | true |
| `get_my_hub_reservations(uuid)` | `search_path=pg_catalog, public, pg_temp` | true | true | true |
| `get_my_hubs()` | `search_path=pg_catalog, public, pg_temp` | true | true | true |
| `get_my_profile()` | `search_path=pg_catalog, public, pg_temp` | true | true | true |
| `get_my_reconciliation_cases()` | `search_path=pg_catalog, public, pg_temp` | false | true | true |
| `preview_location_routing(double precision,double precision)` | `search_path=public, extensions, pg_temp` | false | true | true |
| `publish_whole_donation_batch(uuid,uuid[])` | `search_path=public, extensions, pg_temp` | true | true | true |
| `register_community_hub(text,text,double precision,double precision,numeric,text)` | `search_path=public, extensions, pg_temp` | true | true | true |
| `register_role_profile(text,text,text,text,text,text,double precision,double precision,text)` | `search_path=pg_catalog, public, extensions, pg_temp` | true | true | true |
| `reserve_hub_capacity(uuid,uuid)` | `search_path=public, extensions, pg_temp` | true | true | true |
| `start_pickup(uuid)` | `search_path=public, extensions, pg_temp` | true | true | true |
| `submit_claim_reconciliation(uuid,boolean,uuid)` | `search_path=pg_catalog, public, pg_temp` | false | true | true |

## Flutter source call sites

- `add_hub_batch_image`: `frontend/geolock_hub_app/lib/donation_pages.dart:706`
- `cancel_claim`: `frontend/geolock_hub_app/lib/donation_pages.dart:1171`
- `cancel_donation`: `frontend/geolock_hub_app/lib/donation_pages.dart:2944`
- `claim_listing`: `frontend/geolock_hub_app/lib/donation_pages.dart:113`
- `complete_pickup`: `frontend/geolock_hub_app/lib/donation_pages.dart:1120`
- `confirm_hub_receipt`: `frontend/geolock_hub_app/lib/donation_pages.dart:494`
- `create_donation_with_images`: `frontend/geolock_hub_app/lib/donation_pages.dart:2168`
- `discover_eligible_listing_cards`: `frontend/geolock_hub_app/lib/dashboard_pages.dart:635`, `frontend/geolock_hub_app/lib/donation_pages.dart:96`
- `geolock_app_capabilities`: `frontend/geolock_hub_app/lib/auth/auth_controller.dart:77`, `frontend/geolock_hub_app/lib/dashboard_pages.dart:656`, `frontend/geolock_hub_app/lib/donation_pages.dart:88`
- `get_active_donation_categories`: `frontend/geolock_hub_app/lib/donation_pages.dart:2065`
- `get_authorized_audit_events`: `frontend/geolock_hub_app/lib/donation_pages.dart:639`, `frontend/geolock_hub_app/lib/donation_pages.dart:1223`, `frontend/geolock_hub_app/lib/donation_pages.dart:1610`, `frontend/geolock_hub_app/lib/donation_pages.dart:2759`, `frontend/geolock_hub_app/lib/donation_pages.dart:3965`
- `get_claimed_listing_constituents`: `frontend/geolock_hub_app/lib/donation_pages.dart:1572`
- `get_claimed_listing_detail`: `frontend/geolock_hub_app/lib/donation_pages.dart:1564`
- `get_donation_images`: `frontend/geolock_hub_app/lib/donation_pages.dart:1589`, `frontend/geolock_hub_app/lib/donation_pages.dart:2777`, `frontend/geolock_hub_app/lib/donation_pages.dart:3872`
- `get_eligible_hubs`: `frontend/geolock_hub_app/lib/donation_pages.dart:2842`
- `get_eligible_listing_constituents`: `frontend/geolock_hub_app/lib/donation_pages.dart:1434`
- `get_hub_batch_details`: `frontend/geolock_hub_app/lib/donation_pages.dart:4109`
- `get_hub_dashboard`: `frontend/geolock_hub_app/lib/dashboard_pages.dart:1054`, `frontend/geolock_hub_app/lib/dashboard_pages.dart:1254`
- `get_hub_donation_covers`: `frontend/geolock_hub_app/lib/donation_pages.dart:427`
- `get_my_claim_cards`: `frontend/geolock_hub_app/lib/donation_pages.dart:1105`, `frontend/geolock_hub_app/lib/donation_pages.dart:1597`
- `get_my_claims`: `frontend/geolock_hub_app/lib/dashboard_pages.dart:645`
- `get_my_donation_dashboard_v2`: `frontend/geolock_hub_app/lib/dashboard_pages.dart:217`, `frontend/geolock_hub_app/lib/dashboard_pages.dart:435`, `frontend/geolock_hub_app/lib/dashboard_pages.dart:1143`, `frontend/geolock_hub_app/lib/donation_pages.dart:2567`, `frontend/geolock_hub_app/lib/donation_pages.dart:2809`
- `get_my_donation_detail`: `frontend/geolock_hub_app/lib/donation_pages.dart:2194`, `frontend/geolock_hub_app/lib/donation_pages.dart:2748`
- `get_my_hub_batches_dashboard`: `frontend/geolock_hub_app/lib/donation_pages.dart:423`, `frontend/geolock_hub_app/lib/donation_pages.dart:4113`
- `get_my_hub_inventory`: `frontend/geolock_hub_app/lib/donation_pages.dart:422`, `frontend/geolock_hub_app/lib/donation_pages.dart:3942`
- `get_my_hub_reservations`: `frontend/geolock_hub_app/lib/donation_pages.dart:418`, `frontend/geolock_hub_app/lib/donation_pages.dart:3943`
- `get_my_hubs`: `frontend/geolock_hub_app/lib/dashboard_pages.dart:834`, `frontend/geolock_hub_app/lib/dashboard_pages.dart:1093`, `frontend/geolock_hub_app/lib/dashboard_pages.dart:1241`
- `get_my_profile`: `frontend/geolock_hub_app/lib/auth/auth_controller.dart:29`, `frontend/geolock_hub_app/lib/dashboard_pages.dart:242`, `frontend/geolock_hub_app/lib/dashboard_pages.dart:627`, `frontend/geolock_hub_app/lib/dashboard_pages.dart:1230`
- `get_my_reconciliation_cases`: `frontend/geolock_hub_app/lib/donation_pages.dart:947`
- `preview_location_routing`: `frontend/geolock_hub_app/lib/location/road_routing.dart:45`
- `publish_whole_donation_batch`: `frontend/geolock_hub_app/lib/donation_pages.dart:615`
- `register_community_hub`: `frontend/geolock_hub_app/lib/donation_pages.dart:332`
- `register_role_profile`: `frontend/geolock_hub_app/lib/auth/auth_controller.dart:86`
- `reserve_hub_capacity`: `frontend/geolock_hub_app/lib/donation_pages.dart:2883`
- `start_pickup`: `frontend/geolock_hub_app/lib/donation_pages.dart:1118`
- `submit_claim_reconciliation`: `frontend/geolock_hub_app/lib/donation_pages.dart:966`, `frontend/geolock_hub_app/lib/donation_pages.dart:1638`
