"""Compatibility import for the relocated optimizers.baselines module."""
import sys

from ..optimizers import baselines as _implementation

sys.modules[__name__] = _implementation
