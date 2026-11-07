BEGIN READ ONLY;
SET LOCAL statement_timeout='10s';
SELECT current_database(),session_user,current_user,current_setting('transaction_read_only');
SELECT oid::regprocedure,md5(replace(prosrc,E'\r\n',E'\n')) AS body_md5,
 pg_get_userbyid(proowner) AS owner,provolatile,prosecdef,proconfig,proacl,
 has_function_privilege('authenticated',oid,'EXECUTE') AS ngo_execute,
 has_function_privilege('anon',oid,'EXECUTE') AS anon_execute,
 has_function_privilege('service_role',oid,'EXECUTE') AS service_execute
FROM pg_proc WHERE oid IN('public.get_my_routing_authorization_receipt(uuid)'::regprocedure,
 'fleet_private.require_ngo()'::regprocedure);
-- Receipt BEFORE: 29161768ed763f7a2ac9b34c0fe0abe7
-- Receipt AFTER:  71203f7bc55086683d60f3d0afabbe54
-- Writer guard unchanged: 15d5c2547cabd5df199e104451f5c2d6
-- Receipt remains STABLE, postgres owner, SECURITY DEFINER, pinned search_path/UTC,
-- EXECUTE postgres/authenticated only. No user impersonation or locking RPC calls.
ROLLBACK;
