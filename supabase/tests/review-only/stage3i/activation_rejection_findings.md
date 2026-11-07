# Rejected activation: confirmed findings and remaining evidence

Read-only investigation only; no new execution attempt/package prepared. Latest
user instruction requires approval before preparation of another execution attempt.

The local 113154 file SHA-256 matches
1D79F008BC1640F7CDC7D787055D18439B1D8107EC42FB3AA6BE92CD4C49AD6E.
Reported inline block line 19 is its combined manifest guard RAISE. The error does
NOT identify which disjunct failed. No persistent mutation precedes this guard;
only BEGIN and transaction-local settings. cron.alter_job occurs later.

Confirmed local manifest: operator DEV Test Operator (user), maintenance_confirmed
true, all required IDs/keys, 32-character snapshot hash, max_activation_seconds 300,
correct runtime deadline_mode, timezone UTC. stop_at NULL is intentional: the key
exists and actual absolute deadline is calculated later; NULL is not a rejection
condition in this final wrapper. No manual filling of operator/deadline is needed.

Reviewed baseline 2026-10-23 11:31:54.423718 UTC / 19:31:54.423718 MYT.
Expiry 2026-10-23 11:34:54.423718 UTC / 19:34:54.423718 MYT.
At our predicate-level MCP check 11:34:47.288965 UTC, ALL rejecting conditions were
false. That is a real observation, not proof of the SQL Editor's earlier attempt.

User's later SQL Editor diagnostic 11:36:01.592231 UTC confirms current_user and
session_user postgres, timezone UTC. It does not reveal the historical execution
time/manifest. The supplied failed-time and complete-file answers remained template
placeholders. PostgreSQL pg_stat_activity no longer retains the failed statement;
no read-only log tool is exposed in this session. Exact original rejecting predicate
therefore remains NOT CONFIRMED. Do not label staleness or timezone as confirmed.

If the SAME unedited file ran after 19:34:54.423718 MYT, stale baseline is the exact
failing condition. If it ran within the valid interval with UTC, supplied local
fields would pass; the actually executed manifest/text/session must be compared.
The old file is now expired regardless and must never be retried or timestamp-edited
without genuine fresh review. Current-time diagnostics cannot retrospectively prove
which flag failed at the past attempt.

Post-error live checks 2026-10-23 11:36:20 UTC: job 3 inactive, exactly 12 succeeded
historical runs, no new/failed/unfinished recovery runs; fixture still ACTIVE/ACTIVE,
expired, task CONFIRMED, donation/listing CLAIMED, sole nonterminal/overdue pair;
no case, route, inventory, membership, reservation or receipt evidence. Same four
audits and 13-table populated-target hash 070bb28ff5737477d6d91ec9e36feb02.
Approved recovery source/ACL remain intact. Jobs 1/2 active, 60 successes each in
last-hour snapshot; no unfinished run. No open client transaction was returned in
the earlier post-error predicate inspection.

Persistent effects of the rejected activation: NONE detected/expected; the guard
raised before any ALTER, and current cron/function/business/audit evidence confirms
no activation/recovery change. No failed transaction remains open at inspection.
This cannot prove unrelated unrecorded session activity, but no committed test or
recovery mutation occurred. A clean later SQL Editor SELECT succeeded as reported.

Prepared activation_rejection_manifest_diagnostic.sql contains SELECT-only per-flag
checks for the old manifest. Run in the relevant DEV SQL Editor session if needed.
Its stale flag will now be true; that must not be mistaken for historical proof.

Needed to finish exact attribution: approximate failed-attempt MYT timestamp,
complete/unedited-file confirmation, baseline_at from activation text actually run.
Wait for those details and explicit preparation approval before generating another
execution package. No guard was removed/weakened, no DEV SQL state changed and no
recovery or cron operation was invoked by Codex.
