-- MANUAL ONLY: DEV rcgyuwiidqvrgbxswhqj, SQL Editor role postgres.
-- No passwords here. Set them with interactive psql \password afterwards.
-- Existing login names cause rollback rather than changing existing accounts.
BEGIN;
CREATE ROLE geolock_graph_login LOGIN NOINHERIT NOSUPERUSER NOCREATEDB
 NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 5 PASSWORD NULL;
CREATE ROLE geolock_planner_login LOGIN NOINHERIT NOSUPERUSER NOCREATEDB
 NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 5 PASSWORD NULL;
CREATE ROLE geolock_validator_login LOGIN NOINHERIT NOSUPERUSER NOCREATEDB
 NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 5 PASSWORD NULL;
GRANT CONNECT ON DATABASE postgres TO
 geolock_graph_login,geolock_planner_login,geolock_validator_login;
GRANT geolock_graph_worker TO geolock_graph_login;
GRANT geolock_planner TO geolock_planner_login;
GRANT geolock_validator TO geolock_validator_login;
COMMIT;
