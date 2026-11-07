-- PREPARATION ONLY. DEV rcgyuwiidqvrgbxswhqj. No database execution performed.
-- Confirm Dashboard project ref / credential endpoint OUT OF BAND before connecting.
-- No SQL database name or user-supplied label authenticates a Supabase project.
BEGIN ISOLATION LEVEL READ COMMITTED READ ONLY;
SET LOCAL lock_timeout='2s';
SET LOCAL statement_timeout='30s';
-- P01: identity evidence; execution session must later be postgres/postgres.
SELECT clock_timestamp() AS observed_at,current_database(),current_user,session_user,
 current_setting('transaction_read_only') AS read_only,
 current_setting('transaction_isolation') AS isolation,
 current_setting('server_version') AS server_version,
 current_setting('extra_float_digits') AS extra_float_digits,
 current_setting('TimeZone') AS timezone;
-- P02: 28 reviewed 001/002 functions: exact source/metadata/direct EXECUTE ACL; membership checked separately.
WITH expected(signature,body_md5,result_type,definer,volatility,config,grantees) AS (VALUES
('public.assign_task_to_route(uuid,uuid,integer)','047f2b5d6a4483b8cef8e3b91c9dc299','void',true,'v',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['postgres']::text[]),
('public.attest_routing_candidate(uuid,text,jsonb)','99789f22097aabb066595f44a7cfdb48','void',true,'v',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['geolock_validator','postgres']::text[]),
('public.authorize_my_routing_candidate(uuid,uuid,timestamptz)','1c3c880e27da261a9a95a95730640196','jsonb',true,'v',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['authenticated','postgres']::text[]),
('public.begin_my_routing_snapshot(uuid,uuid,uuid[])','dca3ee04e8fbf991c4ef0993930ec185','jsonb',true,'v',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['authenticated','postgres']::text[]),
('public.freeze_routing_graph(uuid,text,text,text)','8e1434ea2727e30f898ddff289ac2df3','uuid',true,'v',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['geolock_graph_worker','postgres']::text[]),
('public.install_routing_policy(uuid,jsonb)','7b3549f82b239d6c6abbd4a5fee58b4e','uuid',true,'v',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['geolock_graph_worker','postgres']::text[]),
('public.read_frozen_routing_graph(uuid,bigint,integer)','f3f732a1224fa0290077197f473026b6','jsonb',true,'v',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['geolock_graph_worker','postgres']::text[]),
('public.read_pending_routing_snapshot(uuid)','5125c4a3cce5f4c0bf9aebdf83f73847','jsonb',true,'v',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['geolock_planner','postgres']::text[]),
('public.read_routing_snapshot_bundle(uuid)','443812854b91b1bf9f93d6fecbd48ced','jsonb',true,'v',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['geolock_planner','postgres']::text[]),
('public.read_routing_work_item(uuid)','1ee7721aca6bc5d8fd490898e0fcf6d9','jsonb',true,'v',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['geolock_validator','postgres']::text[]),
('public.seal_routing_snapshot(uuid,uuid)','21440a57a37758997fcffcd89cf416a0','jsonb',true,'v',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['geolock_planner','postgres']::text[]),
('public.store_routing_matrix(uuid,uuid,jsonb)','bccccc76068912ae1d3cbff42a18964f','uuid',true,'v',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['geolock_graph_worker','postgres']::text[]),
('public.submit_routing_candidate(uuid,uuid,jsonb)','85ff82ee813722c69a98e8d197bd5323','jsonb',true,'v',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['geolock_planner','postgres']::text[]),
('routing_private.actor_lock(uuid,boolean)','b7de071f2da83c77809f4d505b2cc3b2','void',true,'v',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['postgres']::text[]),
('routing_private.admissible(jsonb,uuid,timestamptz,jsonb)','86cdbf87fcaef3f3ac0e36cda4824418','boolean',false,'s',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['postgres']::text[]),
('routing_private.append_only()','bf4e4f93b210de23118f16eb3b5b6f33','trigger',true,'v',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['postgres']::text[]),
('routing_private.arc(jsonb,text,text)','ceb33e05e1bf4b7d8238daee42c13974','jsonb',false,'i',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['postgres']::text[]),
('routing_private.freeze_network()','55f50fab862e381f21ed355a93c2bcea','trigger',true,'v',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['postgres']::text[]),
('routing_private.hash(jsonb)','9baadd9fb14fce159d94e4e0bd983c22','text',false,'i',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['postgres']::text[]),
('routing_private.lock_sources(uuid[])','52dc6262f3f85bd3c67a787401cf71aa','void',true,'v',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['postgres']::text[]),
('routing_private.network_digest(text,text)','26aceaa8835e3db8bba3a73879024212','jsonb',true,'v',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['postgres']::text[]),
('routing_private.ngo_observation(uuid)','6da6cd58224e4d6e58c732b734a081cb','jsonb',true,'s',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['postgres']::text[]),
('routing_private.observe_task(uuid)','53f058161125f26980f65303d45dccc1','jsonb',true,'s',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['postgres']::text[]),
('routing_private.snapshot_guard()','fd7b479db124345977509f8401b2dab6','trigger',true,'v',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['postgres']::text[]),
('routing_private.snapshot_task(jsonb,uuid)','61704ef635b841fe02fff0118a196aef','jsonb',false,'i',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['postgres']::text[]),
('routing_private.task_digest(jsonb)','e28f2dba4773bbbe8e32a700047e6f6e','text',false,'i',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['postgres']::text[]),
('routing_private.task_window(jsonb,timestamptz,jsonb)','82362da140f544be5d5ca5c622183fbb','jsonb',false,'i',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['postgres']::text[]),
('routing_private.worker(text)','9fce37c17364e88eb1e2101be042a822','void',true,'v',ARRAY['search_path=pg_catalog, pg_temp','TimeZone=UTC','extra_float_digits=0']::text[],ARRAY['postgres']::text[])
), observed AS (
 SELECT e.*,p.oid,p.prosrc,p.proconfig,p.prosecdef,p.provolatile,
 pg_get_userbyid(p.proowner) AS owner,pg_get_function_result(p.oid) AS actual_result,
 ARRAY(SELECT CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END
 FROM aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
 WHERE a.privilege_type='EXECUTE' ORDER BY 1) AS actual_grantees,p.proacl::text AS acl
 FROM expected e LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature)
)
SELECT signature,CASE WHEN oid IS NOT NULL AND owner='postgres'
 AND md5(replace(prosrc,E'\r\n',E'\n'))=body_md5 AND actual_result=result_type
 AND prosecdef=definer AND provolatile::text=volatility AND proconfig IS NOT DISTINCT FROM config
 AND actual_grantees=grantees THEN 'PASS' ELSE 'FAIL' END AS status,
 body_md5 AS expected_md5,md5(replace(prosrc,E'\r\n',E'\n')) AS actual_md5,
 owner,actual_result,prosecdef,provolatile,proconfig,actual_grantees,acl
