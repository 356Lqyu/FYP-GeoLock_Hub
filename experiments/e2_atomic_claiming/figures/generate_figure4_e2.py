#!/usr/bin/env python3
"""Generate E2 Figure 4 from saved run records (no outcome values are embedded).

Uses only the Python standard library plus Poppler's ``pdftoppm`` renderer.
The PDF is drawn with native vector PDF operators; the PNG is rasterized from
that PDF at 300 dpi. The saved raw CSV/JSON result files are read-only inputs.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DEFAULT_RUN = ROOT / "experiments/e2_atomic_claiming/results/e2-three-method-20261109-164724"
DEFAULT_TABLE7 = ROOT / "experiments/results/phase4-stat-analysis-20261109-191130/e2_scenario_proportions.csv"
BLUE = (0.20, 0.39, 0.57)
INK = (0.12, 0.15, 0.19)
GRID = (0.86, 0.88, 0.90)
STANDALONE_LABEL_X = 14
STANDALONE_LABEL_RIGHT = 143
STANDALONE_PLOT_VIEW_LEFT = 154
STANDALONE_PLOT_LEFT = 162
STANDALONE_PLOT_RIGHT = 346
STANDALONE_PLOT_VIEW_RIGHT = 351

HELVETICA_WIDTHS = {
    **dict(zip("ABCDEFGHIJKLMNOPQRSTUVWXYZ", (667,667,722,722,667,611,778,722,278,500,667,556,833,722,778,667,778,722,667,611,722,667,944,667,667,611))),
    **dict(zip("abcdefghijklmnopqrstuvwxyz", (556,556,500,556,556,278,556,556,222,222,500,222,833,556,556,556,556,333,500,278,556,500,722,500,500,500))),
    **dict(zip("0123456789", (556,)*10)),
    " ":278, "(":333, ")":333, ",":278, "-":333, ".":278,
    "/":278, ":":278, "%":889, "'":191,
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream))


def truth(value: object) -> bool:
    return str(value).strip().upper() in {"YES", "TRUE", "1"}


def wilson(successes: int, n: int, z: float = 1.959963984540054) -> tuple[float, float]:
    """Wilson score interval for a binomial proportion, returned as fractions."""
    if n <= 0 or successes < 0 or successes > n:
        raise ValueError(f"Invalid binomial count: {successes}/{n}")
    p = successes / n
    z2 = z * z
    den = 1 + z2 / n
    center = (p + z2 / (2 * n)) / den
    half = z * math.sqrt(p * (1 - p) / n + z2 / (4 * n * n)) / den
    low, high = max(0.0, center - half), min(1.0, center + half)
    if successes == 0:
        low = 0.0
    if successes == n:
        high = 1.0
    return low, high


def rate(successes: int, n: int) -> dict:
    low, high = wilson(successes, n)
    return {"successes": successes, "n": n, "rate": successes / n, "low": low, "high": high}


def compare_table7(derived: dict, table7_path: Path) -> None:
    """Check recomputed run metrics against the saved Table 7 proportions CSV."""
    rows = read_csv(table7_path)
    lookup = {(r["domain"], r["method"], r["outcome"]): r for r in rows}
    pairs = [
        ("E2", "non_atomic", "duplicate_owner_trial", "duplicate", "non_atomic"),
        ("E2", "atomic_no_recovery", "duplicate_owner_trial", "duplicate", "no_recovery"),
        ("E2", "atomic_recovery_corrected", "duplicate_owner_trial", "duplicate", "with_recovery"),
        ("E2 lease", "atomic_no_recovery", "expired_lease_recovered_and_reassigned", "recovery", "no_recovery"),
        ("E2 lease", "atomic_recovery_corrected", "expired_lease_recovered_and_reassigned", "recovery", "with_recovery"),
    ]
    for domain, method, outcome, metric, key in pairs:
        saved = lookup.get((domain, method, outcome))
        if saved is None:
            raise ValueError(f"Table 7 artifact lacks {(domain, method, outcome)}")
        actual = derived[metric][key]
        if int(saved["successes"]) != actual["successes"] or int(saved["n_independent_units"]) != actual["n"]:
            raise ValueError(f"Table 7 counts differ for {(domain, method, outcome)}")
        for field, actual_field in (("proportion", "rate"), ("wilson_95_ci_low", "low"), ("wilson_95_ci_high", "high")):
            if not math.isclose(float(saved[field]), actual[actual_field], rel_tol=0, abs_tol=1e-12):
                raise ValueError(f"Table 7 {field} differs for {(domain, method, outcome)}")


def collect_data(run: Path, table7_path: Path) -> dict:
    run = run.resolve()
    required = {
        "completion": run / "completion.json",
        "manifest": run / "manifest.json",
        "non_atomic": run / "non_atomic_claim/results_per_scenario.csv",
        "no_recovery": run / "protected_claim_without_lease_recovery/results_per_scenario.csv",
        "no_recovery_lease": run / "protected_claim_without_lease_recovery/lease_results_per_scenario.csv",
        "proposed": run / "proposed_results_per_scenario.csv",
    }
    missing = [str(p) for p in required.values() if not p.is_file()]
    if missing:
        raise FileNotFoundError("Missing E2 figure evidence: " + ", ".join(missing))
    completion = json.loads(required["completion"].read_text(encoding="utf-8"))
    manifest = json.loads(required["manifest"].read_text(encoding="utf-8"))
    if completion.get("completed_proposed") != 275 or completion.get("failures") != 0:
        raise ValueError("Figure generation requires all 275 proposed-method scenarios completed without failures")
    if completion.get("remote_connections") != 0 or manifest.get("environment", {}).get("remote_access") is not False:
        raise ValueError("E2 evidence does not confirm a local-only run")
    source_hashes = manifest.get("source_sha256")
    if manifest.get("function_sources_unchanged") is not True or not isinstance(source_hashes, dict) or not source_hashes:
        raise ValueError("E2 run manifest does not confirm its source-integrity checks")
    if any(len(value) != 64 or any(ch not in "0123456789abcdef" for ch in value.lower()) for value in source_hashes.values()):
        raise ValueError("E2 source manifest contains an invalid SHA-256 value")

    proposed_all = read_csv(required["proposed"])
    scenarios = {
        "non_atomic": read_csv(required["non_atomic"]),
        "no_recovery": read_csv(required["no_recovery"]),
        "with_recovery": [r for r in proposed_all if r.get("ngos_competing") in {"2", "5", "10"}],
    }
    scenario_sets = {name: {r["scenario_id"] for r in rows} for name, rows in scenarios.items()}
    if any(len(rows) != 150 for rows in scenarios.values()) or not (
        scenario_sets["non_atomic"] == scenario_sets["no_recovery"] == scenario_sets["with_recovery"]
    ):
        raise ValueError("The three contention methods must contain the same 150 scenario IDs")
    if any(sum(int(r["ngos_competing"]) == level for r in scenarios["with_recovery"]) != 50 for level in (2, 5, 10)):
        raise ValueError("Expected 50 contention trials at each 2/5/10 concurrent-request level")

    duplicate = {}
    for method, rows in scenarios.items():
        for row in rows:
            if truth(row["more_than_one_owner"]) != (int(row["claims_stored"]) > 1):
                raise ValueError(f"Duplicate-owner flag does not match committed claim count: {row['scenario_id']}")
            if method != "non_atomic" and (int(row["told_success"]) != 1 or int(row["failed_with_error"]) != 0):
                raise ValueError(f"Protected contention outcome is not one clean winner: {row['scenario_id']}")
        duplicates = sum(truth(r["more_than_one_owner"]) for r in rows)
        duplicate[method] = rate(duplicates, len(rows))
        if method != "non_atomic" and any(int(r["claims_stored"]) != 1 for r in rows):
            raise ValueError(f"Protected method has a non-single-owner contention trial: {method}")

    baseline_lease_rows = read_csv(required["no_recovery_lease"])
    proposed_lease_rows = [r for r in proposed_all if r.get("case", "").startswith("lease ")]
    no_expired = [r for r in baseline_lease_rows if r.get("case") == "lease expired"]
    yes_expired = [r for r in proposed_lease_rows if r.get("case") == "lease expired"]
    no_active = [r for r in baseline_lease_rows if r.get("case") == "lease still running"]
    yes_active = [r for r in proposed_lease_rows if r.get("case") == "lease still running"]
    if (len(no_expired), len(yes_expired), len(no_active), len(yes_active)) != (100, 100, 25, 25):
        raise ValueError("Expected 100 expired-lease cases and 25 active-lease controls per protected method")

    no_recovery_count = sum(
        truth(r["second_ngo_got_listing"]) and not truth(r["first_claim_still_active"])
        for r in no_expired
    )
    recovery_count = sum(
        truth(r["second_ngo_got_listing"])
        and not truth(r["first_claim_still_active"])
        and int(r["active_claims_after"]) == 1
        and int(r["recovery_affected_rows"]) == 1
        for r in yes_expired
    )
    if any(not truth(r["first_claim_still_active"]) or truth(r["second_ngo_got_listing"])
           or int(r["active_claims_after"]) != 1 for r in no_active + yes_active):
        raise ValueError("An active-lease control was not protected")
    recovery = {"no_recovery": rate(no_recovery_count, len(no_expired)), "with_recovery": rate(recovery_count, len(yes_expired))}

    derived = {"duplicate": duplicate, "recovery": recovery}
    compare_table7(derived, table7_path.resolve())
    sources = {name: path for name, path in required.items()}
    sources["lease_table7_comparison"] = table7_path.resolve()
    return {"run": run, "duplicate": duplicate, "recovery": recovery, "sources": sources}


def _esc(value: str) -> str:
    return value.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


class PdfPage:
    """Small vector PDF canvas, matching the E4 figure generator's approach."""
    def __init__(self, width: int = 720, height: int = 400):
        self.width, self.height = width, height
        self.commands: list[str] = []

    def text(self, x: float, y: float, value: str, size: float = 9, color=INK):
        self.commands.append(f"{color[0]:.3f} {color[1]:.3f} {color[2]:.3f} rg BT /F1 {size:.1f} Tf 1 0 0 1 {x:.2f} {y:.2f} Tm ({_esc(value)}) Tj ET")

    def line(self, x1: float, y1: float, x2: float, y2: float, color=GRID, width: float = 0.6):
        self.commands.append(f"{color[0]:.3f} {color[1]:.3f} {color[2]:.3f} RG {width:.2f} w {x1:.2f} {y1:.2f} m {x2:.2f} {y2:.2f} l S")

    def circle(self, x: float, y: float, radius: float, color=BLUE):
        c = radius * 0.5522847498
        self.commands.append(f"{color[0]:.3f} {color[1]:.3f} {color[2]:.3f} rg {x+radius:.2f} {y:.2f} m {x+radius:.2f} {y+c:.2f} {x+c:.2f} {y+radius:.2f} {x:.2f} {y+radius:.2f} c {x-c:.2f} {y+radius:.2f} {x-radius:.2f} {y+c:.2f} {x-radius:.2f} {y:.2f} c {x-radius:.2f} {y-c:.2f} {x-c:.2f} {y-radius:.2f} {x:.2f} {y-radius:.2f} c {x+c:.2f} {y-radius:.2f} {x+radius:.2f} {y-c:.2f} {x+radius:.2f} {y:.2f} c f")

    def pdf_bytes(self) -> bytes:
        content = ("\n".join(self.commands) + "\n").encode("ascii")
        objects = [
            b"<< /Type /Catalog /Pages 2 0 R >>",
            b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {self.width} {self.height}] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>".encode("ascii"),
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            f"<< /Length {len(content)} >>\nstream\n".encode("ascii") + content + b"endstream",
        ]
        output = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
        offsets = [0]
        for number, obj in enumerate(objects, 1):
            offsets.append(len(output)); output.extend(f"{number} 0 obj\n".encode("ascii")); output.extend(obj); output.extend(b"\nendobj\n")
        xref = len(output)
        output.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode("ascii"))
        for offset in offsets[1:]: output.extend(f"{offset:010d} 00000 n \n".encode("ascii"))
        output.extend(f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode("ascii"))
        return bytes(output)


