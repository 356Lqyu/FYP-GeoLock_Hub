"""Offline routing and independent validation. No live adapters or authority."""

from .baselines import fcfs, nearest_neighbour
from .optimizers import distance_only, proposed
from .routing_model import proposed as routing_model_proposed
from .validation import validate_plan

OPERATIONAL_METHODS = {"fcfs": fcfs, "nearest_neighbour": nearest_neighbour, "proposed": proposed}

METHODS = {"fcfs": fcfs, "nearest_neighbour": nearest_neighbour,
           "distance_only": distance_only, "proposed": proposed}
