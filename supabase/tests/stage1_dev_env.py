"""Small, non-shell dotenv reader for local DEV test credentials."""
from __future__ import annotations

import os
from pathlib import Path


def default_generated_env() -> Path:
    root = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
    return root / "GeoLockHub" / "dev" / "stage1-generated.env"


def load_env_file(path: str | None = None) -> Path:
    selected = Path(path or os.environ.get("GEOLOCK_DEV_ENV_FILE") or default_generated_env())
    if not selected.is_file():
        raise RuntimeError(
            f"DEV environment file not found at {selected}; run the fixture setup first."
        )
    for line_number, raw in enumerate(selected.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise RuntimeError(f"Malformed DEV environment line {line_number}.")
        name, value = line.split("=", 1)
        name, value = name.strip(), value.strip()
        if not name or not name.replace("_", "").isalnum():
            raise RuntimeError(f"Malformed variable name on DEV environment line {line_number}.")
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        os.environ[name] = value
    return selected
