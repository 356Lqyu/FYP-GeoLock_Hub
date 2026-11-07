"""Usage: python -m backend.routing path/to/scenario.json"""

import argparse
import json
from .contract import ContractError, load_scenario


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate and seal routing inputs; does not plan or dispatch")
    parser.add_argument("scenario")
    args = parser.parse_args()
    try:
        frozen = load_scenario(args.scenario)
    except (ContractError, OSError) as exc:
        print(json.dumps({"status": "INVALID_INPUT", "reason": str(exc)}))
        return 2
    print(json.dumps({"status": frozen.readiness, "sha256": frozen.sha256,
                      "admitted_task_ids": frozen.admitted_task_ids,
                      "excluded_tasks": frozen.excluded_tasks,
                      "available_vehicle_ids": frozen.available_vehicle_ids,
                      "unavailable_arcs": frozen.unavailable_arcs,
                      "dispatch_authority_issued": False}, indent=2))
    return 0 if frozen.readiness == "READY_FOR_PLANNING" else 1


if __name__ == "__main__":
    raise SystemExit(main())
