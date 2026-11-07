-- Operator-run DEV preflight ONLY. No application RPC, DDL, DML or recovery call.
\set ON_ERROR_STOP on
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout='15s';
SET LOCAL lock_timeout='2s';
SET LOCAL idle_in_transaction_session_timeout='60s';
SET LOCAL search_path=pg_catalog,public,pg_temp;
SELECT jsonb_build_object('section','identity','observed_at',statement_timestamp(),
 'database',current_database(),'current_user',current_user,'session_user',session_user,
 'server_version',current_setting('server_version'),'read_only',current_setting('transaction_read_only'),
 'default_read_only',current_setting('default_transaction_read_only'),
 'ssl',(SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),
 'tls',(SELECT version FROM pg_stat_ssl WHERE pid=pg_backend_pid()),
 'server_project_setting',current_setting('supabase.project_ref',true));
-- Client runner separately pins the TLS-verified DEV pooler/project-bearing user.
-- Check this explicit transaction's access mode, not the default for future ones.
-- default_read_only stays diagnostic; no new transaction opens before ROLLBACK.
SELECT 1/CASE WHEN current_database()='postgres' AND current_user='postgres' AND session_user='postgres'
 AND current_setting('transaction_read_only')='on'
 AND coalesce((SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),false) THEN 1 ELSE 0 END AS identity_guard;
WITH expected(signature,expected_md5) AS (VALUES
 ('fleet_private.route_vehicle_guard()','af9b1e0e2afd2201b4ac9c284fabf105'),
 ('public.enforce_donation_transition()','c0cbbe68574ea42fafe9d2f60d08cff1'),
 ('public.complete_pickup(uuid,boolean)','26f0cd8cebe783c65b45e05649693860'),
 ('public.recover_expired_claims(integer)','89e01f42d5ec23bfcbcdc47c1f4fd4e5'))
SELECT jsonb_build_object('section','migration_preconditions','guards',jsonb_agg(jsonb_build_object(
 'signature',e.signature,'expected_md5',e.expected_md5,'actual_md5',md5(replace(p.prosrc,E'\r\n',E'\n')),
 'status',CASE WHEN p.oid IS NULL THEN 'MISSING' WHEN md5(replace(p.prosrc,E'\r\n',E'\n'))=e.expected_md5 THEN 'PASS' ELSE 'DRIFT' END)),
 'resolution_schema_present',to_regnamespace('resolution_private') IS NOT NULL,
 'conflicting_functions',(SELECT coalesce(jsonb_agg(p2.oid::regprocedure::text),'[]') FROM pg_proc p2
 WHERE p2.pronamespace='public'::regnamespace AND p2.proname IN('report_my_route_interruption','submit_route_resolution_evidence','report_route_resolution_incident','list_my_route_resolution_cases','get_my_route_resolution','get_my_route_resolution_receipt','finalize_route_resolution','register_route_test_provenance','get_route_resolution_for_operator')))
FROM expected e LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature);
SELECT jsonb_build_object('section','functions','functions',coalesce(jsonb_agg(jsonb_build_object(
 'signature',p.oid::regprocedure::text,'owner',p.proowner::regrole::text,'security_definer',p.prosecdef,
 'volatility',p.provolatile,'argument_names',p.proargnames,'return_type',pg_get_function_result(p.oid),
 'config',(SELECT jsonb_agg(x) FROM unnest(p.proconfig) x WHERE lower(split_part(x,'=',1)) IN('search_path','timezone','extra_float_digits','row_security','default_transaction_read_only','statement_timeout','lock_timeout')),
 'unexpected_config_keys',(SELECT jsonb_agg(split_part(x,'=',1)) FROM unnest(p.proconfig) x WHERE lower(split_part(x,'=',1)) NOT IN('search_path','timezone','extra_float_digits','row_security','default_transaction_read_only','statement_timeout','lock_timeout')),'acl',p.proacl::text,'normalized_md5',md5(replace(p.prosrc,E'\r\n',E'\n')))
 ORDER BY p.oid::regprocedure::text),'[]')) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname IN('public','routing_private','fleet_private');
