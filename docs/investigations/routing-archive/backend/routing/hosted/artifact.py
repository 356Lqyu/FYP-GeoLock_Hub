"""Offline compiler for an operator-approved, independently sealed graph export.

No database/network client. Never accepts an artifact seal from an API caller.
"""
import argparse
import hashlib
import json
from pathlib import Path

from .compact_graph import CompactGraph
from ..phase_c2.matrices import require


def load_export(path, expected_sha256):
    path = Path(path)
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    require(h.hexdigest() == expected_sha256, 'APPROVED_EXPORT_SHA256_MISMATCH')
    manifest, nodes, edges = None, [], []
    with path.open(encoding='utf-8') as stream:
        for line in stream:
            page = json.loads(line)
            if manifest is None:
                manifest = page['graph']
            require(page['graph'] == manifest, 'GRAPH_MANIFEST_CHANGED')
            require(len(page['nodes']) <= 10000 and len(page['edges']) <= 10000, 'GRAPH_PAGE_INVALID')
            nodes.extend(page['nodes']); edges.extend(page['edges'])
            require(len(nodes) <= manifest['node_count'] <= 3_000_000 and
                    len(edges) <= manifest['edge_count'] <= 3_000_000, 'GRAPH_EXPORT_OVERFLOW')
    require(manifest is not None, 'EMPTY_GRAPH_EXPORT')
    return manifest, nodes, edges


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--export', required=True)
    parser.add_argument('--export-sha256', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    graph = CompactGraph.from_export(*load_export(args.export, args.export_sha256))
    seal = graph.write_artifact(args.output)  # Exclusive creation; never overwrite.
    print(json.dumps(dict(artifact_sha256=seal, graph_sha256=graph.graph_sha256,
                          nodes=graph.node_count, edges=graph.edge_count)))


if __name__ == '__main__':
    main()
