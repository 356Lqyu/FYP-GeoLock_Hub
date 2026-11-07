-- Operator-run comprehensive catalog audit; no business RPC calls or mutations.
\set ON_ERROR_STOP on
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout='15s';
SET LOCAL lock_timeout='2s';
SET LOCAL idle_in_transaction_session_timeout='60s';
SET LOCAL transaction_timeout='5min';
SET LOCAL search_path=pg_catalog,pg_temp;
SELECT jsonb_build_object('section','identity','observed_at',statement_timestamp(),
 'database',current_database(),'current_user',current_user,'session_user',session_user,
 'read_only',current_setting('transaction_read_only'),'isolation',current_setting('transaction_isolation'),
 'server_version',current_setting('server_version'),
 'ssl',(SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),
 'tls',(SELECT version FROM pg_stat_ssl WHERE pid=pg_backend_pid()),
 'server_project_setting',current_setting('supabase.project_ref',true));
SELECT current_database()='postgres' AND current_user='postgres' AND session_user='postgres'
 AND current_setting('transaction_read_only')='on' AND current_setting('transaction_isolation')='repeatable read'
 AND coalesce((SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),false)
 AND coalesce(nullif(current_setting('supabase.project_ref',true),''),'rcgyuwiidqvrgbxswhqj')='rcgyuwiidqvrgbxswhqj'
 AS identity_ok \gset
\if :identity_ok
\else
SELECT jsonb_build_object('section','stop','gate','identity_tls_readonly','status','FAIL');
ROLLBACK;
\quit
\endif

WITH expected(signature,body_md5) AS (VALUES
 ('fleet_private.route_vehicle_guard()','af9b1e0e2afd2201b4ac9c284fabf105'),
 ('public.enforce_donation_transition()','c0cbbe68574ea42fafe9d2f60d08cff1'),
 ('public.complete_pickup(uuid,boolean)','26f0cd8cebe783c65b45e05649693860'),
 ('public.recover_expired_claims(integer)','89e01f42d5ec23bfcbcdc47c1f4fd4e5'))
SELECT jsonb_build_object('section','parent_baselines','guards',jsonb_agg(jsonb_build_object(
 'signature',e.signature,'expected_md5',e.body_md5,'actual_md5',md5(replace(p.prosrc,E'\r\n',E'\n')),
 'status',CASE WHEN p.oid IS NULL THEN 'MISSING' WHEN md5(replace(p.prosrc,E'\r\n',E'\n'))=e.body_md5 THEN 'PASS' ELSE 'FAIL' END)))
FROM expected e LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature);
WITH expected(signature,body_md5) AS (VALUES
 ('fleet_private.route_vehicle_guard()','af9b1e0e2afd2201b4ac9c284fabf105'),
 ('public.enforce_donation_transition()','c0cbbe68574ea42fafe9d2f60d08cff1'),
 ('public.complete_pickup(uuid,boolean)','26f0cd8cebe783c65b45e05649693860'),
 ('public.recover_expired_claims(integer)','89e01f42d5ec23bfcbcdc47c1f4fd4e5'))
SELECT bool_and(p.oid IS NOT NULL AND md5(replace(p.prosrc,E'\r\n',E'\n'))=e.body_md5) AS baseline_ok
FROM expected e LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature) \gset
\if :baseline_ok
\else
SELECT jsonb_build_object('section','stop','gate','parent_baselines','status','FAIL');
ROLLBACK;
\quit
\endif

SELECT jsonb_build_object('section','installation_status','resolution_schema_present',to_regnamespace('resolution_private') IS NOT NULL,
 'conflicts',(SELECT coalesce(jsonb_agg(jsonb_build_object('signature',p.oid::regprocedure::text,
 'owner',p.proowner::regrole::text,'acl',p.proacl::text,'body_md5',md5(replace(p.prosrc,E'\r\n',E'\n')))),'[]')
 FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname IN
 ('report_my_route_interruption','submit_route_resolution_evidence','report_route_resolution_incident',
 'list_my_route_resolution_cases','get_my_route_resolution','get_my_route_resolution_receipt',
 'finalize_route_resolution','register_route_test_provenance','get_route_resolution_for_operator','get_my_donation_route_resolution')));
SELECT to_regnamespace('resolution_private') IS NULL AND NOT EXISTS(SELECT 1 FROM pg_proc p
 WHERE p.pronamespace='public'::regnamespace AND p.proname IN
 ('report_my_route_interruption','submit_route_resolution_evidence','report_route_resolution_incident',
 'list_my_route_resolution_cases','get_my_route_resolution','get_my_route_resolution_receipt',
 'finalize_route_resolution','register_route_test_provenance','get_route_resolution_for_operator','get_my_donation_route_resolution')) AS installation_absent \gset
