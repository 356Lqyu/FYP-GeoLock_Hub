-- SELECT ONLY. Confirm MCP URL is rcgyuwiidqvrgbxswhqj before running.
-- Execute statements separately if the client returns only the last result set.
SELECT now() AS inspected_at,version();
SELECT count(*) AS vehicles,count(*) FILTER(WHERE active_flag) AS active_vehicles FROM public.vehicles;
SELECT route_status,count(*) FROM public.pickup_routes GROUP BY route_status ORDER BY route_status;
SELECT a.attname,format_type(a.atttypid,a.atttypmod) AS data_type,a.attnotnull,
 pg_get_expr(d.adbin,d.adrelid) AS default_expression
 FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
 WHERE a.attrelid='public.vehicles'::regclass AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum;
SELECT conrelid::regclass,conname,pg_get_constraintdef(oid) FROM pg_constraint
 WHERE conrelid='public.vehicles'::regclass OR confrelid='public.vehicles'::regclass;
SELECT * FROM pg_policies WHERE schemaname='public' AND tablename='vehicles';
SELECT grantee,privilege_type FROM information_schema.role_table_grants
 WHERE table_schema='public' AND table_name='vehicles' ORDER BY grantee,privilege_type;
SELECT indexname,indexdef FROM pg_indexes WHERE schemaname='public' AND tablename IN ('vehicles','pickup_routes');
SELECT tgrelid::regclass,tgname,pg_get_triggerdef(oid) FROM pg_trigger
 WHERE tgrelid IN ('public.vehicles'::regclass,'public.pickup_routes'::regclass) AND NOT tgisinternal;
SELECT n.nspname,c.relname,a.attname FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid
 JOIN pg_namespace n ON n.oid=c.relnamespace WHERE a.attname IN ('vehicle_id','reserved_vehicle_id')
 AND NOT a.attisdropped AND c.relkind IN ('r','p','v') AND n.nspname NOT IN ('pg_catalog','information_schema');
SELECT n.nspname,p.oid::regprocedure,pg_get_functiondef(p.oid),p.proacl FROM pg_proc p
 JOIN pg_namespace n ON n.oid=p.pronamespace WHERE p.prokind='f' AND n.nspname='public'
 AND (p.prosrc ILIKE '%vehicles%' OR p.proname IN ('geolock_assign_vehicle_depot','start_pickup'));
