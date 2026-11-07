# Frozen graph load timeout: offline assessment

27 October 2026. **HOLD full-size readiness / no new DEV probe run.**
No DEV connection, graph/permission/policy change, worker or recovery activation
was performed during this investigation. Original failed evidence is preserved.
Limits remain **600 seconds / 4096 MiB sampled interpreter commit**.

## Confirmed findings and limits

Original `results/worker-readiness/20261027T073617Z-ddedcc/result.json` timed out
at 600.125s with all 926414 nodes and 1410000/2145828 edges. Neither matrix ran.
Its 237046635-byte partial file has 141 complete pages and is incomplete/unsealed;
it is never resumed or accepted as a complete graph. Its SHA256 remains
`33b581475635278fa1b294b49822795b3467c6bed01b7135eb891e5f1be2eb80`.

1. GraphCache and the approved A001 `read_frozen_routing_graph(uuid,bigint,integer)`
   use **keyset pagination**, not OFFSET. Each RPC returns up to 10000 nodes AND
   10000 directed edges with stable ORDER BY. About 215 RPCs are needed. Once nodes
   are exhausted, their empty ordered query still runs on every remaining page.
2. The inspected pre-freeze `backups/stage-a003/pre-freeze/20261026T194729Z-843e8c/schema.sql`
   has a node-ID primary-key index and node geography index. Edge primary key is
   `(source_node,target_node)`; **no edge_id cursor index** is present in this
   archived schema. Ordering/filtering by edge_id therefore has a concrete repeated
   scan/sort risk. This is archived evidence, not a fresh DEV index inventory.
   A003 postflight recorded matching installed RPC definition MD5
   `f3f732a1224fa0290077197f473026b6`; the approved RPC itself has not been edited.
3. Every page retains explicit READ ONLY, per-page verification, SET LOCAL role,
   statement/lock timeouts, membership checks and rollback. Approximately nine
   serial protocol exchanges per page, including implicit BEGIN, can contribute
   WAN latency. The existing native session already avoids reconnect/auth per page.
   The optional `cursor IS NULL OR id > cursor` predicate also risks a generic plan
   that filters earlier rows. Neither actual WAN latency nor the installed nested
   function's live execution plan was captured in the failed run.
4. Offline replay of all saved pages took **10.7–13.8s** for decoding, cursor and
   manifest checks, and deterministic JSON re-encoding. This makes page acquisition
   the leading bottleneck, rather than matrix search or ordinary page decoding.
   It does NOT measure the original database, transfer, retained full graph object
   memory/paging, or disk-write latency, and cannot uniquely attribute 600 seconds.
5. The original 0.8MiB commit / 3.5MiB working-set figures did not establish Python
   memory usage. Windows venv Python has a small redirector process and a real
   interpreter descendant. Local reproduction confirms monitoring the redirector
   misses a synthetic 64MiB interpreter allocation. The old timeout could likewise
   stop just the redirector. A targeted local process inspection found no remaining
   helper matching the failed probe when inspected. Historical true peak is UNKNOWN.

Offline evidence:

- `results/worker-readiness/offline-timeout-review-20261027T082001Z-2e0479/result.json`
- `results/worker-readiness/offline-timeout-review-20261027T082354Z-ab5193/result.json`
- `results/worker-readiness/geolock-local-paging-0gvzdf1_/result.json`

The latter is a disposable loopback PostgreSQL17.11 **synthetic** 400000-edge
benchmark, not DEV. At cursor200000, unindexed/custom plan took81.189ms versus
8.319ms indexed/custom. An indexed generic late-page plan still took219.973ms,
versus8.048ms indexed/custom. These demonstrate the scan/plan failure modes; they
are not predictions of DEV speed. The owned local server was stopped afterward.
Exact planning-only operator SQL also passed against those local synthetic tables.

## Implemented changes

- GraphCache: per-page rows, paired-node/edge versus edge-only phases, elapsed RPC
  time and rows/s; separate validation, encoding, disk write, fsync and sealed-cache
  read times. Failed RPC elapsed time is retained; partials remain non-PASS.
- Native session/cursor: native-connect, READ ONLY setup, role/timeout/membership
  setup, RPC execute/transfer, fetch/JSON decode and rollback timing/call counters.
  Fixed allowlisted labels only; no SQL parameters, DSNs or password data logged.
  Wall time around execute includes server/network/driver work, not server-only time.
- Probe: atomic phase evidence during graph conversion, canonical decoding,
  digest verification, contract reconstruction, adjacency construction and directed
  search, including settled/discovered counts per source.
