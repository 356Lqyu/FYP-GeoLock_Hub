# AI hub-ranking API (FastAPI)

**What it is:** the small web service that lets the Flutter app use the AI model. The app
cannot run a Python model itself, so when a donor opens "Choose a drop-off hub", the app sends
the donation ID here; this service loads the model from `../model/`, ranks the hubs and sends
the order back. Render runs this folder online (`Dockerfile`, `render.yaml` at the repository
root), so the app works without your laptop. If it is down, the app falls back to "nearest
first".

| File | What it does |
| --- | --- |
| `main.py` | the service: reads the hubs from Supabase, ranks them with the model, returns the order |
| `requirements.txt` | the packages it needs (FastAPI, uvicorn, httpx, plus the model libraries) |
| `Dockerfile` | how Render builds it (copies `main.py` and `../model/`) |
| `start_api.bat` | run it on your own PC for testing (http://localhost:8000) |
| `.env.example` | Supabase URL and public key for a local run (copy to `.env`) |

```
Flutter (donor signed in)
   │  POST /v1/hub-ranking  {donation_id}   Authorization: Bearer <Supabase access token>
   ▼
FastAPI (this folder)
   ├─ Supabase RPC get_hub_options(p_donation, p_dropoff_date) ← hard rules for that day decide "feasible"
   ├─ Supabase RPC get_my_donation_detail(p_donation)  ← weight + item categories
   ├─ Supabase tables donation_categories.needs_* / community_hubs.has_*  ← storage the items need / hubs have
   ├─ rank ONLY feasible hubs: model score (lower = better), ties → road km → hub_id
   │      model missing/broken → REFERENCE_FALLBACK (the weighted reference rule)
   └─ returns all hubs: feasible in ranked order (+ rank, ai_score, recommended,
      explanation), then infeasible ones with their reasons
   ▼
Flutter shows rank 1 as "Recommended"; booking still calls reserve_hub_capacity,
which re-checks capacity, category, hours and route in the database.
```

Both Supabase calls run **as the donor** (their token is forwarded), so the database's own
ownership and state checks apply. Only the public publishable key is used, and the API can't
reserve, claim or change any data (Authority Contract INV-07: AI is advisory only).

## Quick start

Double-click `start_api.bat` (or run it in a terminal). It starts the API and links any
Android phone (USB) or emulator that is connected, so the app finds the API at
`http://127.0.0.1:8000` by itself. Then press Run in Android Studio. No `--dart-define` needed.

If you plug the phone in after starting the API, run `adb reverse tcp:8000 tcp:8000` once
(or restart `start_api.bat`).

## Run it (Windows, from the repository root)

```powershell
py -m venv .venv
.venv\Scripts\activate
pip install -r "ai hub ranking/api/requirements.txt"
copy "ai hub ranking\api\.env.example" "ai hub ranking\api\.env"
cd "ai hub ranking/api"
uvicorn main:app --host 0.0.0.0 --port 8000
```

Open http://localhost:8000/health. It should show `"ranking_mode": "MODEL"` and the model version.
Swagger UI for manual testing is at http://localhost:8000/docs.

`--host 0.0.0.0` lets the emulator or phone reach your PC. Allow Python through Windows Firewall
the first time it asks.

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/health` | Status, ranking mode, model version |
| POST | `/v1/hub-ranking` | Rank the hubs for one donation and drop-off day (body `{"donation_id": "<uuid>", "dropoff_date": "2026-11-05"}`; `dropoff_date` is optional: default today, up to 6 days ahead) |

Errors from the database (e.g. `DONATION_NOT_HUB_ELIGIBLE`, `UNAUTHENTICATED`) come back as
HTTP 400 with `detail.message`. When the service fails, the app falls back to `get_hub_options`
directly, which shows the same database error to the donor.

Each ranked hub in the response also has `handling_penalty` and `storage_note` (e.g. "Has the
storage these items need" or "No lockable storeroom"), which the app shows as a chip.

## Recommendation log

Every response is appended to `logs/recommendations.jsonl` (recommendation id, donation,
ranking mode, model version, all candidates with their features and scores, Top-3, selected
hub, confidence margin, latency). This is advisory evidence for Chapter 5, not
authoritative state.

## Mapping from the database to the model features

| Model feature | Source |
| --- | --- |
| road_distance_km | `get_hub_options.road_km` |
| utilisation_ratio | `get_hub_options.utilisation_ratio` (stored / capacity) |
| capacity_pressure | `get_hub_options.capacity_pressure` (weight / remaining capacity) |
| donation_weight_kg | `get_my_donation_detail.total_weight_kg` |
| handling_penalty | Hub-specific. The donation's storage needs are the ticks of its item categories (`donation_categories.needs_*`); each hub's facilities are its ticks (`community_hubs.has_*`), both read directly from the tables (column-level grants, no extra function). Base = highest need (none 0.10, fragile shelving 0.40, lockable storeroom 0.40, food-safe storage 0.60, vehicle access 0.80); value at a hub = base × (1 − 0.5 × share of the needs the hub meets). Nobody enters a number, and new categories need no retraining. A category with nothing ticked is guessed from its name. If the columns are not there yet, needs are guessed from the category names and every hub gets the base value (`storage_needs_source` says which). |

## Put it online (for public use)

The app should not depend on a laptop. Host the API once and every phone uses it.

Files: `api/Dockerfile`, `render.yaml` and `.dockerignore` (both at the repository root).

**Render (free):**
1. Push the repository to GitHub (including `ai hub ranking/model/`).
2. On https://render.com, sign in with GitHub, then New + > Blueprint > choose the repository.
   Render reads `render.yaml` and builds the image.
3. When it is live, open `https://<name>.onrender.com/health`. It should show `"ranking_mode": "MODEL"`.
4. In `frontend/geolock_hub_app/lib/hub_admin/hub_service.dart`, set
   `const hostedRankingApiUrl = 'https://<name>.onrender.com';` and rebuild the app.

The free plan sleeps after 15 minutes without requests. The first request after that takes
about a minute, and the app shows the nearest-first order meanwhile. A free uptime monitor
(e.g. UptimeRobot) calling `/health` every 10 minutes keeps it awake, or use a paid plan.

The same Dockerfile also runs on Google Cloud Run, Railway or Fly.io.

```powershell
docker build -f "ai hub ranking/api/Dockerfile" -t geolock-hub-ranking .
docker run -p 8000:8000 geolock-hub-ranking
```
