-- SELECT-ONLY; DEV rcgyuwiidqvrgbxswhqj only. Confirm project URL out of band.
-- Execute each CHECK separately when the tool returns only the final result set.
-- PREPARED ONLY: run after separately authorized successful migration, before mutation tests.
-- V08 calls only the audited SQL STABLE read-only catalog-fingerprint helper, as postgres.
-- CHECK: C01_context
SELECT jsonb_build_object('check_id','C01_context','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT current_database() AS database_name,current_user AS execution_role,
 current_setting('server_version') AS server_version,current_setting('search_path') AS search_path,
 current_setting('transaction_isolation') AS isolation,clock_timestamp() AS observed_at
) q;

-- CHECK: C02_columns
SELECT jsonb_build_object('check_id','C02_columns','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT a.attname,format_type(a.atttypid,a.atttypmod) AS data_type,a.attnotnull,
 pg_get_expr(d.adbin,d.adrelid) AS default_expression,a.attacl
 FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
 WHERE a.attrelid='public.vehicles'::regclass AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum
) q;

-- CHECK: C03_constraints
SELECT jsonb_build_object('check_id','C03_constraints','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT c.conrelid::regclass::text AS table_name,c.conname,c.contype,c.convalidated,
 pg_get_constraintdef(c.oid) AS definition FROM pg_constraint c
 WHERE c.conrelid IN ('public.vehicles'::regclass,'public.pickup_routes'::regclass)
 OR c.confrelid='public.vehicles'::regclass ORDER BY table_name,c.conname
) q;

-- CHECK: C04_acl_rls
SELECT jsonb_build_object('check_id','C04_acl_rls','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT n.nspname AS schema_name,c.relname,c.relowner::regrole::text AS owner,
 c.relrowsecurity,c.relforcerowsecurity,
 (SELECT coalesce(jsonb_agg(jsonb_build_object('grantee',CASE WHEN x.grantee=0 THEN 'PUBLIC' ELSE x.grantee::regrole::text END,
   'privilege',x.privilege_type,'grant_option',x.is_grantable) ORDER BY x.grantee,x.privilege_type),'[]'::jsonb)
   FROM aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) x) AS acl,
 (SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.policyname),'[]'::jsonb)
   FROM pg_policies p WHERE p.schemaname=n.nspname AND p.tablename=c.relname) AS policies
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE c.oid IN ('public.vehicles'::regclass,'public.pickup_routes'::regclass) ORDER BY c.relname
) q;

-- CHECK: C05_effective_privileges
SELECT jsonb_build_object('check_id','C05_effective_privileges','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT r.rolname,r.rolbypassrls,p.privilege,
 has_table_privilege(r.rolname,'public.vehicles',p.privilege) AS allowed,
 has_table_privilege(r.rolname,'public.vehicles',p.privilege||' WITH GRANT OPTION') AS grant_option
 FROM pg_roles r CROSS JOIN (VALUES('SELECT'),('INSERT'),('UPDATE'),('DELETE'),('TRUNCATE'),('REFERENCES'),('TRIGGER'),('MAINTAIN')) p(privilege)
 WHERE r.rolname IN ('anon','authenticated','service_role') ORDER BY r.rolname,p.privilege
) q;

-- CHECK: C06_counts
SELECT jsonb_build_object('check_id','C06_counts','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT (SELECT count(*) FROM public.vehicles) AS vehicles,
 (SELECT count(*) FROM public.pickup_routes) AS routes,
 (SELECT count(*) FROM public.pickup_route_stops) AS stops,
 (SELECT count(*) FROM public.active_task_route_assignments) AS active_assignments,
 (SELECT count(*) FROM public.pickup_routes WHERE route_status IN ('DRAFT','VALIDATED','AUTHORISED','IN_PROGRESS')) AS nonterminal_routes
) q;

-- CHECK: C07_route_activity
SELECT jsonb_build_object('check_id','C07_route_activity','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT r.route_id,r.vehicle_id,r.ngo_user_id,r.route_status,r.planned_at,
 (SELECT count(*) FROM public.active_task_route_assignments a WHERE a.route_id=r.route_id) AS assignments,
 (SELECT count(*) FROM public.pickup_route_stops s JOIN public.pickup_tasks t USING(task_id)
   WHERE s.route_id=r.route_id AND t.task_status IN ('PLANNED','DISPATCHED')) AS unresolved_stops
 FROM public.pickup_routes r ORDER BY r.route_id
) q;