FROM observed ORDER BY signature;
-- P03: migration's five exact lifecycle inputs; the audit helper is separate.
WITH expected(signature,body_md5,config,result_type) AS (VALUES ('public.start_pickup(uuid)','e89b650c83713b04e8310f4c372f10f4','search_path=public, extensions, pg_temp','void'),
  ('public.complete_pickup(uuid,boolean)','ae1b885377292281da17951cb18afd55','search_path=public, extensions, pg_temp','void'),
  ('public.submit_claim_reconciliation(uuid,boolean,uuid)','246a33d552da2ac4e229fa79c357d194','search_path=pg_catalog, public, pg_temp','jsonb'),
  ('public.recover_expired_claims(integer)','89e01f42d5ec23bfcbcdc47c1f4fd4e5','search_path=pg_catalog, public, extensions, pg_temp','integer'),
  ('public.claim_listing(uuid,uuid)','2c1f60c876797c61b44b3cb43591bab8','search_path=pg_catalog, public, extensions, pg_temp','jsonb'))
SELECT e.signature,CASE WHEN p.oid IS NOT NULL AND pg_get_userbyid(p.proowner)='postgres'
 AND p.prosecdef AND p.provolatile='v' AND p.proconfig=ARRAY[e.config]
 AND pg_get_function_result(p.oid)=e.result_type
 AND md5(replace(p.prosrc,E'\r\n',E'\n'))=e.body_md5 THEN 'PASS' ELSE 'FAIL' END AS status,
 e.body_md5 AS expected_md5,md5(replace(p.prosrc,E'\r\n',E'\n')) AS actual_md5,
 p.proconfig,p.proacl::text AS acl
