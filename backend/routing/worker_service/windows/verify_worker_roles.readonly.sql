-- MANUAL SELECT-only catalog inspection in DEV SQL Editor as postgres.
-- Expected: exactly one intended worker membership per login; every unsafe
-- flag false, can_login true, inherits false, admin_option false.
SELECT l.rolname AS login,l.rolcanlogin AS can_login,l.rolinherit AS inherits,
 l.rolsuper,l.rolcreatedb,l.rolcreaterole,l.rolreplication,l.rolbypassrls,
 p.rolname AS member_of,m.admin_option
FROM pg_roles l LEFT JOIN pg_auth_members m ON m.member=l.oid
LEFT JOIN pg_roles p ON p.oid=m.roleid
WHERE l.rolname IN ('geolock_graph_login','geolock_planner_login','geolock_validator_login')
ORDER BY login,member_of;

-- Matrix: only the matching scope should be true. Transitive memberships count.
SELECT l.login,g.scope,pg_has_role(l.login,g.scope,'MEMBER') AS member
FROM (VALUES ('geolock_graph_login'),('geolock_planner_login'),('geolock_validator_login')) l(login)
CROSS JOIN (VALUES ('geolock_graph_worker'),('geolock_planner'),('geolock_validator'),
 ('postgres'),('authenticated'),('service_role'),('authenticator')) g(scope)
ORDER BY l.login,g.scope;

-- Effective application privileges INCLUDE PUBLIC. Inspect these; membership
-- alone cannot prove absence of unrelated PUBLIC grants. Do not revoke PUBLIC
-- globally to fix an unexpected grant.
SELECT r.rolname AS scope,n.nspname AS schema,p.proname,p.prosecdef AS security_definer
FROM pg_roles r CROSS JOIN pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE r.rolname IN ('geolock_graph_worker','geolock_planner','geolock_validator',
 'geolock_graph_login','geolock_planner_login','geolock_validator_login')
AND n.nspname IN ('public','fleet_private','routing_private')
AND has_schema_privilege(r.oid,n.oid,'USAGE') AND has_function_privilege(r.oid,p.oid,'EXECUTE')
ORDER BY scope,schema,p.proname;

-- Expected: zero direct application table-write privileges for these scopes.
SELECT r.rolname AS scope,n.nspname AS schema,c.relname
FROM pg_roles r CROSS JOIN pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE r.rolname IN ('geolock_graph_worker','geolock_planner','geolock_validator',
 'geolock_graph_login','geolock_planner_login','geolock_validator_login')
AND n.nspname IN ('public','fleet_private','routing_private') AND c.relkind IN ('r','p')
AND (has_table_privilege(r.oid,c.oid,'INSERT,UPDATE,DELETE,TRUNCATE')
 OR has_any_column_privilege(r.oid,c.oid,'INSERT,UPDATE'))
ORDER BY scope,schema,c.relname;