SELECT jsonb_build_object('section','schema','columns',(
 SELECT jsonb_agg(jsonb_build_object('schema',table_schema,'table',table_name,'column',column_name,'type',udt_name,'nullable',is_nullable) ORDER BY table_schema,table_name,ordinal_position)
 FROM information_schema.columns WHERE table_schema IN('routing_private','fleet_private') OR (table_schema='public' AND table_name IN('pickup_routes','pickup_route_stops','pickup_tasks','active_task_route_assignments','vehicles','donation_claims','claim_leases','listings','donations','hub_batches','hub_batch_members','hub_inventory','claim_reconciliation_cases','claim_reconciliation_evidence','audit_events','user_profiles','ngo_profiles','community_hubs'))),
 'constraints',(SELECT jsonb_agg(jsonb_build_object('table',c.conrelid::regclass::text,'name',c.conname,'validated',c.convalidated,'definition',pg_get_constraintdef(c.oid)) ORDER BY c.conrelid::regclass::text,c.conname) FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid JOIN pg_namespace n ON n.oid=t.relnamespace WHERE n.nspname IN('routing_private','fleet_private') OR (n.nspname='public' AND t.relname IN('pickup_routes','pickup_route_stops','pickup_tasks','active_task_route_assignments','vehicles','donation_claims','claim_leases','listings','donations','hub_batches','hub_batch_members','hub_inventory','claim_reconciliation_cases','claim_reconciliation_evidence','audit_events'))),
 'triggers',(SELECT jsonb_agg(jsonb_build_object('table',t.tgrelid::regclass::text,'name',t.tgname,'enabled',t.tgenabled,'definition',pg_get_triggerdef(t.oid)) ORDER BY t.tgrelid::regclass::text,t.tgname) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE NOT t.tgisinternal AND (n.nspname IN('routing_private','fleet_private') OR (n.nspname='public' AND c.relname IN('pickup_routes','pickup_route_stops','pickup_tasks','active_task_route_assignments','vehicles','donation_claims','claim_leases','listings','donations','hub_batches','hub_batch_members','hub_inventory','audit_events','road_network_nodes','road_network_edges','road_network_coverage')))));
