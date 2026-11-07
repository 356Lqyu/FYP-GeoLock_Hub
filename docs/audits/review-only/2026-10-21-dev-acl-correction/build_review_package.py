"""Offline builder: reads captured catalogs and local source; never connects."""
from __future__ import annotations
import copy, hashlib, json, re
from pathlib import Path
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[3]
DEV="rcgyuwiidqvrgbxswhqj"
CLIENTS={"anon","authenticated"}
CAPTURE=json.loads((HERE/"captured/deployed-security-snapshot.json").read_text())
STORAGE=json.loads((HERE/"captured/storage-trigger-functions.json").read_text())
EVENTS=json.loads((HERE/"captured/event-triggers.json").read_text())
HEADER="-- REVIEW ONLY. NOT APPLIED. Isolated DEV rcgyuwiidqvrgbxswhqj ONLY.\n"
TABLE_PRIVS=["SELECT","INSERT","UPDATE","DELETE","TRUNCATE","REFERENCES","TRIGGER","MAINTAIN"]
SEQ_PRIVS=["USAGE","SELECT","UPDATE"]
def save(name,body):
    p=HERE/name
    p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(body.rstrip()+"\n",encoding="utf-8",newline="\n")
def md5(s): return hashlib.md5(s.encode("utf-8")).hexdigest()
def canon(entries): return sorted(entries or [],key=lambda a:(a["grantor"],a["grantee"],a["privilege"]))
def normalize(s):
    s=copy.deepcopy(s)
    s.pop("connection",None)
    s.pop("catalog_dependencies",None)
    for x in s["relations"]:
        x.pop("acl",None); x.pop("effective_acl",None)
        x["acl_entries"]=canon(x["acl_entries"])
    for x in s["default_acls"]:
        x.pop("acl",None); x["entries"]=canon(x["entries"])
    for x in s["functions"]:
        x.pop("acl",None); x["definition_md5"]=md5(x.pop("definition"))
        x["acl_entries"]=canon(x["acl_entries"])
    s["storage_trigger_functions"]=[{**{k:v for k,v in x.items() if k!="definition"},"definition_md5":md5(x["definition"])} for x in STORAGE]
    s["event_triggers"]=[{**{k:v for k,v in x.items() if k!="definition"},"definition_md5":md5(x["definition"])} for x in EVENTS]
    return s
before=normalize(CAPTURE)
state10=copy.deepcopy(before)
for x in state10["relations"]:
    x["acl_entries"]=[a for a in x["acl_entries"] if a["grantee"] not in CLIENTS]
    for a in x["effective"]:
        if a["role"] in CLIENTS: a["allowed"]=False
for x in state10["default_acls"]:
    if x["creator"]=="postgres" and x["schema"]=="public" and x["type"] in {"r","S"}:
        x["entries"]=[a for a in x["entries"] if a["grantee"] not in CLIENTS]
final=copy.deepcopy(state10)
for x in final["default_acls"]:
    if x["creator"]=="supabase_admin" and x["schema"]=="public" and x["type"] in {"r","S"}:
        x["entries"]=[a for a in x["entries"] if a["grantee"] not in CLIENTS]
