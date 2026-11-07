"""Exact, immutable CSR candidate; the Windows graph path is untouched.

Costs use the same six-decimal values and lexicographic string edge-ID paths.
Compilation may require the full legacy export in RAM. A prebuilt artifact can
avoid that peak, but loading it requires an independently configured SHA256 and
an exact live frozen-manifest match. Artifacts are never trusted from requests.
"""
from array import array
from dataclasses import dataclass, field
from decimal import Decimal
import hashlib
import heapq
import json
from pathlib import Path
import re
import sys
import threading

from ..contract import DEV_PROJECT
from ..phase_c2.matrices import canonical, numeric, require
from ..worker_service.graph_cache import GraphCache

SCALE = 1_000_000
MAGIC = b'GLCSR1\n'
FORMAT = 'geolock.csr.v1.le.u64.u32'
FIELDS = ('nodes', 'offsets', 'targets', 'edge_ids', 'distance', 'minutes')


def _digest(value):
    return bool(isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value))


def _cost(value):
    result = numeric(value) * SCALE
    require(result == int(result) and 0 <= result < 2**64, 'COMPACT_COST_RANGE')
    return int(result)


@dataclass(frozen=True)
class CompactGraph:
    manifest_json: str
    graph_sha256: str
    node_count: int
    edge_count: int
    _payload: bytes = field(repr=False)

    def __post_init__(self):
        require(sys.byteorder == 'little', 'COMPACT_LITTLE_ENDIAN_REQUIRED')
        require(type(self._payload) is bytes, 'IMMUTABLE_COMPACT_BYTES_REQUIRED')
        sizes = (self.node_count * 8, (self.node_count + 1) * 8,
                 self.edge_count * 4, self.edge_count * 8,
                 self.edge_count * 8, self.edge_count * 8)
        require(len(self._payload) == sum(sizes), 'COMPACT_LENGTH_MISMATCH')
        cursor = 0
        for name, size, kind in zip(FIELDS, sizes, ('Q', 'Q', 'I', 'Q', 'Q', 'Q')):
            object.__setattr__(self, '_' + name, memoryview(self._payload)[cursor:cursor + size].cast(kind))
            cursor += size
        require(self._offsets[0] == 0 and self._offsets[-1] == self.edge_count,
                'COMPACT_OFFSETS_INVALID')
        require(all(a <= b for a, b in zip(self._offsets, self._offsets[1:])), 'COMPACT_OFFSETS_INVALID')
        require(all(t < self.node_count for t in self._targets), 'COMPACT_TARGET_INVALID')
        require(all(0 < n < 2**63 for n in self._nodes), 'COMPACT_NODE_INVALID')
        require(all(str(a) < str(b) for a, b in zip(self._nodes, self._nodes[1:])), 'COMPACT_NODE_ORDER')

    @property
    def manifest(self):
        return json.loads(self.manifest_json)

    @classmethod
    def from_export(cls, manifest, nodes, edges):
        require(_digest(manifest['content_digest']), 'DATABASE_DIGEST_REQUIRED')
        require(manifest['precision_policy'] == 'EXACT_MAX_6_DECIMALS' and
                manifest['float_output_profile'] == 'PG_REAL_OUTPUT_0', 'UNREVIEWED_GRAPH_PROFILE')
        require(manifest['coverage_snapshot'].startswith('OSM-OPS-'), 'INVALID_GRAPH_SNAPSHOT')
        require(len(nodes) == manifest['node_count'] and len(edges) == manifest['edge_count'], 'INCOMPLETE_GRAPH_EXPORT')
        require(len({n['osm_node_id'] for n in nodes}) == len(nodes) and
                len({e['edge_id'] for e in edges}) == len(edges), 'DUPLICATE_GRAPH_ROWS')
        selected = sorted((str(n['osm_node_id']) for n in nodes if n['active_flag'] and
                           n['network_snapshot_id'] == manifest['coverage_snapshot']))
        require(bool(selected) and all(re.fullmatch('[1-9][0-9]*', n) for n in selected), 'INVALID_GRAPH_NODE')
        require(len(selected) < 2**32, 'COMPACT_NODE_RANGE')
        lookup = {int(n): i for i, n in enumerate(selected)}
        require(all(0 < n < 2**63 for n in lookup), 'COMPACT_NODE_RANGE')
        order = sorted((i for i, e in enumerate(edges) if e['source_node'] in lookup and
                        e['target_node'] in lookup), key=lambda i: str(edges[i]['edge_id']))
        counts = array('Q', [0]) * (len(selected) + 1)
        for i in order:
            counts[lookup[edges[i]['source_node']] + 1] += 1
        for i in range(len(selected)):
            counts[i + 1] += counts[i]
        cursor = array('Q', counts[:-1])
        targets = array('I', [0]) * len(order)
        ids, distances, minutes = (array('Q', [0]) * len(order) for _ in range(3))
        # Stream the EXACT old canonical graph hash without retaining its JSON.
        digest = hashlib.sha256()
        digest.update(b'{')
        properties = dict(authority='LOCAL_UNTRUSTED', complete=True, edges=None,
                          kind='OPERATIONAL_ROAD_NETWORK', nodes=selected,
                          project_ref=DEV_PROJECT, snapshot_id=manifest['coverage_snapshot'],
                          speed_profile=manifest['speed_profile'], version='geolock.local.graph.v1')
        for ordinal, key in enumerate(sorted(properties)):
            if ordinal:
                digest.update(b',')
            digest.update((canonical(key) + ':').encode())
            if key == 'edges':
                digest.update(b'[')
                for edge_ordinal, i in enumerate(order):
                    edge = edges[i]
                    require(type(edge['edge_id']) is int and 0 <= edge['edge_id'] < 2**64, 'COMPACT_EDGE_RANGE')
                    row = dict(edge_id=str(edge['edge_id']), source_node=str(edge['source_node']),
                               target_node=str(edge['target_node']), road_km=str(numeric(edge['road_km'])),
                               travel_minutes=str(numeric(edge['travel_minutes'])))
                    if edge_ordinal:
                        digest.update(b',')
                    digest.update(canonical(row).encode())
                    src = lookup[edge['source_node']]
                    pos = cursor[src]
                    cursor[src] += 1
                    targets[pos], ids[pos] = lookup[edge['target_node']], edge['edge_id']
                    distances[pos], minutes[pos] = _cost(edge['road_km']), _cost(edge['travel_minutes'])
                digest.update(b']')
            else:
                # iterencode bounds the temporary node-array serialization.
                for piece in json.JSONEncoder(sort_keys=True, separators=(',', ':'), allow_nan=False).iterencode(properties[key]):
                    digest.update(piece.encode())
        digest.update(b'}')
        payload = b''.join(a.tobytes() for a in (array('Q', map(int, selected)), counts, targets, ids, distances, minutes))
        return cls(canonical(manifest), digest.hexdigest(), len(selected), len(order), payload)

    def _index(self, node):
        low, high = 0, self.node_count
        while low < high:
            middle = (low + high) // 2
            if str(self._nodes[middle]) < node:
                low = middle + 1
            else:
                high = middle
        require(low < self.node_count and str(self._nodes[low]) == node, 'UNKNOWN_GRAPH_NODE')
        return low

    def matrix(self, node_order):
        require(type(node_order) is list and 1 <= len(node_order) <= 100 and
                all(type(n) is str for n in node_order) and len(set(node_order)) == len(node_order), 'INVALID_MATRIX_NODE_ORDER')
        indices = [self._index(n) for n in node_order]
        distances, durations, statuses = [], [], []
        for source in indices:
            best = {source: (0, 0, ())}
            queue, settled, remaining = [(0, 0, (), source)], set(), set(indices)
            while queue:
                distance, time, path, node = heapq.heappop(queue)
                if node in settled or (distance, time, path) != best[node]:
                    continue
                settled.add(node)
                remaining.discard(node)
                if not remaining:
                    break
                for pos in range(self._offsets[node], self._offsets[node + 1]):
                    target = self._targets[pos]
                    if target in settled:
                        continue
                    score = (distance + self._distance[pos], time + self._minutes[pos], path + (str(self._edge_ids[pos]),))
                    if target not in best or score < best[target]:
                        best[target] = score
                        heapq.heappush(queue, (*score, target))
            distances.append([float(Decimal(best[n][0]) / SCALE) if n in best else None for n in indices])
            durations.append([float(Decimal(best[n][1]) / SCALE) if n in best else None for n in indices])
            statuses.append(['AVAILABLE' if n in best else 'UNREACHABLE' for n in indices])
        g = self.manifest
        return dict(matrix_id='LOCAL-' + self.graph_sha256, version=self.graph_sha256,
                    network_snapshot_id=g['coverage_snapshot'], source_kind='OPERATIONAL_ROAD_NETWORK',
                    provenance='Frozen graph ' + g['graph_id'] + ' / DB digest ' + g['content_digest'] + '; ' +
                    g['float_output_profile'] + '; C2 path digest ' + self.graph_sha256,
                    method='DIRECTED_DIJKSTRA_DISTANCE_THEN_TIME_THEN_EDGE_ID', edge_speed_profile=g['speed_profile'],
                    path_policy='DIRECTED_SHORTEST_DISTANCE_WITH_TIME_ON_SAME_PATH', unavailable_policy='FAIL_SCENARIO',
                    node_order=list(node_order), distance_km=distances, travel_minutes=durations, arc_status=statuses)

    def write_artifact(self, path):
        header = canonical(dict(format=FORMAT, manifest=self.manifest, graph_sha256=self.graph_sha256,
                                node_count=self.node_count, edge_count=self.edge_count)).encode()
        with Path(path).open('xb') as stream:
            stream.write(MAGIC)
            stream.write(len(header).to_bytes(8, 'big'))
            stream.write(header)
            stream.write(self._payload)
        return hashlib.sha256(Path(path).read_bytes()).hexdigest()

    @classmethod
    def read_artifact(cls, path, expected_sha256, expected_manifest):
        require(_digest(expected_sha256), 'TRUSTED_ARTIFACT_DIGEST_REQUIRED')
        require(Path(path).stat().st_size <= 200_000_000, 'COMPACT_ARTIFACT_TOO_LARGE')
        raw = Path(path).read_bytes()
        require(hashlib.sha256(raw).hexdigest() == expected_sha256, 'COMPACT_ARTIFACT_INTEGRITY_FAILED')
        require(raw.startswith(MAGIC) and len(raw) >= len(MAGIC) + 8, 'COMPACT_HEADER_INVALID')
        start = len(MAGIC) + 8
        length = int.from_bytes(raw[len(MAGIC):start], 'big')
        require(0 < length <= 65536 and start + length <= len(raw), 'COMPACT_HEADER_INVALID')
        header = json.loads(raw[start:start + length])
        require(header['format'] == FORMAT and _digest(header['graph_sha256']), 'COMPACT_FORMAT_INVALID')
        require(header['manifest'] == expected_manifest, 'GRAPH_MANIFEST_CHANGED')
        require(type(header['node_count']) is int and 0 < header['node_count'] <= 3_000_000 and
                type(header['edge_count']) is int and 0 <= header['edge_count'] <= 3_000_000, 'COMPACT_SCOPE_REJECTED')
        # One payload copy here, never a decoded Python object graph. The trusted
        # artifact hash binds compile-time semantic validation; structural checks
        # above/below still reject malformed lengths and adjacency bounds.
        return cls(canonical(header['manifest']), header['graph_sha256'], header['node_count'],
                   header['edge_count'], raw[start + length:])


class CompactGraphCache(GraphCache):
    """Opt-in hosted cache. No new database RPC or permission is introduced."""
    def __init__(self, *args, artifact=None, artifact_sha256=None, **kwargs):
        super().__init__(*args, **kwargs)
        self._compact = None
        self._compile_lock = threading.Lock()
        self.artifact, self.artifact_sha256 = artifact, artifact_sha256

    def warm(self):
        with self._compile_lock:
            if self._compact is None:
                if self.artifact is not None:
                    manifest = self._page(None, None)['graph']
                    self._check_manifest(manifest)
                    self._compact = CompactGraph.read_artifact(self.artifact, self.artifact_sha256, manifest)
                else:
                    manifest, nodes, edges = super().load()
                    self._compact = CompactGraph.from_export(manifest, nodes, edges)
                    self._loaded = None  # Do not retain both the export and CSR.
            return self._compact

    def matrix(self, required_nodes, *, profile=None):
        matrix = self.warm().matrix(required_nodes)
        from ..worker_service.errors import check
        check(all(s == 'AVAILABLE' for row in matrix['arc_status'] for s in row), 'ROUTE_UNAVAILABLE', 422)
        return matrix
