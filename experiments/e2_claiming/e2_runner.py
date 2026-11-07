"""Isolated GeoLock E2 runner. Never accepts a Supabase URL or external DSN."""
from __future__ import annotations

import argparse
import csv
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import random
import re
import secrets
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from uuid import UUID, uuid5, NAMESPACE_URL

import psycopg

ROOT = Path(__file__).resolve().parents[2]
SCRIPT_DIR = Path(__file__).resolve().parent
MARKER = ".geolock-e2-runtime.json"
CONFIRM_CLEANUP = "DELETE_GEOLOCK_E2_RUNTIME"
DEV_PROJECT_REF = "rcgyuwiidqvrgbxswhqj"
CLAIM_HASH = "2c1f60c876797c61b44b3cb43591bab8"
RECOVERY_HASH = "05fe46d8b76085f71c87fcc5f6520775"
LOCK_ROUTE_HASH = "20d815e7357e243757e1dc8b7d066a4e"
RELEASE_STOP_HASH = "a6abd6f8d3c96020a7e93df39483458a"
BASELINE_FUNCTION = "e2_baseline.non_atomic_claim_listing"
ROUTING_CHAIN = (
    "20261104_routing_automatic_departure.sql",
    "20261105_routing_receipt_readonly.sql",
    "20261106_route_interruption_resolution.sql",
    "20261107_donor_route_resolution_read.sql",
    "20261108_per_stop_reconciliation.sql",
)
DATABASES = {
    "protected": "geolock_e2_atomic",
    "non-atomic": "geolock_e2_nonatomic",
}
ACTOR_A = "11111111-1111-4111-8111-111111111111"
ACTOR_B = "22222222-2222-4222-8222-222222222222"
DONOR = "33333333-3333-4333-8333-333333333333"
CATEGORY = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
ACTORS = [ACTOR_A, ACTOR_B]
MAX_TRANSIENT_RETRIES = 1
CONNECT_TIMEOUT_SECONDS = 5
STATEMENT_TIMEOUT_MS = 30000
BARRIER_TIMEOUT_SECONDS = 20
RACE_WINDOW_MS = 50
LEASE_MINUTES = 360
CONTENTION_LEVELS = (2, 5, 10)
MAX_CONTENTION_TRIALS_PER_LEVEL = 50
MAX_LEASE_TRIALS = 100
DONATION_IMAGE_BUCKET = "geolock-donation-images"
DONATION_IMAGE_CONTENT_TYPE = "image/jpeg"
DONATION_IMAGE_SIZE_BYTES = 100


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def short_error(exc: BaseException) -> dict:
    code = getattr(exc, "sqlstate", None)
    diag = getattr(exc, "diag", None)
    category = "TIMEOUT" if code == "57014" or isinstance(exc, TimeoutError) else "DATABASE"
    if isinstance(exc, (psycopg.OperationalError, psycopg.InterfaceError, OSError)):
        category = "CONNECTION"
    if code and code.startswith("23"):
        category = "CONSTRAINT"
    return {
        "category": category,
        "error_type": type(exc).__name__,
        "sqlstate": code,
        "constraint": getattr(diag, "constraint_name", None),
        "table": getattr(diag, "table_name", None),
        "schema": getattr(diag, "schema_name", None),
    }


def digest_sources() -> dict[str, str]:
    paths = [
        ROOT / "geolock-v3-public-schema.sql",
        ROOT / "supabase/migrations/20261019_stage1_claim_recovery_and_reconciliation.sql",
        ROOT / "supabase/migrations/20261027_persisted_donation_lifecycle.sql",
        ROOT / "supabase/migrations/20261029_fix_claim_recovery_listing_expiration_race.sql",
        ROOT / "supabase/migrations/20261030_fix_claim_recovery_unresolved_reconciliation.sql",
        ROOT / "supabase/migrations/20261031_claim_audit_and_failure_capture.sql",
        ROOT / "docs/stage8/stage-a/build_package.py",
        *(ROOT / "docs/stage8/stage-a/forward-migrations" / name for name in (
            "20261101_routing_authority.sql",
            "20261102_routing_publication.sql",
            "20261103_routing_pickup_and_reconciliation.sql",
            *ROUTING_CHAIN,
            "20261109_claim_scoped_reconciliation.sql",
        )),
        ROOT / "supabase/tests/stage8_stage_b_isolated_test.py",
        Path(__file__),
    ]
    return {str(p.relative_to(ROOT)): sha256(p) for p in paths}


def git_state() -> dict:
    def git(*args: str) -> str | None:
        try:
            return subprocess.run(
                ["git", "-C", str(ROOT), *args], check=True, capture_output=True,
                text=True, timeout=10,
            ).stdout.strip()
        except Exception:
            return None
    return {
        "commit": git("rev-parse", "HEAD"),
        "working_tree_dirty": bool(git("status", "--porcelain")),
    }


def conn_args(meta: dict, db: str, user: str = "postgres") -> dict:
    return dict(
        host="127.0.0.1", port=int(meta["port"]), dbname=db, user=user,
        connect_timeout=CONNECT_TIMEOUT_SECONDS,
        application_name="geolock-e2-preparation",
    )


def is_approved_loopback_host(value: str | None) -> bool:
    """Accept only the configured IPv4 loopback address, with or without /32."""
    if not value:
        return False
    try:
        address = ipaddress.ip_interface(value.strip()).ip
    except (ValueError, TypeError):
        return False
    return (isinstance(address, ipaddress.IPv4Address)
            and address == ipaddress.IPv4Address("127.0.0.1")
            and address.is_loopback)


def db_identity(meta: dict, db: str) -> dict:
    with psycopg.connect(**conn_args(meta, db)) as conn, conn.cursor() as cur:
        cur.execute("""
          select current_database(), inet_server_addr()::text, inet_server_port(),
                 current_setting('transaction_isolation'), version(),
                 (select system_identifier::text from pg_control_system())
        """)
        row = cur.fetchone()
    return dict(database=row[0], host=row[1], port=row[2], isolation=row[3],
                version=row[4], system_identifier=row[5])


def verify_local_identity(meta: dict, db: str) -> None:
    expected_db = DATABASES.get(meta.get("condition"), db)
    if db not in DATABASES.values() or db != expected_db:
        raise RuntimeError("E2 database name does not match the approved local condition.")
    identity = db_identity(meta, db)
    if not is_approved_loopback_host(identity["host"]) or identity["database"] != db:
        raise RuntimeError("Refusing: database identity is not the selected loopback E2 database.")
    if str(identity["system_identifier"]) != str(meta["system_identifier"]):
        raise RuntimeError("Refusing: PostgreSQL cluster identifier differs from the E2 setup marker.")
    if DEV_PROJECT_REF in identity["version"] or "supabase.co" in identity["version"].lower():
        raise RuntimeError("Refusing: the selected server does not look like the isolated local PostgreSQL cluster.")


def load_runtime(root: Path) -> dict:
    root = root.resolve()
    temp_root = Path(tempfile.gettempdir()).resolve()
    if not root.is_relative_to(temp_root) or not root.name.startswith("GeoLockE2-"):
        raise RuntimeError("Runtime root must be a GeoLockE2-* child of the system temporary directory.")
    marker = root / MARKER
    if not marker.is_file():
        raise RuntimeError("E2 runtime marker is missing; refusing to connect.")
    meta = json.loads(marker.read_text(encoding="utf-8"))
    if meta.get("marker") != "GeoLock Hub E2 isolated runtime v1" or Path(meta["root"]).resolve() != root:
        raise RuntimeError("E2 runtime marker does not match the selected folder.")
    return meta


def find_pg_bin(value: str | None) -> Path:
    configured = value or os.environ.get("GEOLOCK_E2_PG_BIN")
    candidates = [Path(configured)] if configured else []
    candidates += [Path(r"C:\Program Files\PostgreSQL\17\bin")]
    for candidate in candidates:
        if all((candidate / (name + ".exe")).is_file() for name in ("initdb", "pg_ctl", "psql")):
            return candidate.resolve()
    raise RuntimeError("PostgreSQL 17 initdb.exe, pg_ctl.exe and psql.exe were not found. Set GEOLOCK_E2_PG_BIN.")


class RetainedFolder:
    def __init__(self, path: Path):
        self.name = str(path)

    def cleanup(self) -> None:
        # The isolated runtime is intentionally retained until the explicit cleanup command.
        return