q=(HERE/"00_capture_snapshot.sql").read_text()
q=q[q.index("WITH\nrel AS"):].rstrip().removesuffix(";")
manifest_query="""WITH captured AS (
%s
)
SELECT (snapshot - 'connection' - 'catalog_dependencies' - 'relations' - 'functions' - 'default_acls')
|| jsonb_build_object(
'relations',(SELECT jsonb_agg(
 (r - 'acl' - 'effective_acl' - 'acl_entries') || jsonb_build_object('acl_entries',
 (SELECT coalesce(jsonb_agg(e ORDER BY e->>'grantor',e->>'grantee',e->>'privilege'),'[]'::jsonb)
 FROM jsonb_array_elements(coalesce(r->'acl_entries','[]'::jsonb)) e))
 ORDER BY ord) FROM jsonb_array_elements(snapshot->'relations') WITH ORDINALITY t(r,ord)),
'functions',(SELECT jsonb_agg(
 (f - 'acl' - 'definition' - 'acl_entries') || jsonb_build_object('definition_md5',md5(f->>'definition'),'acl_entries',
 (SELECT coalesce(jsonb_agg(e ORDER BY e->>'grantor',e->>'grantee',e->>'privilege'),'[]'::jsonb)
 FROM jsonb_array_elements(coalesce(f->'acl_entries','[]'::jsonb)) e))
 ORDER BY ord) FROM jsonb_array_elements(snapshot->'functions') WITH ORDINALITY t(f,ord)),
'default_acls',(SELECT jsonb_agg(
 (d - 'acl' - 'entries') || jsonb_build_object('entries',
 (SELECT coalesce(jsonb_agg(e ORDER BY e->>'grantor',e->>'grantee',e->>'privilege'),'[]'::jsonb)
 FROM jsonb_array_elements(coalesce(d->'entries','[]'::jsonb)) e))
 ORDER BY ord) FROM jsonb_array_elements(snapshot->'default_acls') WITH ORDINALITY t(d,ord)),
'storage_trigger_functions',(SELECT jsonb_agg(jsonb_build_object(
 'signature',p.oid::regprocedure::text,'owner',p.proowner::regrole::text,
 'security_definer',p.prosecdef,'config',p.proconfig,'definition_md5',md5(pg_get_functiondef(p.oid)))
 ORDER BY p.oid::regprocedure::text)
 FROM pg_proc p WHERE p.oid IN (SELECT t.tgfoid FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
 JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='storage' AND NOT t.tgisinternal)),
'event_triggers',(SELECT jsonb_agg(jsonb_build_object('name',e.evtname,'event',e.evtevent,
 'owner',e.evtowner::regrole::text,'enabled',e.evtenabled,'tags',e.evttags,
 'function',e.evtfoid::regprocedure::text,'function_owner',p.proowner::regrole::text,
 'security_definer',p.prosecdef,'config',p.proconfig,'definition_md5',md5(pg_get_functiondef(p.oid)))
 ORDER BY e.evtname) FROM pg_event_trigger e JOIN pg_proc p ON p.oid=e.evtfoid)
) AS manifest FROM captured""" % q
save("00c_capture_comparable_manifest.sql",HEADER+manifest_query+";")
for label,state in [("before",before),("after-postgres",state10),("after-both",final)]:
    save("captured/expected-"+label+".json",json.dumps(state,indent=2))
