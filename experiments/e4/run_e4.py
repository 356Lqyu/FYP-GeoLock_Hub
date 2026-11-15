"""Run E4 in private staging and publish only a complete validated run."""
import argparse
from contextlib import contextmanager
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid

E4 = Path(__file__).resolve().parent
WORK = E4 / ".work"
SCRIPTS = (
    "baseline/source_code/nearest_next_baseline.py",
    "baseline/source_code/fcfs_baseline.py",
    "or_tools_route_optimiser/source_code/run_or_tools_route_optimiser.py",
    "experiment_result/source_code/e4_compare.py",
)
METHOD_DESTINATIONS = {
    "nearest_next": "baseline/1_nearest_next",
    "fcfs": "baseline/2_fcfs",
    "optimiser": "or_tools_route_optimiser/result",
}
METHOD_FILES = ("run_manifest.json", "run_info.md", "results_per_scenario.csv", "details/routes.csv")
COMPARISON_FILES = (
    "summary.md", "metrics.json", "comparison_summary.csv", "comparison_per_scenario.csv",
    "e4_fig1_tasks_served.png", "e4_fig1_tasks_served.pdf", "e4_fig2_km_per_scenario.png",
    "e4_fig3_total_km.png", "e4_fig4_matched_task_savings.png", "e4_fig4_matched_task_savings.pdf",
)
ACTIVE_MANIFEST = "experiment_result/run_manifest.json"
RESULT_FILES = {
    **{f"{target}/{name}": f"methods/{method}/{name}"
       for method, target in METHOD_DESTINATIONS.items() for name in METHOD_FILES},
    **{f"experiment_result/{name}": f"comparison/{name}" for name in COMPARISON_FILES},
}
PUBLISH_FILES = {**RESULT_FILES, ACTIVE_MANIFEST: "publication-manifest.json"}


def run_directory(run_id):
    if not re.fullmatch(r"[a-f0-9]{32}", run_id or ""):
        raise ValueError("E4 requires a 32-character lowercase hexadecimal run ID.")
    if WORK.resolve() != WORK:
        raise ValueError("The E4 staging root cannot be redirected.")
    directory = WORK / run_id
    if directory.resolve() != directory:
        raise ValueError("The E4 staging directory cannot be redirected.")
    return directory


@contextmanager
def publication_lock():
    """Release the OS lock even if the process is terminated."""
    WORK.mkdir(exist_ok=True)
    if WORK.resolve() != WORK:
        raise ValueError("The E4 staging root cannot be redirected.")
    with (WORK / "lock").open("a+b") as stream:
        if os.name == "nt":
            import msvcrt
            stream.seek(0)
            msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def read_json(path):
    return json.loads(path.read_bytes())


def persist_json(path, value):
    """Make complete journal records visible with a single rename."""
    temporary = path.with_suffix(".tmp")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def file_hash(path):
    if not path.is_file() or not path.stat().st_size:
        raise ValueError(f"Missing or empty E4 artifact: {path}")
    return sha256(path.read_bytes()).hexdigest()


def active_path(name):
    path = E4 / name
    if path.resolve() != path:
        raise ValueError(f"The E4 output path cannot be redirected: {path}")
    return path


def validate_staging(directory, manifest):
    """Bind each required artifact to the same run before changing active files."""
    run_id = manifest["run_id"]
    for method in METHOD_DESTINATIONS:
        path = directory / "methods" / method
        record = read_json(path / "run_manifest.json")
        if record["run_id"] != run_id or any(record[k] != manifest[k] for k in
                                             ("settings", "input_sha256", "source_sha256")):
            raise ValueError(f"Staged E4 manifest mismatch: {method}")
        expected = {name: file_hash(path / name) for name in METHOD_FILES if name != "run_manifest.json"}
        if record["artifact_sha256"] != expected:
            raise ValueError(f"Staged E4 artifact hash mismatch: {method}")
    metrics = read_json(directory / "comparison/metrics.json")
    if (metrics["run_id"] != run_id or set(metrics["per_method"]) != set(METHOD_DESTINATIONS)
            or metrics["realised_units"] != len(manifest["snapshots"])
            or any(row["independent_check_passed"] != metrics["realised_units"] or row["violations"]
                   for row in metrics["per_method"].values())):
        raise ValueError("Staged E4 comparison failed validation.")
    if f"**Run ID:** \x60{run_id}\x60" not in (directory / "comparison/summary.md").read_text(encoding="utf-8"):
        raise ValueError("Staged E4 summary has the wrong run ID.")
    return {name: file_hash(directory / staged) for name, staged in RESULT_FILES.items()}


def verify_active():
    manifest = read_json(active_path(ACTIVE_MANIFEST))
    if manifest["status"] != "completed" or set(manifest["artifact_sha256"]) != set(RESULT_FILES):
        raise ValueError("The active E4 manifest is incomplete.")
    for name, expected in manifest["artifact_sha256"].items():
        if file_hash(active_path(name)) != expected:
            raise ValueError(f"Active E4 artifact hash mismatch: {name}")
    return manifest


