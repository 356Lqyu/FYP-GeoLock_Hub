-- REVIEW ONLY. NOT APPLIED. Isolated DEV rcgyuwiidqvrgbxswhqj ONLY.
WITH captured AS (
WITH
rel AS (SELECT c.*,n.nspname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p','S')),
fn AS (SELECT p.* FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind='f' AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid='pg_proc'::regclass AND d.objid=p.oid AND d.deptype='e')),
clients AS (SELECT oid,rolname FROM pg_roles WHERE rolname IN ('anon','authenticated','service_role'))
SELECT jsonb_build_object(
'connection',jsonb_build_object('captured_at_utc',to_char(clock_timestamp() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),'database',current_database(),'current_user',current_user,'session_user',session_user,'read_only',current_setting('transaction_read_only'),'default_read_only',current_setting('default_transaction_read_only'),'server_version_num',current_setting('server_version_num'),'project_ref_setting',current_setting('supabase.project_ref',true)),
'relations',(SELECT jsonb_agg(jsonb_build_object('schema',c.nspname,'name',c.relname,'kind',c.relkind,'owner',c.relowner::regrole::text,'acl',c.relacl::text,'effective_acl',coalesce(c.relacl,acldefault(CASE WHEN c.relkind='S' THEN 's'::"char" ELSE 'r'::"char" END,c.relowner))::text,'acl_entries',(SELECT jsonb_agg(jsonb_build_object('grantor',a.grantor::regrole::text,'grantee',CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END,'privilege',a.privilege_type,'grantable',a.is_grantable) ORDER BY a.grantee,a.privilege_type) FROM aclexplode(coalesce(c.relacl,acldefault(CASE WHEN c.relkind='S' THEN 's'::"char" ELSE 'r'::"char" END,c.relowner))) a),'rls',c.relrowsecurity,'force_rls',c.relforcerowsecurity,'effective',(SELECT jsonb_agg(jsonb_build_object('role',r.rolname,'privilege',v.priv,'allowed',CASE WHEN c.relkind='S' THEN has_sequence_privilege(r.oid,c.oid,v.priv) ELSE has_table_privilege(r.oid,c.oid,v.priv) END) ORDER BY r.rolname,v.priv) FROM clients r CROSS JOIN LATERAL unnest(CASE WHEN c.relkind='S' THEN ARRAY['USAGE','SELECT','UPDATE'] ELSE ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER','MAINTAIN'] END) AS v(priv))) ORDER BY c.relkind,c.relname) FROM rel c),
'column_acls',(SELECT coalesce(jsonb_agg(jsonb_build_object('table',c.relname,'column',a.attname,'acl',a.attacl::text) ORDER BY c.relname,a.attnum),'[]'::jsonb) FROM rel c JOIN pg_attribute a ON a.attrelid=c.oid WHERE a.attnum>0 AND NOT a.attisdropped AND a.attacl IS NOT NULL),
'default_acls',(SELECT coalesce(jsonb_agg(jsonb_build_object('creator',d.defaclrole::regrole::text,'schema',CASE WHEN d.defaclnamespace=0 THEN '<global>' ELSE n.nspname END,'type',d.defaclobjtype,'acl',d.defaclacl::text,'entries',(SELECT jsonb_agg(jsonb_build_object('grantor',a.grantor::regrole::text,'grantee',CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END,'privilege',a.privilege_type,'grantable',a.is_grantable) ORDER BY a.grantee,a.privilege_type) FROM aclexplode(d.defaclacl) a)) ORDER BY d.defaclrole::regrole::text,d.defaclnamespace,d.defaclobjtype),'[]'::jsonb) FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid=d.defaclnamespace WHERE d.defaclrole IN ('postgres'::regrole,'supabase_admin'::regrole) AND (d.defaclnamespace=0 OR n.nspname='public')),
'roles',(SELECT jsonb_agg(jsonb_build_object('name',rolname,'inherit',rolinherit,'superuser',rolsuper,'bypassrls',rolbypassrls,'create_role',rolcreaterole,'can_login',rolcanlogin) ORDER BY rolname) FROM pg_roles),
'role_memberships',(SELECT jsonb_agg(jsonb_build_object('role',roleid::regrole::text,'member',member::regrole::text,'grantor',grantor::regrole::text,'admin',admin_option,'inherit',inherit_option,'set',set_option) ORDER BY roleid::regrole::text,member::regrole::text) FROM pg_auth_members),
'effective_role_paths',(SELECT jsonb_agg(jsonb_build_object('client',c.rolname,'role',r.rolname,'member',pg_has_role(c.oid,r.oid,'MEMBER'),'inherited_usage',pg_has_role(c.oid,r.oid,'USAGE'),'can_set',pg_has_role(c.oid,r.oid,'SET')) ORDER BY c.rolname,r.rolname) FROM pg_roles c CROSS JOIN pg_roles r WHERE c.rolname IN ('anon','authenticated','postgres') AND (c.oid=r.oid OR pg_has_role(c.oid,r.oid,'MEMBER'))),
'functions',(SELECT jsonb_agg(jsonb_build_object('name',p.proname,'signature',p.oid::regprocedure::text,'identity_arguments',pg_get_function_identity_arguments(p.oid),'result',pg_get_function_result(p.oid),'owner',p.proowner::regrole::text,'security_definer',p.prosecdef,'config',p.proconfig,'acl',p.proacl::text,'definition',pg_get_functiondef(p.oid),'execute',(SELECT jsonb_agg(jsonb_build_object('role',c.rolname,'allowed',has_function_privilege(c.oid,p.oid,'EXECUTE')) ORDER BY c.rolname) FROM clients c),'acl_entries',(SELECT jsonb_agg(jsonb_build_object('grantor',a.grantor::regrole::text,'grantee',CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END,'privilege',a.privilege_type,'grantable',a.is_grantable) ORDER BY a.grantee) FROM aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a)) ORDER BY p.proname,p.oid::regprocedure::text) FROM fn p),
'schemas',(SELECT jsonb_agg(jsonb_build_object('name',n.nspname,'owner',n.nspowner::regrole::text,'acl',n.nspacl::text,'clients',(SELECT jsonb_agg(jsonb_build_object('role',c.rolname,'usage',has_schema_privilege(c.oid,n.oid,'USAGE'),'create',has_schema_privilege(c.oid,n.oid,'CREATE'))) FROM clients c)) ORDER BY n.nspname) FROM pg_namespace n WHERE n.nspname IN ('public','extensions','storage')),
'triggers',(SELECT jsonb_agg(jsonb_build_object('schema',n.nspname,'table',c.relname,'name',t.tgname,'enabled',t.tgenabled,'function',t.tgfoid::regprocedure::text,'function_owner',p.proowner::regrole::text,'security_definer',p.prosecdef,'function_settings',p.proconfig,'definition',pg_get_triggerdef(t.oid,true)) ORDER BY n.nspname,c.relname,t.tgname) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_proc p ON p.oid=t.tgfoid WHERE n.nspname IN ('public','storage') AND NOT t.tgisinternal),
'policies',(SELECT jsonb_agg(to_jsonb(p) ORDER BY p.schemaname,p.tablename,p.policyname) FROM pg_policies p WHERE schemaname IN ('public','storage')),
'storage_relations',(SELECT jsonb_agg(jsonb_build_object('name',c.relname,'owner',c.relowner::regrole::text,'kind',c.relkind,'acl',c.relacl::text,'rls',c.relrowsecurity,'force_rls',c.relforcerowsecurity) ORDER BY c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='storage' AND c.relkind IN ('r','p','S')),
'catalog_dependencies',(SELECT coalesce(jsonb_agg(jsonb_build_object('dependent',pg_describe_object(d.classid,d.objid,d.objsubid),'referenced',pg_describe_object(d.refclassid,d.refobjid,d.refobjsubid),'type',d.deptype) ORDER BY d.classid,d.objid,d.objsubid,d.refobjid),'[]'::jsonb) FROM pg_depend d WHERE (d.classid='pg_proc'::regclass AND d.objid IN (SELECT oid FROM fn) AND d.refclassid='pg_class'::regclass AND d.refobjid IN (SELECT oid FROM rel)) OR (d.refclassid='pg_class'::regclass AND d.refobjid IN (SELECT oid FROM rel) AND d.classid='pg_rewrite'::regclass))
) AS snapshot
)
SELECT (snapshot - 'connection' - 'catalog_dependencies' - 'relations' - 'functions' - 'default_acls')
|| jsonb_build_object(
'relations',(SELECT jsonb_agg(
 (r - 'acl' - 'effective_acl' - 'acl_entries') || jsonb_build_object('acl_entries',
 (SELECT coalesce(jsonb_agg(e ORDER BY e->>'grantor',e->>'grantee',e->>'privilege'),'[]'::jsonb)
 FROM jsonb_array_elements(coalesce(r->'acl_entries','[]'::jsonb)) e))
 ORDER BY ord) FROM jsonb_array_elements(snapshot->'relations') WITH ORDINALITY t(r,ord)),
'functions',(SELECT jsonb_agg(
 (f - 'acl' - 'definition' - 'acl_entries') || jsonb_build_object('definition_md5',md5(f->>'definition'),'acl_entries',
 (SELECT coalesce(jsonb_agg(e ORDER BY e->>'grantor',e->>'grantee',e->>'privilege'),'[]'::jsonb)
 FROM jsonb_array_elements(coalesce(f->'acl_entries','[]'::jsonb)) e))
 ORDER BY ord) FROM jsonb_array_elements(snapshot->'functions') WITH ORDINALITY t(f,ord)),
'default_acls',(SELECT jsonb_agg(
 (d - 'acl' - 'entries') || jsonb_build_object('entries',
 (SELECT coalesce(jsonb_agg(e ORDER BY e->>'grantor',e->>'grantee',e->>'privilege'),'[]'::jsonb)
 FROM jsonb_array_elements(coalesce(d->'entries','[]'::jsonb)) e))
 ORDER BY ord) FROM jsonb_array_elements(snapshot->'default_acls') WITH ORDINALITY t(d,ord)),
'storage_trigger_functions',(SELECT jsonb_agg(jsonb_build_object(
 'signature',p.oid::regprocedure::text,'owner',p.proowner::regrole::text,
 'security_definer',p.prosecdef,'config',p.proconfig,'definition_md5',md5(pg_get_functiondef(p.oid)))
 ORDER BY p.oid::regprocedure::text)
 FROM pg_proc p WHERE p.oid IN (SELECT t.tgfoid FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
 JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='storage' AND NOT t.tgisinternal)),
'event_triggers',(SELECT jsonb_agg(jsonb_build_object('name',e.evtname,'event',e.evtevent,
 'owner',e.evtowner::regrole::text,'enabled',e.evtenabled,'tags',e.evttags,
 'function',e.evtfoid::regprocedure::text,'function_owner',p.proowner::regrole::text,
 'security_definer',p.prosecdef,'config',p.proconfig,'definition_md5',md5(pg_get_functiondef(p.oid)))
 ORDER BY e.evtname) FROM pg_event_trigger e JOIN pg_proc p ON p.oid=e.evtfoid)
) AS manifest FROM captured;