-- CHECK: C08_vehicle_functions
SELECT jsonb_build_object('check_id','C08_vehicle_functions','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) AS arguments,
 p.proowner::regrole::text AS owner,p.prosecdef,p.provolatile,p.proconfig,p.proacl,
 pg_get_functiondef(p.oid) AS definition
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE p.prokind='f'
 AND n.nspname NOT IN ('pg_catalog','information_schema') AND p.prosrc ILIKE '%vehicles%'
 ORDER BY n.nspname,p.proname,arguments
) q;

-- CHECK: C09_dependencies
SELECT jsonb_build_object('check_id','C09_dependencies','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT pg_describe_object(d.classid,d.objid,d.objsubid) AS dependent,
 pg_describe_object(d.refclassid,d.refobjid,d.refobjsubid) AS referenced,d.deptype
 FROM pg_depend d WHERE (d.refclassid='pg_class'::regclass
 AND d.refobjid IN ('public.vehicles'::regclass,'public.pickup_routes'::regclass))
 ORDER BY dependent,referenced,d.deptype
) q;

-- CHECK: C10_legacy_vehicle_rows
SELECT jsonb_build_object('check_id','C10_legacy_vehicle_rows','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT vehicle_id,ngo_user_id,vehicle_label,payload_capacity_kg,depot_road_node_id,active_flag
 FROM public.vehicles ORDER BY vehicle_id
) q;

-- CHECK: C11_fleet_objects
SELECT jsonb_build_object('check_id','C11_fleet_objects','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) AS arguments,
 p.proowner::regrole::text AS owner,p.prosecdef,p.provolatile,p.proconfig,p.proacl,pg_get_functiondef(p.oid) AS definition
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE p.prokind='f'
 AND (n.nspname='fleet_private' OR (n.nspname='public' AND p.proname IN ('register_my_vehicle','list_my_vehicles','update_my_vehicle','set_my_vehicle_availability','deactivate_my_vehicle')))
 ORDER BY n.nspname,p.proname,arguments
) q;

-- CHECK: C12_triggers_indexes
SELECT jsonb_build_object('check_id','C12_triggers_indexes','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT 'trigger' AS kind,c.relname AS table_name,t.tgname AS name,t.tgenabled::text AS enabled,
 pg_get_triggerdef(t.oid) AS definition FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
 WHERE t.tgrelid IN ('public.vehicles'::regclass,'public.pickup_routes'::regclass) AND NOT t.tgisinternal
 UNION ALL SELECT 'index',c.relname,i.indexrelid::regclass::text,i.indisvalid::text,pg_get_indexdef(i.indexrelid)
 FROM pg_index i JOIN pg_class c ON c.oid=i.indrelid
 WHERE i.indrelid IN ('public.vehicles'::regclass,'public.pickup_routes'::regclass) ORDER BY kind,table_name,name
) q;

-- CHECK: C13_role_capabilities
SELECT jsonb_build_object('check_id','C13_role_capabilities','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT r.rolname,r.rolbypassrls,r.rolsuper,r.rolcreaterole,
 has_schema_privilege(r.rolname,'public','CREATE') AS public_create,
 has_parameter_privilege(r.rolname,'session_replication_role','SET') AS replication_role_set,
 pg_has_role(r.rolname,'postgres','USAGE') AS inherits_postgres,
 (SELECT coalesce(jsonb_agg(jsonb_build_object('role',m.roleid::regrole::text,'inherit',m.inherit_option,'set',m.set_option)
  ORDER BY m.roleid),'[]'::jsonb) FROM pg_auth_members m WHERE m.member=r.oid) AS memberships
 FROM pg_roles r WHERE r.rolname IN ('anon','authenticated','service_role') ORDER BY r.rolname
) q;

-- CHECK: C14_vehicle_relations
SELECT jsonb_build_object('check_id','C14_vehicle_relations','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT n.nspname,c.relname,a.attname FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid
 JOIN pg_namespace n ON n.oid=c.relnamespace WHERE a.attname IN ('vehicle_id','reserved_vehicle_id')
 AND NOT a.attisdropped AND c.relkind IN ('r','p','v') AND n.nspname NOT IN ('pg_catalog','information_schema') ORDER BY 1,2,3
) q;

-- CHECK: C15_depot_identity
SELECT jsonb_build_object('check_id','C15_depot_identity','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT p.proname,pg_get_function_identity_arguments(p.oid) AS arguments,
 pg_get_functiondef(p.oid) AS definition,p.proacl FROM pg_proc p WHERE p.pronamespace='public'::regnamespace
 AND p.prokind='f' AND p.proname IN ('geolock_assign_vehicle_depot','set_ngo_operating_location',
 'verify_ngo_location','geolock_backfill_road_nodes') ORDER BY p.proname,arguments
) q;

