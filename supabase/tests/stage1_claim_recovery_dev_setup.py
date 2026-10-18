"""Create isolated DEV Auth users and claim-recovery fixtures.

Writes only to the one project reference approved in this script (the supplied
DEV project). This script is intentionally not part of the test runner and was
not executed during preparation. It needs a DEV PostgreSQL connection (direct or
the verified Session Pooler), the DEV service-role JWT, and psycopg 3.
"""
from __future__ import annotations

import argparse
import base64
import os
import secrets
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from urllib.parse import urlparse

from stage1_dev_env import default_generated_env

DEV_PROJECT_REF = "rcgyuwiidqvrgbxswhqj"
BLOCKED_PROJECT_REF = "mffccmlimmbrgasgfnnq"
CONFIRMATION = "I_CONFIRM_DISPOSABLE_DEV_PROJECT"
TYPED_PHRASE = f"CREATE SYNTHETIC FIXTURES IN DEV {DEV_PROJECT_REF}"
NAMESPACE = uuid.UUID("ac44105a-1a5b-473b-9eef-a35d55d89552")
PNG_BYTES = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/X9sAAAAASUVORK5CYII="
)
ROLE_EMAILS = {
    "donor": f"geolock-stage1-donor-{DEV_PROJECT_REF}@example.invalid",
    "ngo": f"geolock-stage1-ngo-{DEV_PROJECT_REF}@example.invalid",
    "ngo2": f"geolock-stage1-ngo2-{DEV_PROJECT_REF}@example.invalid",
}
FIXTURE_KEYS = (
    "expired_safe", "cancel_same", "cancel_distinct", "cancel_start_race",
    "expired_pickup", "cancel_recovery_race", "route_linked_expired",
    "reconcile_positive", "reconcile_dispatched_no_handover",
    "reconcile_conflict", "reconcile_safe_release", "audit_own", "audit_foreign",
)
EXPIRED_KEYS = {
    "expired_safe", "expired_pickup", "cancel_recovery_race", "route_linked_expired"
}
EXPIRY_MINUTES_AGO = {
    "expired_safe": 60,
    "cancel_recovery_race": 50,
    "route_linked_expired": 40,
    "expired_pickup": 30,
}
RECONCILIATION_KEYS = {
    "reconcile_positive", "reconcile_dispatched_no_handover",
    "reconcile_conflict", "reconcile_safe_release"
}
DISPATCHED_KEYS = {
    "reconcile_positive", "reconcile_dispatched_no_handover", "reconcile_conflict"
}
PICKUP_STARTED_KEYS = {
    "reconcile_positive", "reconcile_dispatched_no_handover", "reconcile_conflict"
}


def read_env(path: Path) -> dict[str, str]:
    if not path.is_file():
        raise RuntimeError(f"Configuration file not found: {path}")
    values: dict[str, str] = {}
    for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise RuntimeError(f"Malformed configuration line {line_no}.")
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        if not key.replace("_", "").isalnum():
            raise RuntimeError(f"Malformed variable name on line {line_no}.")
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key] = value
    return values


def require(values: dict[str, str], name: str) -> str:
    value = values.get(name, "").strip()
    if not value or "<" in value or ">" in value or "paste-" in value.lower():
        raise RuntimeError(f"Set {name} to the DEV value in the local setup env file.")
    return value


