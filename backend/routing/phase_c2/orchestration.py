"""Compatibility import for the relocated planner.orchestration module."""
import sys

from ..planner import orchestration as _implementation

sys.modules[__name__] = _implementation
