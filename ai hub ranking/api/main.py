"""Hub-ranking API.

POST /v1/hub-ranking reads the donation's hubs from Supabase as the signed-in donor,
ranks the feasible ones with the model and returns all hubs, ranked ones first.
"""
import hashlib
import json
import logging
import os
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import httpx
import numpy as np
from fastapi import FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

HERE = Path(__file__).resolve().parent

# ----------------------------------------------------------------------------- ranking rules
# Must match ai hub ranking/1_train_and_select.py, which trained the model.
FEATURES = ('road_distance_km', 'utilisation_ratio', 'capacity_pressure',
            'donation_weight_kg', 'handling_penalty')
TOP_K = 3
REFERENCE_WEIGHTS = dict(distance=.45, utilisation=.20, capacity_pressure=.25, handling=.10)
FACILITIES = ('food_safe_storage', 'fragile_shelving', 'lockable_storeroom', 'vehicle_access')
FACILITY_RELIEF = .5          # every need met -> half the base value
# Base value from the hardest need (same rule as the benchmark generator: clothing 0.1 ...
# electronics 0.4, food 0.6, appliances 0.8).
NO_NEEDS_PENALTY = .10
NEED_PENALTY = dict(fragile_shelving=.40, lockable_storeroom=.40,
                    food_safe_storage=.60, vehicle_access=.80)
# Words in a category name -> needs, for a category with nothing ticked in the database.
NEED_KEYWORDS = dict(
    food_safe_storage=('food', 'grocer', 'rice', 'beverage', 'drink', 'snack', 'milk', 'formula',
                       'canned', 'noodle', 'biscuit'),
    fragile_shelving=('electronic', 'gadget', 'phone', 'computer', 'laptop', 'tablet', 'glass',
                      'ceramic', 'crockery', 'kitchenware', 'porcelain'),
    lockable_storeroom=('electronic', 'gadget', 'phone', 'computer', 'laptop', 'tablet',
                        'appliance', 'medic'),
    vehicle_access=('furniture', 'appliance', 'mattress', 'sofa', 'cabinet', 'wardrobe'))


def guess_needs(category_name):
    name = str(category_name or '').lower()
    return tuple(n for n in FACILITIES if any(w in name for w in NEED_KEYWORDS[n]))


def base_penalty(needs):
    return max([NEED_PENALTY[n] for n in needs], default=NO_NEEDS_PENALTY)


def hub_handling_penalty(base, needs, facilities):
    """base x (1 - 0.5 x share of the needs the hub has); unknown facilities keep the base."""
    needs = list(needs)
    if not needs or facilities is None:
        return round(base, 6)
    met = sum(1 for n in needs if facilities.get(n))
    return round(base * (1 - FACILITY_RELIEF * met / len(needs)), 6)


def reference_scores(rows):
    """Fallback score (the rule the model learned). Distance min-max scaled within the hubs."""
    distances = [r['road_distance_km'] for r in rows]
    lo, hi = min(distances), max(distances)
    w = REFERENCE_WEIGHTS
    return [w['distance'] * (0.0 if hi == lo else (r['road_distance_km'] - lo) / (hi - lo))
            + w['utilisation'] * r['utilisation_ratio'] + w['capacity_pressure'] * r['capacity_pressure']
            + w['handling'] * r['handling_penalty'] for r in rows]


def rank(rows, scores):
    """Lower score first; ties: shorter road distance, then hub_id. Scores rounded to 9 dp."""
    paired = [dict(r, score=round(float(s), 9)) for r, s in zip(rows, scores)]
    return sorted(paired, key=lambda r: (r['score'], r['road_distance_km'], r['hub_id']))