FROM expected e LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature);
SELECT 'six_argument_audit_helper' AS check_name,
 CASE WHEN pg_get_userbyid(p.proowner)='postgres' AND NOT p.prosecdef
 AND p.proconfig=ARRAY['search_path=pg_catalog, public, pg_temp']
 AND pg_get_function_result(p.oid)='void'
 AND md5(replace(p.prosrc,E'\r\n',E'\n'))='67f27a85fb9129c9017bb0e9178f8ba1'
 THEN 'PASS' ELSE 'FAIL' END AS status,p.proacl::text AS acl
FROM (SELECT to_regprocedure('public.geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text)') oid) t
LEFT JOIN pg_proc p USING(oid);
-- P04: all 14 added signatures must be absent before first 003 installation.
WITH expected(signature) AS (VALUES
('public.cancel_my_unstarted_route(uuid)'),
('public.close_my_collected_route(uuid,boolean)'),
('public.get_my_authorized_route(uuid)'),
('public.get_my_routing_overview()'),
('routing_private.check_remaining(uuid,uuid,timestamptz)'),
('routing_private.close_collected(uuid)'),
('routing_private.finish_reconciled_collection(uuid)'),
('routing_private.legacy_complete_pickup(uuid,boolean)'),
('routing_private.legacy_start_pickup(uuid)'),
('routing_private.lock_reconciliation_scope(uuid)'),
('routing_private.lock_route(uuid,boolean)'),
('routing_private.permit_reconciled_collection(uuid)'),
('routing_private.reconciliation_participant(uuid)'),
('routing_private.task_guard()')
)
SELECT signature,to_regprocedure(signature) IS NULL AS must_be_absent FROM expected;
-- Name inventory also detects unexpected overloads/partial helpers; compare baseline names.
SELECT n.nspname,p.proname,p.oid::regprocedure::text AS signature
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='routing_private' OR (n.nspname='public' AND p.proname IN
 ('close_my_collected_route','cancel_my_unstarted_route','get_my_routing_overview','get_my_authorized_route'))
