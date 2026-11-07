\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL statement_timeout='15s';
SET LOCAL lock_timeout='2s';
SELECT jsonb_build_object('section','native_login','database',current_database(),
 'current_user',current_user,'session_user',session_user,
 'read_only',current_setting('transaction_read_only'),
 'ssl',(SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),
 'tls',(SELECT version FROM pg_stat_ssl WHERE pid=pg_backend_pid()));
SELECT current_database()='postgres'
 AND current_user='geolock_resolution_operator_login' AND session_user='geolock_resolution_operator_login'
 AND current_setting('transaction_read_only')='on'
 AND coalesce((SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()),false)
 AND coalesce(current_setting('request.jwt.claim.sub',true),'')=''
 AND coalesce(current_setting('request.jwt.claims',true),'')=''
 AND coalesce(current_setting('request.jwt.claim.role',true),'')=''
 AND EXISTS(SELECT 1 FROM pg_roles WHERE rolname=session_user
 AND rolcanlogin AND NOT rolinherit AND NOT rolsuper AND NOT rolcreatedb
 AND NOT rolcreaterole AND NOT rolreplication AND NOT rolbypassrls AND rolconnlimit=1)
 AND EXISTS(SELECT 1 FROM pg_auth_members WHERE member=session_user::regrole
 AND roleid='geolock_route_resolver'::regrole AND NOT admin_option AND NOT inherit_option AND set_option)
 AND NOT EXISTS(SELECT 1 FROM pg_auth_members WHERE member=session_user::regrole
 AND roleid<>'geolock_route_resolver'::regrole)
 AS native_identity_ok \gset
\if :native_identity_ok
\else
ROLLBACK;
\quit 3
\endif
SET LOCAL ROLE geolock_route_resolver;
SELECT jsonb_build_object('section','native_resolver','current_user',current_user,'session_user',session_user,
 'read_only',current_setting('transaction_read_only'),
 'finalizer_execute',has_function_privilege(current_user,'public.finalize_route_resolution(uuid,bigint,uuid)','EXECUTE'),
 'provenance_execute',has_function_privilege(current_user,'public.register_route_test_provenance(uuid,text,uuid,uuid,uuid[],uuid)','EXECUTE'));
-- A read-only receipt lookup exercises operator_key(), proving active mapping
-- and trusted native principal without creating a case, receipt or business row.
SELECT public.get_my_route_resolution_receipt('00000000-0000-0000-0000-000000000000') AS native_receipt \gset
SELECT jsonb_build_object('section','native_mapping_probe','receipt',:'native_receipt'::jsonb);
SELECT current_user='geolock_route_resolver'
 AND has_function_privilege(current_user,'public.finalize_route_resolution(uuid,bigint,uuid)','EXECUTE')
 AND has_function_privilege(current_user,'public.register_route_test_provenance(uuid,text,uuid,uuid,uuid[],uuid)','EXECUTE')
 AND (:'native_receipt'::jsonb)->>'outcome'='NOT_FOUND'
 AND (:'native_receipt'::jsonb)->>'request_id'='00000000-0000-0000-0000-000000000000'
 AS native_mapping_ok \gset
\if :native_mapping_ok
\else
ROLLBACK;
\quit 3
\endif
SELECT jsonb_build_object('section','native_verification_complete','status','PASS','read_only',current_setting('transaction_read_only'));
ROLLBACK;