- Memory monitor: validates child-reported interpreter PID ancestry, opens only an
  owned handle and samples that interpreter. Logs launcher and monitored PIDs and
  measurement scope. Resource stops terminate verified owned descendants before
  the redirector and wait for termination. No arbitrary process termination.
  This remains a sampled stop, not a hard allocation reservation/cap.
- Canonical graph: serialize once and hash the same exact canonical bytes, releasing
  the reconstructed graph and selection set sooner. No digest/identity changes.
- Dijkstra: stop only once ALL requested destinations are settled. Preserve directed
  distance-first/time-second/edge-ID-path tie-breaking. Discovery alone never stops
  search; unreachable destinations still exhaust reachable nodes. No cropping,
  changed weights, rounding, fabricated reachability or removed validation.

## Tests actually run

- Worker suite: **92 PASS** in39.943s (`unittest discover ... -t .`).
- C2 suite after canonical/search optimizations: **24 PASS** in91.363s.
- Graph/cache/performance focused suite: **11 PASS** in1.827s; final failed-page
  timing regression: **4 PASS** in0.545s.
- Synthetic 10001-node/20001-edge RPC pages cover the real10000-row page limit,
  cursor transitions, edge-only phase and sealed disk reload.
- Twenty seeded directed graphs, zero costs/ties/disconnected targets compare
  optimized results against the previous exhaustive settlement algorithm.
- A10000-node synthetic tail settles only the three requested nodes for its first
  source. Independent 10000-node/20000-edge bidirectional synthetic benchmark:
  graph freeze0.194s, matrices0.299s/0.323s; these are NOT full-size DEV results.
- Real owned local subprocess tests verify actual interpreter memory sampling and
  memory-stop cleanup of interpreter and launcher; synthetic failures retain no secret.
- PowerShell AST syntax PASS. Exact operator SQL successfully parsed/planned within
  a READ ONLY transaction and rolled back on disposable local PostgreSQL17.11.
- Final native-session/resource and graph-performance focused rerun: **20 PASS**
  in3.624s after all implementation changes.

Changed implementation files: `graph_cache.py`, `native_readonly_session.py`,
`readonly_pilot_probe.py`, `probe_resources.py` under `backend/routing/worker_service`,
`backend/routing/phase_c2/matrices.py`, `backend/routing/integration/graph_worker.py`.
Tests: `test_native_full_probe.py`, new `test_graph_performance.py`, and new
`supabase/tests/offline_graph_loading_benchmark.py` / `local_graph_paging_benchmark.py`.
New operator SQL/PowerShell and this review are alongside this document; current
`NATIVE_FULL_GRAPH_PROBE.md` and `FROZEN_DEV_PILOT.md` checkpoints were updated.
Approved A003 and the pinned graph connection profile hashes remain unchanged.

An initial test discovery invocation without `-t .` could not import the existing
console test's child module. Correct package-aware discovery passed all92 tests;
this was local test invocation, not authentication or a DEV failure.

## Next safe operator action

From repository root:

```powershell
& '.\docs\stage8\functional-routing\review_graph_paging_plan.ps1'
```

Uses the existing approved **read-only owner export service**, native psql17 and
hidden `-W` prompt. The dedicated graph login is not granted extra table access.
This only reads identity/catalog and obtains non-executing EXPLAIN plans, with
READ ONLY,10s statement and2s lock limits, then ROLLBACK. No EXPLAIN ANALYZE, full
network query, index creation or RPC execution. Review output; stop on any error.
The generic inner-query plan does not prove which cached plan SECURITY DEFINER
PL/pgSQL chooses in the real session. Schema qualification and actual function
owner/settings are included so this limitation remains visible.

If the missing cursor index is confirmed, prepare a separately approved narrow
forward change for an edge_id B-tree index. If generic filtering remains a risk,
evaluate probe-local custom planning or a separately reviewed RPC plan fix. An
index alone does not cure every generic plan. **Neither DDL nor settings changes
have been applied or authorized by this investigation.** Preserve graph hashes,
weights, directionality, role boundaries and immutable data; no trigger disabling
or editing previously approved migrations.

After plan review/remediation approval, a separately authorized full probe remains:

```powershell
& '.\docs\stage8\functional-routing\run_readonly_graph_probe.ps1' -NativeServiceProbe
```

No cap increases or automatic retries. Fresh directory only. Full graph plus both
matrices and correct process resource/cleanup evidence must finish inside600s/4GiB.
Large dictionary graphs, canonical reconstruction, adjacency and stored path tuples
remain memory risks; the corrected monitor may now reveal a real memory stop. If
so, profile and review a compact representation/predecessor design separately,
retaining exact canonical identity and tie rules. No full-size readiness PASS or
Flutter end-to-end activation is claimed from this offline work.