def literal(state): return "$expected$"+json.dumps(state,separators=(",",":"),ensure_ascii=False)+"$expected$::jsonb"
def comparison(state):
    return """WITH actual AS (
%s
), expected AS (SELECT %s AS manifest),
a AS (SELECT key,value FROM actual CROSS JOIN LATERAL jsonb_each(actual.manifest)),
e AS (SELECT key,value FROM expected CROSS JOIN LATERAL jsonb_each(expected.manifest))
SELECT coalesce(e.key,a.key) AS section,
       e.value IS NOT DISTINCT FROM a.value AS matches_expected
FROM e FULL JOIN a USING(key) ORDER BY section;""" % (manifest_query,literal(state))
def assertion(state,label):
    return """DO $acl_guard$
DECLARE v_actual jsonb; v_expected jsonb := %s;
BEGIN
  SELECT manifest INTO v_actual FROM (
%s
  ) captured_manifest;
  IF v_actual IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'ACL review snapshot mismatch (%s); stop and recapture/review. No CASCADE or automatic repair.';
  END IF;
END;
$acl_guard$;
""" % (literal(state),manifest_query,label)
def identity(role,action):
    return """DO $identity_guard$
BEGIN
  IF current_database() <> 'postgres' OR current_user <> '%s' THEN
    RAISE EXCEPTION 'Expected database postgres and current_user %s';
  END IF;
  IF current_setting('geolock.reviewed_project_ref',true) IS DISTINCT FROM '%s'
     OR current_setting('geolock.acl_approval',true) IS DISTINCT FROM '%s' THEN
    RAISE EXCEPTION 'Missing explicit DEV target attestation and separately approved action';
  END IF;
  IF nullif(current_setting('supabase.project_ref',true),'') IS NOT NULL
     AND current_setting('supabase.project_ref',true) <> '%s' THEN
    RAISE EXCEPTION 'Database project reference contradicts DEV target';
  END IF;
  IF current_setting('transaction_read_only') = 'on' THEN
    RAISE EXCEPTION 'Read-only session: do not disable MCP protections to run this file';
  END IF;
END;
$identity_guard$;
""" % (role,role,DEV,action,DEV)
def transaction(role,action,pre,commands,post,label):
    return HEADER+"""-- Requires separate explicit approval. Verify the external DEV endpoint first.
-- Custom GUC attestation is NOT an independent project-identity check.
BEGIN;
SET LOCAL search_path = pg_catalog, public, extensions, pg_temp;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';
"""+identity(role,action)+assertion(pre,label+" pre")+"\n".join(commands)+"\n"+assertion(post,label+" post")+"COMMIT;\n"
changes=[]; restores=[]
for r in sorted(CAPTURE["relations"],key=lambda x:x["name"]):
    entries=[e for e in r["acl_entries"] if e["grantee"] in CLIENTS]
    if not entries: continue
    typ="SEQUENCE" if r["kind"]=="S" else "TABLE"
    groups={}
    for e in entries:
        assert e["grantor"]=="postgres" and not e["grantable"]
        groups.setdefault((e["grantee"],e["grantor"],e["grantable"]),[]).append(e["privilege"])
    for (grantee,grantor,grantable),privs in sorted(groups.items()):
        privs=[p for p in (SEQ_PRIVS if typ=="SEQUENCE" else TABLE_PRIVS) if p in privs]
        privileges=", ".join(privs)
        changes.append(f'REVOKE {privileges} ON {typ} public."{r["name"]}" FROM {grantee} RESTRICT;')
        restores.append(f'GRANT {privileges} ON {typ} public."{r["name"]}" TO {grantee}; -- captured grantor: {grantor}; no grant option')
default_revoke={"postgres":[],"supabase_admin":[]}; default_restore={"postgres":[],"supabase_admin":[]}
for d in CAPTURE["default_acls"]:
    if d["schema"]!="public" or d["type"] not in {"r","S"}: continue
    creator=d["creator"]; obj="TABLES" if d["type"]=="r" else "SEQUENCES"
    for client in sorted(CLIENTS):
        entries=[e for e in d["entries"] if e["grantee"]==client]
        assert entries and all(e["grantor"]==creator and not e["grantable"] for e in entries)
        privs=[p for p in (TABLE_PRIVS if obj=="TABLES" else SEQ_PRIVS) if p in {e["privilege"] for e in entries}]
        prefix=f'ALTER DEFAULT PRIVILEGES FOR ROLE {creator} IN SCHEMA public '
        default_revoke[creator].append(prefix+f'REVOKE {", ".join(privs)} ON {obj} FROM {client} RESTRICT;')
        default_restore[creator].append(prefix+f'GRANT {", ".join(privs)} ON {obj} TO {client};')