ORDER BY 1,2,3;
-- P05: reused C.3 Query 2 — full definition comparison, not counts alone.
-- QUERY 2 — routing_private table structure and direct catalog dependencies.
-- One output row per expected table; nested JSON avoids large flat result sets.
-- Catalog metadata only. No application records or UUID values are returned.
WITH expected(table_name) AS (VALUES
 ('bindings'),('cancelled_stop_history'),('candidates'),('graphs'),('items'),
 ('legacy_inflight'),('matrices'),('policies'),('requests'),('snapshots'),('validations')
), target AS (
 SELECT e.table_name,c.oid AS relid,c.relowner,c.relkind,c.relpersistence,
        c.relrowsecurity,c.relforcerowsecurity
 FROM expected e
 LEFT JOIN pg_namespace n ON n.nspname='routing_private'
 LEFT JOIN pg_class c ON c.relnamespace=n.oid AND c.relname=e.table_name
   AND c.relkind IN ('r','p')
), columns_meta AS (
 SELECT t.relid,
        jsonb_agg(jsonb_build_object(
          'ordinal',a.attnum,
          'column',a.attname,
          'type',format_type(a.atttypid,a.atttypmod),
          'not_null',a.attnotnull,
          'default',(SELECT pg_get_expr(d.adbin,d.adrelid)
                     FROM pg_attrdef d
                     WHERE d.adrelid=a.attrelid AND d.adnum=a.attnum),
          'identity',a.attidentity,
          'generated',a.attgenerated
        ) ORDER BY a.attnum) AS items
 FROM target t JOIN pg_attribute a ON a.attrelid=t.relid
 WHERE a.attnum>0 AND NOT a.attisdropped
 GROUP BY t.relid
), indexes_meta AS (
 SELECT t.relid,
        jsonb_agg(jsonb_build_object(
          'name',ic.relname,
          'definition',pg_get_indexdef(i.indexrelid),
          'primary',i.indisprimary,
          'unique',i.indisunique,
          'valid',i.indisvalid,
          'live',i.indislive
        ) ORDER BY ic.relname) AS items
 FROM target t JOIN pg_index i ON i.indrelid=t.relid
 JOIN pg_class ic ON ic.oid=i.indexrelid
 GROUP BY t.relid
), constraints_meta AS (
 SELECT t.relid,
        jsonb_agg(jsonb_build_object(
          'name',con.conname,
          'type',con.contype,
          'validated',con.convalidated,
          'definition',pg_get_constraintdef(con.oid,true)
        ) ORDER BY con.conname) AS items
 FROM target t JOIN pg_constraint con ON con.conrelid=t.relid
 GROUP BY t.relid
), triggers_meta AS (
 SELECT t.relid,
        jsonb_agg(jsonb_build_object(
          'name',tr.tgname,
          'enabled',tr.tgenabled,
          'internal',tr.tgisinternal,
          'function',tr.tgfoid::regprocedure::text,
          'definition',pg_get_triggerdef(tr.oid,true)
        ) ORDER BY tr.tgname) AS items
 FROM target t JOIN pg_trigger tr ON tr.tgrelid=t.relid
 GROUP BY t.relid
), dependencies_raw AS (
 SELECT t.relid,'depends_on'::text AS direction,d.deptype,
        pg_describe_object(d.refclassid,d.refobjid,d.refobjsubid) AS object_description
 FROM target t JOIN pg_depend d
   ON d.classid='pg_class'::regclass AND d.objid=t.relid
 WHERE t.relid IS NOT NULL
 UNION ALL
 SELECT t.relid,'referenced_by'::text AS direction,d.deptype,
        pg_describe_object(d.classid,d.objid,d.objsubid) AS object_description
 FROM target t JOIN pg_depend d
   ON d.refclassid='pg_class'::regclass AND d.refobjid=t.relid
 WHERE t.relid IS NOT NULL
), dependencies_meta AS (
 SELECT dep.relid,
        jsonb_agg(jsonb_build_object(
          'direction',dep.direction,
          'dependency_type',dep.deptype,
          'object',dep.object_description
        ) ORDER BY dep.direction,dep.deptype,dep.object_description) AS items
 FROM (SELECT DISTINCT relid,direction,deptype,object_description
       FROM dependencies_raw) dep
 GROUP BY dep.relid
)
SELECT 'routing_private'::text AS schema_name,
       t.table_name,
       t.relid IS NOT NULL AS table_present,
       CASE WHEN t.relid IS NULL THEN NULL ELSE t.relid::regclass::text END AS relation,
       CASE WHEN t.relowner IS NULL THEN NULL ELSE t.relowner::regrole::text END AS table_owner,
       t.relkind AS relation_kind,
       t.relpersistence AS persistence,
       t.relrowsecurity AS rls_enabled,
       t.relforcerowsecurity AS force_rls,
       coalesce(cm.items,'[]'::jsonb) AS columns,
       coalesce(im.items,'[]'::jsonb) AS indexes,
       coalesce(com.items,'[]'::jsonb) AS constraints,
       coalesce(tm.items,'[]'::jsonb) AS triggers,
       coalesce(dm.items,'[]'::jsonb) AS direct_dependencies
FROM target t
LEFT JOIN columns_meta cm ON cm.relid=t.relid
LEFT JOIN indexes_meta im ON im.relid=t.relid
LEFT JOIN constraints_meta com ON com.relid=t.relid
LEFT JOIN triggers_meta tm ON tm.relid=t.relid
LEFT JOIN dependencies_meta dm ON dm.relid=t.relid
ORDER BY t.table_name;

