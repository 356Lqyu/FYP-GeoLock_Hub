# Policy values approved; installation NOT authorized

Owner explicitly approved the unchanged policy business and pinned technical
values in chat on27 October2026. This approval does not authorize installation,
graph freeze, workers, recovery or live pilot writes. Preserve requests.proposed.json
and all pinned inputs unchanged; its historical proposal status is not the current
business-approval record.

Offline recheck: policy JSON SHA256
30826f3fdb5c52bde2b29605e54b30b19692740fbbb97d098daf4b22a3c0b030;
installation SQL SHA256
6f8312520c112a2993046645c84c50804edef0200aeb3001c7b17382ef930ba1.
Stable policy request:0b8db479-20c8-4595-9d41-d831650cba93.

No further policy-design or graph-source prerequisite blocks policy installation.
Remaining execution gates: dedicated graph-login credential/TLS/scoped access,
owner-named quiet window, fresh read-only before-state and contract/permission
preflight PASS, available existing backup with recorded recovery limitations,
and separate explicit authorization for the exact installation command.
Credential presence/access has not been demonstrated by the owner-export test.
No live connection or write was attempted in this approval-record update.

Use CURRENT_APPROVAL_CHECKPOINT.md for commands and PASS criteria. In particular:

* Run postflight.readonly.sql through owner-export BEFORE installation: zero policy/
  graph/routing state, exact triggers/permissions, recovery disabled; capture actual
  current source counts instead of assuming historical counts.
* Run policy-install-preflight.readonly.sql with geolock_dev_graph_initializer:
  identity_matches=true, read_only=on, ssl=true; p_request/p_body, source MD5
  7b3549f82b239d6c6abbd4a5fee58b4e, owner postgres, SECURITY DEFINER, volatile,
  hardened search_path/UTC/float config and EXECUTE=true. Inspect results, not just exit0.
* Only after separate approval: unchanged BEGIN/COMMIT installation wrapper,
  lock_timeout5s, statement_timeout30s, dedicated graph role.
* Postflight: exactly one matching policy request/body/digest and record policy_id;
  zero graphs, unchanged remaining routing/source data/permissions/triggers and
  inactive recovery. Fail/unknown commit: STOP and inspect same UUID read-only;
  no automatic retry, new request, grants, deletion or recovery operation.

The graph-login profile has startup default_transaction_read_only=off for the future
approved installer, but the preflight explicitly uses BEGIN READ ONLY and ROLLBACK.
Use this account's own password only in native psql's hidden prompt. Never put it
in command arguments, chat, files or environment variables.