def draw_interval_panel(page: PdfPage, rows: list[tuple[str, dict]], *, label_x: float, plot_left: float,
                        plot_right: float, row_y: list[float], base_y: float, grid_top: float,
                        tick_y: float, axis_label_y: float, count_label: str,
                        label_size: float, count_size: float, tick_size: float, axis_label: str,
                        labels_above_points: bool = False):
    for tick in (0, 25, 50, 75, 100):
        x = plot_left + (plot_right - plot_left) * tick / 100
        page.line(x, base_y, x, grid_top, GRID, 0.65)
        page.text(x - (5 if tick < 100 else 10), tick_y, str(tick), tick_size, (0.35, 0.38, 0.41))
    page.line(plot_left, base_y, plot_right, base_y, (0.35, 0.38, 0.41), 0.85)
    for (label, item), y in zip(rows, row_y):
        label_y, count_y = (y + 19, y + 5) if labels_above_points else (y + 5, y - 10)
        page.text(label_x, label_y, label, label_size, INK)
        percentage = item["rate"] * 100
        page.text(label_x, count_y, f"{item['successes']}/{item['n']} {count_label} ({percentage:.0f}%)", count_size, (0.38, 0.41, 0.44))
        scale = plot_right - plot_left
        lo, hi, point = item["low"] * 100, item["high"] * 100, percentage
        xlo, xhi, xp = (plot_left + scale * value / 100 for value in (lo, hi, point))
        page.line(xlo, y, xhi, y, BLUE, 2.1)
        page.line(xlo, y - 4, xlo, y + 4, BLUE, 1.0)
        page.line(xhi, y - 4, xhi, y + 4, BLUE, 1.0)
        page.circle(xp, y, 4.4, BLUE)
    page.text((plot_left + plot_right) / 2 - 25, axis_label_y, axis_label, 8.5, (0.28, 0.32, 0.36))


