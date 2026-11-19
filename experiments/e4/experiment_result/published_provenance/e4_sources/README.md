# Frozen E4 source snapshot

Exact bytes (including CRLF line endings) of source files recorded in `experiments/e4/experiment_result/run_manifest.json` (E4 run `725519de6de948e6a60fb673f563dbe8`, the results currently published in `experiments/e4`) that the 20 Nov 2026 routing restructure moved or changed:

- the 44 `backend/routing` modules and `backend/__init__.py`, at the paths the run recorded;
- `experiments/e4/test_harness/e4_shared.py`, whose imports were updated to the new routing paths.

Folder paths mirror the repository, so every file here has the same relative name as its manifest key. Nothing here is imported or executed. `.gitattributes` turns off line-ending conversion so the bytes stay identical on every checkout.

Check every file against the manifest (run from the repository root):

```
python -c "import json,hashlib,pathlib as p;r=p.Path('experiments/e4/experiment_result');s=r/'published_provenance/e4_sources';m=json.loads((r/'run_manifest.json').read_bytes())['source_sha256'];f=[x for x in s.rglob('*.py')];bad=[str(x) for x in f if hashlib.sha256(x.read_bytes()).hexdigest()!=m[x.relative_to(s).as_posix()]];print(len(f)-len(bad),'of',len(f),'match',bad)"
```

Not covered here (pre-existing, outside this restructure):

- `published_provenance/verify.py` checks the earlier paper run `ac1b77db...`, whose manifest was replaced by later reruns on 16-17 Nov 2026, so it fails at its first check.
- `run_e4.py` and `test_harness/test_e4_publication.py` already differed from this manifest before the restructure, and their recorded bytes are not in git history.