def load_model(model_dir):
    """Load the trained model; refuse it if the file or the feature order does not match."""
    meta = json.loads((model_dir / 'model_metadata.json').read_text(encoding='utf-8'))
    path = model_dir / meta['model_file']
    if hashlib.sha256(path.read_bytes()).hexdigest() != meta['model_sha256']:
        raise ValueError('Model file hash differs from model_metadata.json')
    if tuple(meta['features']) != FEATURES:
        raise ValueError('Model feature order differs from the API')
    if meta['family'] == 'XGBRegressor':
        from xgboost import XGBRegressor
        model = XGBRegressor()
        model.load_model(str(path))
    else:
        import joblib
        model = joblib.load(path)
    return model, meta


def _load_env_file():
    """Read api/.env (KEY=VALUE lines) without an extra dependency."""
    path = HERE / '.env'
    if path.exists():
        for line in path.read_text(encoding='utf-8').splitlines():
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                os.environ.setdefault(key.strip(), value.strip().strip('"'))


_load_env_file()
SUPABASE_URL = os.environ.get('SUPABASE_URL', '').rstrip('/')
SUPABASE_KEY = os.environ.get('SUPABASE_PUBLISHABLE_KEY', '')
MODEL_DIR = Path(os.environ.get('MODEL_DIR', HERE.parent / 'model'))
LOG_PATH = Path(os.environ.get('RECOMMENDATION_LOG', HERE / 'logs' / 'recommendations.jsonl'))
TIMEOUT = float(os.environ.get('SUPABASE_TIMEOUT_SECONDS', '8'))

log = logging.getLogger('hub-ranking')
logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')

try:
    MODEL, META = load_model(MODEL_DIR)
    MODEL_ERROR = None
    log.info('Loaded model %s', META['model_version'])
except Exception as error:  # falls back to the reference score
    MODEL, META, MODEL_ERROR = None, {}, str(error)
    log.warning('Model unavailable, using REFERENCE_FALLBACK: %s', error)

app = FastAPI(title='GeoLock Hub – AI hub ranking', version='1.0.0')
app.add_middleware(CORSMiddleware, allow_origins=['*'], allow_methods=['GET', 'POST'],
                   allow_headers=['Authorization', 'Content-Type'])


class RankRequest(BaseModel):
    donation_id: str = Field(..., description='donations.donation_id (uuid)')


# ----------------------------------------------------------------------------- Supabase

async def supabase_rpc(client, name, params, token):
    """Call a PostgREST RPC as the signed-in user. Database errors become 4xx."""
    response = await client.post(
        f'{SUPABASE_URL}/rest/v1/rpc/{name}', json=params,
        headers={'apikey': SUPABASE_KEY, 'Authorization': f'Bearer {token}',
                 'Content-Type': 'application/json'})
    if response.status_code >= 400:
        try:
            body = response.json()
            message = body.get('message') or body.get('msg') or response.text
        except ValueError:
            message = response.text
        status = 401 if response.status_code in (401, 403) and 'JWT' in message else 400
        raise HTTPException(status_code=status, detail=dict(source=name, message=message))
    return response.json()


def bearer(authorization):
    if not authorization or not authorization.lower().startswith('bearer '):
        raise HTTPException(status_code=401, detail=dict(message='Missing Bearer token'))
    return authorization.split(' ', 1)[1].strip()


# ----------------------------------------------------------------------------- features

NEED_WORDS = dict(food_safe_storage='food-safe storage', fragile_shelving='shelves for fragile items',
                  lockable_storeroom='a lockable storeroom', vehicle_access='vehicle access')


async def supabase_select(client, table, query, token):
    """Read a table as the signed-in user; None if the columns are not there yet."""
    response = await client.get(
        f'{SUPABASE_URL}/rest/v1/{table}', params=query,
        headers={'apikey': SUPABASE_KEY, 'Authorization': f'Bearer {token}'})
    if response.status_code >= 400:
        log.warning('Could not read %s: %s', table, response.text[:200])
        return None
    return response.json()