-- P06: reused scoped effective privileges and membership evidence.
-- QUERY 3 — effective DML privileges on the two tables checked by Stage A 003.
-- Expected output: 2 tables x 6 roles = 12 rows. The combined predicate
-- mirrors the reviewed migration guard; individual privileges are separate.
-- Catalog/ACL inspection only; no table rows or application functions read.
WITH roles(role_name) AS (VALUES
 ('anon'),('authenticated'),('service_role'),
 ('geolock_graph_worker'),('geolock_planner'),('geolock_validator')
), expected_tables(table_name) AS (VALUES
 ('items'),('legacy_inflight')
), target AS (
 SELECT e.table_name,c.oid AS relid
 FROM expected_tables e
 LEFT JOIN pg_namespace n ON n.nspname='routing_private'
 LEFT JOIN pg_class c ON c.relnamespace=n.oid AND c.relname=e.table_name
   AND c.relkind IN ('r','p')
)
SELECT r.role_name,
       role.oid IS NOT NULL AS role_present,
       t.table_name,
       t.relid IS NOT NULL AS table_present,
       CASE WHEN role.oid IS NULL OR t.relid IS NULL THEN NULL
            ELSE has_table_privilege(role.oid,t.relid,'INSERT') END AS can_insert,
       CASE WHEN role.oid IS NULL OR t.relid IS NULL THEN NULL
            ELSE has_table_privilege(role.oid,t.relid,'UPDATE') END AS can_update,
       CASE WHEN role.oid IS NULL OR t.relid IS NULL THEN NULL
            ELSE has_table_privilege(role.oid,t.relid,'DELETE') END AS can_delete,
       CASE WHEN role.oid IS NULL OR t.relid IS NULL THEN NULL
            ELSE has_table_privilege(role.oid,t.relid,'TRUNCATE') END AS can_truncate,
       CASE WHEN role.oid IS NULL OR t.relid IS NULL THEN NULL
            ELSE has_table_privilege(role.oid,t.relid,'INSERT,UPDATE,DELETE') END
         AS stage_a_003_guard_dml_access
FROM roles r CROSS JOIN target t
LEFT JOIN pg_roles role ON role.rolname=r.role_name
ORDER BY t.table_name,r.role_name;