def bootstrap_from_current_isolated_fixture(root: Path, evidence: Path, pg_bin: Path) -> tuple[object, dict]:
    """Reuse the repository's full-schema Stage B builder in a new, loopback-only cluster."""
    test_dir = ROOT / "supabase/tests"
    sys.path.insert(0, str(test_dir))
    sys.path.insert(0, str(ROOT))
    import stage8_stage_b_isolated_test as stage_b

    stage_b.OUT = evidence
    stage_b.DIAGNOSTIC_MODE = False
    stage_b.APPLY_B43 = False
    stage_b.StageBTests.bins = {
        name: str(pg_bin / (name + ".exe" if os.name == "nt" else ""))
        for name in ("initdb", "pg_ctl", "psql")
    }
    prior_td = tempfile.TemporaryDirectory
    prior_cleanup = getattr(stage_b.StageBTests, "addClassCleanup")
    tempfile.TemporaryDirectory = lambda *a, **k: RetainedFolder(root)  # type: ignore[assignment]
    stage_b.StageBTests.addClassCleanup = staticmethod(lambda *a, **k: None)
    try:
        stage_b.StageBTests.setUpClass()
    finally:
        tempfile.TemporaryDirectory = prior_td  # type: ignore[assignment]
        stage_b.StageBTests.addClassCleanup = prior_cleanup

    cls = stage_b.StageBTests
    cls.db = "postgres"
    # Stage B's reusable builder intentionally stops at the initial 20261101-03
    # routing layer. The deployed recovery patch requires the complete 20261101-08
    # chain, so replay the reviewed local forward artifacts in strict order here.
    applied = []
    for name in ROUTING_CHAIN:
        path = ROOT / "docs/stage8/stage-a/forward-migrations" / name
        if not path.is_file():
            raise RuntimeError(f"Required isolated routing migration is missing: {name}")
        cls.query(path.read_text(encoding="utf-8"))
        applied.append({"file": str(path.relative_to(ROOT)), "sha256": sha256(path)})
    (evidence / "e2_routing_chain.json").write_text(
        json.dumps(applied, indent=2) + "\n", encoding="utf-8")
    # The 20261109 forward artifact is run only inside this fresh local cluster.
    patch = ROOT / "docs/stage8/stage-a/forward-migrations/20261109_claim_scoped_reconciliation.sql"
    cls.query(patch.read_text(encoding="utf-8"))

    with psycopg.connect(**conn_args({"port": cls.port}, "postgres")) as conn, conn.cursor() as cur:
        cur.execute("""
          WITH expected(signature) AS (VALUES
            ('public.claim_listing(uuid,uuid)'),
            ('public.recover_expired_claims(integer)'),
            ('routing_private.lock_route_for_recovery(uuid)'),
            ('routing_private.release_expired_unstarted_stop(uuid,uuid,uuid,uuid)'))
          SELECT
            (SELECT jsonb_object_agg(e.signature,
              CASE WHEN p.oid IS NULL THEN jsonb_build_object('present',false)
              ELSE jsonb_build_object('present',true,'normalized_md5',md5(replace(p.prosrc,E'\\r\\n',E'\\n')),
                'raw_md5',md5(p.prosrc),'body_chars',length(p.prosrc),
                'owner',pg_get_userbyid(p.proowner),'security_definer',p.prosecdef,'config',p.proconfig)
              END) FROM expected e LEFT JOIN pg_proc p ON p.oid=to_regprocedure(e.signature)),
            current_setting('transaction_isolation'), current_setting('port')::integer,
            inet_server_addr()::text, current_setting('server_version_num')::integer,
            (SELECT claim_lease_minutes FROM public.coordination_config WHERE singleton)
        """)
        row = cur.fetchone()
    functions = row[0]
    observed = {
        "functions": functions, "isolation": row[1], "port": row[2],
        "host": row[3], "server_version_num": row[4], "lease_minutes": row[5],
        "hash_normalization": "MD5 of prosrc after CRLF-to-LF replacement; raw MD5 and body length also reported",
    }
    function_specs = {
        "public.claim_listing(uuid,uuid)": (CLAIM_HASH,
            ["search_path=pg_catalog, public, extensions, pg_temp"]),
        "public.recover_expired_claims(integer)": (RECOVERY_HASH,
            ["search_path=pg_catalog, public, extensions, pg_temp"]),
        "routing_private.lock_route_for_recovery(uuid)": (LOCK_ROUTE_HASH,
            ["search_path=pg_catalog, pg_temp", "TimeZone=UTC", "extra_float_digits=0"]),
        "routing_private.release_expired_unstarted_stop(uuid,uuid,uuid,uuid)": (RELEASE_STOP_HASH,
            ["search_path=pg_catalog, pg_temp", "TimeZone=UTC", "extra_float_digits=0"]),
    }
    checks = []

    def add_check(name, expected_value, observed_value, passed):
        checks.append({"check": name, "expected": expected_value,
                       "observed": observed_value, "status": "PASS" if passed else "FAIL"})

    for signature, (expected_hash, expected_config) in function_specs.items():
        actual_fn = functions.get(signature, {"present": False})
        add_check(f"{signature}: present", True, actual_fn.get("present", False),
                  actual_fn.get("present", False) is True)
        add_check(f"{signature}: normalized prosrc MD5", expected_hash,
                  actual_fn.get("normalized_md5"), actual_fn.get("normalized_md5") == expected_hash)
        add_check(f"{signature}: owner", "postgres", actual_fn.get("owner"),
                  actual_fn.get("owner") == "postgres")
        add_check(f"{signature}: SECURITY DEFINER", True, actual_fn.get("security_definer"),
                  actual_fn.get("security_definer") is True)
        add_check(f"{signature}: function config", expected_config, actual_fn.get("config"),
                  actual_fn.get("config") == expected_config)
    add_check("database host is approved IPv4 loopback", "127.0.0.1 (CIDR suffix optional)",
              observed["host"], is_approved_loopback_host(observed["host"]))
    add_check("database port matches isolated cluster", int(cls.port), observed["port"],
              observed["port"] == int(cls.port))
    add_check("database isolation", "read committed", observed["isolation"],
              observed["isolation"] == "read committed")
    add_check("PostgreSQL major version", 17, observed["server_version_num"] // 10000,
              observed["server_version_num"] // 10000 == 17)
    add_check("claim lease configuration", LEASE_MINUTES, observed["lease_minutes"],
              observed["lease_minutes"] == LEASE_MINUTES)
    observed["preflight_checks"] = checks
    if any(check["status"] != "PASS" for check in checks):
        failed = sum(check["status"] == "FAIL" for check in checks)
        raise RuntimeError("Isolated SQL source/security preflight failed "
                           f"({failed} failed checks); no E2 database pair was created. "
                           + json.dumps({"status": "PREFLIGHT_FAILED", "checks": checks,
                                         "function_observations": functions,
                                         "environment_observations": {k: v for k, v in observed.items()
                                             if k != "functions" and k != "preflight_checks"}},
                                        indent=2, default=str))
    return cls, observed


BASELINE_SQL = r"""
DROP INDEX public.ux_active_claim;
CREATE SCHEMA e2_baseline;
CREATE OR REPLACE FUNCTION e2_baseline.non_atomic_claim_listing(
 p_listing uuid,p_request uuid,p_race_window_ms integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public,extensions,e2_baseline,pg_temp
AS $function$
DECLARE
 v_actor uuid:=auth.uid(); v_ngo public.ngo_profiles%rowtype;
 v_req public.claim_requests%rowtype; v_l public.listings%rowtype;
 v_digest text; v_reason text; v_claim uuid; v_lease uuid; v_mins integer;
 v_config text; v_outcome text; v_old text;
BEGIN
 IF v_actor IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
 SELECT * INTO v_ngo FROM public.ngo_profiles
  WHERE user_id=v_actor AND active_flag FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_NGO_ONLY'; END IF;
 IF p_request IS NULL OR p_listing IS NULL THEN RAISE EXCEPTION 'REQUEST_AND_LISTING_REQUIRED'; END IF;
 v_digest:=md5(p_listing::text||':'||v_actor::text);
 INSERT INTO public.claim_requests(request_id,listing_id,ngo_user_id,request_digest)
 VALUES(p_request,p_listing,v_actor,v_digest) ON CONFLICT(request_id) DO NOTHING;
 SELECT * INTO v_req FROM public.claim_requests WHERE request_id=p_request FOR UPDATE;
 IF v_req.request_digest<>v_digest OR v_req.listing_id<>p_listing OR v_req.ngo_user_id<>v_actor THEN
   RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD';
 END IF;
 IF v_req.outcome IS NOT NULL THEN
   RETURN jsonb_build_object('outcome',v_req.outcome,'claim_id',v_req.result_claim_id,
     'reason_code',v_req.reason_code,'replayed',true);
 END IF;
 SELECT config_version INTO v_config FROM public.coordination_config WHERE singleton;
 IF v_config IS NULL THEN RAISE EXCEPTION 'CLAIM_CONFIGURATION_NOT_AVAILABLE'; END IF;

 -- Deliberate baseline difference: this check-then-act read takes no listing lock.
 SELECT * INTO v_l FROM public.listings WHERE listing_id=p_listing;
 IF NOT FOUND THEN v_reason:='LISTING_NOT_FOUND';
 ELSIF v_l.listing_status<>'AVAILABLE' THEN v_reason:='CLAIM_CONFLICT';
 ELSIF v_l.listing_expires_at IS NOT NULL AND v_l.listing_expires_at<=clock_timestamp() THEN v_reason:='LISTING_EXPIRED';
 ELSIF v_ngo.location_verified_at IS NULL OR v_ngo.road_node_id IS NULL THEN v_reason:='ELIGIBILITY_UNDETERMINED';
 ELSIF public.geolock_ngo_listing_road_check(v_actor,p_listing)->>'outcome'<>'ELIGIBLE' THEN
   v_reason:=public.geolock_ngo_listing_road_check(v_actor,p_listing)->>'outcome';
 ELSIF v_l.source_type='DIRECT_DONATION' AND NOT EXISTS(
   SELECT 1 FROM public.donations d WHERE d.donation_id=v_l.donation_id AND d.donation_status='AVAILABLE') THEN
   v_reason:='DONATION_NOT_READY';
 ELSIF v_l.source_type='HUB_BATCH' AND NOT EXISTS(
   SELECT 1 FROM public.hub_batches b WHERE b.batch_id=v_l.batch_id AND b.batch_status='PUBLISHED') THEN
   v_reason:='BATCH_NOT_PUBLISHED';
 END IF;
 IF v_reason IS NULL THEN
   -- Widen the vulnerable application read/write window; every worker has passed the same checks first.
   PERFORM pg_sleep(greatest(coalesce(p_race_window_ms,0),0)/1000.0);
   SELECT claim_lease_minutes INTO v_mins FROM public.coordination_config WHERE singleton;
   INSERT INTO public.donation_claims(listing_id,ngo_user_id,request_id)
    VALUES(p_listing,v_actor,p_request) RETURNING claim_id INTO v_claim;
   INSERT INTO public.claim_leases(claim_id,expires_at)
    VALUES(v_claim,clock_timestamp()+make_interval(mins=>v_mins)) RETURNING lease_id INTO v_lease;
   -- No availability recheck: simultaneous workers can each commit ownership.
   UPDATE public.listings SET listing_status='CLAIMED',listing_version=listing_version+1
    WHERE listing_id=p_listing;
   INSERT INTO public.pickup_tasks(claim_id,listing_id,ngo_user_id,pickup_road_node_id,load_kg)
    VALUES(v_claim,p_listing,v_actor,v_l.pickup_road_node_id,v_l.listing_weight_kg);

   -- Keep the final direct-donation lifecycle consistent. The state transition is
   -- conditional and happens once, after every worker has already passed the read.
   IF v_l.source_type='DIRECT_DONATION' THEN
     UPDATE public.donations SET donation_status='CLAIMED'
      WHERE donation_id=v_l.donation_id AND donation_status='AVAILABLE';
     IF FOUND THEN
       INSERT INTO public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
         claim_id,lease_id,previous_state,requested_state,resulting_state,reason_code,outcome,
         details,request_id,correlation_id,software_version,configuration_version)
       VALUES(v_actor,'NGO','DONATION',v_l.donation_id,'DONATION_STATUS_CHANGED',v_claim,v_lease,
         'AVAILABLE','CLAIMED','CLAIMED','CLAIM_ACCEPTED','SUCCESS',
         jsonb_build_object('listing_id',p_listing,'donation_id',v_l.donation_id,
           'ngo_id',v_actor,'transaction_id',pg_current_xact_id()::text,
           'claim_context_available',true),p_request,p_request,'geolock-claim-audit-v1',v_config);
     END IF;
   END IF;
   v_outcome:='SUCCESS';
 ELSE
   v_outcome:=CASE WHEN v_reason IN ('OUTSIDE_GEOFENCE','ROUTE_UNAVAILABLE') THEN 'INELIGIBLE' ELSE 'CONFLICT' END;
 END IF;
 UPDATE public.claim_requests SET outcome=v_outcome,result_claim_id=v_claim,
  reason_code=v_reason,completed_at=clock_timestamp() WHERE request_id=p_request;
 INSERT INTO public.audit_events(actor_user_id,actor_role,entity_type,entity_id,event_type,
   request_id,previous_state,requested_state,resulting_state,reason_code,outcome,details,
   configuration_version,correlation_id,software_version)
 VALUES(v_actor,'NGO','LISTING',p_listing,'CLAIM_ATTEMPT',p_request,v_l.listing_status,
   'CLAIMED',CASE WHEN v_outcome='SUCCESS' THEN 'CLAIMED' ELSE v_l.listing_status END,
   coalesce(v_reason,'CLAIM_ACCEPTED'),CASE WHEN v_outcome='SUCCESS' THEN 'SUCCESS' ELSE 'REJECTED' END,
   jsonb_build_object('ngo_id',v_actor,'listing_id',p_listing,'donation_id',v_l.donation_id,
     'transaction_id',pg_current_xact_id()::text),v_config,p_request,'geolock-e2-nonatomic-v1');
 RETURN jsonb_build_object('outcome',v_outcome,'claim_id',v_claim,
   'reason_code',v_reason,'replayed',false);
END
$function$;
REVOKE ALL ON FUNCTION e2_baseline.non_atomic_claim_listing(uuid,uuid,integer) FROM PUBLIC,anon;
GRANT USAGE ON SCHEMA e2_baseline TO authenticated;
GRANT EXECUTE ON FUNCTION e2_baseline.non_atomic_claim_listing(uuid,uuid,integer) TO authenticated;
"""


def write_metadata(root: Path, meta: dict) -> None:
    (root / MARKER).write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")


def setup(args) -> None:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}", args.run_id):
        raise RuntimeError("run-id must contain only letters, digits, dot, underscore or hyphen.")
    root = Path(args.root).expanduser().resolve()
    temp_root = Path(tempfile.gettempdir()).resolve()
    if (not root.is_relative_to(temp_root) or root.name != f"GeoLockE2-{args.run_id}"
            or root.is_symlink()):
        raise RuntimeError("Runtime must be a new, non-symlink GeoLockE2-<run-id> folder under the system temp directory.")
    if root.exists():
        raise RuntimeError("Runtime folder already exists. Setup never resets or deletes an existing folder.")
    pg_bin = find_pg_bin(args.pg_bin)
    root.mkdir(parents=True)
    evidence = root / "schema-evidence"
    meta = {
        "marker": "GeoLock Hub E2 isolated runtime v1", "root": str(root),
        "setup_token": secrets.token_hex(24),
        "run_id": args.run_id, "created_at": utc_now(), "pg_bin": str(pg_bin),
        "port": None, "system_identifier": None, "databases": DATABASES,
        "dev_project_ref_blocked": DEV_PROJECT_REF, "source_hashes": digest_sources(),
        "git": git_state(), "target": "fresh loopback PostgreSQL cluster only",
    }
    try:
        write_metadata(root, meta)
        evidence.mkdir()
        cls, observed = bootstrap_from_current_isolated_fixture(root, evidence, pg_bin)
        meta["port"] = int(cls.port)
        meta["schema_source_verification"] = observed
        meta["postgresql_data_directory"] = str(root / "data")
        meta["schema_evidence_files"] = sorted(p.name for p in evidence.iterdir() if p.is_file())
        # Create role-only local login identities. Trust is bound to 127.0.0.1 in this fresh cluster.
        cls.db = "template1"
        cls.query("CREATE ROLE e2_worker LOGIN; GRANT authenticated TO e2_worker; CREATE ROLE e2_scheduler LOGIN; GRANT service_role TO e2_scheduler;")
        with psycopg.connect(**conn_args({"port": cls.port}, "template1"), autocommit=True) as conn, conn.cursor() as cur:
            cur.execute("CREATE DATABASE geolock_e2_atomic TEMPLATE postgres")
            cur.execute("CREATE DATABASE geolock_e2_nonatomic TEMPLATE postgres")
        # The deliberately weaker function and index difference exist only in this named local database.
        with psycopg.connect(**conn_args({"port": cls.port}, DATABASES["non-atomic"])) as conn:
            conn.execute(BASELINE_SQL)
        meta["system_identifier"] = db_identity({"port": cls.port}, "postgres")["system_identifier"]
        meta["database_identities"] = {
            key: db_identity({"port": cls.port}, db) for key, db in DATABASES.items()
        }
        meta["scheduler_privilege_evidence"] = {}
        for condition, db in DATABASES.items():
            verify_local_identity({**meta, "condition": condition}, db)
            meta["scheduler_privilege_evidence"][condition] = prepare_scheduler_privileges(meta, db)
        initialize_synthetic_donors(meta, args.run_id)
        # Verify the deliberate schema difference is exactly the active-claim index.
        with psycopg.connect(**conn_args({"port": cls.port}, DATABASES["protected"])) as pconn:
            pindex = pconn.execute("SELECT to_regclass('public.ux_active_claim') IS NOT NULL").fetchone()[0]
        with psycopg.connect(**conn_args({"port": cls.port}, DATABASES["non-atomic"])) as nconn:
            nindex = nconn.execute("SELECT to_regclass('public.ux_active_claim') IS NOT NULL").fetchone()[0]
            nfunc = nconn.execute("SELECT to_regprocedure(%s) IS NOT NULL", (BASELINE_FUNCTION + "(uuid,uuid,integer)",)).fetchone()[0]
        if pindex is not True or nindex is not False or nfunc is not True:
            raise RuntimeError("E2 database pair failed the ownership-index/function setup check.")
        meta["baseline_schema_difference"] = "Only public.ux_active_claim is absent in geolock_e2_nonatomic; all other schema objects come from the same template. Baseline and protected claims use public claim/request/lease/task/audit tables."
        meta["status"] = "READY"
        write_metadata(root, meta)
        print(json.dumps({"status": "READY", "runtime_root": str(root), "port": cls.port,
                          "database_names": list(DATABASES.values()),
                          "postgresql": observed["isolation"],
                          "verified_claim_hash": observed["functions"]["public.claim_listing(uuid,uuid)"]["normalized_md5"],
                          "verified_recovery_hash": observed["functions"]["public.recover_expired_claims(integer)"]["normalized_md5"],
                          "scheduler_privileges": meta["scheduler_privilege_evidence"],
                          "lease_minutes": LEASE_MINUTES}, indent=2))
    except BaseException:
        # Remove only the directory created above, and only while its unique
        # ownership marker still matches. Never remove data if server shutdown
        # cannot be confirmed.
        owned = False
        try:
            marker_path = root / MARKER
            current = json.loads(marker_path.read_text(encoding="utf-8"))
            owned = (root.is_dir() and not root.is_symlink()
                     and current.get("marker") == "GeoLock Hub E2 isolated runtime v1"
                     and current.get("root") == str(root)
                     and current.get("run_id") == args.run_id
                     and current.get("setup_token") == meta["setup_token"])
        except Exception:
            owned = False
        if owned:
            data_dir = root / "data"
            if data_dir.is_dir():
                pg_ctl = str(pg_bin / ("pg_ctl.exe" if os.name == "nt" else "pg_ctl"))
                flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
                status = subprocess.run([pg_ctl, "-D", str(data_dir), "status"],
                    capture_output=True, text=True, timeout=20, check=False, creationflags=flags)
                if status.returncode == 0:
                    stopped = subprocess.run([pg_ctl, "-D", str(data_dir), "-m", "immediate", "-w", "stop"],
                        capture_output=True, text=True, timeout=20, check=False, creationflags=flags)
                    if stopped.returncode != 0:
                        raise RuntimeError("Setup failed and its owned PostgreSQL server could not be stopped; runtime retained for safety.")
                elif status.returncode not in (3,):
                    raise RuntimeError("Setup failed; PostgreSQL status is uncertain, so its runtime was retained for safety.")
            shutil.rmtree(root)
        raise


