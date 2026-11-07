"""Compatibility import for the relocated optimizers.problem module."""
import sys

from ..optimizers import problem as _implementation

sys.modules[__name__] = _implementation