save("10_forward_postgres.sql",transaction("postgres","APPLY_DEV_ACL_PACKAGE",before,changes+default_revoke["postgres"],state10,"postgres forward"))
save("20_forward_supabase_admin_defaults.sql",transaction("supabase_admin","APPLY_DEV_ACL_PACKAGE",state10,default_revoke["supabase_admin"],final,"supabase_admin defaults forward"))
save("90_rollback_supabase_admin_defaults.sql",transaction("supabase_admin","RESTORE_CAPTURED_DEV_ACLS",final,default_restore["supabase_admin"],state10,"supabase_admin defaults rollback"))
save("91_rollback_postgres.sql",transaction("postgres","RESTORE_CAPTURED_DEV_ACLS",state10,restores+default_restore["postgres"],before,"postgres rollback"))
save("01_preflight_verify_snapshot.sql",HEADER+"-- SELECT only. Every matches_expected value must be true.\n"+comparison(before)+"""
SELECT current_user, session_user,
 pg_has_role('postgres','supabase_admin','MEMBER') AS postgres_member_of_supabase_admin,
 pg_has_role('postgres','supabase_admin','SET') AS postgres_can_set_supabase_admin;
""")
save("11_verify_after_postgres.sql",HEADER+"-- SELECT only. Expected intermediate state; admin defaults are still broad.\n"+comparison(state10))
effective_checks="""
-- Every client allowed value must be FALSE; service_role values must remain TRUE.
SELECT n.nspname,c.relname,r.rolname,v.priv,
 CASE WHEN c.relkind='S' THEN has_sequence_privilege(r.oid,c.oid,v.priv)
 ELSE has_table_privilege(r.oid,c.oid,v.priv) END AS allowed
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
CROSS JOIN pg_roles r
CROSS JOIN LATERAL unnest(CASE WHEN c.relkind='S' THEN ARRAY['USAGE','SELECT','UPDATE']
 ELSE ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER','MAINTAIN'] END) v(priv)
WHERE n.nspname='public' AND c.relkind IN ('r','p','S')
 AND r.rolname IN ('anon','authenticated','service_role')
ORDER BY c.relname,r.rolname,v.priv;

-- Must return zero rows: table/sequence defaults through clients, PUBLIC or inherited roles.
SELECT d.defaclrole::regrole::text AS creator,coalesce(n.nspname,'<global>') AS schema,
 d.defaclobjtype,client.rolname AS client,a.*
FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid=d.defaclnamespace
CROSS JOIN LATERAL aclexplode(d.defaclacl) a CROSS JOIN pg_roles client
WHERE d.defaclrole IN ('postgres'::regrole,'supabase_admin'::regrole)
 AND (d.defaclnamespace=0 OR n.nspname='public') AND d.defaclobjtype IN ('r','S')
 AND client.rolname IN ('anon','authenticated')
 AND CASE WHEN a.grantee=0 THEN true ELSE pg_has_role(client.oid,a.grantee,'USAGE') END;

-- Must return zero rows: column grants that could survive table-level revokes.
SELECT c.relname,att.attname,att.attacl
FROM pg_attribute att JOIN pg_class c ON c.oid=att.attrelid
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND att.attnum>0 AND NOT att.attisdropped AND att.attacl IS NOT NULL;

-- Built-in table/sequence defaults give no PUBLIC access. Schema defaults are additive.
SELECT r.rolname,acldefault('r',r.oid) AS builtin_table_defaults,
 acldefault('s',r.oid) AS builtin_sequence_defaults
FROM pg_roles r WHERE r.rolname IN ('postgres','supabase_admin');
"""
save("30_postchange_verify.sql",HEADER+"-- SELECT only. Every matches_expected value must be true.\n"+comparison(final)+effective_checks)
save("92_verify_restored_snapshot.sql",HEADER+"-- SELECT only. After separately approved rollback, every row must match.\n"+comparison(before))
app_sources={}
for p in sorted((ROOT/"frontend/geolock_hub_app/lib").rglob("*.dart")):
    src=p.read_text(encoding="utf-8")
    for m in re.finditer(r"\.rpc\(\s*['\"]([^'\"]+)['\"]",src):
        app_sources.setdefault(m[1],[]).append(f"{p.relative_to(ROOT).as_posix()}:{src.count(chr(10),0,m.start())+1}")