def target_check(values: dict[str, str]) -> str:
    if require(values, "GEOLOCK_DEV_ISOLATED_CONFIRMATION") != CONFIRMATION:
        raise RuntimeError("Disposable DEV confirmation is missing.")
    if require(values, "GEOLOCK_DEV_PROJECT_REF") != DEV_PROJECT_REF:
        raise RuntimeError("The project reference is not the explicitly approved DEV reference.")
    allowed = {part.strip() for part in require(values, "GEOLOCK_DEV_ALLOWED_PROJECT_REFS").split(",") if part.strip()}
    if allowed != {DEV_PROJECT_REF}:
        raise RuntimeError("Allowlist must contain exactly the supplied DEV project reference.")
    url = require(values, "GEOLOCK_DEV_SUPABASE_URL").rstrip("/")
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.hostname != f"{DEV_PROJECT_REF}.supabase.co" or parsed.path or parsed.query or parsed.fragment:
        raise RuntimeError("Supabase URL does not match the canonical DEV project URL.")
    if DEV_PROJECT_REF == BLOCKED_PROJECT_REF:
        raise RuntimeError("Internal safety check rejected the blocked shared project reference.")
    db_url = require(values, "GEOLOCK_DEV_DATABASE_URL")
    db = urlparse(db_url)
    try:
        db_port = db.port
    except ValueError:
        raise RuntimeError("Database URL has an invalid port.") from None
    query = urllib.parse.parse_qs(db.query, keep_blank_values=True)
    common_valid = (
        db.scheme in {"postgres", "postgresql"}
        and db.path == "/postgres"
        and db.password is not None
        and query.get("sslmode") == ["require"]
        and not db.fragment
    )
    direct_valid = (
        db.hostname == f"db.{DEV_PROJECT_REF}.supabase.co"
        and db.username == "postgres"
        and db_port in {None, 5432}
    )
    pooler_valid = (
        db.hostname == "aws-0-ap-northeast-2.pooler.supabase.com"
        and db_port == 5432
        and db.username == f"postgres.{DEV_PROJECT_REF}"
        and DEV_PROJECT_REF in db.username
    )
    if not (common_valid and (direct_valid or pooler_valid)):
        raise RuntimeError(
            "Database URL must use either the exact DEV direct endpoint or the "
            "verified DEV Session Pooler (postgres.rcgyuwiidqvrgbxswhqj@"
            "aws-0-ap-northeast-2.pooler.supabase.com:5432/postgres), with sslmode=require."
        )
    return url


def safe_request(url: str, key: str, bearer: str, method: str = "GET", payload=None):
    import json

    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url, data=data,
        headers={"apikey": key, "Authorization": f"Bearer {bearer}",
                 "Content-Type": "application/json"},
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            body = response.read()
            return response.status, json.loads(body) if body else None
    except urllib.error.HTTPError as error:
        # Never print response bodies: auth endpoints may echo sensitive values.
        return error.code, None
    except urllib.error.URLError:
        raise RuntimeError("DEV Supabase request failed; verify the DEV URL and network.") from None


def find_auth_user(base: str, publishable: str, service: str, email: str):
    page = 1
    while True:
        code, response = safe_request(
            f"{base}/auth/v1/admin/users?page={page}&per_page=1000",
            publishable, service,
        )
        if code != 200 or not isinstance(response, dict):
            raise RuntimeError(f"Could not inspect DEV Auth users (HTTP {code}).")
        users = response.get("users", [])
        for user in users:
            if user.get("email", "").casefold() == email.casefold():
                return user
        if len(users) < 1000:
            return None
        page += 1


def create_or_reset_user(base: str, publishable: str, service: str, role: str, email: str):
    password = secrets.token_urlsafe(40)
    existing = find_auth_user(base, publishable, service, email)
    metadata = {"full_name": f"GeoLock DEV Fixture {role.upper()}", "fixture": "stage1-claim-recovery"}
    if existing:
        if (existing.get("user_metadata") or {}).get("fixture") != "stage1-claim-recovery":
            raise RuntimeError(
                f"An Auth account already uses the synthetic {role} fixture email but lacks this setup's marker; refusing to reset it."
            )
        user_id = existing["id"]
        code, _ = safe_request(
            f"{base}/auth/v1/admin/users/{user_id}", publishable, service, "PUT",
            {"password": password, "email_confirm": True, "user_metadata": metadata},
        )
    else:
        code, response = safe_request(
            f"{base}/auth/v1/admin/users", publishable, service, "POST",
            {"email": email, "password": password, "email_confirm": True, "user_metadata": metadata},
        )
        if code in (200, 201) and isinstance(response, dict):
            user_id = response.get("id")
        else:
            raise RuntimeError(f"Could not create synthetic DEV Auth user {role} (HTTP {code}).")
    if code not in (200, 201) or not user_id:
        raise RuntimeError(f"Could not set synthetic DEV Auth password for {role} (HTTP {code}).")
    code, response = safe_request(
        f"{base}/auth/v1/token?grant_type=password", publishable, publishable, "POST",
        {"email": email, "password": password},
    )
    if code != 200 or not isinstance(response, dict) or not response.get("access_token"):
        raise RuntimeError(f"Could not obtain synthetic DEV JWT for {role} (HTTP {code}).")
    return user_id, response["access_token"]


