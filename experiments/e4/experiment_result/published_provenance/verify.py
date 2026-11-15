"""Verify the saved E4 paper run without database access or routing execution."""

import hashlib
import json
from pathlib import Path

PROVENANCE = Path(__file__).resolve().parent
E4 = PROVENANCE.parents[1]
ROOT = E4.parents[1]
RUN_ID = "ac1b77db93634b7d8da371ee59105679"
SNAPSHOT = "backend/routing/hosted/frozen_benchmark.py"


def verify(path, expected):
    with path.open("rb") as stream:
        actual = hashlib.file_digest(stream, "sha256").hexdigest()
    if actual != expected:
        raise ValueError(f"SHA-256 mismatch: {path}")


def main():
    manifest_path = E4 / "experiment_result" / "run_manifest.json"
    verify(manifest_path, (PROVENANCE / "manifest.sha256").read_text().strip())
    manifest = json.loads(manifest_path.read_bytes())
    if manifest["run_id"] != RUN_ID or manifest["status"] != "completed":
        raise ValueError("Expected the completed E4 paper run")

    for name, expected in manifest["source_sha256"].items():
        verify((PROVENANCE if name == SNAPSHOT else ROOT) / name, expected)

    dataset = ROOT / "benchmark dataset" / "dataset"
    for name, expected in manifest["input_sha256"].items():
        verify(dataset / name, expected)

    for name, expected in manifest["artifact_sha256"].items():
        verify(E4 / name, expected)

    print(f"Verified E4 {RUN_ID}: 84 source files, 8 frozen inputs, "
          "22 published artifacts and the run manifest.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        raise SystemExit(f"E4 paper provenance verification failed: {error}") from None