-- CHECK: C16_route_jobs
SELECT jsonb_build_object('check_id','C16_route_jobs','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT jobname,schedule,active,command FROM cron.job
 WHERE jobname ILIKE '%route%' OR command ILIKE '%pickup_routes%' ORDER BY jobname
) q;

-- CHECK: C17_route_row_hashes
SELECT jsonb_build_object('check_id','C17_route_row_hashes','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT route_id,encode(sha256(convert_to(to_jsonb(r)::text,'UTF8')),'hex') AS sha256
 FROM public.pickup_routes r ORDER BY route_id
) q;

-- CHECK: C18_assignment_hashes
SELECT jsonb_build_object('check_id','C18_assignment_hashes','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT task_id,encode(sha256(convert_to(to_jsonb(a)::text,'UTF8')),'hex') AS sha256
 FROM public.active_task_route_assignments a ORDER BY task_id
) q;

-- CHECK: C19_invalid_legacy_capacity
SELECT jsonb_build_object('check_id','C19_invalid_legacy_capacity','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT vehicle_id,payload_capacity_kg FROM public.vehicles
 WHERE payload_capacity_kg<=0 OR payload_capacity_kg IN ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric) ORDER BY vehicle_id
) q;

-- CHECK: C20_private_schema
SELECT jsonb_build_object('check_id','C20_private_schema','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT n.nspname,n.nspowner::regrole::text AS owner,obj_description(n.oid,'pg_namespace') AS marker
 FROM pg_namespace n WHERE n.nspname='fleet_private'
) q;

-- CHECK: L01_protected_object_fingerprints
SELECT jsonb_build_object('check_id','L01_protected_object_fingerprints','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT kind,identity,encode(sha256(convert_to(payload::text,'UTF8')),'hex') AS sha256 FROM (
 SELECT 'function' AS kind,n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')' AS identity,
 jsonb_build_array(pg_get_functiondef(p.oid),p.proowner::regrole::text,p.proacl,p.proconfig) AS payload
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind IN ('f','p')
 AND p.proname NOT IN ('register_my_vehicle','list_my_vehicles','update_my_vehicle','set_my_vehicle_availability','deactivate_my_vehicle')
 UNION ALL SELECT 'relation',n.nspname||'.'||c.relname,jsonb_build_array(c.relkind,c.relowner::regrole::text,
 c.relacl,c.relrowsecurity,c.relforcerowsecurity,c.reloptions)
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public'
 AND c.relkind IN ('r','p','v','m','S') AND c.relname NOT IN ('vehicles','pickup_routes')
 UNION ALL SELECT 'column',n.nspname||'.'||c.relname||'.'||a.attname,
 jsonb_build_array(format_type(a.atttypid,a.atttypmod),a.attnotnull,a.attidentity,a.attgenerated,a.attacl,
 pg_get_expr(d.adbin,d.adrelid)) FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid
 JOIN pg_namespace n ON n.oid=c.relnamespace LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
 WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m') AND c.relname NOT IN ('vehicles','pickup_routes')
 AND a.attnum>0 AND NOT a.attisdropped
 UNION ALL SELECT 'constraint',n.nspname||'.'||c.relname||'.'||k.conname,
 jsonb_build_array(pg_get_constraintdef(k.oid),k.convalidated)
 FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='public' AND c.relname NOT IN ('vehicles','pickup_routes')
 UNION ALL SELECT 'trigger',n.nspname||'.'||c.relname||'.'||t.tgname,
 jsonb_build_array(pg_get_triggerdef(t.oid),t.tgenabled) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
 JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND NOT t.tgisinternal
 AND c.relname NOT IN ('vehicles','pickup_routes')
 UNION ALL SELECT 'index',n.nspname||'.'||ic.relname,jsonb_build_array(pg_get_indexdef(i.indexrelid),i.indisvalid)
 FROM pg_index i JOIN pg_class c ON c.oid=i.indrelid JOIN pg_class ic ON ic.oid=i.indexrelid
 JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname NOT IN ('vehicles','pickup_routes')
 UNION ALL SELECT 'policy',p.schemaname||'.'||p.tablename||'.'||p.policyname,to_jsonb(p)
 FROM pg_policies p WHERE p.schemaname='public' AND p.tablename NOT IN ('vehicles','pickup_routes')
 UNION ALL SELECT 'type',n.nspname||'.'||t.typname,jsonb_build_array(t.typtype,t.typowner::regrole::text,t.typnotnull,
 t.typdefault,(SELECT jsonb_agg(e.enumlabel ORDER BY e.enumsortorder) FROM pg_enum e WHERE e.enumtypid=t.oid))
 FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace WHERE n.nspname='public' AND t.typtype IN ('e','d')
 UNION ALL SELECT 'default_acl',r.rolname||'.'||coalesce(n.nspname,'GLOBAL')||'.'||d.defaclobjtype::text,
 to_jsonb(d.defaclacl) FROM pg_default_acl d JOIN pg_roles r ON r.oid=d.defaclrole
 LEFT JOIN pg_namespace n ON n.oid=d.defaclnamespace WHERE n.nspname='public' OR d.defaclnamespace=0
) objects ORDER BY kind,identity
) q;