\if :installation_absent
\else
SELECT jsonb_build_object('section','stop','gate','unexpected_existing_or_partial_installation','status','FAIL');
ROLLBACK;
\quit
\endif

-- Types/columns for direct-donation ownership, evidence and retained routing history.
WITH required(relation,columns) AS (VALUES
 ('public.donations',ARRAY['donation_id','donor_user_id','title','donation_status','availability_start','availability_end']),
 ('public.listings',ARRAY['listing_id','donation_id','source_type','listing_status','listing_expires_at','listing_version']),
 ('public.donation_claims',ARRAY['claim_id','listing_id','ngo_user_id','claim_status','closed_at','close_reason']),
 ('public.claim_leases',ARRAY['lease_id','claim_id','lease_status','expires_at','closed_at','release_reason']),
 ('public.pickup_tasks',ARRAY['task_id','claim_id','listing_id','task_status']),
 ('public.pickup_routes',ARRAY['route_id','ngo_user_id','vehicle_id','route_status','validation_reference']),
 ('public.pickup_route_stops',ARRAY['route_id','task_id','stop_order']),
 ('public.user_profiles',ARRAY['user_id','role']),('public.donor_profiles',ARRAY['user_id']),
 ('public.ngo_profiles',ARRAY['user_id','active_flag']),
 ('public.claim_reconciliation_cases',ARRAY['case_id','claim_id','listing_id','donation_id','source_type','case_status','resolved_at','resolution_reason']),
 ('public.claim_reconciliation_evidence',ARRAY['case_id','actor_user_id','handover_confirmed']),
 ('routing_private.bindings',ARRAY['route_id','candidate_id','ngo_id','vehicle_id','vehicle_version','created_at','started_at','closed_at','departure_at','plan']),
 ('routing_private.items',ARRAY['route_id','task_id','ordinal','observation_digest','consumed_at','collected_at','released_at','release_xid']),
 ('routing_private.snapshots',ARRAY['snapshot_id','ngo_id','policy_id','digest']),
 ('routing_private.candidates',ARRAY['candidate_id','snapshot_id','digest']),
 ('routing_private.validations',ARRAY['candidate_id']),
 ('routing_private.requests',ARRAY['ngo_id','request_id','operation','result']),
 ('public.active_task_route_assignments',ARRAY['route_id','task_id']),
 ('public.vehicles',ARRAY['vehicle_id','ngo_user_id','vehicle_version','active_flag','vehicle_label']),
 ('public.audit_events',ARRAY['event_id','claim_id','entity_id','event_type','actor_user_id','actor_role','outcome','details','occurred_at'])
), checks AS (
 SELECT r.relation,col,a.attname IS NOT NULL AS present,format_type(a.atttypid,a.atttypmod) AS data_type
 FROM required r CROSS JOIN LATERAL unnest(r.columns) col
 LEFT JOIN pg_attribute a ON a.attrelid=to_regclass(r.relation) AND a.attname=col AND NOT a.attisdropped
)
SELECT jsonb_build_object('section','required_columns','columns',jsonb_agg(to_jsonb(c) ORDER BY relation,col)) AS columns_report,
 bool_and(present) AS columns_ok FROM checks c \gset
\qecho :columns_report
\if :columns_ok
\else
SELECT jsonb_build_object('section','stop','gate','required_columns','status','FAIL');
ROLLBACK;
\quit
\endif
SELECT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(:'columns_report'::jsonb->'columns') c
 WHERE ((c->>'col')~'_id$' AND c->>'data_type'<>'uuid')
 OR ((c->>'col') IN('plan','result','details') AND c->>'data_type'<>'jsonb')
 OR ((c->>'col') IN('route_status','claim_status','lease_status','task_status','case_status','donation_status','listing_status')
   AND c->>'data_type'<>'text' AND c->>'data_type' NOT LIKE 'character varying%')) AS column_types_ok \gset
SELECT jsonb_build_object('section','column_type_compatibility','pass',:'column_types_ok'::boolean);
\if :column_types_ok
\else
SELECT jsonb_build_object('section','stop','gate','required_column_types','status','FAIL');
ROLLBACK;
\quit
\endif
-- Required relations are guarded before any relation is cast or queried below.
SELECT bool_and(to_regclass(x) IS NOT NULL) AS relations_ok FROM unnest(ARRAY[
 'public.donations','public.listings','public.donation_claims','public.claim_leases','public.pickup_tasks',
 'public.pickup_routes','public.pickup_route_stops','public.user_profiles','public.donor_profiles','public.ngo_profiles',
 'public.claim_reconciliation_cases','public.claim_reconciliation_evidence','routing_private.bindings',
 'routing_private.items','public.active_task_route_assignments','public.vehicles','public.audit_events',
 'routing_private.snapshots','routing_private.candidates','routing_private.validations','routing_private.requests']) x \gset