app_fns=[f for f in CAPTURE["functions"] if f["name"] in app_sources]
assert len(app_sources)==len(app_fns)==36, (ROOT,len(app_sources),len(app_fns))
assert all(f["owner"]=="postgres" and f["security_definer"] for f in app_fns)
assert all(any(x.startswith("search_path=") for x in f["config"] or []) for f in app_fns)
assert all(next(x["allowed"] for x in f["execute"] if x["role"]=="authenticated") for f in app_fns)
assert not CAPTURE["column_acls"]
assert len(CAPTURE["relations"])==37 and sum(r["kind"]!="S" for r in CAPTURE["relations"])==36
assert len([r for r in CAPTURE["relations"] if r["kind"]!="S" and any(a["grantee"] in CLIENTS for a in r["acl_entries"])])==29
assert all(not any(a["grantee"]=="PUBLIC" for a in r["acl_entries"]) for r in CAPTURE["relations"])
assert all(not any(x["client"]==c and x["role"]!=c for x in CAPTURE["effective_role_paths"]) for c in CLIENTS)
rpc_report="# Exact deployed Flutter RPC inventory\n\nReview only; captured "+CAPTURE["connection"]["captured_at_utc"]+".\n\nAll 36 have one deployed signature, owner ~postgres~ (BYPASSRLS), SECURITY DEFINER, authenticated/service_role EXECUTE. No PUBLIC EXECUTE entry was captured on these functions. Definitions and raw grants are in the JSON snapshot. An explicit search path is configuration evidence, not a full security proof.\n\n| Signature | Configuration | anon EXECUTE | authenticated EXECUTE | service_role EXECUTE |\n|---|---|---|---|---|\n"
for f in app_fns:
    grants={x["role"]:x["allowed"] for x in f["execute"]}
    rpc_report+=f'| ~{f["signature"]}~ | ~{", ".join(f["config"] or [])}~ | {str(grants["anon"]).lower()} | {str(grants["authenticated"]).lower()} | {str(grants["service_role"]).lower()} |\n'
rpc_report+="\n## Flutter source call sites\n\n"
for name,sites in sorted(app_sources.items()):
    rpc_report+=f'- ~{name}~: '+", ".join("~"+p+"~" for p in sites)+"\n"
save("RPC_INVENTORY.md",rpc_report.replace("~",chr(96)))
anonymous="# Anonymous EXECUTE: separate authorization review\n\nNo function privileges or function defaults are changed by this package. EXECUTE does not prove that body-level authorization permits an operation.\n\n## Flutter-called RPCs with explicit anon EXECUTE (30)\n\n"
for f in app_fns:
    if next(x["allowed"] for x in f["execute"] if x["role"]=="anon"):
        anonymous+=f'- ~{f["signature"]}~\n'
anonymous+="\n## Other application functions/helpers/trigger functions with anon EXECUTE\n\nTrigger-returning functions are catalog grants, not ordinary callable RPC endpoints.\n\n"
for f in CAPTURE["functions"]:
    if f["name"] not in app_sources and next(x["allowed"] for x in f["execute"] if x["role"]=="anon"):
        anonymous+=f'- ~{f["signature"]}~ (returns ~{f["result"]}~; SECURITY DEFINER={str(f["security_definer"]).lower()})\n'
anonymous+="\nFuture function defaults remain unchanged, including PostgreSQL's implicit global PUBLIC EXECUTE. Review separately; a schema-level default revoke cannot subtract a global default grant.\n"
save("ANONYMOUS_RPC_REVIEW.md",anonymous.replace("~",chr(96)))
save("captured/flutter-rpc-call-sites.json",json.dumps(app_sources,indent=2))
save("captured/proposed-permission-statements.json",json.dumps({
 "10_forward_postgres":changes+default_revoke["postgres"],
 "20_forward_supabase_admin_defaults":default_revoke["supabase_admin"],
 "90_rollback_supabase_admin_defaults":default_restore["supabase_admin"],
 "91_rollback_postgres":restores+default_restore["postgres"]},indent=2))
print(json.dumps({"tables":36,"tables_changed":29,"sequences_changed":1,"flutter_rpcs":36,
 "anon_flutter_rpcs":30,"permission_statements_postgres":len(changes)+len(default_revoke["postgres"]),
 "permission_statements_supabase_admin":len(default_revoke["supabase_admin"]),
 "capture_utc":CAPTURE["connection"]["captured_at_utc"]},indent=2))
