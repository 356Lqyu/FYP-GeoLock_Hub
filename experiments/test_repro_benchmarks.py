"""Offline checks for the sealed benchmark inputs."""

import hashlib
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ReproducibilityChecks(unittest.TestCase):
    def test_exact_manifest_csv_bytes_and_originals_unchanged(self):
        dataset = ROOT / "benchmark dataset" / "dataset"
        manifest = json.loads((dataset / "generation_manifest.json").read_bytes())
        for name, expected in manifest["generated_csv_sha256"].items():
            with self.subTest(input=name):
                filename = name + ".csv"
                sealed = (ROOT / "experiments/repro_inputs/v33" / filename).read_bytes()
                self.assertEqual(hashlib.sha256(sealed).hexdigest(), expected)
                original = (dataset / filename).read_bytes()
                self.assertEqual(sealed.replace(b"\r\n", b"\n"),
                                 original.replace(b"\r\n", b"\n"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