\if :relations_ok
\else
SELECT jsonb_build_object('section','stop','gate','required_relations','status','FAIL');
ROLLBACK;
\quit
\endif

SELECT jsonb_build_object('section','scoped_catalog',
 'constraints',(SELECT jsonb_agg(jsonb_build_object('table',c.conrelid::regclass::text,'name',c.conname,
 'type',c.contype,'validated',c.convalidated,'keys',c.conkey,'referenced_table',nullif(c.confrelid,0)::regclass::text,
 'definition',pg_get_constraintdef(c.oid)) ORDER BY c.conrelid,c.conname)
 FROM pg_constraint c WHERE c.conrelid IN(SELECT to_regclass(x) FROM unnest(ARRAY[
 'public.donations','public.listings','public.donation_claims','public.claim_leases','public.pickup_tasks',
 'public.pickup_routes','public.user_profiles','public.donor_profiles','public.ngo_profiles',
 'public.claim_reconciliation_cases','public.claim_reconciliation_evidence','routing_private.bindings',
 'routing_private.items','public.active_task_route_assignments','public.vehicles','public.audit_events']) x)),
 'indexes',(SELECT jsonb_agg(jsonb_build_object('table',i.indrelid::regclass::text,'name',i.indexrelid::regclass::text,
 'unique',i.indisunique,'valid',i.indisvalid,'definition',pg_get_indexdef(i.indexrelid)) ORDER BY i.indrelid,i.indexrelid)
 FROM pg_index i WHERE i.indrelid IN(SELECT to_regclass(x) FROM unnest(ARRAY[
 'public.listings','public.donation_claims','public.claim_leases','public.pickup_tasks','public.claim_reconciliation_cases',
 'routing_private.bindings','routing_private.items','public.active_task_route_assignments']) x)),
 'triggers',(SELECT jsonb_agg(jsonb_build_object('table',t.tgrelid::regclass::text,'name',t.tgname,'enabled',t.tgenabled,
 'definition',pg_get_triggerdef(t.oid)) ORDER BY t.tgrelid,t.tgname) FROM pg_trigger t WHERE NOT t.tgisinternal
 AND t.tgrelid IN(SELECT to_regclass(x) FROM unnest(ARRAY['public.donations','public.listings','public.donation_claims',
 'public.claim_leases','public.pickup_tasks','public.pickup_routes','public.active_task_route_assignments',
 'public.vehicles','public.audit_events']) x)));

-- Critical uniqueness and FK guarantees: missing/invalid enforcement stops capture.
WITH needed(relation,columns) AS (VALUES
 ('public.donations',ARRAY['donation_id']),('public.listings',ARRAY['listing_id']),
 ('public.donation_claims',ARRAY['claim_id']),('public.claim_leases',ARRAY['claim_id']),
 ('public.pickup_tasks',ARRAY['task_id']),('public.pickup_tasks',ARRAY['claim_id']),
 ('public.claim_reconciliation_cases',ARRAY['claim_id']),('routing_private.bindings',ARRAY['route_id']),
 ('routing_private.items',ARRAY['route_id','task_id']),('routing_private.items',ARRAY['route_id','ordinal']),
 ('public.active_task_route_assignments',ARRAY['task_id']))
SELECT bool_and(EXISTS(SELECT 1 FROM pg_constraint c JOIN pg_index ix ON ix.indexrelid=c.conindid
 WHERE c.conrelid=to_regclass(n.relation) AND ix.indisvalid AND ix.indisready
 AND c.contype IN('p','u') AND c.convalidated AND cardinality(c.conkey)=cardinality(n.columns)
 AND (SELECT array_agg(a.attname::text ORDER BY a.attname) FROM pg_attribute a
  WHERE a.attrelid=c.conrelid AND a.attnum=ANY(c.conkey))=
  (SELECT array_agg(v ORDER BY v) FROM unnest(n.columns) v))) AS uniqueness_ok FROM needed n \gset