def role_connection(meta: dict, db: str, actor: str | None, *, service: bool = False):
    user = "e2_scheduler" if service else "e2_worker"
    if not service and not actor:
        raise RuntimeError("Authenticated NGO connections require a non-empty synthetic actor UUID.")
    jwt_subject = "" if service else actor
    conn = psycopg.connect(**conn_args(meta, db, user))
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute("SET ROLE service_role" if service else "SET ROLE authenticated")
        cur.execute("SELECT set_config('request.jwt.claim.sub',%s,false)", (jwt_subject,))
        cur.execute("SELECT set_config('request.jwt.claim.role',%s,false)",
                    ("service_role" if service else "authenticated",))
    return conn


def verify_scheduler_authority(conn, db: str) -> dict:
    """Verify the scheduler login's effective identity and recovery ACLs."""
    with conn.cursor() as cur:
        cur.execute("""SELECT session_user::text,current_user::text,auth.role(),auth.uid()::text,
          pg_has_role(session_user,'service_role','MEMBER'),
          has_schema_privilege(current_user,'public','USAGE'),
          has_schema_privilege(session_user,'public','USAGE'),
          has_function_privilege(current_user,'public.recover_expired_claims(integer)','EXECUTE'),
          has_function_privilege(session_user,'public.recover_expired_claims(integer)','EXECUTE')""")
        row = cur.fetchone()
    observed = {
        "session_user": row[0], "current_user": row[1], "auth_role": row[2], "auth_uid": row[3],
        "scheduler_is_service_role_member": row[4],
        "current_user_public_usage": row[5], "session_user_public_usage": row[6],
        "current_user_recovery_execute": row[7], "session_user_recovery_execute": row[8],
    }
    expected = {
        "session_user": "e2_scheduler", "current_user": "service_role",
        "auth_role": "service_role", "auth_uid": None,
        "scheduler_is_service_role_member": True,
        "current_user_public_usage": True, "session_user_public_usage": True,
        "current_user_recovery_execute": True, "session_user_recovery_execute": True,
    }
    checks = [{"check": key, "expected": value, "observed": observed[key],
               "status": "PASS" if observed[key] == value else "FAIL"}
              for key, value in expected.items()]
    if any(check["status"] != "PASS" for check in checks):
        raise RuntimeError(f"Scheduler authority preflight failed in {db}: "
                           + json.dumps({"checks": checks}, indent=2))
    return {"database": db, "checks": checks, "observed": observed}


