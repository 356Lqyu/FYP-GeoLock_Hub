#!/bin/bash
# Build a disposable local database equivalent to the audited NEW KLSEL catalog.
# Usage: load_baseline.sh <psql-connection-args...> ; target DB must be empty.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BOOT="${BOOT:?set BOOT to the bootstrap folder}"
REPO_MIGRATION="${REPO_MIGRATION:?set REPO_MIGRATION to 20261123210000_donation_information_readers.sql}"
PSQL=(psql -X -q -v ON_ERROR_STOP=1 "$@")
TMP="$(mktemp -d)"
python3 - "$BOOT" "$TMP" <<'PY'
import re,sys,os
boot,tmp=sys.argv[1],sys.argv[2]
def rd(n): return open(os.path.join(boot,n),encoding='utf-8',newline='').read()
def wr(n,s): open(os.path.join(tmp,n),'w',encoding='utf-8',newline='').write(s)
s=rd('01_extensions_roles_and_schemas.sql')
# Roles are cluster-wide: tolerate a second local database in the same disposable cluster.
s=re.sub(r'(?m)^CREATE ROLE (\w+) (.*);$', lambda m: "DO $r$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='%s') THEN CREATE ROLE %s %s; END IF; END $r$;" % (m.group(1),m.group(1),m.group(2)), s)
s=re.sub(r'(?m)^CREATE EXTENSION IF NOT EXISTS (postgis|pgrouting|pg_cron)\b.*$', r'-- [harness] skipped extension \1', s)
wr('01.sql',s)
s=rd('02_tables_and_constraints.sql')
s=s.replace('geometry(MultiPolygon,4326)','text')
s,n=re.subn(r'geog geography\(Point,4326\) GENERATED ALWAYS AS \(.*?\) STORED','geog text',s)
assert n==1, 'geog column rewrite failed'
wr('02.sql',s)
for f,o in (('03a_functions_and_rpcs_part1.sql','03a.sql'),('03b_functions_and_rpcs_part2.sql','03b.sql'),('03c_functions_and_rpcs_part3.sql','03c.sql')):
    wr(o,'SET check_function_bodies = off;\n'+rd(f))
s=rd('04_views_triggers_indexes_and_rls.sql')
s,n=re.subn(r'(?m)^CREATE INDEX (idx_road_coverage_gist|idx_road_nodes_geog) .*$', r'-- [harness] skipped GiST index \1', s)
assert n==2
wr('04.sql','SET check_function_bodies = off;\n'+s)
s=rd('05_grants_and_permissions.sql')
# Supabase runs PostgreSQL 17; the local harness is 16, which has no MAINTAIN privilege.
s=s.replace('MAINTAIN, ','').replace(', MAINTAIN','')
wr('05.sql',s)
wr('06.sql',rd('06_initial_configuration_and_routing_policies.sql'))
PY
"${PSQL[@]}" -f "$HERE/00_supabase_stubs.sql"
for f in 01 02 03a 03b 03c 04 05 06; do "${PSQL[@]}" -f "$TMP/$f.sql"; done
"${PSQL[@]}" -f "$REPO_MIGRATION"
"${PSQL[@]}" -f "$HERE/90_spatial_and_eligibility_stubs.sql"
rm -rf "$TMP"
echo "BASELINE_LOADED"
