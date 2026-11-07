"""Offline frozen v3.3 plan/validation sample inside a capped Linux container."""
from time import perf_counter
START=perf_counter()
import hashlib
import json
from pathlib import Path
import resource
import sys
sys.path.insert(0,'/app')

from backend.routing.contract import freeze_scenario
from backend.routing.phase_b import METHODS,validate_plan
from backend.routing.phase_b.models import ExecutionConfig

raw=Path('/fixtures/frozen.json').read_bytes();data=json.loads(raw);cases=[]
for item in data['cases']:
    snapshot=freeze_scenario(item['input'])
    assert snapshot.sha256==item['snapshot_sha256'] and snapshot.matrix_sha256==item['matrix_sha256']
    result=dict(scenario_id=item['scenario_id'],admitted_tasks=len(snapshot.admitted_task_ids),methods=[])
    for name,solve in METHODS.items():
        began=perf_counter();plan=solve(snapshot,ExecutionConfig());duration=perf_counter()-began
        began=perf_counter();check=validate_plan(snapshot,plan);validation=perf_counter()-began
        assert check.valid
        result['methods'].append(dict(method=name,seconds=duration,validation_seconds=validation,valid=check.valid,
            feasible=check.feasible,timeout=plan.timeout,solver_statuses=plan.solver_statuses,
            coverage_optimal=plan.coverage_optimal))
    cases.append(result)
root=Path('/sys/fs/cgroup')
print(json.dumps(dict(scope=data['scope'],fixture_sha256=hashlib.sha256(raw).hexdigest(),cases=cases,
    total_seconds=perf_counter()-START,process_peak_rss_bytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss*1024,
    process_cpu_seconds=resource.getrusage(resource.RUSAGE_SELF).ru_utime+resource.getrusage(resource.RUSAGE_SELF).ru_stime,
    cgroup={n:(root/n).read_text().strip() for n in ('memory.max','memory.peak','memory.events','cpu.max','cpu.stat')})))
