"""Validate SQL package offline. This file has no database/network client."""
from __future__ import annotations
import copy, hashlib, json, re
from pathlib import Path
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[3]
CLIENTS={"anon","authenticated"}
def read_json(name): return json.loads((HERE/name).read_text(encoding="utf-8"))
before=read_json("captured/expected-before.json")
state10=read_json("captured/expected-after-postgres.json")
final=read_json("captured/expected-after-both.json")
def canon(xs): return sorted(xs,key=lambda a:(a["grantor"],a["grantee"],a["privilege"]))
def split_sql(src):
    """Split outside SQL strings/comments/dollar bodies, preserving DO bodies."""
    out=[]; start=0; i=0
    while i<len(src):
        if src.startswith("--",i):
            end=src.find("\n",i)
            i=len(src) if end<0 else end+1
        elif src.startswith("/*",i):
            end=src.find("*/",i+2)
            assert end>=0
            i=end+2
        elif src[i] in ("'",'"'):
            quote=src[i]; i+=1
            while i<len(src):
                if src[i]==quote:
                    i+=1
                    if i<len(src) and src[i]==quote: i+=1
                    else: break
                else: i+=1
        elif src[i]=="$" and (m:=re.match(r"\$[A-Za-z_0-9]*\$",src[i:])):
            tag=m.group(); end=src.find(tag,i+len(tag))
            assert end>=0
            i=end+len(tag)
        elif src[i]==";":
            out.append(src[start:i+1]); start=i+1; i+=1
        else: i+=1
    assert not re.sub(r"--[^\n]*","",src[start:]).strip(), "Unterminated SQL"
    return out
def without_comments(src): return re.sub(r"--[^\n]*","",src).strip()
def effective(state):
    for r in state["relations"]:
        for x in r["effective"]:
            x["allowed"]=any(a["privilege"]==x["privilege"] and a["grantee"] in {x["role"],"PUBLIC"} for a in r["acl_entries"]) or x["role"]==r["owner"]
def replay(state,filename,role):
    state=copy.deepcopy(state)
    src=(HERE/filename).read_text(encoding="utf-8")
    statements=[without_comments(s) for s in split_sql(src)]
    assert statements[0]=="BEGIN;" and statements[-1]=="COMMIT;"
    assert sum(s.startswith("DO ") for s in statements)==3
    assert "END;\n$identity_guard$;" in src and src.count("END;\n$acl_guard$;")==2
    assert "CASCADE;" not in src and "GRANT ALL" not in src and "REVOKE ALL" not in src
    assert f"current_user <> '{role}'" in src
    assert "geolock.reviewed_project_ref" in src and "geolock.acl_approval" in src
    permission_count=0
    for st in statements:
        if st in {"BEGIN;","COMMIT;"} or st.startswith("SET LOCAL "): continue
        if st.startswith("DO "):
            assert "\nEXECUTE " not in st and "CREATE FUNCTION" not in st
            continue
        permission_count+=1
        m=re.fullmatch(r'(REVOKE|GRANT) ([A-Z, ]+) ON (TABLE|SEQUENCE) public\."(\w+)" (FROM|TO) (anon|authenticated)(?: RESTRICT)?;',st)
        if m:
            action,ps,typ,name,_,client=m.groups()
            r=next(x for x in state["relations"] if x["name"]==name)
            assert (r["kind"]=="S")==(typ=="SEQUENCE") and role==r["owner"]=="postgres"
            key="acl_entries"; grantor="postgres"; entries=r[key]
        else:
            m=re.fullmatch(r'ALTER DEFAULT PRIVILEGES FOR ROLE (postgres|supabase_admin) IN SCHEMA public (REVOKE|GRANT) ([A-Z, ]+) ON (TABLES|SEQUENCES) (FROM|TO) (anon|authenticated)(?: RESTRICT)?;',st)
            assert m, "Unexpected SQL statement: "+st[:120]
            creator,action,ps,typ,_,client=m.groups()
            assert role==creator
            r=next(x for x in state["default_acls"] if x["creator"]==creator and x["schema"]=="public" and x["type"]==("r" if typ=="TABLES" else "S"))
            key="entries"; grantor=creator; entries=r[key]
        privileges=ps.split(", ")
        assert len(privileges)==len(set(privileges))
        for privilege in privileges:
            entry={"grantor":grantor,"grantee":client,"privilege":privilege,"grantable":False}
            if action=="REVOKE":
                assert entry in entries, (filename,name if 'name' in locals() else typ,entry)
                entries.remove(entry)
            else:
                assert entry not in entries
                entries.append(entry)
        r[key]=canon(entries)
    effective(state)
    return state,permission_count

