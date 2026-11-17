"""Independent plan validation and reconstruction of stored work items."""
from .validation import validate_plan

__all__ = ["validate_plan", "validate_work_item"]


def __getattr__(name):
    if name == "validate_work_item":
        # The worker imports the planner, which uses validate_plan.
        from ..integration.worker import validate_work_item

        return validate_work_item
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