def standalone_layout(page_width: int) -> dict:
    """Return fixed, non-overlapping text and plotting regions for standalone art."""
    if page_width < STANDALONE_PLOT_RIGHT + 14:
        raise ValueError("Standalone figure page is too narrow for its fixed label and plot regions")
    return {
        "label_column": (STANDALONE_LABEL_X, STANDALONE_LABEL_RIGHT),
        "plot_viewport": (STANDALONE_PLOT_VIEW_LEFT, STANDALONE_PLOT_VIEW_RIGHT),
        "plot_axis": (STANDALONE_PLOT_LEFT, STANDALONE_PLOT_RIGHT),
    }


def helvetica_text_width(text: str, size: float) -> float:
    """Measure normal Helvetica text using AFM widths, in PDF points."""
    unknown = sorted(set(text) - HELVETICA_WIDTHS.keys())
    if unknown:
        raise ValueError(f"Unsupported Helvetica characters in figure label: {unknown}")
    return sum(HELVETICA_WIDTHS[ch] for ch in text) * size / 1000


def standalone_rows(data: dict, panel: str) -> list[tuple[str, dict, str]]:
    if panel == "duplicate":
        metric, keys, count_label = data["duplicate"], (
            ("Non-atomic", "non_atomic"),
            ("Protected, no recovery", "no_recovery"),
            ("Proposed, with recovery", "with_recovery"),
        ), "trials"
    elif panel == "recovery":
        metric, keys, count_label = data["recovery"], (
            ("Protected, no recovery", "no_recovery"),
            ("Proposed, with recovery", "with_recovery"),
        ), "cases"
    else:
        raise ValueError(f"Unknown standalone figure panel: {panel}")
    return [(label, metric[key], count_label) for label, key in keys]


