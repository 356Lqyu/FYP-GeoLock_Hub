-- SELECT ONLY. DEV rcgyuwiidqvrgbxswhqj only.
SELECT statement_timestamp() AS checked_at,
 (SELECT jsonb_build_object('version',extversion,'owner',pg_get_userbyid(extowner))
   FROM pg_extension WHERE extname='pg_cron') AS pg_cron,
 (SELECT jsonb_build_object('superuser',rolsuper,'bypassrls',rolbypassrls,'inherit',rolinherit)
   FROM pg_roles WHERE rolname='postgres') AS postgres_role,
 (SELECT jsonb_build_object('owner',pg_get_userbyid(relowner),'acl',relacl::text,
   'rls',relrowsecurity) FROM pg_class WHERE oid='cron.job'::regclass) AS cron_relation,
 jsonb_build_object('SELECT',has_table_privilege('postgres','cron.job','SELECT'),
   'UPDATE',has_table_privilege('postgres','cron.job','UPDATE'),
   'DELETE',has_table_privilege('postgres','cron.job','DELETE'),
   'TRUNCATE',has_table_privilege('postgres','cron.job','TRUNCATE'),
   'MAINTAIN',has_table_privilege('postgres','cron.job','MAINTAIN'),
   'advisory_execute',has_function_privilege('postgres',
      'pg_catalog.pg_try_advisory_xact_lock(integer,integer)','EXECUTE')) AS privileges,
 (SELECT jsonb_build_object('owner',pg_get_userbyid(p.proowner),'security_definer',p.prosecdef,
   'acl',p.proacl::text,'language',l.lanname,
   'postgres_execute',has_function_privilege('postgres',p.oid,'EXECUTE'))
   FROM pg_proc p JOIN pg_language l ON l.oid=p.prolang
   WHERE p.oid='cron.alter_job(bigint,text,text,text,text,boolean)'::regprocedure) AS supported_api;
