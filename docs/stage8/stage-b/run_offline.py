"""Recheck the Stage A module set without overwriting its historical evidence."""
import importlib.util
import json
from pathlib import Path
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[3]
spec=importlib.util.spec_from_file_location('stage_a_offline',ROOT/'docs/stage8/stage-a/run_offline.py')
runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
original=Path.write_text
target=ROOT/'results/stage-b/offline-results.json'

def write(path,data,*args,**kwargs):
    if path==runner.HERE/'offline-results.json':
        evidence=json.loads(data)
        evidence['scope']='STAGE_B_OFFLINE_REGRESSION_OF_CURRENT_SOURCE'
        return original(target,json.dumps(evidence,indent=2)+'\n',*args,**kwargs)
    return original(path,data,*args,**kwargs)

if __name__=='__main__':
    target.parent.mkdir(parents=True,exist_ok=True)
    with patch.object(Path,'write_text',write):
        raise SystemExit(runner.main())
