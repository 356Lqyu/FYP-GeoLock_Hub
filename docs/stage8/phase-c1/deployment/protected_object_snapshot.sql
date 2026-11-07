-- SELECT-ONLY; DEV rcgyuwiidqvrgbxswhqj only. Confirm project URL out of band.
-- Execute each CHECK separately when the tool returns only the final result set.
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
