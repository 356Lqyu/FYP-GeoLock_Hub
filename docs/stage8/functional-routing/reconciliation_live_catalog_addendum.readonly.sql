-- Appended inside the scoped preflight's verified READ ONLY transaction.
-- Definitions are private evidence; never execute captured bodies or print them.
SELECT jsonb_build_object('section','audit_scope','catalog_rows_truncated',false,
 'application_data_sample_limit',50,'application_data_sample_is_complete',false,
 'dependency_limitations','pg_depend omits many PL/pgSQL/dynamic SQL references; source review also required');

SELECT jsonb_build_object('section','catalog_schema','name',nspname,'owner',nspowner::regrole::text,'acl',nspacl::text)
FROM pg_namespace WHERE nspname NOT IN('pg_catalog','information_schema') AND nspname NOT LIKE 'pg_%' ORDER BY nspname;

SELECT jsonb_build_object('section','catalog_relation','oid',c.oid,'schema',n.nspname,'name',c.relname,
 'kind',c.relkind,'owner',c.relowner::regrole::text,'rls',c.relrowsecurity,'force_rls',c.relforcerowsecurity,
 'acl',c.relacl::text,'options',c.reloptions,
 'columns',(SELECT jsonb_agg(jsonb_build_object('name',a.attname,'type',format_type(a.atttypid,a.atttypmod),
 'not_null',a.attnotnull,'identity',a.attidentity,'generated',a.attgenerated,'acl',a.attacl::text,
 'default',pg_get_expr(d.adbin,d.adrelid)) ORDER BY a.attnum)
 FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
 WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped),
 'view_definition',CASE WHEN c.relkind IN('v','m') THEN pg_get_viewdef(c.oid,true) END)
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname NOT IN('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_%'
AND c.relkind IN('r','p','v','m','S','f') ORDER BY n.nspname,c.relname;

SELECT jsonb_build_object('section','catalog_constraint','table',conrelid::regclass::text,'name',conname,
 'type',contype,'valid',convalidated,'deferrable',condeferrable,'initially_deferred',condeferred,
 'referenced_table',CASE WHEN confrelid<>0 THEN confrelid::regclass::text END,
 'definition',pg_get_constraintdef(c.oid,true))
FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace
WHERE n.nspname NOT IN('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_%'
ORDER BY conrelid,conname;

SELECT jsonb_build_object('section','catalog_index','table',i.indrelid::regclass::text,
 'name',i.indexrelid::regclass::text,'valid',i.indisvalid,'ready',i.indisready,
 'unique',i.indisunique,'definition',pg_get_indexdef(i.indexrelid),'predicate',pg_get_expr(i.indpred,i.indrelid))
FROM pg_index i JOIN pg_class c ON c.oid=i.indrelid JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname NOT IN('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_%'
ORDER BY i.indrelid,i.indexrelid;

SELECT jsonb_build_object('section','catalog_function','oid',p.oid,'signature',p.oid::regprocedure::text,
 'schema',n.nspname,'kind',p.prokind,'owner',p.proowner::regrole::text,
 'security_definer',p.prosecdef,'volatility',p.provolatile,'config',p.proconfig,'acl',p.proacl::text,
 'arguments',pg_get_function_arguments(p.oid),'result',pg_get_function_result(p.oid),
 'body_md5',md5(replace(p.prosrc,E'\r\n',E'\n')),
 'extension',(SELECT e.extname FROM pg_depend d JOIN pg_extension e ON e.oid=d.refobjid
 WHERE d.classid='pg_proc'::regclass AND d.objid=p.oid AND d.refclassid='pg_extension'::regclass AND d.deptype='e' LIMIT 1),
 'definition',CASE WHEN NOT EXISTS(SELECT 1 FROM pg_depend d WHERE d.classid='pg_proc'::regclass
 AND d.objid=p.oid AND d.refclassid='pg_extension'::regclass AND d.deptype='e')
 OR (n.nspname='auth' AND p.proname='uid') THEN pg_get_functiondef(p.oid) END)
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname NOT IN('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_%'
AND p.prokind IN('f','p','w') ORDER BY n.nspname,p.oid::regprocedure::text;

SELECT jsonb_build_object('section','catalog_trigger','table',t.tgrelid::regclass::text,'name',t.tgname,
 'enabled',t.tgenabled,'function',t.tgfoid::regprocedure::text,'definition',pg_get_triggerdef(t.oid,true))
FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE NOT t.tgisinternal AND n.nspname NOT IN('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_%'
ORDER BY t.tgrelid,t.tgname;

SELECT jsonb_build_object('section','catalog_policy','table',p.polrelid::regclass::text,'name',p.polname,
 'command',p.polcmd,'permissive',p.polpermissive,'roles',p.polroles,
 'using',pg_get_expr(p.polqual,p.polrelid),'check',pg_get_expr(p.polwithcheck,p.polrelid))
FROM pg_policy p ORDER BY p.polrelid,p.polname;

SELECT jsonb_build_object('section','catalog_enum','schema',n.nspname,'name',t.typname,
 'labels',jsonb_agg(e.enumlabel ORDER BY e.enumsortorder))
FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace JOIN pg_enum e ON e.enumtypid=t.oid
GROUP BY n.nspname,t.typname ORDER BY n.nspname,t.typname;

SELECT jsonb_build_object('section','catalog_dependency','dependent',pg_describe_object(d.classid,d.objid,d.objsubid),
 'referenced',pg_describe_object(d.refclassid,d.refobjid,d.refobjsubid),'type',d.deptype)
FROM pg_depend d
WHERE (d.classid='pg_proc'::regclass AND d.objid IN(SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname IN('public','routing_private','fleet_private','resolution_private','auth')))
OR (d.refclassid='pg_proc'::regclass AND d.refobjid IN(SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname IN('public','routing_private','fleet_private','resolution_private','auth')))
OR (d.classid='pg_rewrite'::regclass AND d.objid IN(SELECT r.oid FROM pg_rewrite r JOIN pg_class c ON c.oid=r.ev_class
 JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public'))
ORDER BY d.classid,d.objid,d.objsubid,d.refclassid,d.refobjid;

SELECT jsonb_build_object('section','catalog_default_acl','schema',n.nspname,'owner',a.defaclrole::regrole::text,
 'kind',a.defaclobjtype,'acl',a.defaclacl::text)
FROM pg_default_acl a LEFT JOIN pg_namespace n ON n.oid=a.defaclnamespace ORDER BY a.oid;

SELECT jsonb_build_object('section','catalog_role','role',rolname,'login',rolcanlogin,'inherit',rolinherit,
 'superuser',rolsuper,'bypass_rls',rolbypassrls,'create_role',rolcreaterole,'create_db',rolcreatedb)
FROM pg_roles ORDER BY rolname;
SELECT jsonb_build_object('section','catalog_membership','role',m.roleid::regrole::text,'member',m.member::regrole::text,
 'grantor',m.grantor::regrole::text,'admin',m.admin_option,'inherit',m.inherit_option,'set',m.set_option)
FROM pg_auth_members m ORDER BY m.roleid,m.member;

SELECT jsonb_build_object('section','effective_rpc_permission','signature',p.oid::regprocedure::text,
 'role',r.rolname,'schema_usage',has_schema_privilege(r.oid,n.oid,'USAGE'),
 'execute',has_function_privilege(r.oid,p.oid,'EXECUTE'))
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace CROSS JOIN pg_roles r
WHERE n.nspname IN('public','routing_private','fleet_private','resolution_private','auth')
AND p.prokind IN('f','p','w') AND r.rolname IN('anon','authenticated','service_role',
 'authenticator','geolock_graph_worker','geolock_planner','geolock_validator','geolock_route_resolver')
ORDER BY p.oid,r.rolname;

SELECT jsonb_build_object('section','effective_table_permission','table',c.oid::regclass::text,
 'role',r.rolname,'select',has_table_privilege(r.oid,c.oid,'SELECT'),
 'insert',has_table_privilege(r.oid,c.oid,'INSERT'),'update',has_table_privilege(r.oid,c.oid,'UPDATE'),
 'delete',has_table_privilege(r.oid,c.oid,'DELETE'),'truncate',has_table_privilege(r.oid,c.oid,'TRUNCATE'))
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace CROSS JOIN pg_roles r
WHERE n.nspname IN('public','routing_private','fleet_private','resolution_private') AND c.relkind IN('r','p','v','m')
AND r.rolname IN('anon','authenticated','service_role','geolock_planner','geolock_validator','geolock_route_resolver')
ORDER BY c.oid,r.rolname;

-- Whitelisted settings only; never capture JWT secrets, passwords or auth records.
SELECT jsonb_build_object('section','postgrest_setting','database_oid',s.setdatabase,'role_oid',s.setrole,'setting',v)
FROM pg_db_role_setting s CROSS JOIN LATERAL unnest(s.setconfig) v
WHERE split_part(v,'=',1) IN('pgrst.db_schemas','pgrst.db_extra_search_path','search_path','TimeZone');

-- Bounded state samples, only scalar identifiers/status/timing/quantity fields.
-- No auth.users rows, descriptions, contact details, evidence narratives or tokens.
SELECT format($query$
SELECT jsonb_build_object('section','application_state_sample','relation',%L,
 'total_rows',(SELECT count(*) FROM %I.%I),'sample_limit',50,
 'rows',(SELECT coalesce(jsonb_agg(j),'[]'::jsonb) FROM
 (SELECT jsonb_build_object(%s) AS j FROM %I.%I ORDER BY %I LIMIT 50) sample));
$query$,n.nspname||'.'||c.relname,n.nspname,c.relname,
 string_agg(format('%L,%I',a.attname,a.attname),',' ORDER BY a.attnum),n.nspname,c.relname,min(a.attname::text))
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
WHERE n.nspname='public' AND c.relkind IN('r','p')
AND c.relname~*'(hub|reservation|inventory|reconciliation)'
AND (a.attname~'(_id|_status|_at|_kg|_quantity)$' OR a.attname IN('status','quantity','collection_path','source_type'))
AND a.atttypid IN('uuid'::regtype,'text'::regtype,'timestamp with time zone'::regtype,
 'timestamp without time zone'::regtype,'numeric'::regtype,'integer'::regtype,'bigint'::regtype,'boolean'::regtype)
GROUP BY n.nspname,c.relname ORDER BY n.nspname,c.relname
\gexec

SELECT jsonb_build_object('section','current_reconciliation_backlog','claims',
 (SELECT count(*) FROM public.donation_claims WHERE claim_status='RECONCILIATION_REQUIRED'),
 'leases',(SELECT count(*) FROM public.claim_leases WHERE lease_status='RECONCILIATION_REQUIRED'),
 'open_cases',(SELECT count(*) FROM public.claim_reconciliation_cases WHERE case_status IN('OPEN','MANUAL_REVIEW')));
