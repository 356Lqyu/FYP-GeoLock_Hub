# Verify the original Phase A routing layout

[phase-a-routing.zip](phase-a-routing.zip) contains all 17 files named by the original [Phase A SHA-256 receipt](../stage8/phase-b-phase-a-preservation.json), plus a byte-for-byte copy of the receipt. The archive retains the original repository-relative paths. Its SHA-256 is `d76c8045afa654c7dff721673293caa924ea28e6a654fd6663a2164c3ff88f62`.

From the repository root, verify the ZIP hash, extract it to a fresh directory, and run the following check. Python uses only files inside the extraction.

```powershell
$archive = 'docs/research-preservation/phase-a-routing.zip'
Get-FileHash -LiteralPath $archive -Algorithm SHA256
# Compare the digest above before continuing.
$snapshot = Join-Path $env:TEMP ("phase-a-routing-" + [guid]::NewGuid())
Expand-Archive -LiteralPath $archive -DestinationPath $snapshot
Push-Location $snapshot
try {
@'
from pathlib import Path
import hashlib
import json

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

receipt = Path('docs/stage8/phase-b-phase-a-preservation.json')
assert sha(receipt) == '85b632045b4b31e25fc198f164ef58d6a227c466469470a7036cbf077d887173'
expected = json.loads(receipt.read_bytes())
assert len(expected) == 17
for name, digest in expected.items():
    assert sha(Path(name)) == digest, name
print('Verified all 17 Phase A files at their original paths.')
'@ | python -I -B -
    if ($LASTEXITCODE -ne 0) { throw 'Phase A verification failed' }
} finally {
    Pop-Location
}
```

The active scenario fixtures live under `backend/routing/tests/fixtures/`. Use the extracted archive to verify the historical receipt as an entire original-layout set.