def upload_fixture_photo(base: str, publishable: str, service: str, path: str) -> None:
    url = f"{base}/storage/v1/object/geolock-donation-images/{urllib.parse.quote(path, safe='/')}"
    request = urllib.request.Request(
        url, data=PNG_BYTES,
        headers={"apikey": publishable, "Authorization": f"Bearer {service}",
                 "Content-Type": "image/png", "x-upsert": "true"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            if response.status not in (200, 201):
                raise RuntimeError(f"Could not upload a DEV fixture photo (HTTP {response.status}).")
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"Could not upload a DEV fixture photo (HTTP {error.code}); verify the DEV bucket exists.") from None
    except urllib.error.URLError:
        raise RuntimeError("DEV Storage upload failed; verify the DEV bucket and network.") from None


def storage_bucket_preflight(base: str, publishable: str, service: str) -> None:
    code, bucket = safe_request(
        f"{base}/storage/v1/bucket/geolock-donation-images", publishable, service
    )
    if code != 200 or not isinstance(bucket, dict):
        raise RuntimeError("The private geolock-donation-images DEV bucket is missing or inaccessible.")
    if bucket.get("public") is True:
        raise RuntimeError("The donation image bucket must remain private in DEV.")


def remove_fixture_photos(base: str, publishable: str, service: str, paths: list[str]) -> None:
    if not paths:
        return
    import json
    req = urllib.request.Request(
        f"{base}/storage/v1/object/geolock-donation-images", data=json.dumps({"prefixes": paths}).encode(),
        headers={"apikey": publishable, "Authorization": f"Bearer {service}", "Content-Type": "application/json"},
        method="DELETE",
    )
    try:
        with urllib.request.urlopen(req, timeout=45):
            pass
    except (urllib.error.HTTPError, urllib.error.URLError):
        # Setup remains safe; report only that local manual cleanup may be needed.
        print("Storage cleanup was not confirmed; see the DEV cleanup instructions.", file=sys.stderr)


def fixture_id(run_id: uuid.UUID, kind: str, key: str) -> uuid.UUID:
    return uuid.uuid5(NAMESPACE, f"{run_id}:{kind}:{key}")


def fixture_ids(run_id: uuid.UUID):
    out = {}
    for key in FIXTURE_KEYS:
        for kind in ("donation", "image", "listing", "request", "claim", "lease", "task", "case"):
            out[(kind, key)] = fixture_id(run_id, kind, key)
    out[("vehicle", "primary")] = fixture_id(run_id, "vehicle", "primary")
    out[("route", "routed_expiry")] = fixture_id(run_id, "route", "routed_expiry")
    return out


def photo_path(donor_id: uuid.UUID, donation_id: uuid.UUID, image_id: uuid.UUID) -> str:
    return f"{donor_id}/{donation_id}/{image_id}.png"


def database_preflight(conn) -> uuid.UUID:
    with conn.cursor() as cur:
        cur.execute("select current_database(), current_user")
        database, db_user = cur.fetchone()
        if database != "postgres" or db_user != "postgres":
            raise RuntimeError("Connect directly as the DEV postgres database role to database postgres.")
        tables = (
            "user_profiles", "donor_profiles", "ngo_profiles", "donation_categories",
            "donations", "donation_items", "donation_images", "listings", "claim_requests",
            "donation_claims", "claim_leases", "pickup_tasks", "pickup_routes",
            "pickup_route_stops", "active_task_route_assignments", "vehicles", "audit_events",
            "claim_cancellation_requests", "claim_reconciliation_cases", "claim_reconciliation_evidence",
        )
        cur.execute("select to_regclass('public.' || n) from unnest(%s::text[]) n", (list(tables),))
        if any(value is None for value, in cur.fetchall()):
            raise RuntimeError("Required V3 / Stage 1 tables are missing; apply and verify approved DEV migrations first.")
        expected_columns = {
            "user_profiles": {"user_id", "full_name", "phone_number", "role"},
            "donor_profiles": {"user_id"},
            "ngo_profiles": {"user_id", "ngo_name", "operating_address", "latitude", "longitude", "location_verified_at"},
            "donation_categories": {"category_id", "active_flag"},
            "donations": {"donation_id", "donor_user_id", "title", "description", "collection_path", "donation_status", "pickup_address", "latitude", "longitude", "total_weight_kg", "availability_start", "availability_end"},
            "donation_items": {"donation_id", "category_id", "item_name", "description", "quantity", "unit_label", "unit_weight_kg", "item_condition"},
            "donation_images": {"image_id", "donation_id", "owner_user_id", "storage_path", "content_type", "size_bytes", "is_primary", "display_order"},
            "listings": {"listing_id", "source_type", "donation_id", "listing_status", "listing_weight_kg", "pickup_latitude", "pickup_longitude", "pickup_road_node_id", "listing_expires_at"},
            "claim_requests": {"request_id", "listing_id", "ngo_user_id", "request_digest", "outcome", "result_claim_id", "reason_code", "completed_at"},
            "donation_claims": {"claim_id", "listing_id", "ngo_user_id", "request_id", "claim_status", "claimed_at"},
            "claim_leases": {"lease_id", "claim_id", "lease_status", "issued_at", "expires_at"},
            "pickup_tasks": {"task_id", "claim_id", "listing_id", "ngo_user_id", "pickup_road_node_id", "load_kg", "task_status"},
            "pickup_routes": {"route_id", "ngo_user_id", "vehicle_id", "route_status", "matrix_id"},
            "pickup_route_stops": {"route_id", "ngo_user_id", "stop_order", "task_id"},
            "active_task_route_assignments": {"route_id", "task_id"},
            "vehicles": {"vehicle_id", "ngo_user_id", "vehicle_label", "payload_capacity_kg", "active_flag"},
            "audit_events": {"actor_user_id", "entity_id", "event_type", "request_id", "claim_id", "lease_id", "outcome"},
            "claim_cancellation_requests": {"request_id", "claim_id", "actor_user_id", "request_fingerprint", "response"},
            "claim_reconciliation_cases": {"case_id", "claim_id", "listing_id", "donation_id", "source_type", "case_status"},
            "claim_reconciliation_evidence": {"request_id", "case_id", "actor_user_id", "handover_confirmed", "response"},
        }
        cur.execute("select table_name,column_name from information_schema.columns where table_schema='public' and table_name=any(%s)",
                    (list(expected_columns),))
        actual = {}
        for table, column in cur.fetchall():
            actual.setdefault(table, set()).add(column)
        missing = [f"{table}.{column}" for table, columns in expected_columns.items()
                   for column in sorted(columns - actual.get(table, set()))]
        if missing:
            raise RuntimeError("DEV schema is missing required fixture columns: " + ", ".join(missing))
        indexes = (
            "ux_active_claim", "ux_direct_listing", "ux_donation_images_primary",
            "claim_leases_claim_id_key", "pickup_tasks_claim_id_key",
            "claim_reconciliation_case_claim_unique",
        )
        cur.execute("select to_regclass('public.' || n) from unnest(%s::text[]) n", (list(indexes),))
        if any(value is None for value, in cur.fetchall()):
            raise RuntimeError("One or more V3 / Stage 1 uniqueness guards are missing.")
        required_constraints = (
            "user_profiles_role_check", "donations_collection_path_check",
            "donations_donation_status_check", "donations_total_weight_kg_check",
            "donation_items_quantity_check", "donation_items_unit_weight_kg_check",
            "donation_images_content_type_check", "donation_images_size_bytes_check",
            "donation_images_order_range", "listings_listing_status_check",
            "claim_requests_outcome_check", "donation_claims_claim_status_check",
            "claim_leases_lease_status_check", "pickup_tasks_task_status_check",
            "claim_reconciliation_case_claim_unique", "claim_reconciliation_source_type_check",
            "donation_claims_request_id_fkey", "fk_request_result",
        )
        cur.execute("select conname from pg_constraint where connamespace='public'::regnamespace and conname=any(%s)",
                    (list(required_constraints),))
        if {row[0] for row in cur.fetchall()} != set(required_constraints):
            raise RuntimeError("One or more required V3 / Stage 1 state or data constraints are missing.")
        # V3 intentionally has a circular claim-request/claim relationship:
        # claims reference their request, and successful requests reference the
        # resulting claim. Both constraints are immediate (not deferred), so a
        # fixture must insert the request with a NULL result first, then claim,
        # and finally update the request result.
        cur.execute(
            "select conname, conrelid='public.donation_claims'::regclass, "
            "confrelid='public.claim_requests'::regclass, "
            "conrelid='public.claim_requests'::regclass, "
            "confrelid='public.donation_claims'::regclass, "
            "condeferrable, condeferred from pg_constraint "
            "where connamespace='public'::regnamespace and conname=any(%s)",
            (["donation_claims_request_id_fkey", "fk_request_result"],),
        )
        foreign_keys = {tuple(row) for row in cur.fetchall()}
        expected_foreign_keys = {
            ("donation_claims_request_id_fkey", True, True, False, False, False, False),
            ("fk_request_result", False, False, True, True, False, False),
        }
        if foreign_keys != expected_foreign_keys:
            raise RuntimeError("The V3 claim-request circular foreign keys differ from the expected immediate constraints.")
        required_triggers = (
            ("donations", "donations_require_photo_at_commit"),
            ("donations", "trg_donation_transition"),
            ("donation_items", "trg_items_guard"),
            ("listings", "trg_listing_transition"),
            ("user_profiles", "trg_role_immutable"),
        )
        cur.execute(
            "select c.relname,t.tgname from pg_trigger t join pg_class c on c.oid=t.tgrelid "
            "join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' "
            "and c.relname=any(%s) and t.tgname=any(%s)",
            ([table for table, _ in required_triggers], [name for _, name in required_triggers]),
        )
        found_triggers = set(cur.fetchall())
        if found_triggers != set(required_triggers):
            raise RuntimeError("Required V3 photo, state-transition, or role-immutability triggers are missing.")
        required_functions = (
            "public.cancel_claim(uuid,uuid)",
            "public.submit_claim_reconciliation(uuid,boolean,uuid)",
            "public.get_my_reconciliation_cases()",
            "public.get_authorized_audit_events(text,uuid)",
            "public.recover_expired_claims(integer)",
        )
        cur.execute("select to_regprocedure(x) from unnest(%s::text[]) x", (list(required_functions),))
        if any(value is None for value, in cur.fetchall()):
            raise RuntimeError("One or more October 19 Stage 1 RPC signatures are missing in DEV.")
        cur.execute("select claim_lease_minutes,hub_reservation_minutes,donation_direct_min_kg from public.coordination_config where singleton")
        config = cur.fetchone()
        if not config or config != (360, 120, 10):
            raise RuntimeError("DEV coordination_config must be exactly 360 minutes / 120 minutes / 10 kg.")
        cur.execute(
            "select count(*) from public.donation_claims c join public.claim_leases le using(claim_id) "
            "where c.claim_status='ACTIVE' and le.lease_status='ACTIVE' and le.expires_at<=clock_timestamp()"
        )
        if cur.fetchone()[0] != 0:
            raise RuntimeError("DEV already has expired active claims; recover/reconcile them before creating fixtures.")
        cur.execute("select category_id from public.donation_categories where active_flag order by category_name,category_id limit 1")
        row = cur.fetchone()
        if not row:
            raise RuntimeError("No active DEV donation category exists.")
        category_id = row[0]
    conn.rollback()
    return category_id


def seed_database(conn, ids: dict, run_id: uuid.UUID, users: dict, category_id: uuid.UUID) -> None:
    donor_id = uuid.UUID(users["donor"][0])
    ngo_id = uuid.UUID(users["ngo"][0])
    ngo2_id = uuid.UUID(users["ngo2"][0])
    with conn.cursor() as cur:
        for role_key, user_id, role in (("donor", donor_id, "DONOR"), ("ngo", ngo_id, "NGO"), ("ngo2", ngo2_id, "NGO")):
            name = f"GeoLock DEV Fixture {role_key.upper()}"
            cur.execute(
                "insert into public.user_profiles(user_id,full_name,phone_number,role) values(%s,%s,%s,%s) "
                "on conflict(user_id) do update set full_name=excluded.full_name,phone_number=excluded.phone_number "
                "where public.user_profiles.role=excluded.role",
                (user_id, name, None, role),
            )
            if cur.rowcount != 1:
                raise RuntimeError("A synthetic Auth account already has an incompatible immutable role profile.")
        cur.execute("insert into public.donor_profiles(user_id) values(%s) on conflict(user_id) do nothing", (donor_id,))
        for user_id, name in ((ngo_id, "GeoLock DEV Fixture NGO A"), (ngo2_id, "GeoLock DEV Fixture NGO B")):
            cur.execute(
                "insert into public.ngo_profiles(user_id,ngo_name,operating_address,latitude,longitude,location_verified_at) "
                "values(%s,%s,'Synthetic DEV test location',3.1390,101.6869,clock_timestamp()) "
                "on conflict(user_id) do update set ngo_name=excluded.ngo_name,operating_address=excluded.operating_address,"
                "latitude=excluded.latitude,longitude=excluded.longitude,location_verified_at=excluded.location_verified_at",
                (user_id, name),
            )

        cur.execute(
            "insert into public.vehicles(vehicle_id,ngo_user_id,vehicle_label,payload_capacity_kg,active_flag) "
            "values(%s,%s,'DEV fixture vehicle',100,true)",
            (ids[("vehicle", "primary")], ngo_id),
        )
        # Insert the only route-linked task as a deliberate synthetic uncertainty
        # signal. Its node sentinel is not an operational routing node.
        cur.execute(
            "insert into public.pickup_routes(route_id,ngo_user_id,vehicle_id,route_status,matrix_id) "
            "values(%s,%s,%s,'IN_PROGRESS','DEV_FIXTURE_ONLY')",
            (ids[("route", "routed_expiry")], ngo_id, ids[("vehicle", "primary")]),
        )

        for key in FIXTURE_KEYS:
            donation_id = ids[("donation", key)]
            image_id = ids[("image", key)]
            listing_id = ids[("listing", key)]
            claim_id = ids[("claim", key)]
            lease_id = ids[("lease", key)]
            task_id = ids[("task", key)]
            request_id = ids[("request", key)]
            ngo_owner = ngo2_id if key == "audit_foreign" else ngo_id
            final_donation_state = "PICKUP_IN_PROGRESS" if key in PICKUP_STARTED_KEYS else "READY_FOR_PICKUP"
            title = f"DEV STAGE1 {run_id} {key}"
            cur.execute(
                "insert into public.donations(donation_id,donor_user_id,title,description,collection_path,donation_status,"
                "pickup_address,latitude,longitude,total_weight_kg,availability_start,availability_end) "
                "values(%s,%s,%s,'Synthetic test fixture','DIRECT_PICKUP','SUBMITTED','Synthetic DEV pickup location',"
                "3.1390,101.6869,18.000,null,null)",
                (donation_id, donor_id, title),
            )
            cur.execute(
                "insert into public.donation_images(image_id,donation_id,owner_user_id,storage_path,content_type,size_bytes,is_primary,display_order) "
                "values(%s,%s,%s,%s,'image/png',%s,true,1)",
                (image_id, donation_id, donor_id, photo_path(donor_id, donation_id, image_id), len(PNG_BYTES)),
            )
            cur.execute(
                "insert into public.donation_items(donation_id,category_id,item_name,description,quantity,unit_label,unit_weight_kg,item_condition) "
                "values(%s,%s,'Synthetic fixture item','Stage 1 test only',1,'piece',18.000,'GOOD')",
                (donation_id, category_id),
            )
            cur.execute("update public.donations set donation_status='VALIDATED' where donation_id=%s", (donation_id,))
            cur.execute("update public.donations set donation_status='READY_FOR_PICKUP' where donation_id=%s", (donation_id,))
            if final_donation_state == "PICKUP_IN_PROGRESS":
                cur.execute("update public.donations set donation_status='PICKUP_IN_PROGRESS' where donation_id=%s", (donation_id,))

            cur.execute(
                "insert into public.listings(listing_id,source_type,donation_id,listing_status,listing_weight_kg,"
                "pickup_latitude,pickup_longitude,pickup_road_node_id,listing_expires_at) "
                "values(%s,'DIRECT_DONATION',%s,'CLAIMED',18.000,3.1390,101.6869,null,null)",
                (listing_id, donation_id),
            )
            cur.execute(
                "insert into public.claim_requests(request_id,listing_id,ngo_user_id,request_digest) "
                "values(%s,%s,%s,%s)",
                (request_id, listing_id, ngo_owner, f"stage1-dev:{run_id}:{key}"),
            )
            claim_state = "RECONCILIATION_REQUIRED" if key in RECONCILIATION_KEYS else "ACTIVE"
            claimed_old = key in EXPIRED_KEYS
            cur.execute(
                "insert into public.donation_claims(claim_id,listing_id,ngo_user_id,request_id,claim_status,claimed_at) "
                "values(%s,%s,%s,%s,%s,case when %s then clock_timestamp()-interval '8 hours' else clock_timestamp() end)",
                (claim_id, listing_id, ngo_owner, request_id, claim_state, claimed_old),
            )
            # fk_request_result is immediate, so it cannot point at a claim
            # until that claim exists. Complete the successful request only
            # after inserting its referenced donation_claims row.
            cur.execute(
                "update public.claim_requests set outcome='SUCCESS',result_claim_id=%s,"
                "reason_code='DEV_FIXTURE',completed_at=clock_timestamp() where request_id=%s",
                (claim_id, request_id),
            )
            cur.execute(
                "insert into public.claim_leases(lease_id,claim_id,lease_status,issued_at,expires_at) "
                "values(%s,%s,%s,case when %s then clock_timestamp()-interval '8 hours' else clock_timestamp() end,"
                "case when %s then clock_timestamp()-(%s * interval '1 minute') else clock_timestamp()+interval '6 hours' end)",
                (lease_id, claim_id, claim_state, claimed_old, claimed_old,
                 EXPIRY_MINUTES_AGO.get(key, 0)),
            )
            task_state = "DISPATCHED" if key in DISPATCHED_KEYS else "CONFIRMED"
            cur.execute(
                "insert into public.pickup_tasks(task_id,claim_id,listing_id,ngo_user_id,pickup_road_node_id,load_kg,task_status) "
                "values(%s,%s,%s,%s,'DEV_FIXTURE_ONLY_NOT_OPERATIONAL_NODE',18.000,%s)",
                (task_id, claim_id, listing_id, ngo_owner, task_state),
            )
            if key in RECONCILIATION_KEYS:
                cur.execute(
                    "insert into public.claim_reconciliation_cases(case_id,claim_id,listing_id,donation_id,source_type,case_status) "
                    "values(%s,%s,%s,%s,'DIRECT_DONATION','OPEN')",
                    (ids[("case", key)], claim_id, listing_id, donation_id),
                )
            if key == "route_linked_expired":
                cur.execute(
                    "insert into public.pickup_route_stops(route_id,ngo_user_id,stop_order,task_id) values(%s,%s,1,%s)",
                    (ids[("route", "routed_expiry")], ngo_id, task_id),
                )
                cur.execute(
                    "insert into public.active_task_route_assignments(task_id,route_id) values(%s,%s)",
                    (task_id, ids[("route", "routed_expiry")]),
                )


def write_generated_env(path: Path, values: dict[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if os.name == "nt":
        identity = f"{os.environ.get('USERDOMAIN', '')}\\{os.environ.get('USERNAME', '')}".strip("\\")
        subprocess.run(["icacls", str(path.parent), "/inheritance:r", "/grant:r", f"{identity}:(OI)(CI)F"],
                       check=True, capture_output=True, text=True)
    content = "# Generated DEV-only credentials and fixture IDs. Do not commit or share.\n"
    content += "\n".join(f"{key}={value}" for key, value in values.items()) + "\n"
    path.write_text(content, encoding="utf-8")
    if os.name == "nt":
        subprocess.run(["icacls", str(path), "/inheritance:r", "/grant:r", f"{identity}:F"],
                       check=True, capture_output=True, text=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=None,
                        help="local secret config; defaults to %%LOCALAPPDATA%%\\GeoLockHub\\dev\\stage1-setup.env")
    args = parser.parse_args()
    local_root = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local")) / "GeoLockHub" / "dev"
    config_path = args.config or local_root / "stage1-setup.env"
    values = read_env(config_path)
    base = target_check(values)
    if input(f"Type exactly: {TYPED_PHRASE}\n> ").strip() != TYPED_PHRASE:
        raise RuntimeError("Confirmation did not match; no remote requests or database writes were made.")

    try:
        import psycopg
    except ImportError:
        raise RuntimeError("Install local fixture dependencies first: python -m pip install -r supabase/tests/requirements-dev-fixtures.txt") from None

    db_url = require(values, "GEOLOCK_DEV_DATABASE_URL")
    try:
        database_connection = psycopg.connect(db_url)
    except Exception:
        raise RuntimeError("Could not connect to the allowlisted DEV PostgreSQL database; verify its local connection settings.") from None
    with database_connection as conn:
        category_id = database_preflight(conn)
        conn.rollback()
        publishable = require(values, "GEOLOCK_DEV_PUBLISHABLE_KEY")
        service = require(values, "GEOLOCK_DEV_SERVICE_ROLE_JWT")
        anon = require(values, "GEOLOCK_DEV_ANON_JWT")
        storage_bucket_preflight(base, publishable, service)
        # Auth writes happen only after exact ref checks, typed confirmation,
        # DEV DB host validation, and read-only schema/config preflight.
        users: dict[str, tuple[str, str]] = {}
        for role, email in ROLE_EMAILS.items():
            user_id, jwt = create_or_reset_user(base, publishable, service, role, email)
            users[role] = (user_id, jwt)

        run_id = uuid.uuid4()
        output = default_generated_env()
        ids = fixture_ids(run_id)
        donor_id = uuid.UUID(users["donor"][0])
        paths = [photo_path(donor_id, ids[("donation", key)], ids[("image", key)]) for key in FIXTURE_KEYS]
        try:
            for path in paths:
                upload_fixture_photo(base, publishable, service, path)
            with conn.transaction():
                seed_database(conn, ids, run_id, users, category_id)
        except Exception:
            remove_fixture_photos(base, publishable, service, paths)
            raise

        env = {
            "GEOLOCK_DEV_ISOLATED_CONFIRMATION": CONFIRMATION,
            "GEOLOCK_DEV_PROJECT_REF": DEV_PROJECT_REF,
            "GEOLOCK_DEV_ALLOWED_PROJECT_REFS": DEV_PROJECT_REF,
            "GEOLOCK_DEV_SUPABASE_URL": base,
            "GEOLOCK_DEV_PUBLISHABLE_KEY": publishable,
            "GEOLOCK_DEV_ANON_JWT": anon,
            "GEOLOCK_DEV_SERVICE_ROLE_JWT": service,
            "GEOLOCK_DEV_NGO_JWT": users["ngo"][1],
            "GEOLOCK_DEV_DONOR_JWT": users["donor"][1],
            "GEOLOCK_DEV_RECONCILE_COUNTERPART_JWT": users["donor"][1],
            "GEOLOCK_DEV_RECONCILE_DISPATCHED_COUNTERPART_JWT": users["donor"][1],
            "GEOLOCK_DEV_RECONCILE_CONFLICT_COUNTERPART_JWT": users["donor"][1],
            "GEOLOCK_DEV_RECONCILE_SAFE_COUNTERPART_JWT": users["donor"][1],
            "GEOLOCK_DEV_RECONCILE_COUNTERPART_NGO_JWT": users["ngo2"][1],
            "GEOLOCK_DEV_FIXTURE_RUN_ID": str(run_id),
            "GEOLOCK_DEV_FIXTURE_DONOR_USER_ID": users["donor"][0],
            "GEOLOCK_DEV_FIXTURE_NGO_USER_ID": users["ngo"][0],
            "GEOLOCK_DEV_FIXTURE_NGO2_USER_ID": users["ngo2"][0],
        }
        env.update({
            "GEOLOCK_DEV_EXPIRED_SAFE_CLAIM_ID": str(ids[("claim", "expired_safe")]),
            "GEOLOCK_DEV_CANCEL_SAME_REQUEST_CLAIM_ID": str(ids[("claim", "cancel_same")]),
            "GEOLOCK_DEV_CANCEL_DISTINCT_REQUEST_CLAIM_ID": str(ids[("claim", "cancel_distinct")]),
            "GEOLOCK_DEV_CANCEL_START_RACE_CLAIM_ID": str(ids[("claim", "cancel_start_race")]),
            "GEOLOCK_DEV_EXPIRED_PICKUP_CLAIM_ID": str(ids[("claim", "expired_pickup")]),
            "GEOLOCK_DEV_CANCEL_RECOVERY_RACE_CLAIM_ID": str(ids[("claim", "cancel_recovery_race")]),
            "GEOLOCK_DEV_ROUTE_LINKED_EXPIRED_CLAIM_ID": str(ids[("claim", "route_linked_expired")]),
            "GEOLOCK_DEV_RECONCILE_POSITIVE_CLAIM_ID": str(ids[("claim", "reconcile_positive")]),
            "GEOLOCK_DEV_RECONCILE_POSITIVE_LISTING_ID": str(ids[("listing", "reconcile_positive")]),
            "GEOLOCK_DEV_RECONCILE_DISPATCHED_NO_HANDOVER_CLAIM_ID": str(ids[("claim", "reconcile_dispatched_no_handover")]),
            "GEOLOCK_DEV_RECONCILE_CONFLICT_CLAIM_ID": str(ids[("claim", "reconcile_conflict")]),
            "GEOLOCK_DEV_RECONCILE_SAFE_RELEASE_CLAIM_ID": str(ids[("claim", "reconcile_safe_release")]),
            "GEOLOCK_DEV_RECONCILE_SAFE_RELEASE_LISTING_ID": str(ids[("listing", "reconcile_safe_release")]),
            "GEOLOCK_DEV_AUDIT_OWN_CLAIM_ID": str(ids[("claim", "audit_own")]),
            "GEOLOCK_DEV_AUDIT_FOREIGN_CLAIM_ID": str(ids[("claim", "audit_foreign")]),
        })
        write_generated_env(output, env)
    print("DEV fixture setup completed. Auth credentials and JWTs were not printed.")
    print(f"Generated test environment: {output}")
    print(f"Fixture run ID: {run_id}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyboardInterrupt, EOFError):
        print("Cancelled before completion.", file=sys.stderr)
        raise SystemExit(2)
    except Exception as error:
        print(f"DEV fixture setup stopped: {error}", file=sys.stderr)
        raise SystemExit(1)