-- QUERY 4 — role membership, inherited ACL paths, and effective EXECUTE for
-- public.submit_claim_reconciliation(uuid,boolean,uuid). Output: six rows.
-- The function is not invoked; only role/function catalogs and ACLs are read.
WITH RECURSIVE requested(role_name) AS (VALUES
 ('anon'),('authenticated'),('service_role'),
 ('geolock_graph_worker'),('geolock_planner'),('geolock_validator')
), target_roles AS (
 SELECT q.role_name,r.oid
 FROM requested q LEFT JOIN pg_roles r ON r.rolname=q.role_name
), membership_paths(start_oid,member_oid,is_direct,inherit_path) AS (
 SELECT m.member,m.roleid,true,m.inherit_option
 FROM pg_auth_members m JOIN target_roles t ON t.oid=m.member
 UNION
 SELECT path.start_oid,m.roleid,false,path.inherit_path AND m.inherit_option
 FROM membership_paths path
 JOIN pg_auth_members m ON m.member=path.member_oid
), membership_summary AS (
 SELECT path.start_oid,
        jsonb_agg(jsonb_build_object(
          'granted_role',granted.rolname,
          'direct_membership',path.is_direct,
          'inherit_path',path.inherit_path
        ) ORDER BY granted.rolname,path.is_direct DESC,path.inherit_path DESC) AS memberships
 FROM membership_paths path
 JOIN pg_roles granted ON granted.oid=path.member_oid
 GROUP BY path.start_oid
), function_target AS (
 SELECT to_regprocedure('public.submit_claim_reconciliation(uuid,boolean,uuid)') AS oid
), acl_rows AS (
 SELECT acl.grantee,acl.grantor,acl.privilege_type,acl.is_grantable
 FROM function_target f JOIN pg_proc p ON p.oid=f.oid
 CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) acl
)
SELECT t.role_name,
       t.oid IS NOT NULL AS role_present,
       f.oid IS NOT NULL AS function_present,
       CASE WHEN p.oid IS NULL THEN NULL ELSE p.oid::regprocedure::text END AS function_signature,
       CASE WHEN p.oid IS NULL THEN NULL ELSE p.proowner::regrole::text END AS function_owner,
       p.prosecdef AS security_definer,
       p.proacl::text AS function_acl,
       coalesce(ms.memberships,'[]'::jsonb) AS membership_paths,
       CASE WHEN t.oid IS NULL OR p.oid IS NULL THEN NULL
            ELSE has_function_privilege(t.oid,p.oid,'EXECUTE') END AS effective_can_execute,
       CASE WHEN t.oid IS NULL OR p.oid IS NULL THEN NULL ELSE EXISTS(
         SELECT 1 FROM acl_rows a
         WHERE a.grantee=t.oid AND a.privilege_type='EXECUTE'
       ) END AS direct_acl_execute,
       CASE WHEN p.oid IS NULL THEN NULL ELSE EXISTS(
         SELECT 1 FROM acl_rows a
         WHERE a.grantee=0 AND a.privilege_type='EXECUTE'
       ) END AS public_acl_execute,
       CASE WHEN t.oid IS NULL OR p.oid IS NULL THEN NULL ELSE EXISTS(
         SELECT 1 FROM membership_paths path JOIN acl_rows a
           ON a.grantee=path.member_oid AND a.privilege_type='EXECUTE'
         WHERE path.start_oid=t.oid AND path.inherit_path
       ) END AS inherited_acl_execute,
       coalesce((
         SELECT jsonb_agg(jsonb_build_object(
           'grantee',CASE WHEN a.grantee=0 THEN 'PUBLIC'
                          ELSE a.grantee::regrole::text END,
           'grantor',a.grantor::regrole::text,
           'grantable',a.is_grantable
         ) ORDER BY a.grantee)
         FROM acl_rows a WHERE a.privilege_type='EXECUTE'
       ),'[]'::jsonb) AS execute_acl_grantees
FROM target_roles t
CROSS JOIN function_target f
LEFT JOIN pg_proc p ON p.oid=f.oid
LEFT JOIN membership_summary ms ON ms.start_oid=t.oid
ORDER BY t.role_name;

-- P07: reused ten aggregate cutover predicates.
-- QUERY 5 — aggregate-only operational cutover counts. Returns one row and
-- no identifiers or individual operational records. Exact COUNT scans are
-- limited to the six reviewed source tables used by the Stage A 003 cutover.
WITH dispatched AS (
 SELECT task_id FROM public.pickup_tasks WHERE task_status='DISPATCHED'
), legacy AS (
 SELECT task_id FROM routing_private.legacy_inflight
), task_cutover AS (
 SELECT
   (SELECT count(*) FROM dispatched) AS dispatched_task_count,
   (SELECT count(*) FROM legacy) AS legacy_inflight_count,
   (SELECT count(*) FROM dispatched d JOIN legacy l USING(task_id)) AS dispatched_legacy_overlap_count,
   (SELECT count(*) FROM dispatched d
    WHERE NOT EXISTS (SELECT 1 FROM legacy l WHERE l.task_id=d.task_id))
      AS dispatched_not_in_legacy_count
), route_cutover AS (
 SELECT
   (SELECT count(*) FROM routing_private.bindings WHERE closed_at IS NULL)
      AS active_route_binding_count,
   (SELECT count(*) FROM routing_private.items WHERE released_at IS NULL)
      AS active_route_item_count,
   (SELECT count(*) FROM routing_private.items i
    JOIN routing_private.bindings b USING(route_id)
    WHERE i.released_at IS NULL AND b.closed_at IS NULL)
      AS active_item_on_active_binding_count,
   (SELECT count(DISTINCT i.task_id)
    FROM routing_private.items i
    JOIN routing_private.bindings b USING(route_id)
    JOIN public.pickup_tasks t USING(task_id)
    WHERE i.released_at IS NULL AND b.closed_at IS NULL
      AND t.task_status='DISPATCHED')
      AS dispatched_task_on_active_route_count,
   (SELECT count(*) FROM public.pickup_routes WHERE route_status='IN_PROGRESS')
      AS in_progress_route_count
), reconciliation_cutover AS (
 SELECT count(*) AS unresolved_reconciliation_case_count
 FROM public.claim_reconciliation_cases
 WHERE case_status IN ('OPEN','MANUAL_REVIEW')
)
SELECT task_cutover.dispatched_task_count,
       task_cutover.legacy_inflight_count,
       task_cutover.dispatched_legacy_overlap_count,
       task_cutover.dispatched_not_in_legacy_count,
       route_cutover.active_route_binding_count,
       route_cutover.active_route_item_count,
       route_cutover.active_item_on_active_binding_count,
       route_cutover.dispatched_task_on_active_route_count,
       route_cutover.in_progress_route_count,
       reconciliation_cutover.unresolved_reconciliation_case_count