SELECT jsonb_build_object('section','permissions','roles',(SELECT jsonb_agg(jsonb_build_object('role',rolname,'login',rolcanlogin,'superuser',rolsuper,'create_role',rolcreaterole,'create_db',rolcreatedb,'inherit',rolinherit,'bypass_rls',rolbypassrls)) FROM pg_roles WHERE rolname IN('postgres','anon','authenticated','service_role','geolock_route_resolver','geolock_graph_worker','geolock_planner','geolock_validator','geolock_graph_login','geolock_planner_login','geolock_validator_login')),
 'memberships',(SELECT jsonb_agg(jsonb_build_object('role',r.rolname,'member',u.rolname,'admin',m.admin_option,'inherit',m.inherit_option,'set',m.set_option)) FROM pg_auth_members m JOIN pg_roles r ON r.oid=m.roleid JOIN pg_roles u ON u.oid=m.member WHERE r.rolname~'^geolock_' OR u.rolname~'^geolock_'),
 'function_execution',(SELECT jsonb_agg(jsonb_build_object('role',r.rolname,'signature',p.oid::regprocedure::text,'execute',has_function_privilege(r.oid,p.oid,'EXECUTE')) ORDER BY r.rolname,p.oid::regprocedure::text) FROM pg_roles r CROSS JOIN pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE r.rolname IN('anon','authenticated','service_role','geolock_route_resolver','geolock_graph_worker','geolock_planner','geolock_validator') AND (n.nspname IN('routing_private','fleet_private') OR (n.nspname='public' AND p.proname IN('authorize_my_routing_candidate','get_my_routing_authorization_receipt','get_my_authorized_route','start_pickup','complete_pickup','recover_expired_claims','submit_claim_reconciliation')))),
 'table_privileges',(SELECT jsonb_agg(jsonb_build_object('role',r.rolname,'table',c.oid::regclass::text,'owner',c.relowner::regrole::text,'rls',c.relrowsecurity,'force_rls',c.relforcerowsecurity,'write',has_table_privilege(r.oid,c.oid,'INSERT,UPDATE,DELETE,TRUNCATE'),'column_write',has_any_column_privilege(r.oid,c.oid,'INSERT,UPDATE'),'acl',c.relacl::text) ORDER BY r.rolname,c.oid::regclass::text) FROM pg_roles r CROSS JOIN pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE r.rolname IN('anon','authenticated','service_role','geolock_route_resolver','geolock_graph_worker','geolock_planner','geolock_validator') AND c.relkind IN('r','p') AND (n.nspname IN('routing_private','fleet_private') OR (n.nspname='public' AND c.relname IN('donations','listings','donation_claims','claim_leases','pickup_tasks','pickup_routes','active_task_route_assignments','vehicles','audit_events')))),
 'installer_capabilities',jsonb_build_object('export_identity_only',true,'database_create',has_database_privilege(current_user,current_database(),'CREATE'),'public_usage_grant_option',has_schema_privilege(current_user,'public','USAGE WITH GRANT OPTION')),
 'schemas',(SELECT jsonb_agg(jsonb_build_object('schema',nspname,'owner',nspowner::regrole::text,'acl',nspacl::text)) FROM pg_namespace WHERE nspname IN('public','fleet_private','routing_private')),
 'default_function_acl',(SELECT jsonb_agg(jsonb_build_object('owner',defaclrole::regrole::text,'schema',defaclnamespace,'acl',defaclacl::text)) FROM pg_default_acl WHERE defaclobjtype='f'));
SELECT jsonb_build_object('section','extensions_and_history','extensions',(SELECT jsonb_agg(jsonb_build_object('name',extname,'version',extversion,'schema',extnamespace::regnamespace::text) ORDER BY extname) FROM pg_extension),
 'cron_database',current_setting('cron.database_name',true),'cron_timezone',current_setting('cron.timezone',true),
 'ledger_candidates',(SELECT jsonb_agg(jsonb_build_object('schema',n.nspname,'table',c.relname)) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relkind IN('r','p') AND n.nspname IN('public','supabase_migrations') AND c.relname~*'(migration|schema_version)'),
 'manual_application_history_requires_review',true);
-- Only generate SELECTs against the known Supabase ledger if its version column exists.
SELECT 'SELECT jsonb_build_object(''section'',''supabase_migration_ledger'',''versions'',(SELECT coalesce(jsonb_agg(jsonb_build_object(''version'',m.version::text,''name'',to_jsonb(m)->>''name'') ORDER BY m.version::text),''[]'') FROM (SELECT * FROM supabase_migrations.schema_migrations ORDER BY version DESC LIMIT 40) m));'
WHERE EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid=to_regclass('supabase_migrations.schema_migrations') AND attname='version' AND NOT attisdropped)
\gexec
SELECT jsonb_build_object('section','recovery_catalog','cron_job_catalog',to_regclass('cron.job') IS NOT NULL,'cron_run_catalog',to_regclass('cron.job_run_details') IS NOT NULL);
SELECT to_regclass('cron.job') IS NOT NULL AS cron_jobs_present \gset
\if :cron_jobs_present
WITH expected(command) AS (VALUES ($known$set lock_timeout = '5s'; set statement_timeout = '50s'; select public.recover_expired_claims(1); -- STAGE3I_ONE_USE_8b4a48ed-97e4-41a9-aa1f-b588ae850b4f$known$)),
 observed AS (SELECT j.jobid,j.jobname,j.schedule,j.active,j.database,j.username,j.command=e.command AS exact_known_command_match
 FROM cron.job j CROSS JOIN expected e WHERE j.jobid=3 OR j.jobname='geolock-expired-claim-recovery')