async def handling_facts(client, token, items, hub_ids):
    """What the donation's items need and what each hub has.

    Needs are the ticks of the item categories (donation_categories.needs_*); a category with
    nothing ticked is guessed from its name. Hub facilities are community_hubs.has_*. If the
    columns are not there, hub facilities are unknown and every hub gets the same value.
    """
    names = {str(i.get('category') or '').strip().lower() for i in items or []} - {''}
    categories = await supabase_select(client, 'donation_categories', {
        'select': 'category_name,' + ','.join(f'needs_{n}' for n in FACILITIES)}, token)
    ticks = {str(c['category_name']).strip().lower(): {n for n in FACILITIES if c.get(f'needs_{n}')}
             for c in categories or []}
    needs = set()
    for name in names:
        needs |= ticks.get(name) or set(guess_needs(name))
    hubs = {}
    if hub_ids:
        rows = await supabase_select(client, 'community_hubs', {
            'select': 'hub_id,' + ','.join(f'has_{n}' for n in FACILITIES),
            'hub_id': f"in.({','.join(hub_ids)})"}, token)
        hubs = {str(h['hub_id']): {n: bool(h.get(f'has_{n}')) for n in FACILITIES}
                for h in rows or []}
    source = 'database' if categories is not None and hubs else 'category names (facilities unknown)'
    return tuple(n for n in FACILITIES if n in needs), hubs, source


def feature_rows(options, weight, needs, hub_facilities):
    base = base_penalty(needs)
    rows = []
    for o in options:
        if o.get('feasible') is not True:
            continue
        values = dict(road_distance_km=o.get('road_km'), utilisation_ratio=o.get('utilisation_ratio'),
                      capacity_pressure=o.get('capacity_pressure'))
        if any(v is None for v in values.values()):
            # Refuse rather than guess a missing feature.
            raise HTTPException(status_code=502, detail=dict(
                message=f"Feasible hub {o.get('hub_id')} is missing a ranking feature"))
        rows.append(dict(hub_id=str(o['hub_id']), road_distance_km=float(values['road_distance_km']),
                         utilisation_ratio=float(values['utilisation_ratio']),
                         capacity_pressure=float(values['capacity_pressure']),
                         donation_weight_kg=float(weight),
                         handling_penalty=hub_handling_penalty(
                             base, needs, hub_facilities.get(str(o['hub_id'])))))
    return rows


def explain(row, n, mode, needs, facilities):
    basis = 'AI model' if mode == 'MODEL' else 'reference rule'
    text = f"{row['road_distance_km']:.1f} km by road, {100 * row['utilisation_ratio']:.0f}% full"
    has = [NEED_WORDS[x] for x in needs if facilities and facilities.get(x)]
    if has:
        text += f"; has {' and '.join(has)}"
    return f"{text}. Best {basis} score of {n} hub{'s' if n != 1 else ''} that can take this donation."


def storage_note(needs, facilities):
    """Plain-language note on the storage this hub has for the donation (None if not needed)."""
    if not needs or facilities is None:
        return None
    missing = [NEED_WORDS[x] for x in needs if not facilities.get(x)]
    if not missing:
        return 'Has the storage these items need'
    return f"No {' or '.join(missing)}"


# ----------------------------------------------------------------------------- endpoints

@app.get('/health')
def health():
    return dict(status='ok', ranking_mode='MODEL' if MODEL is not None else 'REFERENCE_FALLBACK',
                model_version=META.get('model_version'), family=META.get('family'),
                model_error=MODEL_ERROR, supabase_configured=bool(SUPABASE_URL and SUPABASE_KEY))