FROM task_cutover CROSS JOIN route_cutover CROSS JOIN reconciliation_cutover;


-- Active lifecycle summaries: review even when route/dispatch counts are zero.
SELECT task_status::text AS status,count(*) FROM public.pickup_tasks GROUP BY task_status ORDER BY 1;
SELECT claim_status::text AS status,count(*) FROM public.donation_claims GROUP BY claim_status ORDER BY 1;
SELECT lease_status::text AS status,count(*),count(*) FILTER (WHERE expires_at<=statement_timestamp()) AS expired
FROM public.claim_leases GROUP BY lease_status ORDER BY 1;
-- Global counts are comparable only during an agreed writer/deployment pause.
SELECT 'pickup_tasks' AS relation,count(*) FROM public.pickup_tasks
UNION ALL SELECT 'donation_claims',count(*) FROM public.donation_claims
UNION ALL SELECT 'claim_leases',count(*) FROM public.claim_leases
UNION ALL SELECT 'pickup_routes',count(*) FROM public.pickup_routes
UNION ALL SELECT 'pickup_route_stops',count(*) FROM public.pickup_route_stops
UNION ALL SELECT 'active_task_route_assignments',count(*) FROM public.active_task_route_assignments
UNION ALL SELECT 'claim_reconciliation_cases',count(*) FROM public.claim_reconciliation_cases
UNION ALL SELECT 'audit_events',count(*) FROM public.audit_events
UNION ALL SELECT 'donations',count(*) FROM public.donations
UNION ALL SELECT 'listings',count(*) FROM public.listings;
-- P08: full application trigger definitions; compare C.1/C.3 evidence.
SELECT n.nspname,c.relname,t.tgname,t.tgenabled,t.tgfoid::regprocedure::text AS function,
 pg_get_triggerdef(t.oid,true) AS definition
FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE NOT t.tgisinternal AND (n.nspname='routing_private' OR (n.nspname='public' AND c.relname IN
 ('pickup_tasks','pickup_routes','pickup_route_stops','active_task_route_assignments',
 'donation_claims','claim_leases','listings','donations','claim_reconciliation_cases')))
ORDER BY 1,2,3;
SELECT nspname,pg_get_userbyid(nspowner) AS owner,nspacl::text,
 obj_description(oid,'pg_namespace') AS comment
FROM pg_namespace WHERE nspname IN ('routing_private','fleet_private');
-- Explicit false required preflight; true required postflight.
SELECT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid=to_regclass('public.pickup_tasks')
 AND tgname='routing_task_authority') AS authority_trigger_present;
-- Worker presence/attributes; no automatic repair on missing/unexpected roles.
WITH expected(name) AS (VALUES ('geolock_graph_worker'),('geolock_planner'),('geolock_validator'))
SELECT e.name,r.oid IS NOT NULL AS present,r.rolcanlogin,r.rolsuper,r.rolcreatedb,
 r.rolcreaterole,r.rolreplication,r.rolbypassrls
