"""Exercise the review SQL in a newly initialized loopback database."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time


HERE = Path(__file__).resolve().parent
MIGRATIONS = HERE.parents[2] / "supabase" / "migrations"
NGO = "00000000-0000-0000-0000-000000000001"
REVERSE_NGO = "00000000-0000-0000-0000-000000000004"
AT_LIMIT = "00000000-0000-0000-0001-000000000004"
REVERSE_LISTING = "00000000-0000-0000-0001-000000000001"
BELOW = "00000000-0000-0000-0001-000000000005"
ABOVE = "00000000-0000-0000-0001-000000000006"
DISCONNECTED = "00000000-0000-0000-0001-000000000007"


def baseline_definitions():
    selected = {}
    names = {
        "geolock_road_costs", "geolock_road_eligible_km",
        "geolock_ngo_listing_road_check",
        "geolock_refresh_listing_road_eligibility", "geolock_refresh_ngo_road_eligibility",
    }
    sources = (
        "20261020_operational_road_node_resolution.sql",
        "20261024_async_listing_eligibility_refresh.sql",
    )
    pattern = re.compile(
        r"create or replace function public\.(\w+)\([^;]*?\bas\s*(\$\w*\$)(.*?)\2\s*;",
        re.I | re.S,
    )
    for file in sources:
        for match in pattern.finditer((MIGRATIONS / file).read_text(encoding="utf-8")):
            if match[1] in names:
                selected[match[1]] = match[0]
    assert set(selected) == names
    return "\n".join(selected.values())


def verify(query):
    def verdict(ngo, listing):
        return query(
            f"SELECT public.geolock_ngo_listing_road_check('{ngo}','{listing}')->>'outcome';"
        )

    def discover(ngo, listing):
        return query(f"SELECT public.geolock_road_eligible_km('{ngo}','{listing}');")

    def refresh_listing(listing=AT_LIMIT):
        return f"SELECT public.geolock_refresh_listing_road_eligibility('{listing}');"

    def refresh_ngo():
        return f"SELECT public.geolock_refresh_ngo_road_eligibility('{NGO}');"

    query((HERE / "fixture.sql").read_text(encoding="utf-8") + baseline_definitions())
    assert query("""
        SELECT NOT extensions.ST_DWithin(
          extensions.ST_SetSRID(extensions.ST_MakePoint(-0.0063,0),4326)::extensions.geography,
          extensions.ST_SetSRID(extensions.ST_MakePoint(0.1793,0),4326)::extensions.geography,20000)
        AND NOT EXISTS(SELECT FROM public.geolock_road_costs(ARRAY[1::bigint],ARRAY[4::bigint],0,0.1793,20000))
        AND (SELECT max(extensions.ST_Distance(s.geog,t.geog)/(e.road_km*1000)) <= 1.02
             FROM public.road_network_edges e
             JOIN public.road_network_nodes s ON s.osm_node_id=e.source_node
             JOIN public.road_network_nodes t ON t.osm_node_id=e.target_node);
    """) == "t"
    assert verdict(NGO, AT_LIMIT) == "OUTSIDE_GEOFENCE"
    print("PASS: deployed baseline misses the 20 km route with valid snapped endpoints")

    query((HERE / "20261118_claim_eligibility.review.sql").read_text(encoding="utf-8-sig"))
    assert discover(NGO, AT_LIMIT) == ""
    assert verdict(NGO, AT_LIMIT) == "ELIGIBLE"  # claim-side refresh
    assert discover(NGO, AT_LIMIT) == "20"
    query(refresh_ngo())
    assert discover(NGO, AT_LIMIT) == "20"
    assert discover(NGO, BELOW) == "19"
    assert discover(NGO, ABOVE) == "" and verdict(NGO, ABOVE) == "OUTSIDE_GEOFENCE"
    assert verdict(NGO, DISCONNECTED) == "ROUTE_UNAVAILABLE"
    assert discover(REVERSE_NGO, REVERSE_LISTING) == ""
    assert verdict(REVERSE_NGO, REVERSE_LISTING) == "ELIGIBILITY_UNDETERMINED"
    assert verdict(NGO, REVERSE_LISTING) == "ELIGIBLE"  # valid same-node pair
    print("PASS: 19/20/21 km, shared discovery and claim cache, disconnected and one-way handling")

    # Force a stale cache tuple on the fallback insert. Each identity field
    # must independently prevent a stale positive from passing authorization.
    for field, wrong_value in (
        ("network_snapshot_id", "'STALE'"), ("ngo_road_node_id", "'5'"),
        ("listing_road_node_id", "'5'"), ("geofence_radius_m", "20001"),
    ):
        query(f"""
            DELETE FROM public.ngo_listing_road_eligibility;
            CREATE OR REPLACE FUNCTION public.stale_cache_fixture() RETURNS trigger
            LANGUAGE plpgsql AS $$ BEGIN NEW.{field} := {wrong_value}; RETURN NEW; END $$;
            CREATE TRIGGER stale_cache BEFORE INSERT ON public.ngo_listing_road_eligibility
              FOR EACH ROW EXECUTE FUNCTION public.stale_cache_fixture();
        """)
        assert verdict(NGO, AT_LIMIT) == "ELIGIBILITY_UNDETERMINED", field
        assert discover(NGO, AT_LIMIT) == "", field
        query("DROP TRIGGER stale_cache ON public.ngo_listing_road_eligibility;")
    print("PASS: both claim fallback and discovery reject all four stale metadata variants")

    # The two refreshes compete to insert the same pair into an empty cache.
    # The first holds its new row while the other reaches its unique-key wait.
    query("DELETE FROM public.ngo_listing_road_eligibility;")
    with ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(query, "BEGIN; " + refresh_listing() +
                            " SELECT pg_sleep(3); COMMIT;")
        for _ in range(40):
            if query("SELECT EXISTS(SELECT FROM pg_stat_activity WHERE wait_event='PgSleep');") == "t":
                break
            time.sleep(0.05)
        else:
            raise AssertionError("First refresh did not hold an uncommitted row")
        second = pool.submit(query, refresh_ngo())
        for _ in range(25):
            if query("SELECT EXISTS(SELECT FROM pg_stat_activity WHERE wait_event_type='Lock');") == "t":
                break
            time.sleep(0.05)
        else:
            raise AssertionError("Overlapping refresh did not reach a lock wait")
        first.result()
        second.result()
    assert query(f"""
        SELECT count(*) FROM public.ngo_listing_road_eligibility
        WHERE listing_id='{AT_LIMIT}' AND ngo_user_id='{NGO}' AND road_distance_km=20;
    """) == "1"
    assert verdict(NGO, AT_LIMIT) == "ELIGIBLE"
    query("UPDATE routing_private.graphs SET content_digest='different';")
    assert discover(NGO, AT_LIMIT) == ""
    assert verdict(NGO, AT_LIMIT) == "ELIGIBILITY_UNDETERMINED"
    print("PASS: overlapping writers keep one pair and a graph certificate mismatch fails closed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pg-bin", type=Path, required=True)
    args = parser.parse_args()
    pg = args.pg_bin.resolve(strict=True)
    env = {k: v for k, v in os.environ.items() if not k.upper().startswith("PG")}
    extension = ".exe" if os.name == "nt" else ""
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    with tempfile.TemporaryDirectory(prefix="geolock-eligibility-") as tmp:
        folder = Path(tmp).resolve()
        assert folder.parent == Path(tempfile.gettempdir()).resolve()
        data = folder / "db"

        def command(executable, *options, sql=None):
            with tempfile.TemporaryFile(dir=folder) as output:
                result = subprocess.run(
                    [str(pg / (executable + extension)), *map(str, options)],
                    input=sql, encoding="utf-8", stdout=output, stderr=output,
                    env=env, timeout=45,
                )
                output.seek(0)
                message = output.read().decode("utf-8", errors="replace").strip()
                if result.returncode:
                    raise RuntimeError(message)
                return message

        def query(sql):
            return command(
                "psql", "-X", "-w", "-qAt", "-v", "ON_ERROR_STOP=1",
                "-h", "127.0.0.1", "-p", port, "-U", "postgres", "-d", "postgres", sql=sql,
            )

        command("initdb", "-D", data, "-U", "postgres", "-A", "trust")
        try:
            command("pg_ctl", "-D", data, "-l", folder / "server.log",
                    "-o", f"-h 127.0.0.1 -p {port}", "-w", "start")
            verify(query)
        finally:
            if (data / "postmaster.pid").exists():
                command("pg_ctl", "-D", data, "-m", "fast", "-w", "stop")


if __name__ == "__main__":
    main()