WITH needed(child,parent,columns,parent_columns) AS (VALUES
 ('public.listings','public.donations',ARRAY['donation_id'],ARRAY['donation_id']),
 ('public.donation_claims','public.listings',ARRAY['listing_id'],ARRAY['listing_id']),
 ('public.claim_leases','public.donation_claims',ARRAY['claim_id'],ARRAY['claim_id']),
 ('public.pickup_tasks','public.donation_claims',ARRAY['claim_id','listing_id','ngo_user_id'],ARRAY['claim_id','listing_id','ngo_user_id']),
 ('public.claim_reconciliation_cases','public.donation_claims',ARRAY['claim_id'],ARRAY['claim_id']),
 ('public.claim_reconciliation_cases','public.listings',ARRAY['listing_id'],ARRAY['listing_id']),
 ('routing_private.items','public.pickup_tasks',ARRAY['task_id'],ARRAY['task_id']),
 ('routing_private.items','routing_private.bindings',ARRAY['route_id'],ARRAY['route_id']),
 ('routing_private.bindings','public.pickup_routes',ARRAY['route_id'],ARRAY['route_id']),
 ('routing_private.bindings','routing_private.candidates',ARRAY['candidate_id'],ARRAY['candidate_id']))
SELECT bool_and(EXISTS(SELECT 1 FROM pg_constraint c WHERE c.conrelid=to_regclass(n.child)
 AND c.confrelid=to_regclass(n.parent) AND c.contype='f' AND c.convalidated
 AND cardinality(c.conkey)=cardinality(n.columns)
 AND (SELECT array_agg(a.attname::text ORDER BY k.ord) FROM unnest(c.conkey) WITH ORDINALITY k(num,ord)
  JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.num)=n.columns
 AND (SELECT array_agg(a.attname::text ORDER BY k.ord) FROM unnest(c.confkey) WITH ORDINALITY k(num,ord)
  JOIN pg_attribute a ON a.attrelid=c.confrelid AND a.attnum=k.num)=n.parent_columns)) AS foreign_keys_ok FROM needed n \gset
SELECT bool_and(EXISTS(SELECT 1 FROM pg_trigger t WHERE t.tgrelid=to_regclass(r.relation)
 AND t.tgname=r.name AND t.tgenabled IN('O','A'))) AS triggers_ok
FROM (VALUES ('public.pickup_routes','c1_route_vehicle_guard'),('public.pickup_tasks','routing_task_authority'),
 ('public.donations','trg_donation_transition'),('public.donations','donations_lifecycle_at_commit')) r(relation,name) \gset
SELECT jsonb_build_object('section','critical_enforcement','uniqueness',:'uniqueness_ok'::boolean,
 'foreign_keys',:'foreign_keys_ok'::boolean,'triggers',:'triggers_ok'::boolean);
\if :uniqueness_ok
\else
SELECT jsonb_build_object('section','stop','gate','critical_uniqueness','status','FAIL');
ROLLBACK;
\quit
\endif
\if :foreign_keys_ok
\else
SELECT jsonb_build_object('section','stop','gate','critical_foreign_keys','status','FAIL');
ROLLBACK;
\quit
\endif
\if :triggers_ok
\else
SELECT jsonb_build_object('section','stop','gate','critical_triggers','status','FAIL');
ROLLBACK;
\quit
\endif

SELECT bool_and(to_regprocedure(x) IS NOT NULL) AS dependencies_ok FROM unnest(ARRAY[
 'auth.uid()','public.submit_claim_reconciliation(uuid,boolean,uuid)',
 'public.get_my_donation_detail(uuid)','public.get_my_authorized_route(uuid)',
 'public.geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text)',
 'routing_private.hash(jsonb)','routing_private.lock_reconciliation_scope(uuid)',
 'routing_private.lock_route(uuid,boolean)','routing_private.observe_task(uuid)',
 'routing_private.task_digest(jsonb)','routing_private.task_guard()',
 'fleet_private.vehicle_has_hold(uuid)']) x \gset
SELECT jsonb_build_object('section','required_function_signatures','pass',:'dependencies_ok'::boolean);
\if :dependencies_ok
\else
SELECT jsonb_build_object('section','stop','gate','required_function_signatures','status','FAIL');
ROLLBACK;
\quit
\endif

-- Only explicitly named routing/reconciliation dependencies; no general public-function inventory.
SELECT jsonb_build_object('section','dependency','signature',p.oid::regprocedure::text,
 'owner',p.proowner::regrole::text,'definer',p.prosecdef,'volatility',p.provolatile,'acl',p.proacl::text,
 'arguments',pg_get_function_arguments(p.oid),'result',pg_get_function_result(p.oid),
 'config',p.proconfig,'body_md5',md5(replace(p.prosrc,E'\r\n',E'\n')),'definition',pg_get_functiondef(p.oid))
