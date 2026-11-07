"""Local manifest builder only. No SQL executor, network client or credentials."""
from pathlib import Path
import hashlib
import json
import re

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
FILES=('001_authority_proposal.sql','002_publication_proposal.sql','003_pickup_enforcement_proposal.sql')


def build_manifest():
    result=dict(project_ref='rcgyuwiidqvrgbxswhqj',status='REVIEW_ONLY_NOT_AUTHORIZED_FOR_DEPLOYMENT',files=[],
                inherited_c1_sha256='f50af9705de117bdd12581f2515605c8e5c548e0fee7ae01d7ea33ecfbb0cb05')
    c1=ROOT/'docs/stage8/phase-c1/proposed_migration_v2.sql'
    assert hashlib.sha256(c1.read_bytes()).hexdigest()==result['inherited_c1_sha256']
    for name in FILES:
        path=HERE/name; sql=path.read_text()
        assert len(re.findall(r'^BEGIN;',sql,re.M))==1 and sql.rstrip().endswith('COMMIT;')
        assert not re.search(r'\b(CONCURRENTLY|VACUUM|ALTER SYSTEM|CREATE DATABASE)\b',sql)
        result['files'].append(dict(path=str(path.relative_to(ROOT)),sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
            functions=re.findall(r'CREATE (?:OR REPLACE )?FUNCTION\s+([\w.]+)\(',sql),
            tables=re.findall(r'CREATE TABLE\s+([\w.]+)\(',sql),
            indexes=re.findall(r'CREATE (?:UNIQUE )?INDEX\s+(\w+)',sql)))
    return result


if __name__=='__main__':
    (HERE/'package-manifest.json').write_text(json.dumps(build_manifest(),indent=2)+'\n')
    print('Review manifest generated; no database connection.')