def prepare_scheduler_privileges(meta: dict, db: str) -> dict:
    """Grant only local public-schema USAGE to service_role and verify effective ACLs."""
    with psycopg.connect(**conn_args(meta, db)) as conn, conn.cursor() as cur:
        cur.execute("""SELECT has_schema_privilege('service_role','public','USAGE'),
          has_function_privilege('service_role','public.recover_expired_claims(integer)','EXECUTE')""")
        before = cur.fetchone()
        cur.execute("GRANT USAGE ON SCHEMA public TO service_role")
    conn = role_connection(meta, db, None, service=True)
    try:
        evidence = verify_scheduler_authority(conn, db)
    finally:
        conn.close()
    evidence["service_role_schema_usage_before_local_grant"] = before[0]
    evidence["service_role_recovery_execute_before_local_grant"] = before[1]
    evidence["local_grant"] = "GRANT USAGE ON SCHEMA public TO service_role"
    return evidence


def fixture_uuid(run_id: str, *parts: object) -> str:
    return str(uuid5(NAMESPACE_URL, "geolock-e2:" + run_id + ":" + ":".join(map(str, parts))))


def build_donation_image_fixture(run_id: str, condition: str, scenario_id: str,
                                 request_id: str) -> tuple[dict, dict]:
    image_id = fixture_uuid(run_id, "donation-image", condition, scenario_id)
    path = f"{DONOR}/pending/{request_id}/{image_id}.jpg"
    image = {"storage_path": path, "content_type": DONATION_IMAGE_CONTENT_TYPE,
             "size_bytes": DONATION_IMAGE_SIZE_BYTES}
    storage_object = {"bucket_id": DONATION_IMAGE_BUCKET, "name": path,
                      "metadata": {"size": DONATION_IMAGE_SIZE_BYTES,
                                   "mimetype": DONATION_IMAGE_CONTENT_TYPE}}
    return image, storage_object


def build_donation_item_fixture() -> dict:
    """Build one Stage B category-backed 20 kg synthetic donation item."""
    return {"category_id": CATEGORY, "item_name": "E2 synthetic 20 kg item",
            "quantity": 1, "unit_weight_kg": 20, "unit_label": "piece",
            "item_condition": "GOOD"}


def ensure_synthetic_donor(meta: dict, db: str, run_id: str) -> None:
    """Idempotently create and verify the synthetic donor's auth/profile chain."""
    with psycopg.connect(**conn_args(meta, db)) as conn, conn.cursor() as cur:
        cur.execute("""INSERT INTO auth.users(id,email) VALUES(%s,%s)
          ON CONFLICT(id) DO NOTHING""", (DONOR, f"e2-donor-{run_id}@example.invalid"))
        cur.execute("""INSERT INTO public.user_profiles(user_id,full_name,role)
          VALUES(%s,'E2 Synthetic Donor','DONOR') ON CONFLICT(user_id) DO NOTHING""", (DONOR,))
        cur.execute("""INSERT INTO public.donor_profiles(user_id,role)
          VALUES(%s,'DONOR') ON CONFLICT(user_id) DO NOTHING""", (DONOR,))
        cur.execute("""SELECT
          EXISTS(SELECT 1 FROM auth.users WHERE id=%s),
          EXISTS(SELECT 1 FROM public.user_profiles WHERE user_id=%s AND role='DONOR'),
          EXISTS(SELECT 1 FROM public.donor_profiles WHERE user_id=%s AND role='DONOR'),
          NOT EXISTS(SELECT 1 FROM public.user_profiles WHERE user_id=%s AND role<>'DONOR'),
          NOT EXISTS(SELECT 1 FROM public.donor_profiles WHERE user_id=%s AND role<>'DONOR')""",
          (DONOR, DONOR, DONOR, DONOR, DONOR))
        present_auth, donor_role, donor_profile, no_profile_role_conflict, no_donor_role_conflict = cur.fetchone()
        if not all((present_auth, donor_role, donor_profile,
                    no_profile_role_conflict, no_donor_role_conflict)):
            raise RuntimeError(
                f"Synthetic donor fixture is inconsistent in {db}: "
                f"auth_user={present_auth}, user_profile_donor={donor_role}, "
                f"donor_profile={donor_profile}, role_conflicts="
                f"{not no_profile_role_conflict or not no_donor_role_conflict}.")


def initialize_synthetic_donors(meta: dict, run_id: str) -> None:
    """Seed and verify the local synthetic donor in both isolated databases."""
    for db in DATABASES.values():
        ensure_synthetic_donor(meta, db, run_id)


def cleanup_unattached_staged_image(meta: dict, db: str, path: str) -> None:
    """Delete only this failed trial's unreferenced staged storage object."""
    with psycopg.connect(**conn_args(meta, db)) as conn, conn.cursor() as cur:
        cur.execute("""DELETE FROM storage.objects o
          WHERE o.bucket_id=%s AND o.name=%s
            AND NOT EXISTS(SELECT 1 FROM public.donation_images i WHERE i.storage_path=o.name)
            AND NOT EXISTS(SELECT 1 FROM public.hub_batch_images i WHERE i.storage_path=o.name)""",
          (DONATION_IMAGE_BUCKET, path))
        cur.execute("""SELECT EXISTS(SELECT 1 FROM storage.objects
          WHERE bucket_id=%s AND name=%s)""", (DONATION_IMAGE_BUCKET, path))
        remains = cur.fetchone()[0]
    if remains:
        raise RuntimeError("Failed donation fixture left its staged image in storage; "
                           "it is referenced or could not be safely removed.")