FROM pg_proc p WHERE p.oid IN(SELECT to_regprocedure(x) FROM unnest(ARRAY[
 'auth.uid()','fleet_private.route_vehicle_guard()','public.enforce_donation_transition()',
 'public.complete_pickup(uuid,boolean)','public.recover_expired_claims(integer)',
 'public.submit_claim_reconciliation(uuid,boolean,uuid)','public.get_my_reconciliation_cases()',
 'public.get_my_donation_detail(uuid)','public.get_my_authorized_route(uuid)',
 'public.get_my_routing_authorization_receipt(uuid)',
 'public.geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text)',
 'routing_private.hash(jsonb)','routing_private.observe_task(uuid)','routing_private.task_digest(jsonb)',
 'routing_private.lock_reconciliation_scope(uuid)','routing_private.lock_route(uuid,boolean)',
 'routing_private.task_guard()','fleet_private.vehicle_has_hold(uuid)']) x) ORDER BY p.oid::regprocedure::text;
SELECT EXISTS(SELECT 1 FROM pg_proc WHERE oid=to_regprocedure('auth.uid()') AND prorettype='uuid'::regtype
 AND provolatile='s' AND prolang=(SELECT oid FROM pg_language WHERE lanname='sql')) AS auth_catalog_ok \gset
\if :auth_catalog_ok
\else
SELECT jsonb_build_object('section','stop','gate','auth_uid_signature_stability_language','status','FAIL');
ROLLBACK;
\quit
\endif
SELECT jsonb_build_object('section','auth_readonly_probe','auth_uid_without_jwt',auth.uid(),
 'transaction_read_only',current_setting('transaction_read_only'),
 'qualification','Native owner context only; actual hosted JWT/PostgREST verification requires a separately approved authenticated session after installation.');
SELECT auth.uid() IS NULL AS native_auth_context_clean \gset
\if :native_auth_context_clean
\else
SELECT jsonb_build_object('section','stop','gate','unexpected_native_jwt_context','status','FAIL');
ROLLBACK;
\quit
\endif

SELECT jsonb_build_object('section','roles_and_permissions',
 'roles',(SELECT jsonb_agg(jsonb_build_object('name',rolname,'login',rolcanlogin,'superuser',rolsuper,
 'create_role',rolcreaterole,'create_db',rolcreatedb,'inherit',rolinherit,'bypass_rls',rolbypassrls)) FROM pg_roles
 WHERE rolname IN('postgres','anon','authenticated','service_role','geolock_route_resolver',
 'geolock_graph_worker','geolock_planner','geolock_validator','geolock_graph_login','geolock_planner_login','geolock_validator_login')),
 'memberships',(SELECT jsonb_agg(jsonb_build_object('role',r.rolname,'member',u.rolname,'admin',m.admin_option,
 'inherit',m.inherit_option,'set',m.set_option)) FROM pg_auth_members m JOIN pg_roles r ON r.oid=m.roleid
 JOIN pg_roles u ON u.oid=m.member WHERE r.rolname IN('postgres','geolock_route_resolver','geolock_graph_worker','geolock_planner','geolock_validator')
 OR u.rolname IN('anon','authenticated','service_role')),
 'execution',(SELECT jsonb_agg(jsonb_build_object('role',r.rolname,'signature',p.oid::regprocedure::text,
 'execute',has_function_privilege(r.oid,p.oid,'EXECUTE'))) FROM pg_roles r CROSS JOIN pg_proc p
 WHERE r.rolname IN('anon','authenticated','service_role','geolock_graph_worker','geolock_planner','geolock_validator','geolock_route_resolver')
 AND p.oid IN(SELECT to_regprocedure(x) FROM unnest(ARRAY['auth.uid()','public.complete_pickup(uuid,boolean)',
 'public.recover_expired_claims(integer)','public.submit_claim_reconciliation(uuid,boolean,uuid)',
 'public.get_my_reconciliation_cases()','public.get_my_donation_detail(uuid)','public.get_my_authorized_route(uuid)',
 'routing_private.lock_reconciliation_scope(uuid)']) x)),
 'private_privileges',(SELECT jsonb_agg(jsonb_build_object('role',r.rolname,'relation',c.oid::regclass::text,
 'owner',c.relowner::regrole::text,'rls',c.relrowsecurity,'acl',c.relacl::text,
 'write',has_table_privilege(r.oid,c.oid,'INSERT,UPDATE,DELETE,TRUNCATE'),
 'column_write',has_any_column_privilege(r.oid,c.oid,'INSERT,UPDATE'))) FROM pg_roles r CROSS JOIN pg_class c
 WHERE r.rolname IN('anon','authenticated','service_role','geolock_graph_worker','geolock_planner','geolock_validator')
 AND c.oid IN(SELECT to_regclass(x) FROM unnest(ARRAY['routing_private.bindings','routing_private.items',
 'routing_private.snapshots','routing_private.candidates','routing_private.validations','routing_private.requests']) x)),
 'installer_capabilities',jsonb_build_object('export_identity_only',true,
 'create_database_schema',has_database_privilege(current_user,current_database(),'CREATE'),
 'public_create',has_schema_privilege(current_user,'public','CREATE'),
 'current_role',(SELECT jsonb_build_object('create_role',rolcreaterole,'superuser',rolsuper) FROM pg_roles WHERE rolname=current_user),
 'target_owners',(SELECT jsonb_agg(jsonb_build_object('table',c.oid::regclass::text,'owner',c.relowner::regrole::text,
 'owner_rights',pg_has_role(current_user,c.relowner,'USAGE'))) FROM pg_class c WHERE c.oid IN(
 'public.pickup_routes'::regclass,'public.pickup_tasks'::regclass,'public.audit_events'::regclass))));