-- CHECK: V01_expected_columns
SELECT jsonb_build_object('check_id','V01_expected_columns','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT e.name,e.type_name AS expected_type,e.required AS expected_not_null,
 format_type(a.atttypid,a.atttypmod) AS actual_type,a.attnotnull,
 coalesce(format_type(a.atttypid,a.atttypmod)=e.type_name AND a.attnotnull=e.required,false) AS pass
 FROM (VALUES('vehicle_type','text',false),('fixed_cost_rm','numeric',false),('distance_cost_rm_per_km','numeric',false),
 ('max_route_duration_min','numeric',false),('available_for_planning','boolean',true),('vehicle_version','bigint',true),
 ('updated_at','timestamp with time zone',true),('registration_request_id','uuid',false),('registration_payload','jsonb',false)) e(name,type_name,required)
 LEFT JOIN pg_attribute a ON a.attrelid='public.vehicles'::regclass AND a.attname=e.name AND NOT a.attisdropped ORDER BY e.name
) q;

-- CHECK: V02_table_permission_assertions
SELECT jsonb_build_object('check_id','V02_table_permission_assertions','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT r.role,p.privilege,has_table_privilege(r.role,'public.vehicles',p.privilege) AS actual,
 (r.role='service_role' AND p.privilege IN ('SELECT','INSERT','UPDATE')) AS expected,
 has_table_privilege(r.role,'public.vehicles',p.privilege)=(r.role='service_role' AND p.privilege IN ('SELECT','INSERT','UPDATE')) AS pass
 FROM (VALUES('anon'),('authenticated'),('service_role')) r(role)
 CROSS JOIN (VALUES('SELECT'),('INSERT'),('UPDATE'),('DELETE'),('TRUNCATE'),('REFERENCES'),('TRIGGER'),('MAINTAIN')) p(privilege) ORDER BY r.role,p.privilege
) q;

-- CHECK: V03_column_permission_assertions
SELECT jsonb_build_object('check_id','V03_column_permission_assertions','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT r.role,a.attname,p.privilege,
 NOT has_column_privilege(r.role,'public.vehicles',a.attname,p.privilege) AS pass
 FROM (VALUES('anon'),('authenticated')) r(role) CROSS JOIN pg_attribute a
 CROSS JOIN (VALUES('SELECT'),('INSERT'),('UPDATE'),('REFERENCES')) p(privilege)
 WHERE a.attrelid='public.vehicles'::regclass AND a.attnum>0 AND NOT a.attisdropped ORDER BY 1,2,3
) q;

-- CHECK: V04_rpc_assertions
SELECT jsonb_build_object('check_id','V04_rpc_assertions','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT e.signature,r.role,p.oid IS NOT NULL AS present,p.proowner::regrole::text AS owner,p.prosecdef,p.proconfig,
 CASE WHEN p.oid IS NOT NULL THEN has_function_privilege(r.role,p.oid,'EXECUTE') END AS can_execute,
 coalesce(p.proowner='postgres'::regrole AND p.prosecdef AND p.proconfig=ARRAY['search_path=pg_catalog, pg_temp']
 AND has_function_privilege(r.role,p.oid,'EXECUTE')=(r.role='authenticated'),false) AS pass
 FROM (VALUES('public.register_my_vehicle(uuid,text,text,numeric,numeric,numeric,numeric,boolean)'),
 ('public.list_my_vehicles()'),('public.update_my_vehicle(uuid,bigint,text,text,numeric,numeric,numeric,numeric)'),
 ('public.set_my_vehicle_availability(uuid,bigint,boolean)'),('public.deactivate_my_vehicle(uuid,bigint)')) e(signature)
 CROSS JOIN (VALUES('anon'),('authenticated'),('service_role')) r(role)
 LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature) ORDER BY 1,2
) q;