@app.post('/v1/hub-ranking')
async def rank_hubs(body: RankRequest, authorization: str | None = Header(default=None)):
    if not (SUPABASE_URL and SUPABASE_KEY):
        raise HTTPException(status_code=503, detail=dict(message='SUPABASE_URL / key not configured'))
    try:
        uuid.UUID(body.donation_id)
    except ValueError:
        raise HTTPException(status_code=422, detail=dict(message='donation_id must be a uuid'))
    token = bearer(authorization)
    started = time.perf_counter()
    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        # Fails here for a donation the user does not own or that is not a hub donation.
        options = await supabase_rpc(client, 'get_hub_options', {'p_donation': body.donation_id}, token)
        detail = await supabase_rpc(client, 'get_my_donation_detail', {'p_donation': body.donation_id}, token)
        if not isinstance(options, list) or not isinstance(detail, dict):
            raise HTTPException(status_code=502, detail=dict(message='Unexpected Supabase response'))
        hub_ids = [str(o['hub_id']) for o in options if o.get('hub_id')]
        needs, hub_facilities, needs_source = await handling_facts(
            client, token, detail.get('items'), hub_ids)
    weight = detail.get('total_weight_kg')
    if weight is None:
        raise HTTPException(status_code=400, detail=dict(message='Donation has no weight'))
    rows = feature_rows(options, weight, needs, hub_facilities)

    mode = 'MODEL' if MODEL is not None else 'REFERENCE_FALLBACK'
    ranked = []
    if rows:
        if mode == 'MODEL':
            try:
                X = np.asarray([[r[f] for f in FEATURES] for r in rows])
                scores = MODEL.predict(X).tolist()
            except Exception as error:
                log.exception('Model prediction failed: %s', error)
                mode, scores = 'REFERENCE_FALLBACK', reference_scores(rows)
        else:
            scores = reference_scores(rows)
        ranked = rank(rows, scores)
    feasible_ids = {r['hub_id'] for r in rows}
    by_id = {str(o['hub_id']): o for o in options}
    response_rows = []
    for position, r in enumerate(ranked, 1):
        facilities = hub_facilities.get(r['hub_id'])
        response_rows.append(dict(by_id[r['hub_id']], rank=position, ai_score=r['score'],
                                  recommended=position == 1, in_top_k=position <= TOP_K,
                                  handling_penalty=r['handling_penalty'],
                                  storage_note=storage_note(needs, facilities),
                                  explanation=explain(r, len(ranked), mode, needs, facilities)
                                  if position == 1 else None))
    for o in options:  # infeasible hubs keep the database order
        if str(o['hub_id']) not in feasible_ids:
            response_rows.append(dict(o, rank=None, ai_score=None, recommended=False, in_top_k=False,
                                      handling_penalty=None, explanation=None,
                                      storage_note=storage_note(needs, hub_facilities.get(str(o['hub_id'])))))
    result = dict(
        donation_id=body.donation_id, recommendation_id=str(uuid.uuid4()),
        ranking_mode=mode if ranked else 'NO_FEASIBLE_HUB',
        model_version=META.get('model_version') if mode == 'MODEL' else None,
        preprocessing_version=META.get('preprocessing_version') if mode == 'MODEL' else None,
        top_k=[r['hub_id'] for r in ranked[:TOP_K]],
        recommended_hub_id=ranked[0]['hub_id'] if ranked else None,
        confidence_margin=round(ranked[1]['score'] - ranked[0]['score'], 9) if len(ranked) > 1 else None,
        storage_needs=list(needs), storage_needs_source=needs_source,
        generated_at=datetime.now(timezone.utc).isoformat(timespec='seconds'),
        hubs=response_rows)
    _log_recommendation(result, rows, ranked, time.perf_counter() - started)
    return result


def _log_recommendation(result, rows, ranked, seconds):
    """Append the recommendation to the log file."""
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        record = {k: result[k] for k in ('recommendation_id', 'donation_id', 'ranking_mode', 'model_version',
                                          'preprocessing_version',
                                          'top_k', 'recommended_hub_id', 'confidence_margin',
                                          'storage_needs', 'storage_needs_source', 'generated_at')}
        record.update(hard_rules='database get_hub_options (feasible = true)',
                      candidates=[dict(r) for r in ranked] if ranked else [dict(r) for r in rows],
                      latency_ms=round(seconds * 1000, 1))
        with LOG_PATH.open('a', encoding='utf-8') as stream:
            stream.write(json.dumps(record) + '\n')
    except OSError as error:
        log.warning('Could not write recommendation log: %s', error)