SELECT NOT EXISTS(SELECT 1 FROM pg_roles r CROSS JOIN pg_class c
 WHERE r.rolname IN('anon','authenticated','service_role','geolock_graph_worker','geolock_planner','geolock_validator')
 AND c.oid IN(SELECT to_regclass(x) FROM unnest(ARRAY['routing_private.bindings','routing_private.items',
 'routing_private.snapshots','routing_private.candidates','routing_private.validations','routing_private.requests']) x)
 AND (has_table_privilege(r.oid,c.oid,'INSERT,UPDATE,DELETE,TRUNCATE') OR has_any_column_privilege(r.oid,c.oid,'INSERT,UPDATE')))
 AND NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='geolock_route_resolver' AND
 (rolcanlogin OR rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb))
 AND NOT EXISTS(SELECT 1 FROM pg_roles r CROSS JOIN pg_roles target
 WHERE r.rolname IN('anon','authenticated','service_role','geolock_graph_worker','geolock_planner','geolock_validator')
 AND target.rolname IN('postgres','geolock_route_resolver') AND pg_has_role(r.oid,target.oid,'MEMBER'))
 AND NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname IN('anon','authenticated','service_role')
 AND (rolsuper OR rolcreaterole OR rolcreatedb)) AS security_ok \gset
\if :security_ok
\else
SELECT jsonb_build_object('section','stop','gate','private_write_or_resolver_role_invariant','status','FAIL');
ROLLBACK;
\quit
\endif

SELECT jsonb_build_object('section','extensions_and_history','extensions',(SELECT jsonb_agg(jsonb_build_object(
 'name',extname,'version',extversion) ORDER BY extname) FROM pg_extension),
 'ledger_present',to_regclass('supabase_migrations.schema_migrations') IS NOT NULL,
 'manual_application_migration_history','UNKNOWN; no ledger entries created or inferred');
SELECT 'SELECT jsonb_build_object(''section'',''ledger_versions'',''versions'',(SELECT coalesce(jsonb_agg(jsonb_build_object(''version'',m.version::text,''name'',to_jsonb(m)->>''name'') ORDER BY m.version::text),''[]'') FROM (SELECT * FROM supabase_migrations.schema_migrations ORDER BY version DESC LIMIT 40) m));'
WHERE EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=to_regclass('supabase_migrations.schema_migrations') AND attname='version' AND NOT attisdropped)
\gexec
SELECT to_regclass('cron.job') IS NOT NULL AS cron_present \gset
\if :cron_present
WITH expected(command) AS (VALUES ($known$set lock_timeout = '5s'; set statement_timeout = '50s'; select public.recover_expired_claims(1); -- STAGE3I_ONE_USE_8b4a48ed-97e4-41a9-aa1f-b588ae850b4f$known$))
SELECT jsonb_build_object('section','recovery_job','jobs',coalesce(jsonb_agg(jsonb_build_object(
 'jobid',j.jobid,'name',j.jobname,'active',j.active,'schedule',j.schedule,'database',j.database,'username',j.username,
 'exact_known_command_match',j.command=e.command,'batch_limit',CASE WHEN j.command=e.command THEN 1 END,
 'lock_timeout',CASE WHEN j.command=e.command THEN '5s' END,'statement_timeout',CASE WHEN j.command=e.command THEN '50s' END)),'[]'))