def replace_file(source, destination, scratch):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, scratch)
    os.replace(scratch, destination)


def remove_staging(directory):
    if directory != run_directory(directory.name):
        raise ValueError("Refusing to remove an unexpected E4 staging path.")
    if directory.exists():
        shutil.rmtree(directory)


def recover_publication():
    """Under the lock, roll back an uncommitted publication or finish committed cleanup."""
    journal = WORK / "publication.json"
    if not journal.exists():
        return
    transaction = read_json(journal)
    directory = run_directory(transaction["run_id"])
    if transaction["state"] == "committed":
        if verify_active()["run_id"] != directory.name:
            raise ValueError("Committed E4 publication does not match the active manifest.")
        remove_staging(directory)
    elif transaction["state"] == "publishing":
        previous = transaction["previous"]
        if set(previous) != set(PUBLISH_FILES):
            raise ValueError("Unexpected E4 publication journal inventory.")
        for name, existed in previous.items():
            if existed:
                replace_file(directory / "rollback" / name, active_path(name), directory / "restore.tmp")
            else:
                active_path(name).unlink(missing_ok=True)
        persist_json(directory / "failure.json", dict(run_id=directory.name, status="publication_rolled_back"))
    else:
        raise ValueError("Unknown E4 publication journal state.")
    journal.unlink()


def publish(directory, manifest):
    """Replace stable files with recovery information retained until commit."""
    hashes = validate_staging(directory, manifest)
    persist_json(directory / "publication-manifest.json",
                 dict(manifest, status="completed", artifact_sha256=hashes))
    previous = {}
    for name in PUBLISH_FILES:
        destination = active_path(name)
        previous[name] = destination.exists()
        if previous[name]:
            backup = directory / "rollback" / name
            backup.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(destination, backup)
    journal = WORK / "publication.json"
    transaction = dict(run_id=manifest["run_id"], state="publishing", previous=previous)
    persist_json(journal, transaction)
    try:
        # Invalidate the old completion marker before replacing any result.
        active_path(ACTIVE_MANIFEST).unlink(missing_ok=True)
        for name, staged in PUBLISH_FILES.items():
            replace_file(directory / staged, active_path(name), directory / "publish.tmp")
        if verify_active()["run_id"] != manifest["run_id"]:
            raise ValueError("Published E4 run ID differs from staging.")
        persist_json(journal, dict(transaction, state="committed"))
    except BaseException:
        recover_publication()
        raise
    recover_publication()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--preflight-only", action="store_true",
                       help="verify dependencies and sealed inputs without solving or writing results")
    modes.add_argument("--recover-publication", action="store_true",
                       help="recover stable outputs after an interrupted publication without running E4")
    modes.add_argument("--verify-active", action="store_true",
                       help="verify the published manifest and result hashes")
    args = parser.parse_args()
    if args.recover_publication:
        with publication_lock():
            recover_publication()
        return
    if args.verify_active:
        with publication_lock():
            if (WORK / "publication.json").exists():
                raise ValueError("An E4 publication was interrupted. Run --recover-publication first.")
            print(f"Verified published E4 run {verify_active()['run_id']}")
        return

    sys.path.insert(0, str(E4 / "test_harness"))
    from e4_shared import preflight, source_fingerprints

    admission = preflight()
    print(f"E4 preflight: {len(admission['snapshots'])} snapshots, 500 tasks, 50 one-vehicle and 50 two-vehicle fleets.")
    if args.preflight_only:
        return
    with publication_lock():
        recover_publication()
        run_id = uuid.uuid4().hex
        directory = run_directory(run_id)
        directory.mkdir(exist_ok=False)
        manifest = dict(run_id=run_id, status="in_progress", source_sha256=source_fingerprints(), **admission)
        persist_json(directory / "run_manifest.json", manifest)
        print(f"E4 staging {run_id}: {directory}", flush=True)
        try:
            with (directory / "execution.log").open("w", encoding="utf-8") as log:
                for script in SCRIPTS:
                    print(script, file=log, flush=True)
                    subprocess.run([sys.executable, "-B", str(E4 / script)], check=True, cwd=E4.parents[1],
                                   env={**os.environ, "GEOLOCK_E4_RUN_ID": run_id},
                                   stdout=log, stderr=subprocess.STDOUT)
            if source_fingerprints() != manifest["source_sha256"]:
                raise ValueError("E4 source changed during the run.")
            publish(directory, manifest)
        except BaseException:
            print(f"E4 stopped. Inspect {directory} and run --recover-publication if needed.",
                  file=sys.stderr)
            raise
        print(f"Published E4 run {run_id}: {active_path(ACTIVE_MANIFEST)}")


if __name__ == "__main__":
    main()
