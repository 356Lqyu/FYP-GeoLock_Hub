# Claim History UI Fix Proposal — DEV-Verified Findings

**Decision status:** findings verified; fixes proposed only. No implementation or DEV change was made.

## Verified connection boundary

The configured API host is `https://rcgyuwiidqvrgbxswhqj.supabase.co`, the intended DEV project. The database reported `postgres` on PostgreSQL 17.11. `BEGIN READ ONLY` returned `transaction_read_only=on`, and each inspection query ran in its own explicit read-only transaction followed by `ROLLBACK`. No write statement, mutation RPC, identity impersonation, or authenticated reader call was performed.

## Findings and decisions

### A. Donor reconciliation history

**Confirmed from DEV:** the donation has four distinct historical claim IDs, not duplicate records. Three claims were safely released after lease expiry (`EXPIRED_SAFE_RELEASE`) and have no reconciliation case or evidence. The fourth is `RESOLVED_RELEASED` after both parties recorded `handover_confirmed=false`; its audit trail agrees with the case and evidence rows. The donor-context RPC emits one context per claim and derives `NO_OPEN_RECONCILIATION` when a claim has no case. Therefore, the repeated entries are real historical claims and consistent backend state, while their equal visual prominence is a Flutter presentation problem. Missing evidence is accurately represented as null; the current UI translates it to “Not provided.”

**Recommendation:** show the latest relevant outcome prominently and the earlier claims in a collapsed, claim-keyed history. Use “No statement recorded” for null and retain a distinct label for explicit false. Flutter-only presentation changes are sufficient for this observed donor issue; no backend change is indicated. The details are in [DONOR_RECONCILIATION_DISPLAY_ROOT_CAUSE.md](/C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/investigations/DONOR_RECONCILIATION_DISPLAY_ROOT_CAUSE.md).

### B. NGO released-claim details

**Confirmed from DEV and local source:** the affected released claim exists and belongs to the supplied NGO. The deployed history reader includes it. The first detail reader accepts it under `claim_id` plus `ngo_user_id=auth.uid()`; the subsequent constituents reader excludes `RELEASED`, finds no matching row, and raises `CLAIM_NOT_FOUND_OR_FORBIDDEN`. Flutter passes the card’s claim UUID directly and calls both readers sequentially, making the second reader’s state predicate the root cause. The history detail should remain available read-only.

**Recommendation:** a complete history view needs an owner-authorized backend reader update (or a separate historical reader) to return constituents for released claims while retaining the auth/owner checks. A Flutter-only skip for released claims avoids the exception but loses historical constituents. Never enable mutation actions for released history. The detailed review is in [NGO_RELEASED_CLAIM_DETAIL_ROOT_CAUSE.md](/C:/Users/User/Downloads/FYP-GeoLock_Hub/docs/investigations/NGO_RELEASED_CLAIM_DETAIL_ROOT_CAUSE.md).

### C. Authorization observations

The affected read functions are `SECURITY DEFINER` and include `auth.uid()`/owner checks. Catalog ACLs also showed `anon` EXECUTE on several readers, while table RLS was enabled with no policies on the inspected claim, lease, pickup-task, and reconciliation tables. The investigation did not test anonymous calls or attempt a bypass. Treat the broad grants as a separate least-privilege review; they are not the released-state mismatch and should not be altered as part of the UI fix.

## Minimal future implementation proposal

1. **Donor Flutter:** represent each RPC context by `claim_id`; show the newest relevant outcome and a collapsed previous-history section. Preserve all distinct claims. If identical IDs repeat, deduplicate only identical payloads; differing data should raise a visible integrity state. Display absent statements separately from an explicit “Not Collected” response.
2. **NGO database reader:** prepare a forward-only migration only after review/approval, updating the historical constituents contract or adding an owner-authorized historical read RPC. Keep the same `auth.uid()` and claim ownership predicates, safe SECURITY DEFINER configuration, and no direct table-read workaround. Decide explicitly whether `RELEASED` and `EXPIRED` history are both supported and ensure no mutation action becomes available.
3. **NGO Flutter:** continue to pass the exact claim UUID; handle history responses as read-only; map authorization/network failures to safe messages instead of rendering raw PostgREST text. A temporary UI fallback can omit constituents for released claims, but is incomplete and should be labeled accordingly if chosen.

## Validation plan after approval

- Four distinct donor claim contexts render as one latest outcome plus three historical entries; `NO_OPEN_RECONCILIATION` is shown as a historical state explanation, not an alarm.
- Null evidence reads “No statement recorded”; false reads “Not Collected”; true reads “Collected.”
- Duplicate exact rows do not duplicate cards; conflicting rows are surfaced for review.
- OPEN/MANUAL_REVIEW, contradictory statements, and resolved outcomes remain visible.
- NGO owner can read released historical details; another NGO, absent IDs, and malformed IDs remain non-enumerable and reveal no listing data.
- Released/expired states expose no claim/pickup mutation; active unexpired behavior remains unchanged.
- Flutter presents safe, distinct states for authorization denial, stale history, and network failure.

## Confirmed limitations

No authenticated request was executed as either the donor or NGO; no user was impersonated. The root causes are established by the live rows, deployed SQL definitions, catalog ACL/RLS, and Flutter call sequences, but the exact client-side network trace was not captured. The investigation neither proves nor attempts to exploit any anonymous ACL exposure. No fixes are implemented pending further instruction.
