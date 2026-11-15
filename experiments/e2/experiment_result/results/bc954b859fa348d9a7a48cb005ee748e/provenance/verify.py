"""Verify the published E2 run and its source snapshot offline."""
import hashlib
import json
import re
from pathlib import Path

PROVENANCE = Path(__file__).resolve().parent
RUN = PROVENANCE.parent
ROOT = RUN.parents[4]
RUN_ID = "bc954b859fa348d9a7a48cb005ee748e"


def read_json(path):
    return json.loads(path.read_bytes())


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def verify_hashes(folder, hashes):
    for name, expected in hashes.items():
        path = folder / name.replace("\\", "/")
        require(path.is_file(), f"Missing file: {path}")
        require(hashlib.sha256(path.read_bytes()).hexdigest() == expected,
                f"SHA-256 mismatch: {path}")


def main():
    manifest = read_json(RUN / "run_manifest.json")
    require(RUN.name == manifest["experiment_run_id"] == RUN_ID
            and manifest["status"] == "completed" and manifest["mode"] == "hosted",
            "Unexpected paper run identity or status.")
    sources = manifest["source_sha256"]
    inputs = manifest["benchmark_input_sha256"]
    results = read_json(PROVENANCE / "original-result-sha256.json")
    require((len(sources), len(inputs), len(results)) == (19, 8, 31),
            "Unexpected source, input, or result inventory size.")
    verify_hashes(PROVENANCE / "sources", sources)
    verify_hashes(RUN, results)
    dataset = ROOT / "benchmark dataset" / "dataset"
    verify_hashes(dataset, inputs)
    generation = read_json(dataset / "generation_manifest.json")["generated_csv_sha256"]
    require(all(generation.get(Path(name).stem) == digest for name, digest in inputs.items()),
            "Frozen input hashes disagree with the generation manifest.")
    method_manifests = sorted((RUN / "methods").glob("*/run_manifest.json"))
    require(len(method_manifests) == 3
            and {p.parent.name for p in method_manifests} == set(manifest["selected_methods"]),
            "The paper run must contain all three method manifests.")
    for path in method_manifests:
        method = read_json(path)
        require(method["experiment_run_id"] == RUN_ID
                and method["target_identity"] == manifest["target_identity"]
                and method["source_sha256"] == sources and method["input_sha256"] == inputs,
                f"Method provenance disagrees with the root manifest: {path}")
    comparison = RUN / "comparison"
    figures = re.findall(r"!\[[^\]]*\]\(([^)]+)\)",
                         (comparison / "summary.md").read_text(encoding="utf-8"))
    require(len(figures) == 4 and all((comparison / name).is_file() for name in figures),
            "The comparison summary must link to four existing figures.")
    verify_hashes(comparison, read_json(PROVENANCE / "paper-export-sha256.json"))
    print("Verified 19 paper-run sources, 8 frozen inputs, 31 original results,")
    print("3 method manifests, 4 summary figure links, and 2 derivative paper exports.")


if __name__ == "__main__":
    main()