def ensure_actors(meta: dict, db: str, run_id: str) -> list[str]:
    ensure_synthetic_donor(meta, db, run_id)
    actors = [ACTOR_A, ACTOR_B]
    actors.extend(fixture_uuid(run_id, "ngo", i) for i in range(3, 11))
    with psycopg.connect(**conn_args(meta, db)) as conn, conn.cursor() as cur:
        for i, actor in enumerate(actors, 1):
            cur.execute("INSERT INTO auth.users(id,email) VALUES(%s,%s) ON CONFLICT(id) DO NOTHING",
                        (actor, f"e2-ngo-{i}-{run_id}@example.invalid"))
            cur.execute("INSERT INTO public.user_profiles(user_id,full_name,role) VALUES(%s,%s,'NGO') ON CONFLICT(user_id) DO NOTHING",
                        (actor, f"E2 Synthetic NGO {i}"))
            cur.execute("""INSERT INTO public.ngo_profiles(user_id,ngo_name,registration_number,
              operating_address,latitude,longitude,road_node_id,location_verified_at,active_flag)
              VALUES(%s,%s,%s,'E2 synthetic local fixture',3.0,101.0,'101',clock_timestamp(),true)
              ON CONFLICT(user_id) DO NOTHING""", (actor, f"E2 Synthetic NGO {i}", f"E2-{run_id}-{i}"))
        # `ON CONFLICT DO NOTHING` is followed by read-only identity assertions.
        cur.execute("""SELECT count(*) FROM public.ngo_profiles
          WHERE user_id=ANY(%s::uuid[]) AND active_flag AND location_verified_at IS NOT NULL
            AND road_node_id IS NOT NULL""", (actors,))
        if cur.fetchone()[0] != len(actors):
            raise RuntimeError("Synthetic NGO identity fixture is incomplete or inconsistent.")
    return actors


def create_listing(meta: dict, db: str, run_id: str, condition: str, scenario_id: str) -> dict:
    # Guard every creation path, including isolated lease trials, before creating
    # a storage fixture or invoking the protected donation RPC.
    ensure_synthetic_donor(meta, db, run_id)
    req = fixture_uuid(run_id, "donation-create", scenario_id)
    image, storage_object = build_donation_image_fixture(run_id, condition, scenario_id, req)
    image_path = image["storage_path"]
    try:
        with psycopg.connect(**conn_args(meta, db)) as conn, conn.cursor() as cur:
            cur.execute("INSERT INTO storage.objects(bucket_id,name,metadata) VALUES(%s,%s,%s::jsonb)",
                        (storage_object["bucket_id"], storage_object["name"],
                         json.dumps(storage_object["metadata"])))
    except BaseException as stage_error:
        try:
            cleanup_unattached_staged_image(meta, db, image_path)
        except Exception as cleanup_error:
            raise RuntimeError(f"Staging failed and staged-image cleanup failed: {cleanup_error}") from stage_error
        raise
    items = [build_donation_item_fixture()]
    images = [image]
    conn = None
    try:
        conn = role_connection(meta, db, DONOR)
        with conn.cursor() as cur:
            cur.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
            cur.execute("""SELECT public.create_donation_with_images(
              %s::uuid,%s::text,%s::text,%s::text,%s::float8,%s::float8,
              %s::jsonb,%s::text,%s::jsonb)""",
              (req, f"E2 synthetic donation {scenario_id}", "Synthetic local contention fixture",
               "E2 local fixture", 3.01, 101.01, json.dumps(items), "102", json.dumps(images)))
            donation = str(cur.fetchone()[0])
            cur.execute("COMMIT")
    except BaseException as create_error:
        try:
            cleanup_unattached_staged_image(meta, db, image_path)
        except Exception as cleanup_error:
            raise RuntimeError(f"Donation fixture failed and staged-image cleanup failed: {cleanup_error}") from create_error
        raise
    finally:
        if conn is not None:
            conn.close()
    with psycopg.connect(**conn_args(meta, db)) as conn, conn.cursor() as cur:
        cur.execute("SELECT listing_id,listing_status,listing_weight_kg,listing_expires_at FROM public.listings WHERE donation_id=%s", (donation,))
        row = cur.fetchone()
        if row is None:
            raise RuntimeError("Protected donation workflow did not create its direct listing.")
        listing = str(row[0])
        cur.execute("SELECT donation_status,total_weight_kg FROM public.donations WHERE donation_id=%s", (donation,))
        donation_row = cur.fetchone()
        cur.execute("SELECT category_id FROM public.donation_items WHERE donation_id=%s", (donation,))
        item_rows = cur.fetchall()
        cur.execute("""SELECT count(*) FROM public.donation_claims WHERE listing_id=%s
          UNION ALL SELECT count(*) FROM public.claim_leases le JOIN public.donation_claims c USING(claim_id)
            WHERE c.listing_id=%s""", (listing, listing))
        counts = [x[0] for x in cur.fetchall()]
    if row[1] != "AVAILABLE" or donation_row[0] != "AVAILABLE" or float(row[2]) != 20.0 or counts != [0, 0]:
        raise RuntimeError("Fresh listing does not match the verified clean, claimable 20 kg fixture contract.")
    if not item_rows or any(str(x[0]) != CATEGORY for x in item_rows):
        raise RuntimeError("Donation item fixture category does not match the controlled category record.")
    return {"donation_id": donation, "listing_id": listing, "listing_status": row[1],
            "donation_status": donation_row[0], "listing_weight_kg": str(row[2]),
            "lease_minutes": LEASE_MINUTES, "image_path": image_path}


def discover_listing(meta: dict, db: str, actor: str, listing: str) -> bool:
    conn = role_connection(meta, db, actor)
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT listing_id FROM public.discover_eligible_listing_cards()")
            return any(str(row[0]) == listing for row in cur.fetchall())
    finally:
        conn.close()


def claim_connection(meta: dict, db: str, condition: str, actor: str):
    conn = role_connection(meta, db, actor)
    return conn


def run_attempt(conn, condition: str, actor: str, listing: str, request: str,
                barrier: threading.Barrier, timeouts: dict) -> dict:
    item = {"actor_id": actor, "request_id": request, "outcome": "UNCONFIRMED",
            "claim_id": None, "reason_code": None, "replayed": None,
            "retry_count": 0, "attempts": [], "latency_ms": None, "timed_out": False}
    try:
        barrier.wait(timeout=BARRIER_TIMEOUT_SECONDS)
    except Exception as exc:
        item["attempts"].append({"error": short_error(exc), "phase": "barrier"})
        return item
    started = time.perf_counter()
    for attempt_no in range(MAX_TRANSIENT_RETRIES + 1):
        try:
            with conn.cursor() as cur:
                cur.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
                cur.execute("SELECT set_config('statement_timeout',%s,true)", (f"{STATEMENT_TIMEOUT_MS}ms",))
                if condition == "protected":
                    cur.execute("SELECT public.claim_listing(%s::uuid,%s::uuid)", (listing, request))
                else:
                    cur.execute("SELECT e2_baseline.non_atomic_claim_listing(%s::uuid,%s::uuid,%s::integer)",
                                (listing, request, RACE_WINDOW_MS))
                response = cur.fetchone()[0]
                cur.execute("COMMIT")
            item.update(outcome=response.get("outcome", "INVALID_RESPONSE"),
                        claim_id=str(response["claim_id"]) if response.get("claim_id") else None,
                        reason_code=response.get("reason_code"), replayed=response.get("replayed", False))
            item["attempts"].append({"attempt": attempt_no + 1, "response": response})
            item["retry_count"] = attempt_no
            break
        except psycopg.Error as exc:
            try:
                conn.rollback()
            except Exception:
                pass
            error = short_error(exc)
            item["attempts"].append({"attempt": attempt_no + 1, "error": error})
            if error["sqlstate"] in ("40P01", "40001") and attempt_no < MAX_TRANSIENT_RETRIES:
                item["retry_count"] = attempt_no + 1
                continue
            item["outcome"] = "TIMEOUT" if error["category"] == "TIMEOUT" else "DATABASE_ERROR"
            item["timed_out"] = error["category"] == "TIMEOUT"
            break
        except Exception as exc:
            try:
                conn.rollback()
            except Exception:
                pass
            item["attempts"].append({"attempt": attempt_no + 1, "error": short_error(exc)})
            item["outcome"] = "CONNECTION_ERROR"
            break
    item["latency_ms"] = round((time.perf_counter() - started) * 1000.0, 3)
    try:
        conn.close()
    except Exception:
        pass
    return item


def snapshot_listing(meta: dict, db: str, listing: str) -> dict:
    with psycopg.connect(**conn_args(meta, db)) as conn, conn.cursor() as cur:
        cur.execute("""
          SELECT jsonb_build_object(
            'listing',(SELECT to_jsonb(l) FROM public.listings l WHERE listing_id=%s),
            'donation',(SELECT to_jsonb(d) FROM public.donations d JOIN public.listings l USING(donation_id) WHERE l.listing_id=%s),
            'claims',(SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY c.claim_id),'[]'::jsonb)
              FROM public.donation_claims c WHERE c.listing_id=%s),
            'active_claims',(SELECT count(*) FROM public.donation_claims c
              WHERE c.listing_id=%s AND c.claim_status IN ('ACTIVE','RECONCILIATION_REQUIRED')),
            'active_owners',(SELECT count(DISTINCT c.ngo_user_id) FROM public.donation_claims c
              JOIN public.claim_leases le USING(claim_id) WHERE c.listing_id=%s
                AND c.claim_status='ACTIVE' AND le.lease_status='ACTIVE' AND le.expires_at>clock_timestamp()),
            'active_leases',(SELECT count(*) FROM public.claim_leases le JOIN public.donation_claims c USING(claim_id)
              WHERE c.listing_id=%s AND le.lease_status='ACTIVE' AND le.expires_at>clock_timestamp()),
            'tasks',(SELECT count(*) FROM public.pickup_tasks t JOIN public.donation_claims c USING(claim_id) WHERE c.listing_id=%s),
            'claim_requests',(SELECT count(*) FROM public.claim_requests WHERE listing_id=%s),
            'attempt_audits',(SELECT count(*) FROM public.audit_events WHERE event_type='CLAIM_ATTEMPT' AND entity_id=%s),
            'donation_transition_audits',(SELECT count(*) FROM public.audit_events WHERE event_type='DONATION_STATUS_CHANGED'
              AND details->>'listing_id'=%s),
            'failure_receipts',(SELECT count(*) FROM public.operation_failure_events WHERE listing_id=%s
              AND operation_name='claim_listing'),
            'claim_links_ok',NOT EXISTS(SELECT 1 FROM public.donation_claims c WHERE c.listing_id=%s
              AND (NOT EXISTS(SELECT 1 FROM public.claim_leases le WHERE le.claim_id=c.claim_id)
                OR NOT EXISTS(SELECT 1 FROM public.pickup_tasks t WHERE t.claim_id=c.claim_id))),
            'request_audit_counts_ok',
              (SELECT count(*) FROM public.audit_events a WHERE a.event_type='CLAIM_ATTEMPT' AND a.entity_id=%s)
                =(SELECT count(*) FROM public.claim_requests WHERE listing_id=%s)
          )
        """, (
            listing, listing, listing, listing, listing, listing, listing,
            listing, listing, listing, listing, listing, listing, listing,
        ))
        result = cur.fetchone()[0]
    return result


