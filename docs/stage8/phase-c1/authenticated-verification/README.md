# Phase C1 authenticated verification preparation

**Batch A PASS. Batch B has conditional approval but is blocked and unexecuted. Current work authorizes local preparation only.**

The provisioning/cleanup controller is now resumable and resource-idempotent: see [the implementation checkpoint](../../phase-c2/implementation-and-workflow.md). Use the same synthetic journal with `--mode provision`, `--mode run` or `--mode cleanup`. Do not run a live mode until rotation/recovery/credentials gates are confirmed. An interrupted test suite must go to cleanup rather than replaying partially committed tests. No real accounts were used.

See [execution results and the consolidated Batch B approval scope](execution.md), [coverage of all 54 groups](coverage.json) and the runnable harness. Batch A used SELECT-only MCP inspection, anonymous read-only HTTP probes and offline/isolated tests. No NGO session, account or DEV fixture was created.

Review [the test plan](test-plan.md): 54 test groups with individual variants, expected results, channel restrictions, concurrency ordering, fixture gates, execution sequence and cleanup precautions.

Fresh SELECT-only observations against DEV `rcgyuwiidqvrgbxswhqj`:

- Zero vehicles, routes, stops and assignments.
- Two active NGOs with verified operational depot nodes; neither designated for testing.
- No existing unverified or inactive NGO.
- Five public RPC bodies match the pinned migration; installation seal matches current installed objects.

Before execution, designate A/B identities and approve session handling, controlled write attempts, retained retired test vehicles, recovery preparation and cleanup owner. Proposed functional budget is at most five synthetic vehicle rows. Route fixtures and teardown need separate exact approval. No task/assignment or identity/location changes are included in that initial scope.

The accepted 32-check read-only sign-off is unchanged. Authenticated behavior and DEV concurrency remain NOT TESTED. No Phase C2 work is authorized.
