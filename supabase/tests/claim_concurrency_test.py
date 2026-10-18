"""Run claim concurrency acceptance cases against a disposable Supabase project only.

Required environment variables:
  GEOLOCK_TEST_SUPABASE_URL
  GEOLOCK_TEST_ISOLATED_CONFIRMATION=I_CONFIRM_DISPOSABLE_DEV_PROJECT
  GEOLOCK_TEST_ALLOWED_PROJECT_REFS=exact-disposable-project-ref
  GEOLOCK_TEST_PUBLISHABLE_KEY
  GEOLOCK_TEST_SERVICE_ROLE_KEY
  GEOLOCK_TEST_NGO_JWT_TOKENS  JSON array of 50 eligible NGO access tokens
  GEOLOCK_TEST_LISTING_IDS     JSON array of 3 distinct AVAILABLE listing UUIDs

Do not point this at the shared/live Supabase project. The exact project
reference must be explicitly allowlisted and the disposable-project guard
must be set. This script uses a service-role JWT only from the test process
environment to verify the committed active-claim count.
"""

from __future__ import annotations

import concurrent.futures
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from urllib.parse import urlparse

BLOCKED_PROJECT_REF = "mffccmlimmbrgasgfnnq"
CONFIRMATION = "I_CONFIRM_DISPOSABLE_DEV_PROJECT"
COUNTS = (2, 10, 50)


def required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def request_json(url: str, headers: dict[str, str], payload: object | None = None):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="GET" if data is None else "POST")
    try:
        with urllib.request.urlopen(req, timeout=35) as response:
            body = response.read().decode("utf-8")
            return json.loads(body) if body else None
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"Supabase test request failed with HTTP {exc.code}") from None
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Supabase test request did not complete: {exc.reason}") from None


def main() -> int:
    if required("GEOLOCK_TEST_ISOLATED_CONFIRMATION") != CONFIRMATION:
        raise RuntimeError("Refusing to run without disposable development-project confirmation.")
    base_url = required("GEOLOCK_TEST_SUPABASE_URL").rstrip("/")
    if urlparse(base_url).scheme != "https":
        raise RuntimeError("Development Supabase URL must use HTTPS.")
    host = urlparse(base_url).hostname or ""
    suffix = ".supabase.co"
    if not host.endswith(suffix):
        raise RuntimeError("Use canonical https://<project-ref>.supabase.co URL.")
    project_ref = host[:-len(suffix)]
    allowed = {part.strip() for part in required("GEOLOCK_TEST_ALLOWED_PROJECT_REFS").split(",") if part.strip()}
    if project_ref == BLOCKED_PROJECT_REF or project_ref not in allowed:
        raise RuntimeError("Refusing to run against the shared/live GeoLock Hub project.")
    inherited_url = os.environ.get("SUPABASE_URL", "").strip()
    if inherited_url:
        inherited_host = urlparse(inherited_url).hostname or ""
        if not inherited_host.endswith(suffix) or inherited_host[:-len(suffix)] != project_ref:
            raise RuntimeError("Inherited SUPABASE_URL points to a different project; refusing to run.")
    publishable_key = required("GEOLOCK_TEST_PUBLISHABLE_KEY")
    service_role_key = required("GEOLOCK_TEST_SERVICE_ROLE_KEY")
    tokens = json.loads(required("GEOLOCK_TEST_NGO_JWT_TOKENS"))
    listing_ids = json.loads(required("GEOLOCK_TEST_LISTING_IDS"))
    if not isinstance(tokens, list) or len(tokens) < 50:
        raise RuntimeError("Provide 50 eligible NGO JWTs from the disposable test project.")
    if not isinstance(listing_ids, list) or len(listing_ids) != len(COUNTS):
        raise RuntimeError("Provide exactly 3 distinct prepared listing UUIDs.")
    if len(set(listing_ids)) != len(COUNTS):
        raise RuntimeError("Each concurrency size needs a distinct listing.")

    results = []
    for round_index, (count, listing_id) in enumerate(zip(COUNTS, listing_ids)):
        attempts = [
            {"token": tokens[index], "request_id": str(uuid.uuid4())}
            for index in range(count)
        ]

        def claim(attempt: dict[str, str]):
            return request_json(
                f"{base_url}/rest/v1/rpc/claim_listing",
                {
                    "apikey": publishable_key,
                    "Authorization": f"Bearer {attempt['token']}",
                    "Content-Type": "application/json",
                },
                {"p_listing": listing_id, "p_request": attempt["request_id"]},
            )

        with concurrent.futures.ThreadPoolExecutor(max_workers=count) as pool:
            responses = list(pool.map(claim, attempts))
        successes = [row for row in responses if row.get("outcome") == "SUCCESS"]
        if len(successes) != 1:
            raise RuntimeError(f"{count}-way claim race returned {len(successes)} winners, expected exactly one.")
        if any(row.get("outcome") not in {"SUCCESS", "CONFLICT"} for row in responses):
            raise RuntimeError(f"{count}-way race returned a non-conflict failure; check test fixture eligibility.")

        query = urllib.parse.urlencode({
            "listing_id": f"eq.{listing_id}",
            "claim_status": "eq.ACTIVE",
            "select": "claim_id",
        })
        active = request_json(
            f"{base_url}/rest/v1/donation_claims?{query}",
            {"apikey": service_role_key, "Authorization": f"Bearer {service_role_key}"},
        )
        if not isinstance(active, list) or len(active) != 1:
            raise RuntimeError(f"{count}-way race committed {len(active) if isinstance(active, list) else 'unknown'} active claims.")

        winner_index = next(i for i, row in enumerate(responses) if row.get("outcome") == "SUCCESS")
        winner_attempt = attempts[winner_index]
        replay = claim(winner_attempt)
        if replay.get("outcome") != "SUCCESS" or replay.get("claim_id") != successes[0].get("claim_id") or replay.get("replayed") is not True:
            raise RuntimeError("Winner request-ID replay did not return the same committed claim.")
        results.append({"concurrency": count, "winner_count": 1, "active_claim_count": 1, "replay": "same claim"})

    print(json.dumps({"project": "disposable test project", "results": results}, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # Keep credentials and response bodies out of logs.
        print(f"TEST BLOCKED/FAILED: {error}", file=sys.stderr)
        sys.exit(1)