def draw_standalone_label_column(page: PdfPage, rows: list[tuple[str, dict, str]], row_y: list[float], label_size: float, count_size: float) -> None:
    if len(rows) != len(row_y):
        raise ValueError("Each standalone method label must align with exactly one plotted point")
    for (label, item, count_label), y in zip(rows, row_y):
        count = f"{item['successes']}/{item['n']} {count_label} ({item['rate'] * 100:.0f}%)"
        for text, baseline, size in ((label, y + 7, label_size), (count, y - 10, count_size)):
            if STANDALONE_LABEL_X + helvetica_text_width(text, size) > STANDALONE_LABEL_RIGHT:
                raise ValueError(f"Standalone label exceeds its fixed column: {text}")
            page.text(STANDALONE_LABEL_X, baseline, text, size, INK if text == label else (0.38, 0.41, 0.44))


def draw_standalone_graph(page: PdfPage, rows: list[tuple[str, dict, str]], row_y: list[float], *,
                          base_y: float, grid_top: float, tick_y: float, axis_label_y: float,
                          axis_label: str, tick_size: float = 10.5, axis_label_size: float = 11.5) -> None:
    """Draw graph-only marks; no method or count text enters this viewport."""
    if len(rows) != len(row_y):
        raise ValueError("Each standalone plotted point must have one aligned label block")
    plot_left, plot_right = STANDALONE_PLOT_LEFT, STANDALONE_PLOT_RIGHT
    for tick in (0, 25, 50, 75, 100):
        x = plot_left + (plot_right - plot_left) * tick / 100
        page.line(x, base_y, x, grid_top, GRID, 0.65)
        page.text(x - (5 if tick < 100 else 10), tick_y, str(tick), tick_size, (0.35, 0.38, 0.41))
    page.line(plot_left, base_y, plot_right, base_y, (0.35, 0.38, 0.41), 0.85)
    for (_, item, _), y in zip(rows, row_y):
        scale = plot_right - plot_left
        lo, hi, point = item["low"] * 100, item["high"] * 100, item["rate"] * 100
        xlo, xhi, xp = (plot_left + scale * value / 100 for value in (lo, hi, point))
        page.line(xlo, y, xhi, y, BLUE, 2.1)
        page.line(xlo, y - 4, xlo, y + 4, BLUE, 1.0)
        page.line(xhi, y - 4, xhi, y + 4, BLUE, 1.0)
        page.circle(xp, y, 4.4, BLUE)
    axis_x = (plot_left + plot_right - helvetica_text_width(axis_label, axis_label_size)) / 2
    page.text(axis_x, axis_label_y, axis_label, axis_label_size, (0.28, 0.32, 0.36))