FROM cron.job j CROSS JOIN expected e WHERE j.jobid=3 OR j.jobname='geolock-expired-claim-recovery';
\else
SELECT jsonb_build_object('section','recovery_job','status','UNKNOWN','reason','cron catalog absent');
\endif
SELECT 'SELECT jsonb_build_object(''section'',''recovery_runs'',''runs'',(SELECT coalesce(jsonb_agg(jsonb_build_object(''runid'',runid,''status'',status,''start_time'',start_time,''end_time'',end_time,''failure_class'',CASE WHEN status<>''failed'' THEN NULL WHEN return_message~*''permission denied'' THEN ''PERMISSION_DENIED'' WHEN return_message~*''statement timeout'' THEN ''STATEMENT_TIMEOUT'' WHEN return_message~*''lock timeout|deadlock'' THEN ''LOCK_OR_DEADLOCK'' ELSE ''OTHER_REVIEW_REQUIRED'' END) ORDER BY runid DESC),''[]'') FROM (SELECT * FROM cron.job_run_details WHERE jobid=3 ORDER BY runid DESC LIMIT 12) x));'
WHERE to_regclass('cron.job_run_details') IS NOT NULL
\gexec

-- V2/V3-only preservation queries are appended below; no custody is inferred.
SELECT jsonb_build_object('section','preserved_route','routes',(SELECT coalesce(jsonb_agg(jsonb_build_object('route_id',r.route_id,'status',r.route_status,'vehicle_id',r.vehicle_id,'vehicle_label',v.vehicle_label,'vehicle_active',v.active_flag,'vehicle_version',v.vehicle_version,'bound_vehicle_version',b.vehicle_version,'departure_at',b.departure_at,'started_at',b.started_at,'closed_at',b.closed_at,'active_assignments',(SELECT count(*) FROM public.active_task_route_assignments a WHERE a.route_id=r.route_id),'unresolved_stops',(SELECT count(*) FROM public.pickup_route_stops s JOIN public.pickup_tasks t USING(task_id) WHERE s.route_id=r.route_id AND t.task_status IN('PLANNED','DISPATCHED')))),'[]') FROM public.pickup_routes r JOIN routing_private.bindings b USING(route_id) JOIN public.vehicles v ON v.vehicle_id=b.vehicle_id WHERE r.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9'),
 'items',(SELECT coalesce(jsonb_agg(jsonb_build_object('ordinal',i.ordinal,'task_id',t.task_id,'task_status',t.task_status,'claim_id',t.claim_id,'claim_status',c.claim_status,'lease_status',le.lease_status,'expires_at',le.expires_at,'listing_status',l.listing_status,'listing_expires_at',l.listing_expires_at,'donation_status',d.donation_status,'consumed_at',i.consumed_at,'collected_at',i.collected_at,'released_at',i.released_at,'open_cases',(SELECT count(*) FROM public.claim_reconciliation_cases rc WHERE rc.claim_id=c.claim_id AND rc.case_status IN('OPEN','MANUAL_REVIEW'))) ORDER BY i.ordinal),'[]') FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id) JOIN public.donation_claims c USING(claim_id) JOIN public.claim_leases le USING(claim_id) JOIN public.listings l ON l.listing_id=c.listing_id LEFT JOIN public.donations d ON d.donation_id=l.donation_id WHERE i.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9'));

SELECT jsonb_build_object('section','v2_source_windows_and_assignments','ordinal',i.ordinal,'task_id',t.task_id,'claim_id',t.claim_id,
 'donation_id',d.donation_id,'source_actor',d.donor_user_id,'source_role',u.role,
 'availability_start',d.availability_start,'availability_end',d.availability_end,
 'listing_expires_at',l.listing_expires_at,'assignment',
 (SELECT to_jsonb(a) FROM public.active_task_route_assignments a WHERE a.task_id=t.task_id))
FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id) JOIN public.listings l ON l.listing_id=t.listing_id
LEFT JOIN public.donations d ON d.donation_id=l.donation_id LEFT JOIN public.user_profiles u ON u.user_id=d.donor_user_id
WHERE i.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9' ORDER BY i.ordinal;
SELECT jsonb_build_object('section','v2_claim_case','case',to_jsonb(rc))
FROM public.claim_reconciliation_cases rc WHERE rc.claim_id IN(SELECT t.claim_id FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id)
 WHERE i.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9') ORDER BY rc.case_id LIMIT 10;
SELECT jsonb_build_object('section','v2_existing_statement','case_id',e.case_id,'request_id',e.request_id,
 'actor_user_id',e.actor_user_id,'handover_confirmed',e.handover_confirmed,'response',e.response)
FROM public.claim_reconciliation_evidence e JOIN public.claim_reconciliation_cases rc USING(case_id)
WHERE rc.claim_id IN(SELECT t.claim_id FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id)
 WHERE i.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9') ORDER BY e.case_id,e.request_id LIMIT 30;
SELECT jsonb_build_object('section','completed_v3_preservation','route_id',r.route_id,'route_status',r.route_status,
 'binding_closed_at',b.closed_at,'candidate_id',b.candidate_id,'snapshot_id',c.snapshot_id,'vehicle_id',b.vehicle_id,
 'snapshot_digest',s.digest,'candidate_digest',c.digest,'validation_present',EXISTS(SELECT 1 FROM routing_private.validations v WHERE v.candidate_id=c.candidate_id),
 'assignments',(SELECT count(*) FROM public.active_task_route_assignments a WHERE a.route_id=r.route_id),
 'items',(SELECT jsonb_agg(jsonb_build_object('task_id',t.task_id,'task_status',t.task_status,'claim_id',dc.claim_id,'claim_status',dc.claim_status,'lease_status',le.lease_status,'listing_status',l.listing_status,'donation_status',d.donation_status) ORDER BY i.ordinal)
 FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id) JOIN public.donation_claims dc USING(claim_id) JOIN public.claim_leases le USING(claim_id)
 JOIN public.listings l ON l.listing_id=t.listing_id LEFT JOIN public.donations d ON d.donation_id=l.donation_id WHERE i.route_id=r.route_id),
 'closure_audit',(SELECT jsonb_agg(jsonb_build_object('id',a.event_id,'outcome',a.outcome,'actor',a.actor_user_id,'occurred_at',a.occurred_at)) FROM public.audit_events a WHERE a.entity_id=r.route_id AND a.event_type='CLOSE_COLLECTED_ROUTE'),
 'authorization_receipts',(SELECT jsonb_agg(jsonb_build_object('ngo_id',q.ngo_id,'request_id',q.request_id,'operation',q.operation,'result',q.result)) FROM routing_private.requests q WHERE q.ngo_id=b.ngo_id AND q.result->'route_ids' @> jsonb_build_array(r.route_id)))