-- CHECK: V05_private_permissions
SELECT jsonb_build_object('check_id','V05_private_permissions','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT r.role,n.nspname,p.proname,
 NOT has_schema_privilege(r.role,n.oid,'USAGE') AND NOT has_schema_privilege(r.role,n.oid,'CREATE')
 AND NOT has_function_privilege(r.role,p.oid,'EXECUTE') AS pass
 FROM pg_namespace n JOIN pg_proc p ON p.pronamespace=n.oid
 CROSS JOIN (VALUES('anon'),('authenticated'),('service_role')) r(role)
 WHERE n.nspname='fleet_private' ORDER BY 1,3
) q;

-- CHECK: V06_route_truncate
SELECT jsonb_build_object('check_id','V06_route_truncate','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT r.role,NOT has_table_privilege(r.role,'public.pickup_routes','TRUNCATE') AS pass
 FROM (VALUES('anon'),('authenticated'),('service_role')) r(role) ORDER BY 1
) q;

-- CHECK: V07_integrity_rows
SELECT jsonb_build_object('check_id','V07_integrity_rows','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT vehicle_id FROM public.vehicles WHERE
 (available_for_planning AND (NOT active_flag OR vehicle_type IS NULL OR fixed_cost_rm IS NULL
 OR distance_cost_rm_per_km IS NULL OR max_route_duration_min IS NULL OR depot_road_node_id IS NULL))
 OR vehicle_version<1 OR ngo_user_id IS NULL ORDER BY vehicle_id
) q;

-- CHECK: V08_snapshot_seal
SELECT jsonb_build_object('check_id','V08_snapshot_seal','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT n.nspname,n.nspowner::regrole::text AS owner,obj_description(n.oid,'pg_namespace') AS marker,
 obj_description(n.oid,'pg_namespace')='geolock-stage8-c1-v2:'||fleet_private.installation_fingerprint() AS pass
 FROM pg_namespace n WHERE n.nspname='fleet_private'
) q;

-- CHECK: V09_trigger_assertions
SELECT jsonb_build_object('check_id','V09_trigger_assertions','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT e.table_name,e.trigger_name,e.function_name,t.tgenabled,
 coalesce(t.tgenabled='O' AND t.tgfoid=to_regprocedure(e.function_name),false) AS pass
 FROM (VALUES('public.vehicles','trg_vehicle_depot_node','public.geolock_assign_vehicle_depot()'),
 ('public.vehicles','zz_c1_vehicle_guard','fleet_private.vehicle_guard()'),
 ('public.vehicles','c1_vehicle_audit','fleet_private.audit_vehicle()'),
 ('public.pickup_routes','c1_route_vehicle_guard','fleet_private.route_vehicle_guard()')) e(table_name,trigger_name,function_name)
 LEFT JOIN pg_trigger t ON t.tgrelid=to_regclass(e.table_name) AND t.tgname=e.trigger_name AND NOT t.tgisinternal ORDER BY 1,2
) q;

-- CHECK: V10_constraint_assertions
SELECT jsonb_build_object('check_id','V10_constraint_assertions','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT e.name,k.convalidated,pg_get_constraintdef(k.oid) AS definition,
 coalesce(k.contype='c' AND k.convalidated,false) AS pass FROM (VALUES('vehicles_c1_fields'),('vehicles_c1_available_complete')) e(name)
 LEFT JOIN pg_constraint k ON k.conrelid='public.vehicles'::regclass AND k.conname=e.name ORDER BY e.name
) q;

-- CHECK: V11_private_function_assertions
SELECT jsonb_build_object('check_id','V11_private_function_assertions','rows',coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb)) AS verification
FROM (
SELECT e.name,p.proowner::regrole::text AS owner,p.prosecdef,p.proconfig,
 coalesce(p.proowner='postgres'::regrole AND p.prosecdef AND p.proconfig=ARRAY['search_path=pg_catalog, pg_temp'],false) AS pass
 FROM (VALUES('require_ngo'),('road_node_key'),('require_depot'),('check_values'),('vehicle_has_hold'),
 ('vehicle_guard'),('route_vehicle_guard'),('audit_vehicle'),('installation_fingerprint')) e(name)
 LEFT JOIN pg_namespace n ON n.nspname='fleet_private' LEFT JOIN pg_proc p ON p.pronamespace=n.oid AND p.proname=e.name
 ORDER BY e.name
) q;