def combined_page(data: dict) -> PdfPage:
    page = PdfPage()
    page.text(32, 372, "E2: claim safety and lease recovery", 14, (0.10, 0.16, 0.22))
    page.text(28, 337, "(a) Duplicate ownership", 11, (0.10, 0.16, 0.22))
    draw_interval_panel(page, [
        ("Non-atomic", data["duplicate"]["non_atomic"]),
        ("Protected, no recovery", data["duplicate"]["no_recovery"]),
        ("Proposed, with recovery", data["duplicate"]["with_recovery"]),
    ], label_x=28, plot_left=158, plot_right=342, row_y=[275, 207, 139], base_y=106,
        grid_top=315, tick_y=88, axis_label_y=66, count_label="trials",
        label_size=8.7, count_size=7.5, tick_size=8, axis_label="Rate (%)")
    page.text(374, 337, "(b) Expired-lease recovery", 11, (0.10, 0.16, 0.22))
    draw_interval_panel(page, [
        ("Protected, no recovery", data["recovery"]["no_recovery"]),
        ("Proposed, with recovery", data["recovery"]["with_recovery"]),
    ], label_x=374, plot_left=505, plot_right=690, row_y=[245, 165], base_y=106,
        grid_top=315, tick_y=88, axis_label_y=66, count_label="cases",
        label_size=8.7, count_size=7.5, tick_size=8, axis_label="Rate (%)")
    page.text(374, 126, "Non-atomic: not applicable", 7.8, (0.38, 0.41, 0.44))
    page.text(28, 34, "Points: observed rates; bars: 95% Wilson score confidence intervals.", 8, (0.35, 0.38, 0.41))
    return page


def duplicate_ownership_page(data: dict) -> PdfPage:
    page = PdfPage(360, 400)
    page.text(14, 374, "Duplicate ownership", 14, (0.10, 0.16, 0.22))
    rows, y_values = standalone_rows(data, "duplicate"), [285, 200, 115]
    draw_standalone_label_column(page, rows, y_values, 11.5, 10.5)
    draw_standalone_graph(page, rows, y_values, base_y=75, grid_top=335, tick_y=57,
                          axis_label_y=36, axis_label="Duplicate ownership (%)")
    page.text(14, 16, "Points: observed rates; bars: 95% Wilson score CIs.", 8.5, (0.35, 0.38, 0.41))
    return page


def lease_recovery_page(data: dict) -> PdfPage:
    page = PdfPage(360, 330)
    page.text(14, 304, "Expired-lease recovery", 14, (0.10, 0.16, 0.22))
    rows, y_values = standalone_rows(data, "recovery"), [215, 130]
    draw_standalone_label_column(page, rows, y_values, 11.5, 10.5)
    draw_standalone_graph(page, rows, y_values, base_y=75, grid_top=265, tick_y=57,
                          axis_label_y=36, axis_label="Expired-lease recovery (%)")
    page.text(14, 16, "Protected methods only; bars are 95% Wilson score CIs.", 8.5, (0.35, 0.38, 0.41))
    return page


FIGURES = {
    "figure4_e2_claim_safety_recovery": combined_page,
    "figure4a_e2_duplicate_ownership": duplicate_ownership_page,
    "figure4b_e2_expired_lease_recovery": lease_recovery_page,
}