def check_idempotency(meta: dict, db: str, condition: str, winner: dict, listing: str) -> dict:
    if not winner.get("request_id") or not winner.get("actor_id") or not winner.get("claim_id"):
        return {"checked": False, "reason": "No successful response to replay."}
    conn = role_connection(meta, db, winner["actor_id"])
    try:
        with conn.cursor() as cur:
            cur.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
            if condition == "protected":
                cur.execute("SELECT public.claim_listing(%s::uuid,%s::uuid)", (listing, winner["request_id"]))
            else:
                cur.execute("SELECT e2_baseline.non_atomic_claim_listing(%s::uuid,%s::uuid,%s::integer)",
                            (listing, winner["request_id"], RACE_WINDOW_MS))
            result = cur.fetchone()[0]
            cur.execute("COMMIT")
        return {"checked": True, "replayed": result.get("replayed") is True,
                "same_claim_id": str(result.get("claim_id")) == winner["claim_id"],
                "response": result}
    finally:
        conn.close()


def run_contention_trial(meta: dict, condition: str, run_id: str, seed: int,
                         concurrency: int, trial_no: int, actors: list[str]) -> tuple[dict, list[dict]]:
    scenario = f"{run_id}-C{concurrency}-T{trial_no:03d}"
    fixture = create_listing(meta, DATABASES[condition], run_id, condition, scenario)
    listing = fixture["listing_id"]
    eligible = {actor: discover_listing(meta, DATABASES[condition], actor, listing)
                for actor in actors[:concurrency]}
    requests = [fixture_uuid(run_id, "claim-request", concurrency, trial_no, actors[i])
                for i in range(concurrency)]
    if not all(eligible.values()):
        return ({"scenario_id": scenario, "fixture_id": scenario, "condition": condition,
                 "concurrency": concurrency, "trial_number": trial_no, "fixture": fixture,
                 "preflight_eligible": eligible, "completed": False,
                 "incomplete_reason": "One or more synthetic NGOs could not discover the fresh listing."}, [])
    # Keep the same actor ordering in paired conditions while varying it deterministically per trial.
    indices = list(range(concurrency))
    random.Random(seed ^ (concurrency << 12) ^ trial_no).shuffle(indices)
    participants = [(actors[i], requests[i]) for i in indices]
    barrier = threading.Barrier(concurrency)
    connections = []
    try:
        for actor, _ in participants:
            connections.append(claim_connection(meta, DATABASES[condition], condition, actor))
    except Exception as exc:
        for conn in connections:
            try: conn.close()
            except Exception: pass
        return ({"scenario_id": scenario, "fixture_id": scenario, "condition": condition,
                 "concurrency": concurrency, "trial_number": trial_no, "fixture": fixture,
                 "preflight_eligible": eligible, "completed": False,
                 "incomplete_reason": "Could not prepare every independent authenticated session.",
                 "setup_error": short_error(exc)}, [])
    started = utc_now()
    futures = []
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        for (actor, request), conn in zip(participants, connections):
            futures.append(pool.submit(run_attempt, conn, condition, actor, listing, request,
                                       barrier, {"connect": CONNECT_TIMEOUT_SECONDS,
                                                 "statement_ms": STATEMENT_TIMEOUT_MS}))
        results = [future.result() for future in futures]
    state = snapshot_listing(meta, DATABASES[condition], listing)
    successes = sum(r["outcome"] == "SUCCESS" for r in results)
    conflicts = sum(r["outcome"] == "CONFLICT" for r in results)
    ineligible = sum(r["outcome"] == "INELIGIBLE" for r in results)
    errors = sum(r["outcome"] in ("ERROR", "DATABASE_ERROR", "CONNECTION_ERROR", "TIMEOUT") for r in results)
    zero_winner = int(state.get("active_owners", 0)) == 0
    duplicate = int(state.get("active_owners", 0)) > 1
    winner = next((dict(r, request_id=participants[i][1]) for i, r in enumerate(results)
                   if r["outcome"] == "SUCCESS"), None)
    replay = check_idempotency(meta, DATABASES[condition], condition, winner, listing) if winner else {
        "checked": False, "reason": "No successful response to replay."}
    # This is an observed database invariant for either condition. The baseline
    # is allowed to violate it; the row records that result rather than failing.
    invariant = at_most_one_owner_preserved(state)
    audit_consistent = bool(state.get("claim_links_ok")) and bool(state.get("request_audit_counts_ok"))
    row = {
        "scenario_id": scenario, "pair_id": f"{run_id}-C{concurrency}-T{trial_no:03d}",
        "fixture_id": scenario, "condition": condition, "trial_number": trial_no,
        "concurrency": concurrency, "started_at": started, "completed_at": utc_now(),
        "fixture": fixture, "preflight_eligible": eligible, "successful_responses": successes,
        "committed_claims": state.get("active_claims", 0),
        "active_owners": state.get("active_owners", 0), "conflicting_committed_ownership": duplicate,
        "active_leases": state.get("active_leases", 0), "pickup_tasks": state.get("tasks", 0),
        "rejected_requests": conflicts + ineligible, "conflicts": conflicts, "ineligible": ineligible,
        "errors": errors, "timeouts": sum(bool(r.get("timed_out")) for r in results),
        "unexpected_zero_winner": zero_winner, "database_constraint_errors": sum(
            1 for r in results for a in r.get("attempts", [])
            if a.get("error", {}).get("category") == "CONSTRAINT"),
        "request_count": len(results), "claim_requests": state.get("claim_requests", 0),
        "claim_attempt_audits": state.get("attempt_audits", 0),
        "donation_transition_audits": state.get("donation_transition_audits", 0),
        "failure_receipts": state.get("failure_receipts", 0), "audit_consistent": audit_consistent,
        "at_most_one_owner_preserved": invariant, "state_reconciled": True,
        "completed": True, "state": state, "idempotency_replay": replay,
        "median_latency_ms": statistics.median([r["latency_ms"] for r in results if r.get("latency_ms") is not None])
            if any(r.get("latency_ms") is not None for r in results) else None,
        "max_latency_ms": max([r["latency_ms"] for r in results if r.get("latency_ms") is not None], default=None),
    }
    for i, result in enumerate(results):
        result.update({"scenario_id": scenario, "pair_id": row["pair_id"],
                       "condition": condition, "concurrency": concurrency,
                       "trial_number": trial_no, "listing_id": listing,
                       "donation_id": fixture["donation_id"], "request_id": participants[i][1]})
    return row, results


def at_most_one_owner_preserved(state: dict) -> bool:
    """Return whether the observed DB state has no more than one owner."""
    return int(state.get("active_owners", 0)) <= 1


def validate_contention_trial_count(trials_per_level: int) -> None:
    if not 1 <= trials_per_level <= MAX_CONTENTION_TRIALS_PER_LEVEL:
        raise RuntimeError(
            f"trials-per-level must be 1..{MAX_CONTENTION_TRIALS_PER_LEVEL}."
        )


def validate_lease_trial_count(trials: int) -> None:
    if not 1 <= trials <= MAX_LEASE_TRIALS:
        raise RuntimeError(f"Lease-trial count must be 1..{MAX_LEASE_TRIALS}.")


def register_run(meta: dict, db: str, run_id: str, condition: str, kind: str, seed: int) -> None:
    verify_local_identity({**meta, "condition": condition}, db)
    with psycopg.connect(**conn_args(meta, db)) as conn, conn.cursor() as cur:
        cur.execute("CREATE SCHEMA IF NOT EXISTS e2_experiment")
        cur.execute("""CREATE TABLE IF NOT EXISTS e2_experiment.run_registry(
          run_id text NOT NULL,condition text NOT NULL,kind text NOT NULL,seed bigint NOT NULL,
          status text NOT NULL CHECK(status IN ('STARTED','COMPLETE','INCOMPLETE')),
          started_at timestamptz NOT NULL DEFAULT clock_timestamp(),completed_at timestamptz,
          PRIMARY KEY(run_id,condition,kind))""")
        cur.execute("""INSERT INTO e2_experiment.run_registry(run_id,condition,kind,seed,status)
          VALUES(%s,%s,%s,%s,'STARTED')""", (run_id, condition, kind, seed))


