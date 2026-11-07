"""Stable solver entry points for historical manifests and callable identity."""
from ..optimizers.cp_sat import _cost, _optimise
from ..optimizers.models import ExecutionConfig


def distance_only(snapshot, config=ExecutionConfig()):
    """Maximize served pickup tasks, then minimize total directed road km."""
    return _optimise(snapshot, "distance_only", config)


def proposed(snapshot, config=ExecutionConfig()):
    """Maximize served pickup tasks, then minimize total directed road km."""
    return _optimise(snapshot, "proposed", config)