FROM expected e LEFT JOIN pg_roles r ON r.rolname=e.name;
-- Global direct membership edges expose paths beyond the earlier six-role scope.
SELECT pg_get_userbyid(member) AS member,pg_get_userbyid(roleid) AS granted_role,
 inherit_option,set_option,admin_option FROM pg_auth_members ORDER BY 1,2;
-- Audit helper must be inaccessible to all six roles.
WITH expected(name) AS (VALUES ('anon'),('authenticated'),('service_role'),
 ('geolock_graph_worker'),('geolock_planner'),('geolock_validator'))
SELECT e.name,r.oid IS NOT NULL AS present,
 CASE WHEN r.oid IS NULL OR f.oid IS NULL THEN NULL ELSE has_function_privilege(r.oid,f.oid,'EXECUTE') END AS forbidden_execute
FROM expected e LEFT JOIN pg_roles r ON r.rolname=e.name
CROSS JOIN (SELECT to_regprocedure('public.geolock_transition_listing_donations(uuid,text,text,uuid,uuid,text)') oid) f;
-- P09: inherited table/column writes; every returned forbidden_write must be false.
SELECT r.rolname,c.oid::regclass::text AS relation,
 (has_table_privilege(r.oid,c.oid,'INSERT,UPDATE,DELETE,TRUNCATE')
 OR has_any_column_privilege(r.oid,c.oid,'INSERT,UPDATE')) AS forbidden_write
FROM pg_roles r CROSS JOIN pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE (r.rolname IN ('anon','authenticated') AND n.nspname='public'
 AND c.relname IN ('pickup_tasks','pickup_routes','pickup_route_stops','active_task_route_assignments'))
OR (r.rolname IN ('anon','authenticated','service_role','geolock_graph_worker','geolock_planner','geolock_validator')
 AND n.nspname='routing_private' AND c.relkind='r') ORDER BY 1,2;
-- P10: policy and spatial inventory. 003 has no direct spatial-version guard.
SELECT count(*) AS singleton_rows,bool_and(claim_lease_minutes=360 AND donation_direct_min_kg=10
 AND geofence_radius_m=20000) AS policy_matches FROM public.coordination_config WHERE singleton;
SELECT e.extname,e.extversion,n.nspname AS schema FROM pg_extension e
JOIN pg_namespace n ON n.oid=e.extnamespace WHERE e.extname IN ('postgis','pgrouting');
SELECT p.oid::regprocedure::text AS signature,pg_get_function_result(p.oid) AS result,
 p.provolatile FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='extensions' AND p.proname='pgr_dijkstracost' ORDER BY 1;
-- Catalog seal observation only: no SECURITY DEFINER application function invoked.
SELECT pg_get_userbyid(p.proowner) AS owner,p.prosecdef,p.provolatile,p.proconfig,p.proacl::text,
 md5(replace(p.prosrc,E'\r\n',E'\n')) AS body_md5
FROM pg_proc p WHERE p.oid=to_regprocedure('fleet_private.installation_fingerprint()');
-- P11: history discovery only. Missing ledger is UNKNOWN, not "never applied".
SELECT to_regclass('supabase_migrations.schema_migrations') AS application_ledger,
 EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='supabase_migrations'
 AND table_name='schema_migrations' AND column_name='version') AS has_version,
 EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='supabase_migrations'
 AND table_name='schema_migrations' AND column_name='name') AS has_name;
-- Effective function EXECUTE matrix; compare allowed roles in expected-functions.json.
WITH functions AS (SELECT p.oid,n.nspname,p.proname FROM pg_proc p
 JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='routing_private'
 OR (n.nspname='public' AND p.proname IN
 ('start_pickup','complete_pickup','submit_claim_reconciliation','close_my_collected_route',
 'cancel_my_unstarted_route','get_my_routing_overview','get_my_authorized_route')))
SELECT f.oid::regprocedure::text AS signature,r.rolname,has_function_privilege(r.oid,f.oid,'EXECUTE') AS can_execute
FROM functions f CROSS JOIN pg_roles r WHERE r.rolname IN ('anon','authenticated','service_role',
 'geolock_graph_worker','geolock_planner','geolock_validator') ORDER BY 1,2;

ROLLBACK;
