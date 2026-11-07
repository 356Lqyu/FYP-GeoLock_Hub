"""Run the actual history-reader migration on a disposable PostgreSQL 17."""

from pathlib import Path
import json
import os
import shutil
import socket
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "supabase/migrations/20261104_released_claim_history_readers.sql"
BIN = Path(r"C:\Program Files\PostgreSQL\17\bin")
OWNER = "aaaaaaaa-0000-4000-8000-000000000001"
FOREIGN = "bbbbbbbb-0000-4000-8000-000000000001"

SCHEMA = r"""
CREATE ROLE anon;
CREATE ROLE authenticated;
CREATE ROLE service_role;
CREATE SCHEMA auth;
CREATE SCHEMA routing_private;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS
  $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
GRANT USAGE ON SCHEMA auth TO PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres GRANT EXECUTE ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres GRANT EXECUTE ON FUNCTIONS TO anon;

CREATE TABLE public.ngo_profiles(user_id uuid PRIMARY KEY,active_flag boolean NOT NULL);
CREATE TABLE public.donation_claims(
 claim_id uuid PRIMARY KEY, listing_id uuid NOT NULL, ngo_user_id uuid NOT NULL,
 claim_status text NOT NULL, close_reason text, closed_at timestamptz, claimed_at timestamptz NOT NULL
);
CREATE TABLE public.claim_leases(
 lease_id uuid PRIMARY KEY,claim_id uuid UNIQUE NOT NULL,lease_status text NOT NULL,
 issued_at timestamptz NOT NULL,expires_at timestamptz NOT NULL,closed_at timestamptz,release_reason text
);
CREATE TABLE public.listings(
 listing_id uuid PRIMARY KEY,source_type text NOT NULL,donation_id uuid,batch_id uuid,
 listing_status text,pickup_latitude double precision,pickup_longitude double precision,
 listing_weight_kg numeric
);
CREATE TABLE public.donations(
 donation_id uuid PRIMARY KEY,title text NOT NULL,total_weight_kg numeric,
 donation_status text NOT NULL,pickup_address text,latitude double precision,
 longitude double precision,pickup_road_node_id text,created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.donation_categories(category_id uuid PRIMARY KEY,category_name text NOT NULL);
CREATE TABLE public.donation_items(
 item_id uuid PRIMARY KEY,donation_id uuid NOT NULL,category_id uuid NOT NULL,
 item_name text NOT NULL,description text,quantity integer NOT NULL,unit_label text NOT NULL,
 unit_weight_kg numeric NOT NULL,item_condition text NOT NULL,created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.hub_batches(batch_id uuid PRIMARY KEY,hub_id uuid);
CREATE TABLE public.community_hubs(
 hub_id uuid PRIMARY KEY,address_text text NOT NULL,latitude double precision NOT NULL,
 longitude double precision NOT NULL
);
CREATE TABLE public.hub_batch_members(
 batch_id uuid NOT NULL,donation_id uuid NOT NULL,membership_status text NOT NULL
);
CREATE TABLE public.donation_images(donation_id uuid,display_order integer,storage_path text);
CREATE TABLE public.hub_batch_images(batch_id uuid,is_primary boolean,storage_path text);
CREATE TABLE public.claim_reconciliation_cases(
 case_id uuid PRIMARY KEY,claim_id uuid NOT NULL,listing_id uuid NOT NULL,donation_id uuid,
 source_type text NOT NULL,case_status text NOT NULL,opened_at timestamptz NOT NULL,
 resolved_at timestamptz,resolution_reason text
);
CREATE TABLE public.pickup_tasks(
 task_id uuid PRIMARY KEY,claim_id uuid NOT NULL,listing_id uuid NOT NULL,ngo_user_id uuid NOT NULL,
 pickup_road_node_id text NOT NULL,load_kg numeric NOT NULL,task_status text NOT NULL,created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.pickup_routes(
 route_id uuid PRIMARY KEY,ngo_user_id uuid NOT NULL,vehicle_id uuid NOT NULL,
 validation_reference text,route_status text NOT NULL,matrix_id text,
 total_distance_km numeric,total_duration_min numeric,departure_at timestamptz
);
CREATE TABLE public.pickup_route_stops(route_id uuid,task_id uuid,planned_arrival timestamptz);

CREATE TABLE routing_private.bindings(
 route_id uuid,ngo_id uuid,vehicle_id uuid,candidate_id uuid,plan jsonb,
 started_at timestamptz,closed_at timestamptz,departure_at timestamptz
);
CREATE TABLE routing_private.candidates(candidate_id uuid,snapshot_id uuid,digest text);
CREATE TABLE routing_private.validations(candidate_id uuid,candidate_digest text);
CREATE TABLE routing_private.snapshots(snapshot_id uuid,matrix_id uuid,body jsonb);
CREATE TABLE routing_private.items(
 route_id uuid,task_id uuid,ordinal integer,collected_at timestamptz,released_at timestamptz,
 consumed_at timestamptz,observation_digest text
);
CREATE FUNCTION routing_private.check_remaining(uuid,uuid,timestamptz) RETURNS void
 LANGUAGE sql AS $$ SELECT $$;
CREATE FUNCTION routing_private.snapshot_task(jsonb,uuid) RETURNS jsonb LANGUAGE sql AS $$
 SELECT '{"listing":{"pickup_latitude":3.1,"pickup_longitude":101.6},"task":{"pickup_road_node_id":"NODE-1","load_kg":4}}'::jsonb
$$;
CREATE FUNCTION routing_private.observe_task(uuid) RETURNS jsonb LANGUAGE sql AS $$ SELECT '{}'::jsonb $$;
CREATE FUNCTION routing_private.task_digest(jsonb) RETURNS text LANGUAGE sql AS $$ SELECT 'digest' $$;
CREATE FUNCTION public.get_my_authorized_route_pre_deferral(uuid) RETURNS jsonb
 LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,pg_temp AS $$ SELECT '{}'::jsonb $$;
GRANT EXECUTE ON FUNCTION public.get_my_authorized_route_pre_deferral(uuid) TO authenticated;

INSERT INTO public.ngo_profiles VALUES
 ('aaaaaaaa-0000-4000-8000-000000000001',true),
 ('bbbbbbbb-0000-4000-8000-000000000001',true);
INSERT INTO public.donation_categories VALUES
 ('90000000-0000-4000-8000-000000000001','Food');
INSERT INTO public.community_hubs VALUES
 ('80000000-0000-4000-8000-000000000001','Community Hub',3.2,101.7);
INSERT INTO public.hub_batches VALUES
 ('70000000-0000-4000-8000-000000000001','80000000-0000-4000-8000-000000000001');
INSERT INTO public.donations(donation_id,title,total_weight_kg,donation_status,pickup_address,latitude,longitude)
VALUES
 ('30000000-0000-4000-8000-000000000001','Released goods',10,'AVAILABLE','SECRET DIRECT ADDRESS',3.1,101.6),
 ('30000000-0000-4000-8000-000000000002','Expired goods',7,'AVAILABLE','SECRET EXPIRED ADDRESS',3.3,101.8),
 ('30000000-0000-4000-8000-000000000003','Active goods',5,'CLAIMED','ACTIVE ADDRESS',3.4,101.9),
 ('30000000-0000-4000-8000-000000000004','Pending goods',6,'CLAIMED','PENDING ADDRESS',3.5,102.0),
 ('30000000-0000-4000-8000-000000000005','Foreign goods',8,'AVAILABLE','FOREIGN ADDRESS',3.6,102.1),
 ('30000000-0000-4000-8000-000000000006','Completed goods',9,'COLLECTED','COMPLETED ADDRESS',3.7,102.2),
 ('30000000-0000-4000-8000-000000000007','Review goods',11,'CLAIMED','REVIEW ADDRESS',3.8,102.3),
 ('30000000-0000-4000-8000-000000000008','Cancelled goods',12,'AVAILABLE','CANCELLED ADDRESS',3.9,102.4),
 ('30000000-0000-4000-8000-000000000009','Hub donation',4,'AVAILABLE',NULL,NULL,NULL);
INSERT INTO public.listings VALUES
 ('20000000-0000-4000-8000-000000000001','DIRECT_DONATION','30000000-0000-4000-8000-000000000001',NULL,'AVAILABLE',3.1,101.6,10),
 ('20000000-0000-4000-8000-000000000002','DIRECT_DONATION','30000000-0000-4000-8000-000000000002',NULL,'AVAILABLE',3.3,101.8,7),
 ('20000000-0000-4000-8000-000000000003','DIRECT_DONATION','30000000-0000-4000-8000-000000000003',NULL,'CLAIMED',3.4,101.9,5),
 ('20000000-0000-4000-8000-000000000004','DIRECT_DONATION','30000000-0000-4000-8000-000000000004',NULL,'CLAIMED',3.5,102.0,6),
 ('20000000-0000-4000-8000-000000000005','DIRECT_DONATION','30000000-0000-4000-8000-000000000005',NULL,'AVAILABLE',3.6,102.1,8),
 ('20000000-0000-4000-8000-000000000006','DIRECT_DONATION','30000000-0000-4000-8000-000000000006',NULL,'AVAILABLE',3.7,102.2,9),
 ('20000000-0000-4000-8000-000000000007','DIRECT_DONATION','30000000-0000-4000-8000-000000000007',NULL,'CLAIMED',3.8,102.3,11),
 ('20000000-0000-4000-8000-000000000008','DIRECT_DONATION','30000000-0000-4000-8000-000000000008',NULL,'AVAILABLE',3.9,102.4,12),
 ('20000000-0000-4000-8000-000000000009','HUB_BATCH',NULL,'70000000-0000-4000-8000-000000000001','AVAILABLE',3.2,101.7,4);
INSERT INTO public.hub_batch_members VALUES
 ('70000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000009','ACTIVE');
INSERT INTO public.donation_items VALUES
 ('40000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','90000000-0000-4000-8000-000000000001','Canned beans','Tinned food',2,'cans',0.5,'GOOD',now()),
 ('40000000-0000-4000-8000-000000000002','30000000-0000-4000-8000-000000000002','90000000-0000-4000-8000-000000000001','Expired rice','Dry food',1,'bag',7,'GOOD',now()),
 ('40000000-0000-4000-8000-000000000009','30000000-0000-4000-8000-000000000009','90000000-0000-4000-8000-000000000001','Hub rice','Dry rice',1,'bag',4,'GOOD',now());
INSERT INTO public.donation_claims VALUES
 ('10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','aaaaaaaa-0000-4000-8000-000000000001','RELEASED','EXPIRED_SAFE_RELEASE',now()-interval '1 day',now()-interval '2 days'),
 ('10000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000002','aaaaaaaa-0000-4000-8000-000000000001','EXPIRED','LEASE_EXPIRED',now()-interval '1 day',now()-interval '2 days'),
 ('10000000-0000-4000-8000-000000000003','20000000-0000-4000-8000-000000000003','aaaaaaaa-0000-4000-8000-000000000001','ACTIVE',NULL,NULL,now()-interval '2 hours'),
 ('10000000-0000-4000-8000-000000000004','20000000-0000-4000-8000-000000000004','aaaaaaaa-0000-4000-8000-000000000001','ACTIVE',NULL,NULL,now()-interval '2 hours'),
 ('10000000-0000-4000-8000-000000000005','20000000-0000-4000-8000-000000000005','bbbbbbbb-0000-4000-8000-000000000001','RELEASED','OTHER_NGO',now()-interval '1 day',now()-interval '2 days'),
 ('10000000-0000-4000-8000-000000000006','20000000-0000-4000-8000-000000000006','aaaaaaaa-0000-4000-8000-000000000001','COMPLETED','PICKUP_COMPLETED',now()-interval '1 hour',now()-interval '2 days'),
 ('10000000-0000-4000-8000-000000000007','20000000-0000-4000-8000-000000000007','aaaaaaaa-0000-4000-8000-000000000001','RECONCILIATION_REQUIRED','UNCERTAIN',NULL,now()-interval '2 hours'),
 ('10000000-0000-4000-8000-000000000008','20000000-0000-4000-8000-000000000008','aaaaaaaa-0000-4000-8000-000000000001','CANCELLED','CANCELLED_BY_NGO',now()-interval '1 day',now()-interval '2 days'),
 ('10000000-0000-4000-8000-000000000009','20000000-0000-4000-8000-000000000009','aaaaaaaa-0000-4000-8000-000000000001','RELEASED','EXPIRED_SAFE_RELEASE',now()-interval '1 day',now()-interval '2 days');
INSERT INTO public.claim_leases VALUES
 ('11000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','RELEASED',now()-interval '3 days',now()-interval '2 days',now()-interval '1 day','EXPIRED_SAFE_RELEASE'),
 ('11000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002','EXPIRED',now()-interval '3 days',now()-interval '2 days',now()-interval '1 day','LEASE_EXPIRED'),
 ('11000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000003','ACTIVE',now()-interval '1 day',now()+interval '1 day',NULL,NULL),
 ('11000000-0000-4000-8000-000000000004','10000000-0000-4000-8000-000000000004','ACTIVE',now()-interval '1 day',now()-interval '1 hour',NULL,NULL),
 ('11000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000005','RELEASED',now()-interval '3 days',now()-interval '2 days',now()-interval '1 day','OTHER_NGO'),
 ('11000000-0000-4000-8000-000000000006','10000000-0000-4000-8000-000000000006','COMPLETED',now()-interval '3 days',now()-interval '2 days',now()-interval '1 day','PICKUP_COMPLETED'),
 ('11000000-0000-4000-8000-000000000007','10000000-0000-4000-8000-000000000007','RECONCILIATION_REQUIRED',now()-interval '3 days',now()-interval '2 days',NULL,NULL),
 ('11000000-0000-4000-8000-000000000008','10000000-0000-4000-8000-000000000008','RELEASED',now()-interval '3 days',now()-interval '2 days',now()-interval '1 day','CANCELLED_BY_NGO'),
 ('11000000-0000-4000-8000-000000000009','10000000-0000-4000-8000-000000000009','RELEASED',now()-interval '3 days',now()-interval '2 days',now()-interval '1 day','EXPIRED_SAFE_RELEASE');
INSERT INTO public.claim_reconciliation_cases VALUES
 ('50000000-0000-4000-8000-000000000006','10000000-0000-4000-8000-000000000006','20000000-0000-4000-8000-000000000006','30000000-0000-4000-8000-000000000006','DIRECT_DONATION','RESOLVED_COLLECTED',now()-interval '2 days',now()-interval '1 day','BOTH_PARTIES_CONFIRMED_HANDOVER'),
 ('50000000-0000-4000-8000-000000000007','10000000-0000-4000-8000-000000000007','20000000-0000-4000-8000-000000000007','30000000-0000-4000-8000-000000000007','DIRECT_DONATION','OPEN',now()-interval '1 hour',NULL,NULL);
INSERT INTO public.donation_images VALUES ('30000000-0000-4000-8000-000000000001',1,'donation/one.jpg');
INSERT INTO public.hub_batch_images VALUES ('70000000-0000-4000-8000-000000000001',true,'batch/cover.jpg');

INSERT INTO public.pickup_tasks(task_id,claim_id,listing_id,ngo_user_id,pickup_road_node_id,load_kg,task_status)
VALUES
 ('60000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','aaaaaaaa-0000-4000-8000-000000000001','NODE-1',10,'PLANNED'),
 ('60000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000003','20000000-0000-4000-8000-000000000003','aaaaaaaa-0000-4000-8000-000000000001','NODE-3',5,'PLANNED');
INSERT INTO public.pickup_routes VALUES
 ('61000000-0000-4000-8000-000000000001','aaaaaaaa-0000-4000-8000-000000000001','62000000-0000-4000-8000-000000000001','63000000-0000-4000-8000-000000000001','IN_PROGRESS','64000000-0000-4000-8000-000000000001',4,20,now()),
 ('61000000-0000-4000-8000-000000000003','aaaaaaaa-0000-4000-8000-000000000001','62000000-0000-4000-8000-000000000003','63000000-0000-4000-8000-000000000003','IN_PROGRESS','64000000-0000-4000-8000-000000000003',4,20,now());
INSERT INTO routing_private.snapshots VALUES
 ('65000000-0000-4000-8000-000000000001','64000000-0000-4000-8000-000000000001','{"ngo":{"road_node_id":"DEPOT","latitude":3.0,"longitude":101.5},"vehicles":[{"vehicle_id":"62000000-0000-4000-8000-000000000001","vehicle_label":"A"}]}'),
 ('65000000-0000-4000-8000-000000000003','64000000-0000-4000-8000-000000000003','{"ngo":{"road_node_id":"DEPOT","latitude":3.0,"longitude":101.5},"vehicles":[{"vehicle_id":"62000000-0000-4000-8000-000000000003","vehicle_label":"B"}]}');
INSERT INTO routing_private.candidates VALUES
 ('63000000-0000-4000-8000-000000000001','65000000-0000-4000-8000-000000000001','digest1'),
 ('63000000-0000-4000-8000-000000000003','65000000-0000-4000-8000-000000000003','digest3');
INSERT INTO routing_private.validations VALUES
 ('63000000-0000-4000-8000-000000000001','digest1'),
 ('63000000-0000-4000-8000-000000000003','digest3');
INSERT INTO routing_private.bindings VALUES
 ('61000000-0000-4000-8000-000000000001','aaaaaaaa-0000-4000-8000-000000000001','62000000-0000-4000-8000-000000000001','63000000-0000-4000-8000-000000000001','{"stops":[{"task_id":"60000000-0000-4000-8000-000000000001","location_id":"L1"}],"start_node_id":"DEPOT"}',now(),NULL,now()),
 ('61000000-0000-4000-8000-000000000003','aaaaaaaa-0000-4000-8000-000000000001','62000000-0000-4000-8000-000000000003','63000000-0000-4000-8000-000000000003','{"stops":[{"task_id":"60000000-0000-4000-8000-000000000003","location_id":"L3"}],"start_node_id":"DEPOT"}',now(),NULL,now());
INSERT INTO routing_private.items VALUES
 ('61000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000001',1,NULL,NULL,NULL,'digest'),
 ('61000000-0000-4000-8000-000000000003','60000000-0000-4000-8000-000000000003',1,NULL,NULL,NULL,'digest');
"""


class ReleasedClaimHistoryIsolatedTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not all((BIN / name).exists() for name in ("initdb.exe", "pg_ctl.exe", "psql.exe")):
            raise unittest.SkipTest("PostgreSQL 17 binaries are unavailable")
        temp_root = ROOT / ".tmp"
        temp_root.mkdir(exist_ok=True)
        cls.temp = tempfile.TemporaryDirectory(prefix="claim-history-pg-", dir=temp_root)
        cls.path = Path(cls.temp.name)
        cls.data = cls.path / "data"
        cls.log = cls.path / "postgres.log"
        cls.env = {
            key: value for key, value in os.environ.items()
            if key.upper() not in {"PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD"}
        }
        cls.env.update(PGCONNECT_TIMEOUT="3", PGPASSFILE=str(cls.path / "no-passfile"))
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            cls.port = sock.getsockname()[1]
        cls.running = False
        try:
            cls.run_process([str(BIN / "initdb.exe"), "-D", str(cls.data), "-U", "postgres",
                             "-A", "trust", "--no-locale", "--encoding=UTF8"])
            start = subprocess.run(
                [str(BIN / "pg_ctl.exe"), "-D", str(cls.data), "-l", str(cls.log),
                 "-w", "-t", "30", "-o", f"-h 127.0.0.1 -p {cls.port}", "start"],
                env=cls.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                check=False, timeout=40,
            )
            if start.returncode != 0:
                detail = cls.log.read_text(encoding="utf-8", errors="replace") if cls.log.exists() else "no PostgreSQL log was created"
                raise RuntimeError("pg_ctl start failed: " + detail)
            cls.running = True
            cls.sql(SCHEMA)
            cls.sql(MIGRATION.read_text(encoding="utf-8"))
        except BaseException as exc:
            detail = getattr(exc, "stderr", "") or ""
            if isinstance(detail, bytes):
                detail = detail.decode("utf-8", errors="replace")
            if cls.log.exists():
                detail += "\n" + cls.log.read_text(encoding="utf-8", errors="replace")
            cls.cleanup_cluster()
            if detail:
                raise RuntimeError(f"Disposable PostgreSQL bootstrap failed: {detail}") from exc
            raise

    @classmethod
    def tearDownClass(cls):
        cls.cleanup_cluster()

    @classmethod
    def cleanup_cluster(cls):
        if getattr(cls, "running", False):
            stopped = subprocess.run(
                [str(BIN / "pg_ctl.exe"), "-D", str(cls.data), "-m", "fast",
                 "-w", "-t", "15", "stop"], env=cls.env, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            )
            if stopped.returncode != 0:
                status = subprocess.run(
                    [str(BIN / "pg_ctl.exe"), "-D", str(cls.data), "status"],
                    env=cls.env, text=True, stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, check=False,
                )
                if status.returncode == 0:
                    raise RuntimeError("Test-owned PostgreSQL is still running; preserving its directory")
            cls.running = False
        if hasattr(cls, "temp"):
            cls.temp.cleanup()

    @classmethod
    def run_process(cls, args):
        return subprocess.run(args, env=cls.env, check=True, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)

    @classmethod
    def sql(cls, statement):
        sql_file = cls.path / "query.sql"
        sql_file.write_text(statement, encoding="utf-8", newline="")
        try:
            return cls.run_process([str(BIN / "psql.exe"), "-X", "-v", "ON_ERROR_STOP=1",
                                    "-h", "127.0.0.1", "-p", str(cls.port), "-U", "postgres",
                                    "-d", "postgres", "-At", "-f", str(sql_file)]).stdout.strip()
        finally:
            sql_file.unlink(missing_ok=True)

    def read_as(self, actor: str, expression: str) -> str:
        return self.sql(
            "BEGIN READ ONLY; SET LOCAL ROLE authenticated; "
            f"SELECT set_config('request.jwt.claim.sub','{actor}',true); "
            f"SELECT {expression}; ROLLBACK;"
        ).splitlines()[-2]

    def test_released_and_expired_history_returns_items_without_private_location(self):
        for claim_num in (1, 2):
            result = json.loads(self.read_as(
                OWNER,
                "public.get_my_historical_claim_detail("
                f"'10000000-0000-4000-8000-{claim_num:012d}')"
            ))
            self.assertTrue(result["read_only"])
            self.assertIn(result["claim_status"], ("RELEASED", "EXPIRED"))
            self.assertIsNone(result["pickup_address"])
            self.assertIsNone(result["latitude"])
            self.assertIsNone(result["longitude"])
            self.assertEqual(result["constituents"][0]["items"][0]["category_name"], "Food")
            self.assertEqual(result["constituents"][0]["total_weight_kg"], 10 if claim_num == 1 else 7)

    def test_completed_and_cancelled_history_are_read_only_and_reconciliation_is_separate(self):
        for claim_num, expected in ((6, "COMPLETED"), (8, "CANCELLED")):
            result = json.loads(self.read_as(
                OWNER,
                "public.get_my_historical_claim_detail("
                f"'10000000-0000-4000-8000-{claim_num:012d}')"
            ))
            self.assertEqual(result["claim_status"], expected)
            self.assertIsNone(result["pickup_address"])
            self.assertEqual(len(result["constituents"]), 1)
        denied = self.sql(
            "BEGIN READ ONLY; SET LOCAL ROLE authenticated; "
            f"SELECT set_config('request.jwt.claim.sub','{OWNER}',true); "
            "DO $$ BEGIN PERFORM public.get_my_historical_claim_detail("
            "'10000000-0000-4000-8000-000000000007'); "
            "RAISE EXCEPTION 'EXPECTED_RECONCILIATION_ROUTE'; "
            "EXCEPTION WHEN SQLSTATE 'P0001' THEN "
            "IF SQLERRM <> 'CLAIM_NOT_FOUND_OR_FORBIDDEN' THEN RAISE; END IF; "
            "END $$; ROLLBACK;"
        )
        self.assertIn("DO", denied)

    def test_active_valid_keeps_location_and_expired_active_loses_it(self):
        detail_active = json.loads(self.read_as(
            OWNER, "public.get_claimed_listing_detail('10000000-0000-4000-8000-000000000003')"
        ))
        self.assertEqual(detail_active["pickup_address"], "ACTIVE ADDRESS")
        self.assertEqual(detail_active["latitude"], 3.4)
        detail_expired = json.loads(self.read_as(
            OWNER, "public.get_claimed_listing_detail('10000000-0000-4000-8000-000000000004')"
        ))
        self.assertIsNone(detail_expired["pickup_address"])
        self.assertIsNone(detail_expired["latitude"])
        history = json.loads(self.read_as(
            OWNER, "public.get_my_historical_claim_detail('10000000-0000-4000-8000-000000000004')"
        ))
        self.assertEqual(history["claim_status"], "ACTIVE")
        self.assertIsNone(history["pickup_address"])

        denied = self.sql(
            "BEGIN READ ONLY; SET LOCAL ROLE authenticated; "
            f"SELECT set_config('request.jwt.claim.sub','{OWNER}',true); "
            "DO $$ BEGIN PERFORM * FROM public.get_claimed_listing_constituents("
            "'10000000-0000-4000-8000-000000000004'); "
            "RAISE EXCEPTION 'EXPECTED_EXPIRED_LEASE_DENIAL'; "
            "EXCEPTION WHEN SQLSTATE 'P0001' THEN "
            "IF SQLERRM <> 'CLAIM_NOT_FOUND_OR_FORBIDDEN' THEN RAISE; END IF; "
            "END $$; ROLLBACK;"
        )
        self.assertIn("DO", denied)

    def test_explicit_expired_claim_constituents_are_historical(self):
        value = self.read_as(
            OWNER,
            "(SELECT count(*) FROM public.get_claimed_listing_constituents("
            "'10000000-0000-4000-8000-000000000002'))",
        )
        self.assertEqual(value, "1")

    def test_hub_location_remains_community_location_for_historical_claim(self):
        result = json.loads(self.read_as(
            OWNER, "public.get_my_historical_claim_detail('10000000-0000-4000-8000-000000000009')"
        ))
        self.assertEqual(result["pickup_location_type"], "COMMUNITY_HUB")
        self.assertEqual(result["pickup_address"], "Community Hub")
        self.assertEqual(result["latitude"], 3.2)
        self.assertEqual(result["constituents"][0]["items"][0]["item_name"], "Hub rice")

    def test_foreign_and_unauthenticated_requests_are_non_enumerating(self):
        denied = self.sql(
            "BEGIN READ ONLY; SET LOCAL ROLE authenticated; "
            f"SELECT set_config('request.jwt.claim.sub','{OWNER}',true); "
            "DO $$ BEGIN PERFORM public.get_my_historical_claim_detail("
            "'10000000-0000-4000-8000-000000000005'); "
            "RAISE EXCEPTION 'EXPECTED_FOREIGN_DENIAL'; "
            "EXCEPTION WHEN SQLSTATE 'P0001' THEN "
            "IF SQLERRM <> 'CLAIM_NOT_FOUND_OR_FORBIDDEN' THEN RAISE; END IF; "
            "END $$; ROLLBACK;"
        )
        self.assertIn("DO", denied)
        self.assertEqual(
            self.sql("SELECT has_function_privilege('anon',"
                     "'public.get_my_historical_claim_detail(uuid)','EXECUTE')"),
            "f",
        )
        self.assertEqual(
            self.sql("SELECT has_function_privilege('authenticated',"
                     "'public.get_my_historical_claim_detail(uuid)','EXECUTE')"),
            "t",
        )
        unauthenticated = self.sql(
            "BEGIN READ ONLY; SET LOCAL ROLE authenticated; "
            "SELECT set_config('request.jwt.claim.sub','',true); "
            "DO $$ BEGIN PERFORM public.get_my_historical_claim_detail("
            "'10000000-0000-4000-8000-000000000001'); "
            "RAISE EXCEPTION 'EXPECTED_UNAUTHENTICATED'; "
            "EXCEPTION WHEN SQLSTATE 'P0001' THEN "
            "IF SQLERRM <> 'UNAUTHENTICATED' THEN RAISE; END IF; "
            "END $$; ROLLBACK;"
        )
        self.assertIn("DO", unauthenticated)

    def test_route_readers_mask_historical_direct_location_and_keep_active_location(self):
        released = json.loads(self.read_as(
            OWNER, "public.get_my_authorized_route_pre_deferral('61000000-0000-4000-8000-000000000001')"
        ))
        self.assertTrue(released["authorization_confirmed"])
        self.assertIsNone(released["stops"][0]["pickup_address"])
        self.assertIsNone(released["stops"][0]["pickup_latitude"])
        self.assertIsNone(released["stops"][0]["pickup_road_node_id"])
        self.assertFalse(released["stops"][0]["can_start"])
        active = json.loads(self.read_as(
            OWNER, "public.get_my_authorized_route_pre_deferral('61000000-0000-4000-8000-000000000003')"
        ))
        self.assertEqual(active["stops"][0]["pickup_address"], "ACTIVE ADDRESS")
        self.assertEqual(active["stops"][0]["pickup_latitude"], 3.1)

    def test_existing_reader_acl_and_all_records_remain_unchanged(self):
        self.assertEqual(
            self.sql("SELECT has_function_privilege('anon',"
                     "'public.get_claimed_listing_detail(uuid)','EXECUTE')"), "t")
        self.assertEqual(
            self.sql("SELECT has_function_privilege('authenticated',"
                     "'public.get_claimed_listing_constituents(uuid)','EXECUTE')"), "t")
        before = self.sql(
            "SELECT jsonb_build_object("
            "'claims',(SELECT jsonb_agg(jsonb_build_array(claim_id,claim_status,close_reason,closed_at) ORDER BY claim_id) FROM public.donation_claims),"
            "'leases',(SELECT jsonb_agg(jsonb_build_array(lease_id,lease_status,closed_at,release_reason) ORDER BY lease_id) FROM public.claim_leases),"
            "'listings',(SELECT jsonb_agg(jsonb_build_array(listing_id,listing_status) ORDER BY listing_id) FROM public.listings),"
            "'donations',(SELECT jsonb_agg(jsonb_build_array(donation_id,donation_status) ORDER BY donation_id) FROM public.donations))::text"
        )
        self.sql("BEGIN READ ONLY; SET LOCAL ROLE authenticated; "
                 f"SELECT set_config('request.jwt.claim.sub','{OWNER}',true); "
                 "SELECT public.get_my_historical_claim_detail('10000000-0000-4000-8000-000000000001'); "
                 "ROLLBACK;")
        after = self.sql(
            "SELECT jsonb_build_object("
            "'claims',(SELECT jsonb_agg(jsonb_build_array(claim_id,claim_status,close_reason,closed_at) ORDER BY claim_id) FROM public.donation_claims),"
            "'leases',(SELECT jsonb_agg(jsonb_build_array(lease_id,lease_status,closed_at,release_reason) ORDER BY lease_id) FROM public.claim_leases),"
            "'listings',(SELECT jsonb_agg(jsonb_build_array(listing_id,listing_status) ORDER BY listing_id) FROM public.listings),"
            "'donations',(SELECT jsonb_agg(jsonb_build_array(donation_id,donation_status) ORDER BY donation_id) FROM public.donations))::text"
        )
        self.assertEqual(after, before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
