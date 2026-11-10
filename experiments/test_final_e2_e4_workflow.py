"""Offline tests for the final E2/E4 read-only summary and PG path selection."""
import hashlib
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path

from experiments.e2_atomic_claiming import run_claim_lock_regressions as corrected_runner
from experiments.e2_atomic_claiming import run as standard_runner
from experiments.summarize_final_e2_e4 import (
    DEFAULTS,
    FINAL_METHODS,
    corrected_behavior_comparison,
    corrected_contention_rows,
    read_csv,
    source_artifacts,
    summarize,
    validate_three_method_rows,
    validate_corrected_manifest,
)

E4_FINAL_RESULT_AVAILABLE = DEFAULTS["e4"] is not None and DEFAULTS["e4"].is_dir()


class WorkflowTests(unittest.TestCase):
    @staticmethod
    def copy_corrected_fixture(source, destination):
        destination.mkdir()
        names = ("proposed_results_per_scenario.csv", "proposed_requests.json", "proposed_committed_states.json",
                 "completion.json", "manifest.json", "failures.json", "database_errors.csv")
        for name in names:
            path = Path(source) / name
            if path.is_file():
                shutil.copy2(path, destination / name)

    def test_standard_runner_fails_closed_on_patch_or_function_drift(self):
        _sql, digest = standard_runner.verified_lock_patch()
        self.assertEqual(digest, standard_runner.LOCK_PATCH_SHA256)
        catalog = {
            "claim_listing(uuid,uuid)": dict(md5=standard_runner.CORRECTED_CLAIM_MD5, owner="postgres", result_type="jsonb", volatility="v", definer=True, acl="{=X/postgres,postgres=X/postgres,authenticated=X/postgres}", config=["search_path=pg_catalog, public, extensions, pg_temp"]),
            "geolock_lock_listing_donations(uuid,text[])": dict(md5=standard_runner.CORRECTED_LOCK_HELPER_MD5, owner="postgres", result_type="boolean", volatility="v", definer=False, acl="{postgres=X/postgres}", config=["search_path=pg_catalog, public, pg_temp"]),
            "recover_expired_claims(integer)": dict(md5=standard_runner.old.RECOVERY_HASH, owner="postgres", definer=True, acl="{postgres=X/postgres,service_role=X/postgres}", config=["search_path=pg_catalog, public, extensions, pg_temp"]),
        }
        standard_runner.verify_corrected_catalog(catalog)
        catalog["geolock_lock_listing_donations(uuid,text[])"]["config"] = ["search_path=pg_catalog, public, extensions, pg_temp"]
        with self.assertRaisesRegex(RuntimeError, "geolock_lock_listing_donations.*config mismatch"):
            standard_runner.verify_corrected_catalog(catalog)
        catalog["geolock_lock_listing_donations(uuid,text[])"]["config"] = ["search_path=pg_catalog, public, pg_temp"]
        catalog["claim_listing(uuid,uuid)"]["md5"] = standard_runner.old.CLAIM_HASH
        with self.assertRaisesRegex(RuntimeError, "claim_listing.*md5 mismatch"):
            standard_runner.verify_corrected_catalog(catalog)
        import inspect
        body = inspect.getsource(standard_runner.run)
        self.assertLess(body.index("for name in ('non_atomic_claim'"), body.index("c.execute(patch_sql)"))
        self.assertIn("primary_methods=['non_atomic_claim','protected_claim_without_lease_recovery','corrected_atomic_claim_with_lease_recovery']", body)

    def test_combined_manifest_requires_corrected_third_method_and_local_run(self):
        manifest = {
            "correction_patch_sha256": "a0a35b5dfeab92351c79a240af79e46ad638f57b57f204a6cb54e9eeed3a0433",
            "function_catalog": {"e2_proposed": {
                "claim_listing(uuid,uuid)": {"md5": "0e1954dc17a5d30b81c57a161d99faac"},
                "geolock_lock_listing_donations(uuid,text[])": {"md5": "e97a3fd80673a827465f3eaa79b65903"},
                "recover_expired_claims(integer)": {"md5": "05fe46d8b76085f71c87fcc5f6520775"},
            }},
            "primary_methods": ["non_atomic_claim", "protected_claim_without_lease_recovery", "corrected_atomic_claim_with_lease_recovery"],
            "method_runs": 3, "environment": {"remote_access": False},
        }
        validate_corrected_manifest(manifest, combined=True)
        manifest["primary_methods"][2] = "original_deadlock_prone_proposed"
        with self.assertRaisesRegex(ValueError, "exactly the three approved"):
            validate_corrected_manifest(manifest, combined=True)

    def test_corrected_reference_accepts_winner_swaps_and_audits_them(self):
        base = DEFAULTS["corrected"].parent
        candidate = base / "e2-three-method-20261109-164724"
        comparison = corrected_behavior_comparison(candidate, DEFAULTS["corrected"])
        summary = comparison["summary"]
        self.assertEqual(summary["request_count_each_run"], 975)
        self.assertEqual(summary["candidate_vs_reference_request_uuid_differences"], 975)
        self.assertEqual(summary["request_outcome_reason_retry_sqlstate_record_differences"], 196)
        self.assertEqual(summary["scenarios_with_winner_request_ordinal_change"], 98)
        self.assertEqual(summary["scenarios_with_winner_ngo_identity_change"], 79)
        self.assertTrue(all(row["classification"].startswith("request-level winner scheduling") for row in comparison["request_differences"]))
        self.assertEqual(len([r for r in comparison["scenario_rows"] if r.get("case") in ("", "lease expired", "lease still running")]), 275)

    def test_corrected_reference_rejects_invariant_regressions(self):
        candidate_source = DEFAULTS["corrected"].parent / "e2-three-method-20261109-164724"
        reference = DEFAULTS["corrected"]
        mutations = (
            ("duplicate ownership", "proposed_committed_states.json", lambda data: data[0].update(active_owner_count=2)),
            ("missing success", "proposed_requests.json", lambda data: next(r for r in data if r["scenario_id"] == "SCN-CLAIM_COORDINATION-0001" and r["outcome"] == "SUCCESS").update(outcome="CONFLICT", reason_code="ALREADY_CLAIMED")),
            ("unexpected error", "proposed_requests.json", lambda data: data[0].update(outcome="ERROR", error="injected")),
            ("retry anomaly", "proposed_requests.json", lambda data: data[0].update(retries=1)),
            ("SQLSTATE anomaly", "proposed_requests.json", lambda data: data[0].update(sqlstate="40P01")),
            ("lease recovery failure", "proposed_results_per_scenario.csv", None),
        )
        for label, filename, mutation in mutations:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                candidate, reference_copy = root / "candidate", root / "reference"
                self.copy_corrected_fixture(candidate_source, candidate)
                self.copy_corrected_fixture(reference, reference_copy)
                path = candidate / filename
                if filename.endswith(".json"):
                    data = json.loads(path.read_text())
                    mutation(data)
                    path.write_text(json.dumps(data))
                else:
                    rows = read_csv(path)
                    expired = next(r for r in rows if r["case"] == "lease expired")
                    expired["second_ngo_got_listing"] = "NO"
                    from experiments.summarize_final_e2_e4 import write_csv
                    write_csv(path, rows)
                with self.assertRaises(ValueError):
                    corrected_behavior_comparison(candidate, reference_copy)

    def test_pg_bin_explicit_and_environment_selection(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            for binary in ("initdb.exe", "pg_ctl.exe", "psql.exe"):
                (folder / binary).touch()
            self.assertEqual(corrected_runner.configured_pg_bin(str(folder)), folder.resolve())
            previous = os.environ.get("GEOLOCK_E2_PG_BIN")
            try:
                os.environ["GEOLOCK_E2_PG_BIN"] = str(folder)
                self.assertEqual(corrected_runner.configured_pg_bin(), folder.resolve())
            finally:
                if previous is None:
                    os.environ.pop("GEOLOCK_E2_PG_BIN", None)
                else:
                    os.environ["GEOLOCK_E2_PG_BIN"] = previous

    def test_corrected_summary_separates_request_and_identity_counts(self):
        results, requests = [], []
        for workers in (2, 5, 10):
            for trial in range(50):
                sid = f"S-{workers}-{trial}"
                results.append({"scenario_id": sid, "case": "", "ngos_competing": str(workers),
                                "different_ngos": str(min(workers, 4)), "told_success": "1",
                                "told_already_claimed": str(workers - 1), "told_not_eligible": "0",
                                "failed_with_error": "0", "more_than_one_owner": "NO"})
                for req in range(workers):
                    requests.append({"scenario_id": sid, "request_uuid": f"{sid}-{req}", "latency_ms": "5",
                                     "outcome": "SUCCESS" if req == 0 else "CONFLICT",
                                     "reason_code": "" if req == 0 else "ALREADY_CLAIMED"})
        rows = corrected_contention_rows(results, requests)
        self.assertEqual([r["claim_requests"] for r in rows], [100, 250, 500])
        self.assertEqual([r["identity_distribution"] for r in rows], ["2 distinct NGOs:50 scenarios", "4 distinct NGOs:50 scenarios", "4 distinct NGOs:50 scenarios"])
        self.assertEqual([r["already_claimed_conflicts"] for r in rows], [50, 200, 450])

    def test_missing_or_duplicate_primary_methods_fail(self):
        rows = [{"method": method, "concurrent_requests": level} for method in FINAL_METHODS for level in (2, 5, 10)]
        validate_three_method_rows(rows)
        with self.assertRaisesRegex(ValueError, "missing=.*atomic_with_lease_recovery_corrected"):
            validate_three_method_rows([r for r in rows if r["method"] != "atomic_with_lease_recovery_corrected"])
        with self.assertRaisesRegex(ValueError, "duplicate"):
            validate_three_method_rows(rows + [dict(rows[0])])

    @unittest.skipUnless(E4_FINAL_RESULT_AVAILABLE, "Final E4 result is intentionally absent pending rerun; pass --e4 to summarize a new run")
    def test_preserved_run_summary_checks_three_methods_and_hashes_sources(self):
        sources = source_artifacts(DEFAULTS["original"], DEFAULTS["corrected"], DEFAULTS["e4"])
        before = [hashlib.sha256(p.read_bytes()).hexdigest() for p in sources]
        with tempfile.TemporaryDirectory() as tmp:
            out = summarize(DEFAULTS["original"], DEFAULTS["corrected"], DEFAULTS["e4"], Path(tmp) / "summary")
            primary = read_csv(out / "e2_primary_three_method_comparison.csv")
            self.assertEqual({r["method"] for r in primary}, set(FINAL_METHODS))
            self.assertEqual(len(primary), 9)
            self.assertNotIn("original_proposed", {r["method"] for r in primary})
            totals = {method: sum(int(r["claim_requests"]) for r in primary if r["method"] == method) for method in FINAL_METHODS}
            self.assertEqual(set(totals.values()), {850})
            history = read_csv(out / "e2_development_history.csv")
            original = [r for r in history if r["implementation_version"] == "original_proposed_historical"]
            corrected = [r for r in history if r["implementation_version"] == "corrected_proposed_final"]
            self.assertEqual(sum(int(r["sqlstate_40P01"]) for r in original), 683)
            self.assertEqual(sum(int(r["surfaced_request_errors"]) for r in corrected), 0)
            reference = read_csv(out / "e2_corrected_reference_comparison.csv")
            self.assertTrue(all(r["behavior_match"] == "True" for r in reference if r["scenario_id"] not in ("TIMING_2_CONCURRENT_REQUESTS", "TIMING_5_CONCURRENT_REQUESTS", "TIMING_10_CONCURRENT_REQUESTS")))
            lease = read_csv(out / "e2_lease_comparison.csv")
            corrected_expired = next(r for r in lease if r["method"] == FINAL_METHODS[2] and r["case"] == "lease expired")
            corrected_active = next(r for r in lease if r["method"] == FINAL_METHODS[2] and r["case"] == "lease still running")
            self.assertEqual((corrected_expired["scenarios"], corrected_expired["successful_recovery_or_reassignment"]), ("100", "100"))
            self.assertEqual((corrected_active["scenarios"], corrected_active["active_lease_protected"]), ("25", "25"))
            e4 = read_csv(out / "e4_common_admission_summary.csv")
            e4_original = read_csv(out / "e4_original_500_task_baseline.csv")
            self.assertEqual({int(r["valid_tasks"]) for r in e4}, {500})
            self.assertEqual({int(r["valid_tasks"]) for r in e4_original}, {500})
        self.assertEqual(before, [hashlib.sha256(p.read_bytes()).hexdigest() for p in sources])

    @unittest.skipUnless(E4_FINAL_RESULT_AVAILABLE, "Final E4 result is intentionally absent pending rerun; pass --e4 to summarize a new run")
    def test_combined_run_summary_uses_corrected_method_and_separate_history(self):
        original = DEFAULTS["original"].parent / "e2-final-20261109-055816"
        corrected = DEFAULTS["corrected"]
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            combined = tmp_path / "combined-e2"
            combined.mkdir()
            for method in ("non_atomic_claim", "protected_claim_without_lease_recovery"):
                shutil.copytree(original / method, combined / method)
            for name in ("proposed_results_per_scenario.csv", "proposed_requests.json", "proposed_committed_states.json", "completion.json", "manifest.json"):
                shutil.copy2(corrected / name, combined / name)
            combined_manifest = json.loads((combined / "manifest.json").read_text())
            combined_manifest["primary_methods"] = ["non_atomic_claim", "protected_claim_without_lease_recovery", "corrected_atomic_claim_with_lease_recovery"]
            combined_manifest["method_runs"] = 3
            (combined / "manifest.json").write_text(json.dumps(combined_manifest))
            out = summarize(combined, combined, DEFAULTS["e4"], tmp_path / "summary", DEFAULTS["historical"])
            primary = read_csv(out / "e2_primary_three_method_comparison.csv")
            self.assertEqual(len(primary), 9)
            self.assertEqual({r["method"] for r in primary}, set(FINAL_METHODS))
            self.assertEqual(sum(int(r["claim_requests"]) for r in primary if r["method"] == FINAL_METHODS[2]), 850)
            history = read_csv(out / "e2_development_history.csv")
            original_history = [r for r in history if r["implementation_version"] == "original_proposed_historical"]
            self.assertEqual(sum(int(r["sqlstate_40P01"]) for r in original_history), 683)
            reference = read_csv(out / "e2_corrected_reference_comparison.csv")
            self.assertEqual(len([r for r in reference if r["scenario_id"].startswith("SCN-")]), 275)
            self.assertTrue(all(r["behavior_match"] == "True" for r in reference if r["scenario_id"] not in ("TIMING_2_CONCURRENT_REQUESTS", "TIMING_5_CONCURRENT_REQUESTS", "TIMING_10_CONCURRENT_REQUESTS")))

    def test_no_deleted_e4_run_is_selected_as_default(self):
        self.assertIsNone(DEFAULTS["e4"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