SELECT jsonb_build_object('section','recovery_job','job_count',(SELECT count(*) FROM observed),
 'jobs',(SELECT coalesce(jsonb_agg(jsonb_build_object('jobid',jobid,'jobname',jobname,'schedule',schedule,'active',active,'database',database,'username',username,
 'exact_known_command_match',exact_known_command_match,'batch_limit',CASE WHEN exact_known_command_match THEN 1 END,
 'lock_timeout',CASE WHEN exact_known_command_match THEN '5s' END,'statement_timeout',CASE WHEN exact_known_command_match THEN '50s' END,
 'wrapper',CASE WHEN exact_known_command_match THEN 'NO_EXPLICIT_BEGIN_COMMIT' ELSE 'UNRECOGNIZED_COMMAND_REVIEW_REQUIRED' END)),'[]') FROM observed));
\endif
SELECT 'SELECT jsonb_build_object(''section'',''recovery_runs'',''runs'',(SELECT coalesce(jsonb_agg(jsonb_build_object(''runid'',runid,''jobid'',jobid,''status'',status,''start_time'',start_time,''end_time'',end_time,''failure_class'',CASE WHEN status<>''failed'' THEN NULL WHEN return_message~*''permission denied'' THEN ''PERMISSION_DENIED'' WHEN return_message~*''statement timeout'' THEN ''STATEMENT_TIMEOUT'' WHEN return_message~*''lock timeout|deadlock'' THEN ''LOCK_OR_DEADLOCK'' ELSE ''OTHER_REVIEW_REQUIRED'' END) ORDER BY runid DESC),''[]'') FROM (SELECT * FROM cron.job_run_details WHERE jobid=3 ORDER BY runid DESC LIMIT 12) x));' WHERE to_regclass('cron.job_run_details') IS NOT NULL
\gexec
SELECT jsonb_build_object('section','preserved_route','routes',(SELECT coalesce(jsonb_agg(jsonb_build_object('route_id',r.route_id,'status',r.route_status,'vehicle_id',r.vehicle_id,'vehicle_label',v.vehicle_label,'vehicle_active',v.active_flag,'vehicle_version',v.vehicle_version,'bound_vehicle_version',b.vehicle_version,'departure_at',b.departure_at,'started_at',b.started_at,'closed_at',b.closed_at,'active_assignments',(SELECT count(*) FROM public.active_task_route_assignments a WHERE a.route_id=r.route_id),'unresolved_stops',(SELECT count(*) FROM public.pickup_route_stops s JOIN public.pickup_tasks t USING(task_id) WHERE s.route_id=r.route_id AND t.task_status IN('PLANNED','DISPATCHED')))),'[]') FROM public.pickup_routes r JOIN routing_private.bindings b USING(route_id) JOIN public.vehicles v ON v.vehicle_id=b.vehicle_id WHERE r.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9'),
 'items',(SELECT coalesce(jsonb_agg(jsonb_build_object('ordinal',i.ordinal,'task_id',t.task_id,'task_status',t.task_status,'claim_id',t.claim_id,'claim_status',c.claim_status,'lease_status',le.lease_status,'expires_at',le.expires_at,'listing_status',l.listing_status,'listing_expires_at',l.listing_expires_at,'donation_status',d.donation_status,'consumed_at',i.consumed_at,'collected_at',i.collected_at,'released_at',i.released_at,'open_cases',(SELECT count(*) FROM public.claim_reconciliation_cases rc WHERE rc.claim_id=c.claim_id AND rc.case_status IN('OPEN','MANUAL_REVIEW'))) ORDER BY i.ordinal),'[]') FROM routing_private.items i JOIN public.pickup_tasks t USING(task_id) JOIN public.donation_claims c USING(claim_id) JOIN public.claim_leases le USING(claim_id) JOIN public.listings l ON l.listing_id=c.listing_id LEFT JOIN public.donations d ON d.donation_id=l.donation_id WHERE i.route_id='db1b455e-92d0-4d58-9fa1-5de07d7ab0f9'));
SELECT jsonb_build_object('section','recent_audit_reserved_keys','checked_rows',count(*),
 'simulation_key_rows',count(*) FILTER(WHERE details?'simulation'),
 'test_run_key_rows',count(*) FILTER(WHERE details?'test_run_id'),
 'test_manifest_key_rows',count(*) FILTER(WHERE details?'test_manifest_digest'))
FROM (SELECT details FROM public.audit_events ORDER BY occurred_at DESC,event_id DESC LIMIT 1000) a;
SELECT jsonb_build_object('section','preservation_baseline','counts',jsonb_build_object('snapshots',(SELECT count(*) FROM routing_private.snapshots),'candidates',(SELECT count(*) FROM routing_private.candidates),'validations',(SELECT count(*) FROM routing_private.validations),'routes',(SELECT count(*) FROM public.pickup_routes),'assignments',(SELECT count(*) FROM public.active_task_route_assignments),'claims',(SELECT count(*) FROM public.donation_claims),'leases',(SELECT count(*) FROM public.claim_leases),'open_reconciliation',(SELECT count(*) FROM public.claim_reconciliation_cases WHERE case_status IN('OPEN','MANUAL_REVIEW')),'audit',(SELECT count(*) FROM public.audit_events)),
 'policies',(SELECT jsonb_agg(jsonb_build_object('id',policy_id,'digest',digest)) FROM routing_private.policies),
 'graphs',(SELECT jsonb_agg(to_jsonb(g)) FROM routing_private.graphs g),
 'active_transactions_other_than_inspection',(SELECT count(*) FROM pg_stat_activity WHERE pid<>pg_backend_pid() AND datname=current_database() AND (state='active' OR xact_start IS NOT NULL)),
 'target_relation_locks',(SELECT jsonb_agg(jsonb_build_object('pid',pid,'relation',relation::regclass::text,'mode',mode,'granted',granted)) FROM pg_locks WHERE relation IN('public.pickup_routes'::regclass,'public.pickup_tasks'::regclass,'public.donations'::regclass,'public.vehicles'::regclass)));

-- Full definitions only for migration dependencies and participant readers.
SELECT jsonb_build_object('section','dependency_definitions','signature',p.oid::regprocedure::text,
 'body_md5',md5(replace(p.prosrc,E'\r\n',E'\n')),'owner',p.proowner::regrole::text,'acl',p.proacl::text,
 'definition',pg_get_functiondef(p.oid))
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE (n.nspname='public' AND p.proname IN('recover_expired_claims','submit_claim_reconciliation','get_my_reconciliation_cases',
 'enforce_donation_transition','complete_pickup','close_my_collected_route','get_my_authorized_route'))
 OR (n.nspname='fleet_private' AND p.proname='route_vehicle_guard')
 OR (n.nspname='routing_private' AND p.proname IN('lock_reconciliation_scope','lock_sources','lock_route','permit_reconciled_collection','finish_reconciled_collection','task_guard'))
 ORDER BY p.oid::regprocedure::text;
SELECT jsonb_build_object('section','installer_ownership_prerequisites',
 'identity_is_export_not_installer_approval',true,
 'current_role',(SELECT jsonb_build_object('create_role',rolcreaterole,'superuser',rolsuper) FROM pg_roles WHERE rolname=current_user),
 'target_owners',(SELECT jsonb_agg(jsonb_build_object('table',c.oid::regclass::text,'owner',c.relowner::regrole::text,'current_role_owns',pg_has_role(current_user,c.relowner,'USAGE')))
 FROM pg_class c WHERE c.oid IN('public.pickup_routes'::regclass,'public.pickup_tasks'::regclass,'public.audit_events'::regclass)));
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
ROLLBACK;
