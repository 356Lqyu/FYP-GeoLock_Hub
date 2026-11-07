-- Stage C.3 manual read-only inspection package.
-- Query 1 only. User-run in the approved DEV Dashboard SQL Editor.
-- Catalog SELECT only: no application function calls, table rows, DDL, or DML.

-- QUERY 1 — Complete Stage A 001/002 function signature and metadata inventory.
-- Expected output: 28 rows. The assign_task_to_route entry is phase 002;
-- other signatures are compared to their reviewed 001/002 definitions.
WITH expected(signature,stage_phase) AS (VALUES
 ('routing_private.hash(jsonb)','001'),
 ('routing_private.worker(text)','001'),
 ('routing_private.append_only()','001'),
 ('routing_private.snapshot_guard()','001'),
 ('routing_private.freeze_network()','001'),
 ('public.install_routing_policy(uuid,jsonb)','001'),
 ('routing_private.network_digest(text,text)','001'),
 ('public.freeze_routing_graph(uuid,text,text,text)','001'),
 ('public.store_routing_matrix(uuid,uuid,jsonb)','001'),
 ('routing_private.observe_task(uuid)','001'),
 ('routing_private.task_digest(jsonb)','001'),
 ('routing_private.ngo_observation(uuid)','001'),
 ('public.begin_my_routing_snapshot(uuid,uuid,uuid[])','001'),
 ('public.seal_routing_snapshot(uuid,uuid)','001'),
 ('public.submit_routing_candidate(uuid,uuid,jsonb)','001'),
 ('public.read_routing_work_item(uuid)','001'),
 ('public.attest_routing_candidate(uuid,text,jsonb)','001'),
 ('public.read_frozen_routing_graph(uuid,bigint,integer)','001'),
 ('public.read_routing_snapshot_bundle(uuid)','001'),
 ('public.read_pending_routing_snapshot(uuid)','001'),
 ('routing_private.actor_lock(uuid,boolean)','002'),
 ('routing_private.lock_sources(uuid[])','002'),
 ('routing_private.task_window(jsonb,timestamptz,jsonb)','002'),
 ('routing_private.admissible(jsonb,uuid,timestamptz,jsonb)','002'),
 ('routing_private.arc(jsonb,text,text)','002'),
 ('routing_private.snapshot_task(jsonb,uuid)','002'),
 ('public.authorize_my_routing_candidate(uuid,uuid,timestamptz)','002'),
 ('public.assign_task_to_route(uuid,uuid,integer)','002 (post-publication)')
)
SELECT e.stage_phase,
       e.signature AS expected_signature,
       p.oid IS NOT NULL AS function_present,
       CASE WHEN p.oid IS NULL THEN NULL ELSE p.oid::regprocedure::text END AS actual_signature,
       CASE WHEN p.oid IS NULL THEN NULL ELSE pg_get_function_identity_arguments(p.oid) END AS identity_arguments,
       pg_get_function_result(p.oid) AS result_type,
       CASE WHEN p.oid IS NULL THEN NULL ELSE p.proowner::regrole::text END AS function_owner,
       p.prosecdef AS security_definer,
       p.provolatile AS volatility,
       p.proconfig AS function_configuration,
       p.proacl::text AS function_acl,
       CASE WHEN p.oid IS NULL THEN NULL
            ELSE md5(replace(p.prosrc,E'\r\n',E'\n')) END AS body_md5
FROM expected e
LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature)
ORDER BY e.stage_phase,e.signature;

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

-- QUERY 6 — discover alternate migration-history relations by catalog name.
-- Query 2a found no supabase_migrations.schema_migrations relation. This
-- bounded catalog-only query checks whether another conventionally named
-- migration ledger relation exists; it does not read ledger rows or data.
SELECT n.nspname AS schema_name,
       c.relname AS relation_name,
       CASE c.relkind
         WHEN 'r' THEN 'table'
         WHEN 'p' THEN 'partitioned table'
         WHEN 'v' THEN 'view'
         WHEN 'm' THEN 'materialized view'
         WHEN 'f' THEN 'foreign table'
         ELSE c.relkind::text
       END AS relation_kind,
       pg_get_userbyid(c.relowner) AS relation_owner,
       c.relpersistence AS persistence
FROM pg_class c
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname NOT IN ('pg_catalog','information_schema')
  AND (c.relname ILIKE '%migration%'
       OR c.relname ILIKE '%flyway%'
       OR c.relname ILIKE '%liquibase%')
ORDER BY n.nspname,c.relname
LIMIT 100;