def complete_run(meta: dict, db: str, run_id: str, condition: str, kind: str, complete: bool) -> None:
    with psycopg.connect(**conn_args(meta, db)) as conn, conn.cursor() as cur:
        cur.execute("""UPDATE e2_experiment.run_registry SET status=%s,completed_at=clock_timestamp()
          WHERE run_id=%s AND condition=%s AND kind=%s AND status='STARTED'""",
          ("COMPLETE" if complete else "INCOMPLETE", run_id, condition, kind))


def output_dir(run_id: str, condition: str, kind: str, custom: str | None) -> Path:
    base = Path(custom).resolve() if custom else SCRIPT_DIR / "results"
    if kind == "contention":
        return base / run_id / ("PROTECTED_ATOMIC" if condition == "protected" else "NON_ATOMIC_BASELINE")
    if kind == "lease":
        return base / run_id / "LEASE_RECOVERY"
    return base / run_id / "SMOKE" / ("PROTECTED_ATOMIC" if condition == "protected" else "NON_ATOMIC_BASELINE")


def write_run_artifacts(folder: Path, info: dict, trials: list[dict], requests: list[dict],
                        lease_trials: list[dict] | None = None) -> None:
    folder.mkdir(parents=True, exist_ok=False)
    (folder / "run_info.json").write_text(json.dumps(info, indent=2, default=str) + "\n", encoding="utf-8")
    if lease_trials is None:
        (folder / "trials.json").write_text(json.dumps(trials, indent=2, default=str) + "\n", encoding="utf-8")
        (folder / "requests.json").write_text(json.dumps(requests, indent=2, default=str) + "\n", encoding="utf-8")
        flatten_csv(folder / "trials.csv", trials)
        flatten_csv(folder / "requests.csv", requests)
    else:
        (folder / "lease_trials.json").write_text(json.dumps(lease_trials, indent=2, default=str) + "\n", encoding="utf-8")
        flatten_csv(folder / "lease_trials.csv", lease_trials)


def flatten_csv(path: Path, rows: list[dict]) -> None:
    keys = sorted({key for row in rows for key in row})
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=keys)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: json.dumps(row.get(key), default=str) if isinstance(row.get(key), (dict, list))
                             else row.get(key) for key in keys})


def run_contention(args, meta: dict, condition: str, kind: str) -> None:
    validate_contention_trial_count(args.trials_per_level)
    if args.smoke:
        sizes = (2,)
        trials_per = 1
        run_id = args.run_id + "-smoke"
    else:
        sizes = CONTENTION_LEVELS
        trials_per = args.trials_per_level
        run_id = args.run_id
    db = DATABASES[condition]
    seed = args.seed if args.seed is not None else secrets.randbits(32)
    folder = output_dir(run_id, condition, "smoke" if args.smoke else "contention", args.output_dir)
    if folder.exists():
        raise RuntimeError(f"Result folder already exists; refusing to overwrite: {folder}")
    register_run(meta, db, run_id, condition, "smoke" if args.smoke else "contention", seed)
    actors = ensure_actors(meta, db, run_id)
    trial_rows: list[dict] = []
    request_rows: list[dict] = []
    planned = sum(trials_per for _ in sizes)
    aborted = False
    try:
        for concurrency in sizes:
            for trial_no in range(1, trials_per + 1):
                row, requests = run_contention_trial(meta, condition, run_id, seed,
                                                     concurrency, trial_no, actors)
                trial_rows.append(row)
                request_rows.extend(requests)
                if not row.get("completed"):
                    aborted = True
        status = "INCOMPLETE" if aborted else "COMPLETE"
        info = {
            "experiment": "GeoLock Hub E2 Atomic vs Non-Atomic Claiming",
            "run_id": run_id, "condition": condition, "run_kind": "smoke" if args.smoke else "contention",
            "started_at": trial_rows[0].get("started_at") if trial_rows else utc_now(),
            "completed_at": utc_now(), "status": status, "database": db,
            "database_identity": meta["database_identities"][condition],
            "seed": seed, "source_git": meta["git"], "source_hashes": meta["source_hashes"],
            "observed_function_hashes": meta["schema_source_verification"],
            "isolation": "READ COMMITTED", "barrier": "threading.Barrier; one authenticated PostgreSQL session per NGO",
            "planned_trials": planned, "trials_per_concurrency": trials_per,
            "concurrency_levels": list(sizes), "worker_retry_policy": {"max_transient_retries": MAX_TRANSIENT_RETRIES,
                "transient_sqlstates": ["40P01", "40001"], "same_request_uuid_on_retry": True},
            "timeouts": {"connect_seconds": CONNECT_TIMEOUT_SECONDS, "statement_ms": STATEMENT_TIMEOUT_MS,
                "barrier_seconds": BARRIER_TIMEOUT_SECONDS},
            "baseline_race_window_ms": RACE_WINDOW_MS, "lease_minutes": LEASE_MINUTES,
            "fixture": {"kind": "new protected photo-backed direct donation", "weight_kg": 20,
                "ngo_identity_count": len(actors), "all_ngo_identities_synthetic": True,
                "road_check": "local Stage B deterministic eligible-result test double; not a road-graph experiment"},
            "schema_difference": meta["baseline_schema_difference"],
            "trial_rows": len(trial_rows), "request_rows": len(request_rows),
        }
        write_run_artifacts(folder, info, trial_rows, request_rows)
        complete_run(meta, db, run_id, condition, "smoke" if args.smoke else "contention", not aborted)
        print(json.dumps({"status": status, "result_folder": str(folder), "database": db,
                          "trials": len(trial_rows), "requests": len(request_rows),
                          "duplicate_trials": sum(bool(r.get("conflicting_committed_ownership")) for r in trial_rows),
                          "incomplete_trials": sum(not r.get("completed") for r in trial_rows)}, indent=2))
    except BaseException:
        complete_run(meta, db, run_id, condition, "smoke" if args.smoke else "contention", False)
        raise


def as_ngo(db: str, actor: str, meta: dict) -> dict:
    return {"actor_id": actor, "connection_user": "e2_worker", "database": db,
            "host": "127.0.0.1", "port": meta["port"]}


def adjust_fixture_lease(meta: dict, db: str, claim: str) -> None:
    # Only the newly created fixture row is adjusted. The lease interval remains 360 minutes.
    with psycopg.connect(**conn_args(meta, db)) as conn, conn.cursor() as cur:
        cur.execute("""UPDATE public.claim_leases SET issued_at=clock_timestamp()-interval '7 hours',
          expires_at=clock_timestamp()-interval '1 hour'
          WHERE claim_id=%s AND lease_status='ACTIVE'
            AND round(extract(epoch FROM(expires_at-issued_at))/60)=360""", (claim,))
        if cur.rowcount != 1:
            raise RuntimeError("Isolated fixture lease could not be controlled without changing its 360-minute duration.")


def call_recovery(meta: dict, db: str) -> int:
    conn = role_connection(meta, db, None, service=True)
    try:
        verify_scheduler_authority(conn, db)
        with conn.cursor() as cur:
            cur.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
            cur.execute("SELECT set_config('statement_timeout',%s,true)", (f"{STATEMENT_TIMEOUT_MS}ms",))
            cur.execute("SELECT public.recover_expired_claims(1)")
            count = cur.fetchone()[0]
            cur.execute("COMMIT")
        return int(count)
    finally:
        conn.close()


def claim_one(meta: dict, condition: str, actor: str, listing: str, request: str) -> dict:
    conn = role_connection(meta, DATABASES[condition], actor)
    try:
        with conn.cursor() as cur:
            cur.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
            cur.execute("SELECT set_config('statement_timeout',%s,true)", (f"{STATEMENT_TIMEOUT_MS}ms",))
            if condition == "protected":
                cur.execute("SELECT public.claim_listing(%s::uuid,%s::uuid)", (listing, request))
            else:
                cur.execute("SELECT e2_baseline.non_atomic_claim_listing(%s::uuid,%s::uuid,%s::integer)",
                            (listing, request, RACE_WINDOW_MS))
            out = cur.fetchone()[0]
            cur.execute("COMMIT")
            return out
    finally:
        conn.close()


def lease_state(meta: dict, db: str, listing: str) -> dict:
    with psycopg.connect(**conn_args(meta, db)) as conn, conn.cursor() as cur:
        cur.execute("""SELECT jsonb_build_object(
          'listing_status',(SELECT listing_status FROM public.listings WHERE listing_id=%s),
          'donation_status',(SELECT d.donation_status FROM public.donations d JOIN public.listings l USING(donation_id) WHERE l.listing_id=%s),
          'claims',(SELECT coalesce(jsonb_agg(jsonb_build_object('claim_id',c.claim_id,'ngo_user_id',c.ngo_user_id,
             'claim_status',c.claim_status) ORDER BY c.claimed_at),'[]'::jsonb)
             FROM public.donation_claims c WHERE c.listing_id=%s),
          'active_claims',(SELECT count(*) FROM public.donation_claims WHERE listing_id=%s AND claim_status='ACTIVE'),
          'active_leases',(SELECT count(*) FROM public.claim_leases le JOIN public.donation_claims c USING(claim_id)
             WHERE c.listing_id=%s AND le.lease_status='ACTIVE' AND le.expires_at>clock_timestamp()),
          'tasks',(SELECT count(*) FROM public.pickup_tasks t JOIN public.donation_claims c USING(claim_id) WHERE c.listing_id=%s),
          'recovery_audits',(SELECT count(*) FROM public.audit_events WHERE event_type='LEASE_RECOVERY'
             AND details->>'listing_id'=%s),
          'claim_attempt_audits',(SELECT count(*) FROM public.audit_events WHERE event_type='CLAIM_ATTEMPT' AND entity_id=%s))""",
          (listing,listing,listing,listing,listing,listing,listing,listing))
        return cur.fetchone()[0]


