# Methodology and Feature Summary

This document summarises the GeoLock Hub project as described in the project report and supervision review notes.

## 1. Project objective
GeoLock Hub is a coordination framework for multiple NGOs collecting donations from donor locations and community hubs without conflicting claim behaviour. The core challenge is not just route planning or mapping; it is to coordinate scarce donation pickups under a correct and auditable operational policy.

## 2. Main research contribution
The project’s strongest contribution is not the invention of geofencing, routing, or basic lease semantics alone. Rather, it integrates these components into a single reproducible coordination framework for multi-NGO donation management.

The intended contribution is a verifiable system that combines:
- geographic eligibility checks
- protected claim management
- lease expiry and recovery logic
- community hub aggregation
- deterministic route planning
- benchmark-driven comparison against baselines

## 3. Deterministic authority vs AI advisory
A central design principle in the project is separation between two classes of logic.

### Deterministic authority functions
These functions are correctness-critical and must not be delegated to AI:
- donation validity and eligibility
- NGO service-area checks
- whether a donation is already claimed by another NGO
- whether a claim succeeds
- lease expiry and re-open conditions
- donation state transitions and duplicates
- route feasibility under capacity or timing constraints

### AI-assisted advisory functions
AI may be used to rank valid options that already satisfy deterministic rules:
- ranking candidate hubs
- prioritising eligible donation pickups
- suggesting the most suitable action within a known feasible set
- explaining the ranking rationale

AI must not bypass geofence restrictions, override claim protection, create invalid donations, or assign a donation to a second NGO while it is already claimed.

## 4. Donation lifecycle and authority contract
The project recommends a clear coordination authority contract before advanced features are built. This includes a formal state machine such as:
- AVAILABLE
- CLAIMED
- PICKUP_IN_PROGRESS
- COLLECTED
- DELIVERED
- LEASE_EXPIRED
- CANCELLED

Each state transition should record:
- actor or NGO
- previous state and requested state
- required conditions
- transaction boundary
- timestamp
- transaction ID
- audit record
- failure handling or recovery action

This design is meant to prevent inconsistent UI states and protect against a front end reporting success while the underlying database transaction fails.

## 5. Atomic claim management
This is the core correctness feature of the project.

The unsafe pattern is:
1. read donation status
2. confirm it is AVAILABLE
3. update it to CLAIMED

If two NGOs execute this concurrently, they can both observe AVAILABLE and both proceed.

The correct target is a single atomic database operation:
- update the donation to CLAIMED only if its current state is still AVAILABLE
- decide success based on the number of rows actually affected in the database

The project explicitly tests for:
- two NGOs trying to claim the same donation
- ten concurrent claim attempts
- duplicate request IDs
- database delays during claim processing

Expected outcomes:
- only one claim succeeds
- the other receives a clear conflict response
- only one active claim remains in the database
- both attempts are logged in the audit trail

## 6. Lease and recovery
Claims should not permanently block a donation forever. Lease records should include:
- claim ID
- donation ID
- holder NGO
- created time
- expiry time
- renewal count
- current lease status
- release reason
- recovery status

The system must define:
- default lease duration
- whether renewal is allowed
- maximum renewals
- whether pickup can continue after expiry
- how recovery workers re-open stale claims
- how to handle clock skew and timestamp consistency

The project also tests that normal claims complete on time while expired claims do not continue to hold ownership without formal recovery.

## 7. Hub aggregation and route planning
The project does not stop at eligibility or claim management. It also evaluates whether scattered donations can be grouped into effective community hubs and then routed for collection.

The report emphasises that the value of the system depends on whether:
- protected claim management reduces duplicate pickup claims
- lease recovery safely recovers stale tasks
- hub aggregation improves collection efficiency
- routing reduces distance or time under the same candidate set
- AI ranking adds value only within a deterministic feasible boundary

## 8. Benchmark-driven evaluation
This repository includes a frozen benchmark and baseline implementations to objectively compare alternatives.

The benchmark supports:
- deterministic scenario selection
- reproducible evaluation
- policy comparison for hub selection and routing
- concurrency stress testing for claims
- assessment of the effect of aggregation and route decisions

The project’s review notes explicitly recommend using the benchmark to show that the system can perform well under fixed conditions rather than only in a demo environment.

## 9. Implementation status in this repository
This repository currently contains the benchmark and evaluation baselines rather than a full production application front end. It is therefore best understood as the experimental and reproducible support layer for the GeoLock Hub study.

The relevant folders are:
- `benchmark dataset/` for generated data and benchmark inputs
- `baseline implementation/` for standalone comparison scripts and result outputs
- `pubic dataset/` for public geographic input data

## 10. Outcome expectation
A strong GeoLock Hub implementation should demonstrate that deterministic coordination logic ensures correctness and that AI or optimisation modules add value only after feasibility and safety checks are already satisfied. In other words, the system should be auditable, conflict-free, benchmarkable, and explainable.
