# NGO Released Claim Detail — DEV-Verified Root Cause

**Status:** read-only DEV investigation complete. No Flutter, SQL, grants, policies, or records were changed.

## DEV identity and safety

The configured API URL was `https://rcgyuwiidqvrgbxswhqj.supabase.co`, matching the intended DEV project. The SQL identity probe ran as `postgres` on database `postgres`, PostgreSQL 17.11. `BEGIN READ ONLY` reported `transaction_read_only=on` within the same MCP call and was followed by `ROLLBACK`; all following inspections likewise used individual explicit read-only transactions. No account impersonation, protected RPC invocation, or mutation was used. The supplied email is not repeated in this report.

## Verified owner history and RPC sequence

DEV contains one active NGO profile for the supplied account and five claims owned by it. The affected claim is `1adfccce-a8f2-484b-a0a1-168018188b4a`; it still exists, belongs to that NGO, and is `RELEASED` with close reason `RECONCILED_NO_HANDOVER`. Its lease is released with the same reason, its listing is available, its pickup task is stale, and its reconciliation case is `RESOLVED_RELEASED`. It is historical data, not a missing or foreign claim.

The deployed functions establish this path:

1. `get_my_claim_cards()` checks for an authenticated active NGO and selects claims by `c.ngo_user_id=auth.uid()` without filtering claim state. `get_my_claim_cards_v2()` wraps those cards and adds expiry details; it also retains historical rows. The released claim is therefore included in My Claims history.
2. `get_claimed_listing_detail(uuid)` checks a non-null `auth.uid()` and matches both the supplied `claim_id` and `c.ngo_user_id=auth.uid()`. It has no released-state filter, so an owned released claim is permitted by this reader.
3. `get_claimed_listing_constituents(uuid)` checks authentication and ownership, but further restricts rows to `COMPLETED`, `RECONCILIATION_REQUIRED`, or `ACTIVE` with an active unexpired lease. A `RELEASED` claim fails that predicate; if no row is found, the function raises `CLAIM_NOT_FOUND_OR_FORBIDDEN` (`P0001`).

Flutter passes the card’s `claim_id` directly: `ClaimCard.claimId` reads that field and `_openDetails` passes it unchanged to `ClaimPickupDetailPage`. The detail loader first requests `get_claimed_listing_detail`, then unconditionally requests `get_claimed_listing_constituents`. Thus the state-filtered second reader is the source of the observed error for this valid released history row. No authenticated RPC call was made, but the deployed definitions plus the exact owner-scoped database row confirm the mismatch in reader contracts.

Relevant local references: [claim_card.dart](/C:/Users/User/Downloads/FYP-GeoLock_Hub/frontend/geolock_hub_app/lib/claim_card.dart:23); [donation_pages.dart](/C:/Users/User/Downloads/FYP-GeoLock_Hub/frontend/geolock_hub_app/lib/donation_pages.dart:1421) for navigation and around line 2090 for the sequential detail/constituents calls; around line 2200 for rendering raw error text.

## Authorization and RLS observations

All four deployed readers are `SECURITY DEFINER`. Their ACLs include EXECUTE for `authenticated`; the catalog also showed EXECUTE for `anon` on `get_my_claim_cards`, `get_claimed_listing_detail`, and `get_claimed_listing_constituents` (the v2 reader did not show anon). The functions’ `auth.uid()` and owner predicates remain the row authorization checks; no unauthenticated behavior was tested. This broader EXECUTE ACL is a separate hardening review item, not the cause of this NGO’s error. Do not broaden grants to fix the state mismatch.

RLS is enabled (not forced) on `donation_claims`, `claim_leases`, and `pickup_tasks`; it is enabled on the two reconciliation tables as well. The `pg_policies` query returned no policies for these five tables. Direct authenticated table reads are therefore not the supported history path; these SECURITY DEFINER readers are the relevant path. Catalog ACLs showed broad table privileges, including anon grants on some claim tables, but with RLS enabled and no policies those grants do not establish row visibility. This deserves a separate least-privilege review; it was not modified.

## Root cause and recommendation

**Confirmed root cause:** My Claims intentionally includes owner-scoped history, and the first detail reader accepts owned claims without a state restriction. Flutter then always calls a constituents reader that intentionally only admits active/in-progress states and completed or reconciliation-required cases. That mismatch rejects the released claim and yields the reported error. Flutter passes the correct claim UUID.

**Recommendation:** released claim details should remain accessible in read-only mode. For complete historical details, an authorized backend reader change is needed: add intended released/history states to the owner-scoped constituents reader or provide a separate owner-authorized historical reader. Preserve `auth.uid()` ownership checks, SECURITY DEFINER search path, and current protected authorization. A Flutter-only fallback could skip the constituents call for known released claims, but would omit constituents and related data; it is not a complete fix. Map the exception to a safe user-facing message rather than rendering raw PostgREST text.

No claim mutation, route, pickup action, or vehicle booking should be exposed for released history.

## Remaining limitation

We did not exercise the reader under the NGO’s live authenticated session or inspect an app request trace. The error attribution is supported by the exact deployed RPC predicates, the verified owned released row, and the Flutter call sequence; actual authenticated network execution remains unverified. No foreign claim was queried through the app or RPC.
