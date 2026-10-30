"""Hub-ranking API.

POST /v1/hub-ranking reads the donation's hubs from Supabase as the signed-in donor,
ranks the feasible ones with the model and returns all hubs, ranked ones first.
"""
import json
import logging
import os
import sys
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
sys.path.insert(0, str(HERE.parent))
import hub_ranking_core as core  # noqa: E402


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
MODEL_DIR = Path(os.environ.get('MODEL_DIR', core.MODEL_DIR))
UNKNOWN_CATEGORY_PENALTY = float(os.environ.get('UNKNOWN_CATEGORY_PENALTY', '0.5'))
LOG_PATH = Path(os.environ.get('RECOMMENDATION_LOG', HERE / 'logs' / 'recommendations.jsonl'))
TIMEOUT = float(os.environ.get('SUPABASE_TIMEOUT_SECONDS', '8'))

log = logging.getLogger('hub-ranking')
logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')

try:
    MODEL, META = core.load_model(MODEL_DIR)
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

CATEGORY_ALIASES = {'clothes': 'clothing', 'apparel': 'clothing', 'book': 'books',
                    'electronic': 'electronics', 'appliance': 'appliances',
                    'food & beverages': 'food', 'groceries': 'food'}


def benchmark_category(name):
    """Map a database category name to a benchmark category (None if unknown)."""
    name = name.strip().lower()
    name = CATEGORY_ALIASES.get(name, name)
    if name in core.HANDLING_PENALTY:
        return name
    for key in core.HANDLING_PENALTY:  # e.g. "Books & Stationery" -> books
        if key in name or key.rstrip('s') in name.split():
            return key
    return None


def handling_penalty(items):
    """Highest penalty among the donation's item categories (most demanding item)."""
    penalties, assumed = [], []
    for item in items or []:
        name = benchmark_category(str(item.get('category') or ''))
        if name is not None:
            penalties.append(core.HANDLING_PENALTY[name])
        else:
            penalties.append(UNKNOWN_CATEGORY_PENALTY)
            assumed.append(str(item.get('category') or 'unknown'))
    if not penalties:
        return UNKNOWN_CATEGORY_PENALTY, ['no items']
    return max(penalties), assumed


def feature_rows(options, weight, penalty):
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
                         donation_weight_kg=float(weight), handling_penalty=float(penalty)))
    return rows


def explain(row, n, mode):
    basis = 'AI model' if mode == 'MODEL' else 'reference rule'
    return (f"{row['road_distance_km']:.1f} km by road, {100 * row['utilisation_ratio']:.0f}% full; "
            f"best {basis} score of {n} hub{'s' if n != 1 else ''} that can take this donation.")


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
    weight = detail.get('total_weight_kg')
    if weight is None:
        raise HTTPException(status_code=400, detail=dict(message='Donation has no weight'))
    penalty, assumed = handling_penalty(detail.get('items'))
    rows = feature_rows(options, weight, penalty)

    mode = 'MODEL' if MODEL is not None else 'REFERENCE_FALLBACK'
    ranked = []
    if rows:
        if mode == 'MODEL':
            try:
                X = np.asarray([[r[f] for f in core.FEATURES] for r in rows])
                scores = MODEL.predict(X).tolist()
            except Exception as error:
                log.exception('Model prediction failed: %s', error)
                mode, scores = 'REFERENCE_FALLBACK', core.reference_scores(rows)
        else:
            scores = core.reference_scores(rows)
        ranked = core.rank(rows, scores)
    feasible_ids = {r['hub_id'] for r in rows}
    by_id = {str(o['hub_id']): o for o in options}
    response_rows = []
    for position, r in enumerate(ranked, 1):
        response_rows.append(dict(by_id[r['hub_id']], rank=position, ai_score=r['score'],
                                  recommended=position == 1, in_top_k=position <= core.TOP_K,
                                  explanation=explain(r, len(ranked), mode) if position == 1 else None))
    for o in options:  # infeasible hubs keep the database order
        if str(o['hub_id']) not in feasible_ids:
            response_rows.append(dict(o, rank=None, ai_score=None, recommended=False,
                                      in_top_k=False, explanation=None))
    result = dict(
        donation_id=body.donation_id, recommendation_id=str(uuid.uuid4()),
        ranking_mode=mode if ranked else 'NO_FEASIBLE_HUB',
        model_version=META.get('model_version') if mode == 'MODEL' else None,
        top_k=[r['hub_id'] for r in ranked[:core.TOP_K]],
        recommended_hub_id=ranked[0]['hub_id'] if ranked else None,
        confidence_margin=round(ranked[1]['score'] - ranked[0]['score'], 9) if len(ranked) > 1 else None,
        features_assumed=dict(unknown_categories=assumed) if assumed else None,
        generated_at=datetime.now(timezone.utc).isoformat(timespec='seconds'),
        hubs=response_rows)
    _log_recommendation(result, rows, ranked, time.perf_counter() - started)
    return result


def _log_recommendation(result, rows, ranked, seconds):
    """Append the recommendation to the log file."""
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        record = {k: result[k] for k in ('recommendation_id', 'donation_id', 'ranking_mode', 'model_version',
                                          'top_k', 'recommended_hub_id', 'confidence_margin',
                                          'features_assumed', 'generated_at')}
        record.update(hard_rules='database get_hub_options (feasible = true)',
                      candidates=[dict(r) for r in ranked] if ranked else [dict(r) for r in rows],
                      latency_ms=round(seconds * 1000, 1))
        with LOG_PATH.open('a', encoding='utf-8') as stream:
            stream.write(json.dumps(record) + '\n')
    except OSError as error:
        log.warning('Could not write recommendation log: %s', error)
