"""Local C2 contracts and matrix preparation; no database or dispatch authority."""
from .matrices import freeze_graph, build_matrix
from .orchestration import prepare_input, evaluate, ReadOnlyPlanningSource
