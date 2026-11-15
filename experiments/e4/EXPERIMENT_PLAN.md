# E4 experiment plan — Post-claim route planning

## 1. Research questions

With the same claimed pickups and vehicle rules, does the app's route planner serve more pickups than simple rules? On snapshots where the planners serve exactly the same pickups, does the app planner drive less?

## 2. Dataset

The [frozen benchmark](../../benchmark%20dataset/dataset/) supplies 100 route-planning snapshots with five admitted pickups each. Fifty snapshots have one vehicle and fifty have two. The four profiles cover ordinary routing, connectivity stress, capacity pressure, and geographic spread.

All three methods receive the same 500 task IDs. A task is admitted when it may be considered for routing. A served task is one that actually appears in a valid plan. The older 483-task diagnostic included a synthetic listing expiry. Current post-claim routing ignores that legacy field and retains the checks for claim lease, owner, status, and pickup window.

## 3. Methods and rules

| Method | How it plans |
| --- | --- |
| Nearest-Next | Takes the closest feasible pickup next. |
| FCFS | Takes the oldest feasible task next. |
| OR-Tools CP-SAT | Maximizes the number of served pickups, then minimizes total road distance at that number. |

The planner uses the shared [backend optimizer](../../backend/routing/optimizers/cp_sat.py). All methods use directed road distances, start and return at the depot, make at most one trip per vehicle, obey capacity and pickup windows, and use a 240-minute route limit with 10 minutes of service per stop.

## 4. Measures

1. Check every plan independently for valid routes and constraint violations.
2. Compare pickups served across all 100 snapshots. Count snapshots that serve every admitted pickup.
3. Report aggregate distance, driving time, and planning time. Compare distance and driving time in pairs only when the two valid plans serve exactly the same task IDs.

Coverage charts use descriptive Wilson intervals. Compare each snapshot's served count with a paired Wilcoxon–Pratt test and its full-coverage outcome with an exact McNemar test. Matched-task distance and time use Wilcoxon–Pratt tests, Hodges–Lehmann effects with 10,000-resample bootstrap intervals, and Holm adjustment across the four distance and time comparisons.

## 5. Execution flow

1. Verify the environment, frozen inputs, and admission.
2. Run all three methods under one run ID and independently check each plan.
3. Generate the comparison tables and figures in staging.
4. Verify the staged evidence, then publish it to the stable output paths. Follow the [run guide](README.md#how-to-run) to run and verify it.

## 6. Interpretation and limits

Use the matched comparisons to explain savings for the same pickups. Aggregate distance can cover different tasks. Pickup counts within a snapshot share the same vehicle constraints, so the Wilson intervals are descriptive. The benchmark does not model live traffic, repeated vehicle trips, or fleets larger than two vehicles.
