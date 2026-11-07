"""Read-only application-source literal audit; never prints matched values."""
import ast
import json
from pathlib import Path
import re

patterns={
    'private_key':re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'supabase_secret':re.compile(r'sb_secret_[A-Za-z0-9_-]{12,}'),
    'credentialed_postgres_url':re.compile(r'postgres(?:ql)?://[^:/\s]+:[^@/\s]+@'),
    'jwt_literal':re.compile(r'eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}'),
}
files=list(Path('/app').rglob('*.py'));hits=[]
for path in files:
    for node in ast.walk(ast.parse(path.read_text(encoding='utf-8'))):
        if isinstance(node,ast.Constant) and isinstance(node.value,str):
            for category,pattern in patterns.items():
                if pattern.search(node.value):hits.append(dict(file=str(path.relative_to('/app')),line=node.lineno,category=category))
print(json.dumps(dict(scope='APPLICATION_SOURCE_LITERALS_ONLY_NO_VALUES_PRINTED',files_scanned=len(files),findings=hits)))
if hits:raise SystemExit(1)
