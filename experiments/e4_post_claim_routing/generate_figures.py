"""Generate publication figures from a completed, independently verified E4 run.

This module reads result and statistical-analysis artifacts only. It writes
vector PDF charts, rasterizes them to 300 dpi with Poppler's pdftoppm, and
records hashes for every source artifact. No metric values are embedded in the
script.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import shutil
import subprocess
from pathlib import Path

METHODS = ("nearest_next", "fcfs", "proposed")
LABELS = {"nearest_next": "Nearest-Next", "fcfs": "FCFS", "proposed": "CP-SAT"}
COLORS = {
    "nearest_next": (0.20, 0.39, 0.57),
    "fcfs": (0.78, 0.49, 0.20),
    "proposed": (0.24, 0.52, 0.40),
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream))


def collect_data(run: Path) -> dict:
    run = run.resolve()
    completion_path = run / "completion.json"
    verification_path = run / "verification.json"
    manifest_path = run / "manifest.json"
    summary_path = run / "summary_statistics.csv"
    paired_path = run / "statistical_analysis" / "paired_tests.csv"
    required = (completion_path, verification_path, manifest_path, summary_path, paired_path)
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        raise FileNotFoundError("Missing verified E4 figure input(s): " + ", ".join(missing))

    completion = json.loads(completion_path.read_text(encoding="utf-8"))
    verification = json.loads(verification_path.read_text(encoding="utf-8"))
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("status") != "COMPLETE":
        raise ValueError("Figure generation requires manifest status COMPLETE")
    if not completion.get("all_100_completed") or completion.get("scenarios") != 100:
        raise ValueError("Figure generation requires all 100 E4 scenarios")
    if completion.get("evaluations") != 300 or completion.get("errors") != 0:
        raise ValueError("Figure generation requires 300 successful method evaluations")
    if not completion.get("source_unchanged"):
        raise ValueError("E4 source hashes changed during the benchmark")
    if verification.get("saved_routes_independently_revalidated") != 300:
        raise ValueError("All 300 plans must pass independent post-run validation")
    if verification.get("additional_admission_exclusions") != 0:
        raise ValueError("Corrected E4 figure generation requires zero admission exclusions")

    summary = read_csv(summary_path)
    by_method = {row.get("method"): row for row in summary}
    if set(by_method) != set(METHODS) or len(summary) != 3:
        raise ValueError("Summary must contain exactly Nearest-Next, FCFS, and CP-SAT")
    for method, row in by_method.items():
        if int(row["scenarios"]) != 100 or int(row["valid_tasks"]) != 500:
            raise ValueError(f"{method} does not contain 100 scenarios and 500 admitted tasks")
        if int(row["successful_plans"]) != 100 or int(row["failed_or_invalid"]) != 0:
            raise ValueError(f"{method} does not have 100 independently validated plans")
        if int(row["feasibility_pass"]) != 100 or int(row["timeouts"]) != 0:
            raise ValueError(f"{method} has infeasible plans or timeouts")
        for field in ("capacity_violations", "window_violations", "duration_violations"):
            if int(row[field]) != 0:
                raise ValueError(f"{method} has {field}: {row[field]}")

    per_scenario_path = run / "results_per_scenario.csv"
    per_scenario = read_csv(per_scenario_path)
    if len(per_scenario) != 300:
        raise ValueError(f"Expected 300 scenario/method rows, got {len(per_scenario)}")
    scenarios = {method: set() for method in METHODS}
    for row in per_scenario:
        if row["method"] not in scenarios:
            raise ValueError(f"Unexpected method in per-scenario results: {row['method']}")
        scenarios[row["method"]].add(row["scenario_id"])
    if any(len(scenarios[m]) != 100 for m in METHODS) or not (scenarios["nearest_next"] == scenarios["fcfs"] == scenarios["proposed"]):
        raise ValueError("Each method must contain the same 100 scenario IDs")

    paired_rows = read_csv(paired_path)
    pairs = {}
    for baseline in ("nearest_next", "fcfs"):
        matches = [
            row for row in paired_rows
            if row.get("baseline") == baseline
            and row.get("metric") == "distance_km_identical_served_task_set"
        ]
        if len(matches) != 1:
            raise ValueError(f"Expected one matched-task distance analysis for {baseline}")
        row = matches[0]
        if row.get("analysis_scope") != "identical_served_task_sets_only":
            raise ValueError(f"Distance comparison for {baseline} is not task-set matched")
        n = int(row["matched_scenarios"])
        if n <= 0 or n != int(row["n_pairs"]):
            raise ValueError(f"Invalid matched scenario count for {baseline}: {n}")
        pairs[baseline] = {
            "n": n,
            # Analysis differences are proposed minus baseline; savings reverse sign.
            "estimate": -float(row["hodges_lehmann_paired_location"]),
            "low": -float(row["hl_bootstrap_95_ci_high"]),
            "high": -float(row["hl_bootstrap_95_ci_low"]),
            "p_holm": float(row["p_holm_e4_secondary"]),
        }

    return {
        "run": run,
        "completion": completion,
        "verification": verification,
        "summary": by_method,
        "paired_savings": pairs,
        "sources": {
            "completion.json": completion_path,
            "verification.json": verification_path,
            "manifest.json": manifest_path,
            "summary_statistics.csv": summary_path,
            "results_per_scenario.csv": per_scenario_path,
            "statistical_analysis/paired_tests.csv": paired_path,
        },
    }


def esc(text: str) -> str:
    return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


class PdfPage:
    """Small vector-PDF canvas using only built-in fonts and PDF operators."""

    width = 720
    height = 504

    def __init__(self):
        self.commands: list[str] = []

    def text(self, x: float, y: float, value: str, size: float = 10, color=(0.12, 0.15, 0.19)):
        self.commands.append(
            f"{color[0]:.3f} {color[1]:.3f} {color[2]:.3f} rg BT /F1 {size:.1f} Tf "
            f"1 0 0 1 {x:.2f} {y:.2f} Tm ({esc(value)}) Tj ET"
        )

    def line(self, x1: float, y1: float, x2: float, y2: float, color=(0.78, 0.80, 0.82), width=0.7):
        self.commands.append(
            f"{color[0]:.3f} {color[1]:.3f} {color[2]:.3f} RG {width:.2f} w "
            f"{x1:.2f} {y1:.2f} m {x2:.2f} {y2:.2f} l S"
        )

    def rect(self, x: float, y: float, width: float, height: float, color):
        self.commands.append(
            f"{color[0]:.3f} {color[1]:.3f} {color[2]:.3f} rg "
            f"{x:.2f} {y:.2f} {width:.2f} {height:.2f} re f"
        )

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
        for index, obj in enumerate(objects, 1):
            offsets.append(len(output))
            output.extend(f"{index} 0 obj\n".encode("ascii"))
            output.extend(obj)
            output.extend(b"\nendobj\n")
        xref = len(output)
        output.extend(f"xref\n0 {len(offsets)}\n".encode("ascii"))
        output.extend(b"0000000000 65535 f \n")
        for offset in offsets[1:]:
            output.extend(f"{offset:010d} 00000 n \n".encode("ascii"))
        output.extend(
            f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode("ascii")
        )
        return bytes(output)


def chart_base(page: PdfPage, title: str, y_label: str, max_value: float, ticks: list[float]):
    page.text(58, 460, title, 16, (0.10, 0.16, 0.22))
    left, right, bottom, top = 92, 680, 108, 420
    page.text(20, 270, y_label, 10, (0.28, 0.32, 0.36))
    for tick in ticks:
        y = bottom + (tick / max_value) * (top - bottom)
        page.line(left, y, right, y, (0.87, 0.88, 0.89), 0.55)
        page.text(48, y - 3, f"{tick:g}", 9, (0.35, 0.38, 0.41))
    page.line(left, bottom, left, top, (0.35, 0.38, 0.41), 0.8)
    page.line(left, bottom, right, bottom, (0.35, 0.38, 0.41), 0.8)
    return left, right, bottom, top


def coverage_page(data: dict) -> PdfPage:
    page = PdfPage()
    left, right, bottom, top = chart_base(page, "Figure 6(a). Valid-task coverage by routing method", "Coverage (%)", 100, [0, 20, 40, 60, 80, 100])
    width = 88
    centers = [left + (right - left) * (i + 0.5) / 3 for i in range(3)]
    for method, center in zip(METHODS, centers):
        row = data["summary"][method]
        served, valid = int(row["served_tasks"]), int(row["valid_tasks"])
        coverage = float(row["task_weighted_coverage_pct"])
        height = (coverage / 100) * (top - bottom)
        page.rect(center - width / 2, bottom, width, height, COLORS[method])
        page.text(center - 46, bottom + height + 9, f"{served}/{valid} ({coverage:.1f}%)", 10)
        page.text(center - 34, 78, LABELS[method], 10)
    page.text(92, 37, "Task-weighted counts aggregated across 100 snapshots; descriptive coverage.", 9, (0.35, 0.38, 0.41))
    return page


def distance_page(data: dict) -> PdfPage:
    page = PdfPage()
    maximum = max(float(data["summary"][m]["distance_km"]) for m in METHODS)
    maximum = max(1000, (int(maximum / 1000) + 1) * 1000)
    ticks = list(range(0, int(maximum) + 1, 1000))
    left, right, bottom, top = chart_base(page, "Figure 6(b). Total directed-road distance", "Distance (km)", maximum, ticks)
    width = 88
    centers = [left + (right - left) * (i + 0.5) / 3 for i in range(3)]
    for method, center in zip(METHODS, centers):
        total = float(data["summary"][method]["distance_km"])
        height = (total / maximum) * (top - bottom)
        page.rect(center - width / 2, bottom, width, height, COLORS[method])
        page.text(center - 39, bottom + height + 9, f"{total:,.1f} km", 10)
        page.text(center - 34, 78, LABELS[method], 10)
    page.text(92, 37, "Aggregate totals are descriptive; served task identities differ by method.", 9, (0.35, 0.38, 0.41))
    return page


def paired_savings_page(data: dict) -> PdfPage:
    page = PdfPage()
    page.text(58, 460, "Supplementary figure. CP-SAT matched-task distance savings", 16, (0.10, 0.16, 0.22))
    left, right, bottom, top = 200, 660, 130, 405
    pairs = data["paired_savings"]
    extent = max(abs(v) for row in pairs.values() for v in (row["low"], row["high"], row["estimate"]))
    limit = max(5, (int(extent / 5) + 1) * 5)
    x0 = left + limit / (2 * limit) * (right - left)
    page.line(x0, bottom, x0, top, (0.55, 0.57, 0.59), 0.9)
    for i, (baseline, label) in enumerate((("nearest_next", "vs Nearest-Next"), ("fcfs", "vs FCFS"))):
        row = pairs[baseline]
        y = top - 65 - i * 125
        map_x = lambda value: left + ((value + limit) / (2 * limit)) * (right - left)
        page.line(map_x(row["low"]), y, map_x(row["high"]), y, COLORS["proposed"], 2.0)
        page.line(map_x(row["low"]), y - 8, map_x(row["low"]), y + 8, COLORS["proposed"], 1.2)
        page.line(map_x(row["high"]), y - 8, map_x(row["high"]), y + 8, COLORS["proposed"], 1.2)
        page.rect(map_x(row["estimate"]) - 4, y - 4, 8, 8, COLORS["proposed"])
        page.text(58, y + 4, label, 11)
        page.text(58, y - 14, f"HL savings {row['estimate']:.2f} km; n={row['n']}; 95% CI {row['low']:.2f} to {row['high']:.2f}", 9, (0.35, 0.38, 0.41))
    page.text(200, 90, f"Matched-task distance savings (km); positive favors CP-SAT. Holm-adjusted p: NN {pairs['nearest_next']['p_holm']:.3g}; FCFS {pairs['fcfs']['p_holm']:.3g}.", 9, (0.35, 0.38, 0.41))
    page.text(200, 72, "Only snapshots with identical served task ID sets are included.", 9, (0.35, 0.38, 0.41))
    page.line(left, bottom, right, bottom, (0.35, 0.38, 0.41), 0.8)
    for tick in range(-limit, limit + 1, max(1, limit // 4)):
        x = left + ((tick + limit) / (2 * limit)) * (right - left)
        page.line(x, bottom - 4, x, bottom + 4, (0.35, 0.38, 0.41), 0.8)
        page.text(x - 9, bottom - 20, f"{tick:g}", 8, (0.35, 0.38, 0.41))
    return page


def matched_savings_geometry(data: dict) -> dict[str, dict[str, float]]:
    """Map the analyzed matched-task estimates and intervals onto the plot axis."""
    left, right = 168.0, 412.0
    axis_max = 15.0

    def x(value: float) -> float:
        return left + (value / axis_max) * (right - left)

    return {
        baseline: {
            "low": x(row["low"]),
            "estimate": x(row["estimate"]),
            "high": x(row["high"]),
        }
        for baseline, row in data["paired_savings"].items()
    }


def matched_task_savings_page(data: dict) -> PdfPage:
    """Compact, paper-sized point/95% CI chart for identical served-task sets."""
    page = PdfPage()
    page.width = 432  # 6 in at 72 dpi; compact paper-column figure.
    page.height = 300
    title = "E4: road-distance savings for identical served tasks"
    blue = (0.20, 0.39, 0.57)
    muted = (0.38, 0.41, 0.44)
    left, right, bottom, top = 168.0, 412.0, 72.0, 220.0
    axis_max = 15.0

    def x(value: float) -> float:
        return left + (value / axis_max) * (right - left)

    page.text(18, 274, title, 11.5, (0.10, 0.16, 0.22))
    for tick in range(0, 16, 3):
        tx = x(float(tick))
        page.line(tx, bottom, tx, top, (0.89, 0.90, 0.91), 0.55)
        page.text(tx - (3 if tick < 10 else 6), bottom - 14, str(tick), 8, muted)
    page.line(left, bottom, right, bottom, (0.35, 0.38, 0.41), 0.8)

    rows = (("nearest_next", "Nearest-Next", 174.0), ("fcfs", "FCFS", 118.0))
    geometry = matched_savings_geometry(data)
    for baseline, label, y in rows:
        row = data["paired_savings"][baseline]
        coords = geometry[baseline]
        page.text(18, y + 4, label, 9, (0.12, 0.15, 0.19))
        page.text(18, y - 10, f"{row['n']} matched snapshots", 8, muted)
        page.line(coords["low"], y, coords["high"], y, blue, 2.1)
        page.line(coords["low"], y - 5, coords["low"], y + 5, blue, 1.1)
        page.line(coords["high"], y - 5, coords["high"], y + 5, blue, 1.1)
        page.rect(coords["estimate"] - 3.2, y - 3.2, 6.4, 6.4, blue)
        page.text(coords["estimate"] + 5, y + 6, f"{row['estimate']:.2f}", 8, blue)

    axis_label = "Matched-task road-distance savings (km)"
    page.text(104, 39, axis_label, 8.5, (0.20, 0.23, 0.26))
    page.text(18, 19, "Positive values favour CP-SAT.", 8, muted)
    return page


def find_pdftoppm(override: str | None) -> str:
    executable = override or shutil.which("pdftoppm")
    if not executable:
        raise FileNotFoundError("Poppler pdftoppm is required to export 300-dpi PNG files")
    return executable


def generate(run: Path, output: Path | None = None, pdftoppm: str | None = None) -> Path:
    data = collect_data(run)
    output = (output or (data["run"] / "figures")).resolve()
    if output.exists():
        raise FileExistsError(f"Refusing to overwrite figure directory: {output}")
    renderer = find_pdftoppm(pdftoppm)
    output.mkdir(parents=True)
    figures = {
        "figure6a_valid_task_coverage": coverage_page(data),
        "figure6b_total_road_distance": distance_page(data),
        "figureS1_matched_task_distance_savings": paired_savings_page(data),
    }
    for stem, page in figures.items():
        pdf = output / f"{stem}.pdf"
        pdf.write_bytes(page.pdf_bytes())
        prefix = output / stem
        proc = subprocess.run(
            [renderer, "-singlefile", "-r", "300", "-png", str(pdf), str(prefix)],
            capture_output=True, text=True, check=False,
        )
        if proc.returncode != 0 or not (output / f"{stem}.png").is_file():
            raise RuntimeError(f"pdftoppm failed for {stem}: {proc.stderr.strip()}")

    manifest = {
        "status": "FIGURES_GENERATED_FROM_VERIFIED_RUN",
        "source_run": str(data["run"]),
        "candidate_tasks": 500,
        "admitted_tasks": 500,
        "scenarios": 100,
        "independently_validated_plans": 300,
        "png_resolution_dpi": 300,
        "vector_format": "PDF",
        "renderer": renderer,
        "figure_source_sha256": sha256(Path(__file__)),
        "input_sha256": {name: sha256(path) for name, path in data["sources"].items()},
        "figures": {stem: {"pdf_sha256": sha256(output / f"{stem}.pdf"), "png_sha256": sha256(output / f"{stem}.png")} for stem in figures},
        "data_rules": {
            "coverage": "served_tasks / valid_tasks, aggregated across 100 scenario results; counts are labelled",
            "aggregate_distance": "descriptive total; served task identities differ across methods",
            "paired_savings": "Hodges-Lehmann and bootstrap interval from the verified paired analysis; identical served-task sets only",
        },
    }
    (output / "figure_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return output


def generate_matched_task_savings(run: Path, output: Path | None = None, pdftoppm: str | None = None) -> Path:
    """Add the compact main E4 savings figure without replacing existing figures."""
    data = collect_data(run)
    output = (output or (data["run"] / "figures")).resolve()
    if output.exists() and not output.is_dir():
        raise NotADirectoryError(f"Figure output is not a directory: {output}")
    output.mkdir(parents=True, exist_ok=True)
    stem = "figure6_e4_matched_task_savings"
    pdf, png = output / f"{stem}.pdf", output / f"{stem}.png"
    manifest_path = output / "figure_manifest.json"
    for target in (pdf, png):
        if target.exists():
            raise FileExistsError(f"Refusing to overwrite existing figure: {target}")
    existing_manifest = None
    if manifest_path.exists():
        existing_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if existing_manifest.get("source_run") != str(data["run"]):
            raise ValueError("Existing figure manifest belongs to a different E4 run")

    pdf.write_bytes(matched_task_savings_page(data).pdf_bytes())
    renderer = find_pdftoppm(pdftoppm)
    proc = subprocess.run(
        [renderer, "-singlefile", "-r", "300", "-png", str(pdf), str(output / stem)],
        capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0 or not png.is_file():
        raise RuntimeError(f"pdftoppm failed for {stem}: {proc.stderr.strip()}")

    if existing_manifest is None:
        manifest = {
            "status": "FIGURES_GENERATED_FROM_VERIFIED_RUN",
            "source_run": str(data["run"]),
            "candidate_tasks": 500,
            "admitted_tasks": 500,
            "scenarios": 100,
            "independently_validated_plans": 300,
            "png_resolution_dpi": 300,
            "vector_format": "PDF",
            "figures": {},
        }
    else:
        manifest = existing_manifest
    manifest.update({
        "status": "FIGURES_GENERATED_FROM_VERIFIED_RUN",
        "source_run": str(data["run"]),
        "png_resolution_dpi": 300,
        "vector_format": "PDF",
        "renderer": renderer,
        "figure_source_sha256": sha256(Path(__file__)),
        "input_sha256": {name: sha256(path) for name, path in data["sources"].items()},
    })
    manifest.setdefault("figures", {})[stem] = {
        "pdf_sha256": sha256(pdf),
        "png_sha256": sha256(png),
        "data_source": "statistical_analysis/paired_tests.csv; identical served-task sets only",
        "axis": "Matched-task road-distance savings (km); positive values favour CP-SAT",
    }
    (output / "figure_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return output


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, required=True, help="Completed and independently verified E4 run")
    parser.add_argument("--output", type=Path, help="New output directory (default: <run>/figures)")
    parser.add_argument("--pdftoppm", help="Optional Poppler renderer path")
    parser.add_argument("--matched-savings-only", action="store_true", help="Add only the compact main matched-task savings figure without replacing existing figures")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    run = args.run if args.run.is_absolute() else root / args.run
    output = args.output if args.output is None or args.output.is_absolute() else root / args.output
    if args.matched_savings_only:
        print(generate_matched_task_savings(run, output, args.pdftoppm))
    else:
        print(generate(run, output, args.pdftoppm))


if __name__ == "__main__":
    main()
