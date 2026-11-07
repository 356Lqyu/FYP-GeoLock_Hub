# Phase C1 NGO fleet management proposal

Status: v2 manually deployed by the user. [DEV post-migration verification](deployment/dev-postflight-report-2026-10-24.md) is PASS for conditional read-only sign-off. Authenticated Batch B has conditional approval but remains blocked/unexecuted. Local-only C2 matrix/orchestration preparation is authorized and implemented; live database integration is not. Codex performed no DEV database mutation. See [the current implementation checkpoint](../phase-c2/implementation-and-workflow.md).

The [DEV migration verification package](deployment/README.md) retains the historical deployment preflight/postflight SQL, baseline, manual execution order and rollback checklist. The v2 migration was already manually executed; no new migration execution is requested.

Start with the [final SQL security and operational review](final-security-operational-review.md).
The current review candidate is [v2 migration and protected RPC SQL](proposed_migration_v2.sql).
See [exact SQL differences](original-to-v2.diff), [fresh DEV findings](final-review-dev-evidence.json), and [v2 isolated tests](v2-isolated-test-results.txt).

The [original implementation review](implementation-review.md), [original SQL](proposed_migration.sql), and original test log are retained as history. Their blanket service-role revocation and status-only route release are superseded by v2. The proposal files remain outside the automatic migrations directory; only v2 was manually applied to DEV.