def run_lease_trial(meta: dict, run_id: str, index: int, actors: list[str]) -> dict:
    condition = "protected"
    db = DATABASES[condition]
    scenario = f"{run_id}-LEASE-{index:03d}"
    fixture = create_listing(meta, db, run_id, condition, scenario)
    listing = fixture["listing_id"]
    actor_a, actor_b = actors[:2]
    request_a = fixture_uuid(run_id, "lease-claim-a", index)
    request_b = fixture_uuid(run_id, "lease-claim-b", index)
    before_minutes = None
    with psycopg.connect(**conn_args(meta, db)) as conn, conn.cursor() as cur:
        cur.execute("SELECT claim_lease_minutes FROM public.coordination_config WHERE singleton")
        before_minutes = cur.fetchone()[0]
    first = claim_one(meta, condition, actor_a, listing, request_a)
    if first.get("outcome") != "SUCCESS":
        return {"scenario_id": scenario, "trial_number": index, "completed": False,
                "reason": "Initial NGO A claim did not succeed", "first_response": first,
                "fixture": fixture}
    claim_a = str(first["claim_id"])
    with psycopg.connect(**conn_args(meta, db)) as conn, conn.cursor() as cur:
        cur.execute("SELECT round(extract(epoch FROM(expires_at-issued_at))/60)::integer FROM public.claim_leases WHERE claim_id=%s", (claim_a,))
        original_duration = cur.fetchone()[0]
    adjust_fixture_lease(meta, db, claim_a)
    recovered = call_recovery(meta, db)
    after_recovery = lease_state(meta, db, listing)
    second = claim_one(meta, condition, actor_b, listing, request_b)
    final = lease_state(meta, db, listing)
    recovered_state = (after_recovery.get("listing_status") == "AVAILABLE"
        and after_recovery.get("donation_status") == "AVAILABLE"
        and recovered == 1
        and any(c.get("claim_id") == claim_a and c.get("claim_status") == "RELEASED"
                for c in after_recovery.get("claims", [])))
    reclaimer = second.get("outcome") == "SUCCESS" and str(second.get("claim_id")) != claim_a
    valid_owner_count = final.get("active_claims", 0)
    lease_ok = (before_minutes == LEASE_MINUTES and original_duration == LEASE_MINUTES
        and recovered_state and reclaimer and valid_owner_count == 1
        and final.get("active_leases") == 1 and final.get("tasks") == 2
        and final.get("recovery_audits") == 1)
    return {
        "scenario_id": scenario, "pair_id": scenario, "trial_number": index,
        "condition": "PROTECTED_ATOMIC", "database": db, "fixture": fixture,
        "ngo_a": actor_a, "ngo_b": actor_b, "request_a": request_a, "request_b": request_b,
        "claim_a": claim_a, "first_response": first, "recovery_rows": recovered,
        "second_response": second, "configured_lease_minutes": before_minutes,
        "original_lease_duration_minutes": original_duration,
        "fixture_time_control": "backdated only this new test lease; issued_at/expires_at retain 360-minute interval",
        "state_after_recovery": after_recovery, "final_state": final,
        "released_expired_claim": recovered_state, "ngo_b_reclaimed": reclaimer,
        "valid_active_owner_count": valid_owner_count,
        "at_most_one_valid_owner": valid_owner_count <= 1,
        "lease_recovery_success": bool(lease_ok), "completed": True,
    }


def run_lease(args, meta: dict) -> None:
    validate_lease_trial_count(args.trials)
    run_id = args.run_id + ("-lease-smoke" if args.smoke else "")
    seed = args.seed if args.seed is not None else secrets.randbits(32)
    folder = output_dir(run_id, "protected", "lease", args.output_dir)
    if folder.exists():
        raise RuntimeError(f"Result folder already exists; refusing to overwrite: {folder}")
    register_run(meta, DATABASES["protected"], run_id, "protected", "lease", seed)
    actors = ensure_actors(meta, DATABASES["protected"], run_id)
    rows = []
    try:
        for i in range(1, args.trials + 1):
            rows.append(run_lease_trial(meta, run_id, i, actors))
        info = {
            "experiment": "GeoLock Hub E2 lease expiry and reclaim",
            "run_id": run_id, "condition": "PROTECTED_ATOMIC", "run_kind": "lease_smoke" if args.smoke else "lease_recovery",
            "status": "COMPLETE" if all(row.get("completed") for row in rows) else "INCOMPLETE",
            "started_at": rows[0].get("started_at", utc_now()) if rows else utc_now(), "completed_at": utc_now(),
            "database": DATABASES["protected"], "database_identity": meta["database_identities"]["protected"],
            "seed": seed, "source_git": meta["git"], "source_hashes": meta["source_hashes"],
            "observed_function_hashes": meta["schema_source_verification"], "isolation": "READ COMMITTED",
            "scheduler_privilege_evidence": meta["scheduler_privilege_evidence"]["protected"],
            "planned_trials": args.trials, "trials_completed": sum(bool(r.get("completed")) for r in rows),
            "lease_minutes": LEASE_MINUTES, "recovery_rpc": "public.recover_expired_claims(integer)",
            "recovery_called_as": "e2_scheduler SET ROLE service_role with auth.role()=service_role; not postgres session",
            "fixture_time_control": "local fixture only; backdate issued_at/expires_at while preserving exactly 360 minutes",
            "road_check": "local Stage B deterministic eligible-result test double; not a road-graph experiment",
        }
        write_run_artifacts(folder, info, [], [], rows)
        complete_run(meta, DATABASES["protected"], run_id, "protected", "lease", all(r.get("completed") for r in rows))
        print(json.dumps({"status": info["status"], "result_folder": str(folder),
                          "trials": len(rows), "recovery_successes": sum(bool(r.get("lease_recovery_success")) for r in rows)}, indent=2))
    except BaseException:
        complete_run(meta, DATABASES["protected"], run_id, "protected", "lease", False)
        raise


def cleanup(args) -> None:
    requested_root = Path(args.root).expanduser()
    if requested_root.is_symlink():
        raise RuntimeError("Cleanup refuses a symlink runtime path.")
    root = requested_root.resolve()
    meta = load_runtime(root)
    if args.confirm != CONFIRM_CLEANUP:
        raise RuntimeError(f"Cleanup requires --confirm {CONFIRM_CLEANUP}.")
    temp_root = Path(tempfile.gettempdir()).resolve()
    data = (root / "data").resolve()
    if (not root.is_relative_to(temp_root) or root.name != f"GeoLockE2-{meta['run_id']}"
            or not data.is_relative_to(root) or not meta.get("setup_token")):
        raise RuntimeError("Cleanup path does not match the marked E2-only runtime.")
    pg_ctl = str(Path(meta["pg_bin"]) / ("pg_ctl.exe" if os.name == "nt" else "pg_ctl"))
    result = subprocess.run([pg_ctl, "-D", str(data), "-m", "fast", "-w", "stop"],
        capture_output=True, text=True, timeout=30,
        creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
    if result.returncode != 0:
        raise RuntimeError("Local E2 PostgreSQL did not stop cleanly; folder retained for inspection.")
    shutil.rmtree(root)
    print(json.dumps({"status": "CLEANED", "removed_runtime_root": str(root)}, indent=2))


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("setup", help="Create a fresh loopback PostgreSQL cluster and both E2 databases.")
    p.add_argument("--root", required=True)
    p.add_argument("--run-id", required=True)
    p.add_argument("--pg-bin")
    p.set_defaults(func=setup)
    for command in ("smoke", "contention"):
        p = sub.add_parser(command)
        p.add_argument("--root", required=True)
        p.add_argument("--condition", required=True, choices=("protected", "non-atomic"))
        p.add_argument("--run-id", required=True)
        p.add_argument("--seed", type=int)
        p.add_argument("--trials-per-level", type=int, default=50)
        p.add_argument("--output-dir")
        p.set_defaults(func=run_contention, smoke=(command == "smoke"))
    p = sub.add_parser("lease", help="Run only the protected 100-trial isolated lease-recovery experiment.")
    p.add_argument("--root", required=True)
    p.add_argument("--run-id", required=True)
    p.add_argument("--seed", type=int)
    p.add_argument("--trials", type=int, default=100)
    p.add_argument("--output-dir")
    p.add_argument("--smoke", action="store_true")
    p.set_defaults(func=run_lease)
    p = sub.add_parser("cleanup", help="Stop and remove only the marked temporary E2 runtime.")
    p.add_argument("--root", required=True)
    p.add_argument("--confirm", required=True)
    p.set_defaults(func=cleanup)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.command != "setup":
            meta = load_runtime(Path(args.root))
            if meta.get("status") != "READY":
                raise RuntimeError("E2 runtime is not marked READY.")
            if args.command in ("smoke", "contention"):
                run_contention(args, meta, args.condition, "smoke" if args.smoke else "contention")
            elif args.command == "lease":
                run_lease(args, meta)
            else:
                args.func(args)
        else:
            args.func(args)
        return 0
    except Exception as exc:
        # Avoid printing connection strings, environment variables, SQL bodies or raw tokens.
        print(f"E2 runner stopped: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
