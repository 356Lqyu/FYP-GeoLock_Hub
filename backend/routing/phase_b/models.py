"""Compatibility import for the relocated optimizers.models module."""
import sys

from ..optimizers import models as _implementation

sys.modules[__name__] = _implementation