def generate(run: Path, output: Path | None = None, table7_path: Path = DEFAULT_TABLE7,
             pdftoppm: str | None = None, replace_existing: bool = False) -> dict[str, tuple[Path, Path]]:
    data = collect_data(run, table7_path)
    output_candidate = output or (data["run"] / "figures")
    if output_candidate.is_symlink():
        raise ValueError(f"Refusing a symlinked figure output directory: {output_candidate}")
    output = output_candidate.resolve()
    output.mkdir(parents=True, exist_ok=True)
    output_stems = tuple(FIGURES)
    targets = [output / f"{stem}.{ext}" for stem in output_stems for ext in ("pdf", "png")]
    manifest_path = output / "figure4_e2_claim_safety_recovery_manifest.json"
    if manifest_path.exists():
        old_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if old_manifest.get("source_run") != str(data["run"]):
            raise ValueError("Existing figure manifest belongs to a different E2 run")
    existing = [target for target in [*targets, manifest_path] if target.exists()]
    if existing and not replace_existing:
        raise FileExistsError("Refusing to overwrite figure artifacts; use --replace-existing after verifying the output directory: " + ", ".join(str(p) for p in existing))
    if any(path.is_symlink() for path in existing):
        raise ValueError("Refusing to replace a symlinked figure artifact")
    renderer = pdftoppm or shutil.which("pdftoppm")
    if not renderer:
        raise FileNotFoundError("pdftoppm is required to render the 300 dpi PNG")
    rendered: dict[str, tuple[Path, Path]] = {}
    for stem, page_factory in FIGURES.items():
        pdf, png = output / f"{stem}.pdf", output / f"{stem}.png"
        pdf.write_bytes(page_factory(data).pdf_bytes())
        result = subprocess.run([renderer, "-singlefile", "-r", "300", "-png", str(pdf), str(output / stem)], capture_output=True, text=True)
        if result.returncode != 0 or not png.is_file():
            raise RuntimeError(f"pdftoppm failed for {stem}: {result.stderr.strip()}")
        rendered[stem] = (png, pdf)
    manifest = {
        "status": "FIGURES_GENERATED_FROM_SAVED_E2_EVIDENCE",
        "source_run": str(data["run"]),
        "table7_crosscheck": str(table7_path.resolve()),
        "metrics": {"duplicate_ownership": data["duplicate"], "expired_lease_recovery": data["recovery"]},
        "wilson_confidence_level": 0.95,
        "png_resolution_dpi": 300,
        "vector_format": "PDF",
        "source_sha256": sha256(Path(__file__).resolve()),
        "input_sha256": {name: sha256(path) for name, path in data["sources"].items()},
        "outputs_sha256": {stem: {"pdf": sha256(paths[1]), "png": sha256(paths[0])} for stem, paths in rendered.items()},
        "figure_data_rules": {
            "duplicate_ownership": "Independent units are contention scenarios; numerator is more_than_one_owner.",
            "expired_lease_recovery": "Independent units are expired-lease scenarios; success requires reassignment and old claim no longer active.",
            "active_lease_controls": "All saved controls checked as protected before plotting.",
        },
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return rendered


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, default=DEFAULT_RUN)
    parser.add_argument("--output", type=Path, help="Defaults to <run>/figures; existing figure files are never overwritten")
    parser.add_argument("--table7-csv", type=Path, default=DEFAULT_TABLE7)
    parser.add_argument("--pdftoppm", help="Optional explicit path to Poppler pdftoppm")
    parser.add_argument("--check-only", action="store_true", help="Validate data and Table 7 agreement without writing files")
    parser.add_argument("--replace-existing", action="store_true", help="Explicitly replace only these three named generated figures and their manifest")
    args = parser.parse_args()
    data = collect_data(args.run, args.table7_csv)
    if args.check_only:
        print("PASS: E2 evidence, Wilson intervals, lease controls, and Table 7 values agree.")
        return
    rendered = generate(args.run, args.output, args.table7_csv, args.pdftoppm, args.replace_existing)
    for stem, (png, pdf) in rendered.items():
        print(f"{stem} PNG: {png}")
        print(f"{stem} PDF: {pdf}")
    print(f"Manifest: {(args.output or (data['run'] / 'figures')) / 'figure4_e2_claim_safety_recovery_manifest.json'}")


if __name__ == "__main__":
    main()
