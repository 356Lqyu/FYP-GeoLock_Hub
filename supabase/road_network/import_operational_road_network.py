#!/usr/bin/env python3
"""Load a built operational snapshot into the Supabase DEV database.

Steps (one transaction): register coverage -> COPY nodes -> COPY edges -> verify
counts against manifest.json. The snapshot stays NOT approved and NOT active;
activation is a separate, deliberate step (output/activate_snapshot.sql).

The connection string is read from the GEOLOCK_DEV_DATABASE_URL environment variable
that you set in your own terminal. It is never written to disk or printed.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import psycopg

DEV_PROJECT_REF = "rcgyuwiidqvrgbxswhqj"
FORBIDDEN_PROJECT_REFS = {"mffccmlimmbrgasgfnnq"}
NODE_COLUMNS = "osm_node_id, network_snapshot_id, latitude, longitude, component_id, active_flag"
EDGE_COLUMNS = "source_node, target_node, road_km, travel_minutes"


def copy_csv(cur, table: str, columns: str, path: Path) -> None:
    with cur.copy(f"copy public.{table} ({columns}) from stdin with (format csv, header true)") as cp:
        with path.open("rb") as f:
            while chunk := f.read(1 << 20):
                cp.write(chunk)


def main() -> None:
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", type=Path, default=here / "output")
    args = ap.parse_args()

    url = os.environ.get("GEOLOCK_DEV_DATABASE_URL", "")
    if not url:
        sys.exit("Set GEOLOCK_DEV_DATABASE_URL in this terminal first (DEV project only).")
    if any(ref in url for ref in FORBIDDEN_PROJECT_REFS) or DEV_PROJECT_REF not in url:
        sys.exit(f"Refusing: the connection string must belong to DEV project {DEV_PROJECT_REF}.")

    manifest = json.loads((args.out / "manifest.json").read_text(encoding="utf-8"))
    snapshot = manifest["network_snapshot_id"]
    n_nodes, n_edges = manifest["counts"]["nodes"], manifest["counts"]["edges"]
    print(f"Snapshot {snapshot}: {n_nodes} nodes, {n_edges} edges -> DEV {DEV_PROJECT_REF}")
    if input("Type IMPORT to continue: ").strip() != "IMPORT":
        sys.exit("Cancelled.")

    with psycopg.connect(url, autocommit=False) as conn, conn.cursor() as cur:
        cur.execute("set local statement_timeout = 0")
        cur.execute("select to_regclass('public.road_network_edges') is not null")
        if not cur.fetchone()[0]:
            sys.exit("Apply 20261020_operational_road_node_resolution.sql first.")
        cur.execute("select count(*) from public.road_network_nodes where network_snapshot_id = %s",
                    (snapshot,))
        if cur.fetchone()[0]:
            sys.exit(f"{snapshot} already has nodes; nothing imported.")

        print("Registering coverage ...")
        cur.execute((args.out / "operational_road_coverage.sql").read_text(encoding="utf-8")
                    .replace("begin;", "").replace("commit;", ""))
        print("Copying nodes ...")
        copy_csv(cur, "road_network_nodes", NODE_COLUMNS, args.out / "road_network_nodes.csv")
        print("Copying edges ...")
        copy_csv(cur, "road_network_edges", EDGE_COLUMNS, args.out / "road_network_edges.csv")

        cur.execute("select count(*) from public.road_network_nodes where network_snapshot_id = %s",
                    (snapshot,))
        got_nodes = cur.fetchone()[0]
        cur.execute("""select count(*) from public.road_network_edges e
                         join public.road_network_nodes n on n.osm_node_id = e.source_node
                        where n.network_snapshot_id = %s""", (snapshot,))
        got_edges = cur.fetchone()[0]
        cur.execute("""select count(*) from public.road_network_edges e
                        where not exists (select 1 from public.road_network_nodes n
                                           where n.osm_node_id = e.target_node)""")
        dangling = cur.fetchone()[0]
        if (got_nodes, got_edges, dangling) != (n_nodes, n_edges, 0):
            conn.rollback()
            sys.exit(f"Count mismatch: nodes {got_nodes}/{n_nodes}, edges {got_edges}/{n_edges}, "
                     f"dangling targets {dangling}. Rolled back.")
        conn.commit()
        cur.execute("analyze public.road_network_nodes")
        cur.execute("analyze public.road_network_edges")
        conn.commit()
    print(f"Imported {snapshot}. It is NOT active yet: review, then run output/activate_snapshot.sql.")


if __name__ == "__main__":
    main()
