"""Compatibility import for the relocated planner.matrices module."""
import sys

from ..planner import matrices as _implementation

sys.modules[__name__] = _implementation
