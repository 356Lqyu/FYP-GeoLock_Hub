# GeoLock Hub Routing Backend

GeoLock Hub generates collection routes for non-governmental organisations
(NGOs) from donation pickups they have claimed. It uses the road network for
Kuala Lumpur, Selangor and Putrajaya, Google OR-Tools CP-SAT to plan routes, and
a separate validator to check the proposed routes before the NGO can start them.

## How It Works

1. The NGO selects **Generate Route** in Flutter. The app asks Supabase to prepare
   a snapshot, which is a record of the data for this planning request.
2. The planner reads that snapshot from Supabase. It includes eligible pickup
   tasks, vehicle information and the NGO's depot.
3. The road network module calculates road distances and travel times between
   the depot and pickup locations.
4. The planner runs the three routing methods on the same input and saves the
   feasible CP-SAT proposal for validation.
5. The independent validator reads the proposal and its inputs from Supabase.
   It checks the route and records the result.
6. Flutter displays the validated proposal for the NGO to review.
7. The NGO selects **Start Route**. Flutter asks Supabase to authorise the
   proposal and start the first pickup in one database transaction.
8. The NGO uses Flutter to record pickups, confirm the return to the depot
   and close the route.

**Generate Route** produces a proposal for review. Dispatch begins only when the
NGO selects **Start Route** and Supabase approves the request.

### Planner and Validator

The planner uses CP-SAT to find routes. The validator runs as a separate process
and reads the saved proposal and original inputs from Supabase. It checks the
stop order, timings, vehicle loads and return to the depot by recalculating the
route details directly. This gives the app an independent check before the
proposal is shown. Supabase handles the decision to authorise and start it.

## Routing Algorithms

All three methods use the same pickup tasks, vehicles and road travel data so
their results can be compared on equal terms.

- **First Come, First Served (FCFS)** considers the oldest pickup task first
  and adds it when it fits the current route.
- **Nearest Neighbour** tries the closest remaining pickup by road distance.
  It adds the closest one that fits the route.
- **OR-Tools CP-SAT** is the proposed method. It considers how to assign pickups
  across vehicles and in what order to visit them. It first aims to serve the
  most eligible pickup tasks. For the same number of tasks, it aims to minimise
  the configured routing cost, which is the total road distance in the current
  system.

Each method accounts for vehicle capacity, pickup time windows, road distance
and travel time, and the maximum duration for each vehicle's depot-to-depot
route. The app uses the checked CP-SAT result as its proposal. FCFS and Nearest
Neighbour provide comparison results.

## Project Structure

```text
backend/routing/
|-- contract.py
|-- environment.py
|-- route_plan.py
|-- snapshot.py
|-- requirements.txt
|-- planner/
|   |-- planning.py
|   |-- baselines.py
|   +-- cp_sat.py
|-- validator/
|   +-- validation.py
|-- road_network/
|   |-- graph_cache.py
|   +-- matrix.py
|-- service/
|   |-- planner_service.py
|   +-- validator_service.py
|-- database/
|   +-- supabase_rpc.py
|-- windows/
|-- diagnostics/
+-- tests/
```

| Folder | Responsibility |
| --- | --- |
| `planner/` | Prepares the routing input and runs the three methods. |
| `validator/` | Checks proposed routes against their original inputs. |
| `road_network/` | Loads the road network and calculates distances and travel times. |
| `service/` | Runs the planner and validator services and returns results to Flutter. |
| `database/` | Connects the workers to Supabase and calls database functions. |
| `windows/` | Provides PowerShell scripts for setup and worker startup. |
| `diagnostics/` | Provides tools for checking worker setup and connections. |
| `tests/` | Contains offline tests and sample routing scenarios. |

| Root file | Responsibility |
| --- | --- |
| `contract.py` | Defines and checks the data that the routing process expects. |
| `environment.py` | Identifies the Supabase project and road network for each environment. |
| `route_plan.py` | Defines the shared representation of routes, stops and results. |
| `snapshot.py` | Converts saved database data into routing inputs and reads saved plans. |
| `requirements.txt` | Lists the pinned Python dependencies for the workers. |

## Technologies Used

- **Python 3.12** runs the planner, validator and offline tests.
- **Google OR-Tools CP-SAT** searches for feasible routes under the routing constraints.
- **Supabase PostgreSQL** stores pickups, vehicles, proposals and route progress.
- **Flutter** lets NGOs generate, review, start and complete collection routes.
- **OpenStreetMap** provides the road data for the KLSEL service area.
- **PowerShell** starts and checks the workers on Windows.

<a name="start-the-planner-and-validator-windows"></a>

## Running the Backend

Run these commands from the repository root in PowerShell. They assume the
`.venv-stage8` Python environment and both KLSEL worker profiles are set up.

1. Run the offline setup check.

   ```powershell
   .\backend\routing\windows\Test-LocalRoutingSetup.ps1 -Environment KLSEL
   ```

2. Start the validator in a separate terminal.

   ```powershell
   .\backend\routing\windows\Start-Worker.ps1 -Environment KLSEL -Mode validator -Activate -ApprovalRef 'APPROVED_REFERENCE'
   ```

3. Start the planner in another terminal.

   ```powershell
   .\backend\routing\windows\Start-Worker.ps1 -Environment KLSEL -Mode planner -Activate -ApprovalRef 'APPROVED_REFERENCE'
   ```

4. Check both workers from a third terminal. Both should report `ACTIVE` and
   the KLSEL project reference (`ppwmdsyoesvhgmqiaoxa`).

   ```powershell
   Invoke-RestMethod 'http://127.0.0.1:8788/health'
   Invoke-RestMethod 'http://127.0.0.1:8787/health'
   ```

<a name="what-each-switch-does"></a>

Replace `APPROVED_REFERENCE` in each startup command with the actual approved
reference. `-Environment` selects the project and profiles, `-Mode` chooses
the worker, and `-Activate` enables it for routing requests.

Set Flutter to use the KLSEL Supabase project and point
`GEOLOCK_ROUTING_API_URL` at the planner address reachable from the device.
The planner uses port 8787, while port 8788 is for the validator. For profile
setup, device connection and troubleshooting, see the
[Windows routing guide](../../docs/LOCAL_ROUTING_WINDOWS.md).

## Testing

Run the offline suite from the repository root.

```powershell
$env:PYTHONDONTWRITEBYTECODE = "1"
& .\.venv-stage8\Scripts\python.exe -B -m unittest discover -s backend/routing/tests -t . -v
```

The suite uses sample scenarios and simulated service responses to check road
distances and times, planning constraints, independent validation, and worker
behaviour. It runs without a live Supabase connection.


