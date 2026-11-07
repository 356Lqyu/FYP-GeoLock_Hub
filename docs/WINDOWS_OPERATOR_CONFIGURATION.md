# Windows operator configuration

Ask the DEV administrator for the approved host, project, frozen graph, scoped login access, pinned PostgreSQL service profile and public CA. Each operator obtains credentials through the authorized channel and enters them locally. Flutter users only need their own app accounts. Keep worker passwords, the private validator token, DPAPI profiles and journals local.

The current Windows native bootstrap requires libpq 17.11. The profile is read at `docs/stage8/stage-a/deployment-preparation/routing-initialization/pg_service.proposed.conf` and checked against a SHA256 pin. Install the administrator-provided bytes at that exact checkout-relative path. Preserve the original line endings. Place the administrator-verified CA at the absolute path contained in that profile. If the path cannot be provisioned under the operator laptop's policy, stop before live startup. Editing the profile, disabling TLS checks or swapping out the pinned client would break the reviewed setup.

The administrator provisions the existing graph, planner and validator login scopes separately. They should confirm the current role grants, eligibility data, approved graph and session authorization before any live use. The current launcher expects fixed role-specific login names. Separately revocable per-operator LOGIN names need an approved provisioning and launcher change.

## Proposed portable follow-up

Move profile and CA selection to an operator-controlled configuration directory and keep a reviewed allowlist of approved project, host, port and role mapping. Verify the CA fingerprint supplied through an independent approved channel. Treat the operator-local CA path as a locator, with separate verification of the certificate contents. Retain libpq version pinning, TLS `verify-full`, separate roles, hidden native password prompts, private validator authentication and explicit activation. Validate mismatched hosts, roles and CA fingerprints offline before proposing a live check. This requires runtime review and approval before implementation.

Use [the credential-free checklist](../config/operator.example.json) to gather the administrator's inputs. Keep any completed operator configuration outside this repository.
