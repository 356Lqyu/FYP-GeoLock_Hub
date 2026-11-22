#!/usr/bin/env python3
"""Switch the Supabase DEV road network to the KL, Putrajaya and Selangor snapshot in output/.

Everything happens in ONE transaction, so it either finishes or changes nothing:
  1. stop if a routed trip is still open (its plan uses the old road nodes)
  2. pause the routing freeze triggers on the three road tables
  3. turn off the old snapshot and empty the road tables (frees the old ~370 MB)
  4. register the new coverage, copy the nodes and edges, check the counts
  5. approve and activate the new snapshot
  6. turn the freeze triggers back on
After the commit it re-matches open donations, listings, hubs and NGOs.
Donations, listings, hubs, NGOs and users are never deleted; only the two road tables
are emptied and refilled.

The routing graph that was frozen on the old snapshot no longer matches the data,
so the routing worker stops until a new graph is frozen (freeze_kl_selangor_graph.sql).

Run:
    $env:GEOLOCK_DEV_DATABASE_URL = Read-Host "DEV session pooler connection string"
    python supabase/road_network/import_operational_road_network.py
    Remove-Item Env:GEOLOCK_DEV_DATABASE_URL

The connection string is only read from that variable. It is never saved or printed.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import psycopg

DEV_PROJECT_REF = "rcgyuwiidqvrgbxswhqj"
FORBIDDEN_PROJECT_REFS = {"mffccmlimmbrgasgfnnq"}
SNAPSHOT_DIR = Path(__file__).resolve().parent / "output"
ROAD_TABLES = ("road_network_nodes", "road_network_edges", "road_network_coverage")
FREEZE_TRIGGERS = ("routing_graph_freeze", "routing_graph_truncate")
NODE_COLUMNS = "osm_node_id, network_snapshot_id, latitude, longitude, component_id, active_flag"
EDGE_COLUMNS = "source_node, target_node, road_km, travel_minutes"


def copy_csv(cur, table: str, columns: str, path: Path) -> None:
    with cur.copy(f"copy public.{table} ({columns}) from stdin with (format csv, header true)") as cp:
        with path.open("rb") as f:
            while chunk := f.read(1 << 20):
                cp.write(chunk)


def set_freeze_triggers(cur, enable: bool) -> int:
    # Only touches the triggers that exist, so a project without routing also works.
    action = "enable" if enable else "disable"
    changed = 0
    for table in ROAD_TABLES:
        for trigger in FREEZE_TRIGGERS:
            cur.execute("select 1 from pg_trigger where tgrelid = %s::regclass and tgname = %s",
                        (f"public.{table}", trigger))
            if cur.fetchone():
                cur.execute(f"alter table public.{table} {action} trigger {trigger}")
                changed += 1
    return changed


def main() -> None:
    url = os.environ.get("GEOLOCK_DEV_DATABASE_URL", "")
    if not url:
        sys.exit("Set GEOLOCK_DEV_DATABASE_URL in this terminal first (DEV project only).")
    if any(ref in url for ref in FORBIDDEN_PROJECT_REFS) or DEV_PROJECT_REF not in url:
        sys.exit(f"Refusing: the connection string must belong to DEV project {DEV_PROJECT_REF}.")

    manifest = json.loads((SNAPSHOT_DIR / "manifest.json").read_text(encoding="utf-8"))
    snapshot = manifest["network_snapshot_id"]
    n_nodes, n_edges = manifest["counts"]["nodes"], manifest["counts"]["edges"]
    print(f"New snapshot {snapshot}: {n_nodes} nodes, {n_edges} edges -> DEV {DEV_PROJECT_REF}")
    print("The old road network is removed in the same transaction.")

    with psycopg.connect(url, autocommit=True) as conn, conn.cursor() as cur:
        # A Free project over quota is read-only. This lifts it for this session only.
        cur.execute("set session characteristics as transaction read write")
        cur.execute("select pg_size_pretty(pg_database_size(current_database()))")
        print(f"Database size before: {cur.fetchone()[0]}")

        with conn.transaction():
            cur.execute("set local statement_timeout = 0")
            cur.execute("set local lock_timeout = '10s'")
            cur.execute("select to_regclass('public.road_network_edges') is not null")
            if not cur.fetchone()[0]:
                sys.exit("Apply 20261020_operational_road_node_resolution.sql first.")

            cur.execute("select to_regclass('routing_private.bindings') is not null")
            if cur.fetchone()[0]:
                cur.execute("select count(*) from routing_private.bindings where closed_at is null")
                open_routes = cur.fetchone()[0]
                if open_routes:
                    sys.exit(f"{open_routes} routed trip(s) still open. Finish or close them first. "
                             "Nothing changed.")

            paused = set_freeze_triggers(cur, enable=False)
            print(f"Paused {paused} routing freeze trigger(s)")

            cur.execute("update public.road_network_coverage set active_flag = false where active_flag")
            cur.execute("truncate public.road_network_edges, public.road_network_nodes restart identity")
            cur.execute("delete from public.road_network_coverage where network_snapshot_id = %s",
                        (snapshot,))

            print("Registering coverage ...")
            cur.execute((SNAPSHOT_DIR / "operational_road_coverage.sql").read_text(encoding="utf-8")
                        .replace("begin;", "").replace("commit;", ""))
            print("Copying nodes ...")
            copy_csv(cur, "road_network_nodes", NODE_COLUMNS, SNAPSHOT_DIR / "road_network_nodes.csv")
            print("Copying edges ...")
            copy_csv(cur, "road_network_edges", EDGE_COLUMNS, SNAPSHOT_DIR / "road_network_edges.csv")

            cur.execute("select count(*) from public.road_network_nodes")
            got_nodes = cur.fetchone()[0]
            cur.execute("select count(*) from public.road_network_edges")
            got_edges = cur.fetchone()[0]
            cur.execute("""select count(*) from public.road_network_edges e
                            where not exists (select 1 from public.road_network_nodes n
                                               where n.osm_node_id = e.target_node)""")
            dangling = cur.fetchone()[0]
            if (got_nodes, got_edges, dangling) != (n_nodes, n_edges, 0):
                raise SystemExit(f"Count mismatch: nodes {got_nodes}/{n_nodes}, edges {got_edges}/{n_edges}, "
                                 f"dangling {dangling}. Rolled back, nothing changed.")

            cur.execute("""update public.road_network_coverage
                              set approved_at = coalesce(approved_at, clock_timestamp()), active_flag = true
                            where network_snapshot_id = %s""", (snapshot,))
            set_freeze_triggers(cur, enable=True)
            print("Freeze triggers back on")

        cur.execute("analyze public.road_network_nodes")
        cur.execute("analyze public.road_network_edges")
        cur.execute("select public.geolock_backfill_road_nodes()")
        print(f"Re-matched open records: {cur.fetchone()[0]}")
        cur.execute("select pg_size_pretty(pg_database_size(current_database()))")
        print(f"Database size after: {cur.fetchone()[0]}")
    print(f"{snapshot} is active. Next: the routing owner runs freeze_kl_selangor_graph.sql.")


if __name__ == "__main__":
    main()