FROM public.pickup_routes r JOIN routing_private.bindings b USING(route_id) JOIN routing_private.candidates c ON c.candidate_id=b.candidate_id
JOIN routing_private.snapshots s ON s.snapshot_id=c.snapshot_id WHERE r.route_id='7dd2d00a-ff03-4021-994f-155bbfc8e12c';

SELECT jsonb_build_object('section','target_audits','events',(SELECT coalesce(jsonb_agg(jsonb_build_object(
 'event_id',event_id,'entity_id',entity_id,'claim_id',claim_id,'type',event_type,'outcome',outcome,
 'actor',actor_user_id,'role',actor_role,'occurred_at',occurred_at) ORDER BY occurred_at,event_id),'[]')
 FROM public.audit_events a WHERE a.entity_id IN('db1b455e-92d0-4d58-9fa1-5de07d7ab0f9','7dd2d00a-ff03-4021-994f-155bbfc8e12c')
 OR a.claim_id IN(SELECT t.claim_id FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id)
 WHERE i.route_id IN('db1b455e-92d0-4d58-9fa1-5de07d7ab0f9','7dd2d00a-ff03-4021-994f-155bbfc8e12c'))));
SELECT jsonb_build_object('section','v2_authorization_receipts','receipts',(SELECT coalesce(jsonb_agg(jsonb_build_object(
 'request_id',q.request_id,'operation',q.operation,'ngo_id',q.ngo_id,'result',q.result)),'[]')
 FROM routing_private.requests q JOIN routing_private.bindings b ON b.ngo_id=q.ngo_id
 WHERE b.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9'
 AND q.result->'route_ids' @> jsonb_build_array(b.route_id)));
SELECT jsonb_build_object('section','limits_and_remaining_gates',
 'installer_login_verified',false,'writer_pause_verified',false,'hosted_jwt_postgrest_verified',false,
 'backup_gate','HOLD UNCHANGED; current audit inspects definitions but cannot confer change-owner approval',
 'restore_readiness','UNKNOWN; no restore performed',
 'synthetic_visibility','REQUIRES EXPLICIT DECISION',
 'truthful_participant_evidence','REQUIRES SEPARATE APPROVAL; expiry is not proof of custody');
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

SELECT jsonb_build_object('section','capture_complete','read_only',current_setting('transaction_read_only'),
 'observed_at',statement_timestamp(),'status','CAPTURE COMPLETE / CATALOG REVIEW REQUIRED');
ROLLBACK;
