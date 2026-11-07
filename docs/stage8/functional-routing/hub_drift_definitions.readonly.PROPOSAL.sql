-- PROPOSAL ONLY: separately approved native owner-export READ ONLY connection.
-- Exactly 27 function definitions/privileges; no application RPC is invoked.
\set ON_ERROR_STOP on
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout='15s';
SET LOCAL lock_timeout='2s';
SET LOCAL idle_in_transaction_session_timeout='60s';
SELECT jsonb_build_object('section','identity','observed_at',statement_timestamp(),
 'database',current_database(),'current_user',current_user,'session_user',session_user,
 'read_only',current_setting('transaction_read_only'),
 'ssl',(SELECT ssl FROM pg_catalog.pg_stat_ssl WHERE pid=pg_backend_pid()));
SELECT current_database()='postgres' AND current_user='postgres' AND session_user='postgres'
 AND current_setting('transaction_read_only')='on'
 AND coalesce((SELECT ssl FROM pg_catalog.pg_stat_ssl WHERE pid=pg_backend_pid()),false)
 AS approved_identity \gset
\if :approved_identity
\else
\echo IDENTITY_OR_READONLY_OR_TLS_GUARD_FAILED
ROLLBACK;
\quit 3
\endif
WITH expected(signature,expected_md5) AS (VALUES
 ('public.check_hub_batch(uuid,uuid[])','486ea91e688059ca12d466b755df49c0'),
 ('public.geolock_assert_donor_hub_choice(uuid)','8ba97af377e54581173f83910518849c'),
 ('public.geolock_assert_hub_spacing(uuid,double precision,double precision)','6c69bb9a87934eec5242394bf58a2702'),
 ('public.geolock_assert_my_hub(uuid)','1a2e24c780f4000091680b4a6bcd7f1b'),
 ('public.geolock_hub_candidates(uuid,timestamp with time zone)','f39f27682e3ae33534b4415d21da9bb9'),
 ('public.geolock_hub_dropoff_status(text,timestamp with time zone,boolean)','fc73304c711e001d3fc1e962e78cbb4b'),
 ('public.geolock_hub_is_verified(uuid)','f238d5b77083cd7dd51824077e00a304'),
 ('public.geolock_hub_location_sync()','f51721d853aad77e3b5330185e694190'),
 ('public.geolock_hub_open_minutes(jsonb,timestamp with time zone,timestamp with time zone)','413f9b299f9551f8049c81864b8ed01d'),
 ('public.geolock_hub_reference(uuid)','c4896d48a18841d4b37ea016521594c3'),
 ('public.geolock_min_handover_minutes()','4638bb23faecefc9b3d394bd003167e2'),
 ('public.geolock_normalise_phone(text)','ad5122fc56f762591f962fb37a793dcc'),
 ('public.geolock_require_hub_open()','c8182ef02cd1d7c5ad8a85efb9e245bc'),
 ('public.geolock_valid_operating_hours(jsonb)','ad43d81a58d159864b8b56a7b4fbda77'),
 ('public.get_eligible_hubs(uuid)','1444c3c9a1cee2700426558ed95fdf58'),
 ('public.get_hub_options(uuid)','04761baddae2999162653dcd740d3815'),
 ('public.get_my_hub_activity(uuid,integer)','75916be4383c1f062207f92c2e13ba3e'),
 ('public.get_my_hub_admin_status()','68d0a670f33983b5e57362e0aac36155'),
 ('public.get_my_hub_donation_detail(uuid,uuid)','68ed3ebc4bfd41b39037ccee9eac1b03'),
 ('public.get_my_hub_dropoff(uuid)','cb5d624b9688cfaebf2398d42878be5a'),
 ('public.get_my_hub_dropoffs(uuid)','06e1d44087d44219d292c7fa34eb21b2'),
 ('public.get_my_hub_inventory_v2(uuid)','2a259fe85bc4be72ce2a01bdb1aefb37'),
 ('public.get_my_hub_listings(uuid)','9444fe184901897c1bcc1713de85ca9d'),
 ('public.get_my_hub_service_rules(uuid)','d2878162f7fbc7cf5448939d1892dba5'),
 ('public.register_my_hub(text,text,double precision,double precision,numeric,text)','97c6455818384ea5378249313a43337a'),
 ('public.set_my_hub_service_rules(uuid,uuid[],jsonb)','4a41bc2ee4d20366d0934a6834bf92b9'),
 ('public.verify_my_hub_admin(text)','a6a534883ad057431bd64fdc28efe4ed')
)
SELECT jsonb_build_object('section','hub_drift_function','requested_signature',e.signature,
 'expected_md5',e.expected_md5,'present',p.oid IS NOT NULL,
 'current_md5',md5(replace(p.prosrc,E'\r\n',E'\n')),
 'matches_captured_fingerprint',md5(replace(p.prosrc,E'\r\n',E'\n'))=e.expected_md5,
 'owner',p.proowner::regrole::text,'security_definer',p.prosecdef,'volatility',p.provolatile,
 'argument_names',p.proargnames,'return_type',pg_get_function_result(p.oid),
 'settings',p.proconfig,'acl',p.proacl::text,'definition',pg_get_functiondef(p.oid),
 'effective_execute',(SELECT jsonb_agg(jsonb_build_object('role',r.rolname,
 'execute',has_function_privilege(r.oid,p.oid,'EXECUTE')) ORDER BY r.rolname)
 FROM pg_catalog.pg_roles r WHERE r.rolname IN('anon','authenticated','service_role',
 'geolock_graph_worker','geolock_planner','geolock_validator','geolock_route_resolver')))
FROM expected e LEFT JOIN pg_catalog.pg_proc p ON p.oid=to_regprocedure(e.signature)
ORDER BY e.signature;
ROLLBACK;
