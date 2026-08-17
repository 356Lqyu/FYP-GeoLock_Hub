from pathlib import Path
import pandas as pd

# Define paths relative to repository root for modular offline execution
REPO_ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = REPO_ROOT / "benchmark"
RESULTS_DIR = REPO_ROOT / "results"
SEED = 42 # Global frozen random seed for reproducibility across runs

def read_csv(name: str) -> pd.DataFrame:
    return pd.read_csv(DATA_DIR / name)

def save_csv(df: pd.DataFrame, name: str) -> None:
    RESULTS_DIR.mkdir(exist_ok=True)
    df.to_csv(RESULTS_DIR / name, index=False)