a,n10=replay(before,"10_forward_postgres.sql","postgres")
assert a==state10,"Forward postgres model differs from exact proposed state"
b,n20=replay(a,"20_forward_supabase_admin_defaults.sql","supabase_admin")
assert b==final,"Forward supabase_admin model differs from exact proposed state"
c,n90=replay(b,"90_rollback_supabase_admin_defaults.sql","supabase_admin")
assert c==state10,"Admin default rollback does not exactly restore intermediate state"
d,n91=replay(c,"91_rollback_postgres.sql","postgres")
assert d==before,"Rollback does not exactly restore captured semantic ACLs"
assert all(not x["allowed"] for r in final["relations"] for x in r["effective"] if x["role"] in CLIENTS)
assert all(x["allowed"] for r in final["relations"] for x in r["effective"] if x["role"]=="service_role")
for key in set(before)-{"relations","default_acls"}:
    assert before[key]==final[key], "Protected catalog section changed: "+key
assert [x for x in before["default_acls"] if x["type"]=="f"]==[x for x in final["default_acls"] if x["type"]=="f"]
# SELECT-only files must contain no top-level mutations. WITH statements contain only catalog SELECTs.
read_only=[]
for p in sorted(HERE.glob("*.sql")):
    if p.name.startswith(("10_","20_","90_","91_")): continue
    for st in split_sql(p.read_text(encoding="utf-8")):
        plain=without_comments(st)
        assert re.match(r"^(WITH|SELECT)\s",plain), (p.name,plain[:80])
    read_only.append(p.name)
files=[]
folders=[ROOT/"frontend/geolock_hub_app/lib",ROOT/"supabase/tests",ROOT/"experiments",ROOT/"baseline implementation/source code"]
for folder in folders:
    files += [p for p in folder.rglob("*") if p.is_file() and p.suffix in {".dart",".py",".sql"}]
files += [ROOT/x for x in ["geolock-v3-permissions-dev.sql","geolock-v3-public-schema-with-grants.sql","supabase/road_network/import_operational_road_network.py","docs/audits/2026-10-21-stage1-4-seven-day-gap-analysis.md"]]
source_evidence={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(set(files))}
(HERE/"captured/source-files-sha256.json").write_text(json.dumps(source_evidence,indent=2)+"\n",encoding="utf-8")
result={"status":"PASS","database_changes_executed":False,"validation":"Offline statement-scope inspection and explicit-grant replay, not PostgreSQL DDL execution or full SQL/PLpgSQL parsing.",
"checks":["forward states exactly match expected manifests","rollback restores exact captured privileges/grantors/grant options","no blanket GRANT ALL, REVOKE ALL, CASCADE or unplanned permission statements","all functions, function defaults, policies, triggers, owners and role graph preserved","client effective table/sequence grants modeled false; service_role preserved","read-only SQL files contain only top-level SELECT/WITH statements"],
"permission_statement_counts":{"postgres_forward":n10,"supabase_admin_forward":n20,"supabase_admin_rollback":n90,"postgres_rollback":n91},"read_only_files":read_only,"source_files_hashed":len(source_evidence)}
(HERE/"captured/offline-validation.json").write_text(json.dumps(result,indent=2)+"\n",encoding="utf-8")
print(json.dumps(result,indent=2))

