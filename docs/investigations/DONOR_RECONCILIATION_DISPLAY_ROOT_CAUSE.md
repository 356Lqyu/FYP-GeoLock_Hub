# Donor Reconciliation Display — DEV-Verified Root Cause

**Status:** read-only DEV investigation complete. No Flutter, SQL, policy, grant, or database-record changes were made.

## DEV identity and safety

The configured API URL was `https://rcgyuwiidqvrgbxswhqj.supabase.co`, matching the intended DEV project reference. The database identity probe ran as `postgres` against database `postgres`, PostgreSQL 17.11. In the same MCP SQL call, `BEGIN READ ONLY` reported `transaction_read_only=on` and was followed by `ROLLBACK`. Each subsequent inspection was also issued as an explicit `BEGIN READ ONLY; SELECT ...; ROLLBACK;` call. No mutation SQL or RPC was issued. User identifiers are omitted here.

## Verified records

The supplied donation label resolved uniquely to donation `3a012ba4-25cc-4054-897e-008e11da3e9e`, currently `AVAILABLE`, with one `AVAILABLE` listing. Its four associated claim IDs are distinct; this is not one claim duplicated four times:

| Claim | Claim/lease outcome | Reconciliation evidence |
|---|---|---|
| `8161392c-e1e1-4723-a954-c80b6b61a8c7` | `RELEASED`; lease expired and released by `EXPIRED_SAFE_RELEASE`; task `STALE` | No case and no evidence rows |
| `dd1be70f-0e42-4b75-9124-cac3702d76f6` | `RELEASED`; lease expired and released by `EXPIRED_SAFE_RELEASE`; task `STALE` | No case and no evidence rows |
| `c732f0fa-b54e-40bd-a87a-b352210a8ba6` | `RELEASED`; lease expired and released by `EXPIRED_SAFE_RELEASE`; task `STALE` | No case and no evidence rows |
| `1adfccce-a8f2-484b-a0a1-168018188b4a` | `RELEASED`; lease released by `RECONCILED_NO_HANDOVER`; task `STALE` | Case `52757a35-d809-4ee3-8bdf-89a098d9598e`, `RESOLVED_RELEASED`, reason `BOTH_PARTIES_CONFIRMED_NO_HANDOVER`; NGO and donor both recorded `handover_confirmed=false` |

The audit trail corroborates the three safe expiry releases and the later reconciliation flow. For the fourth claim, audit events record an uncertainty/reconciliation-required phase, NGO confirmation awaiting the second party, then the donor confirmation and release. The donation became available after the resolved no-handover outcome. The three old claims have no reconciliation statement records, so their absent donor and NGO values are accurate; the UI’s “Not provided” text reflects null evidence, not a failed join for the resolved claim.

## Deployed RPC and Flutter correlation

DEV `public.get_my_donation_claim_reconciliation(uuid)` is `STABLE SECURITY DEFINER`, owned by `postgres`, with a fixed search path and EXECUTE granted to `authenticated` (and owner). It verifies the caller is the donation’s donor, then builds history from donation → listing → claim → pickup task, with lease, routing item, reconciliation case, and evidence joins. Each of the four claims produces one context. The resolved case maps to the resolved outcome; a claim without a case maps to the derived `NO_OPEN_RECONCILIATION` reason. That token is therefore a read-model/blocking reason, not a stored reconciliation `case_status`.

Flutter’s `DonationDetailPage` embeds `DonorPickupOutcomeNotice`; `_load()` invokes `RouteResolutionRepository.donorClaimContext()`. The widget renders every returned context without grouping, so it presents three older no-case claims alongside the latest resolved outcome. `_claimCustodyLabel(null)` maps to “Not provided”; explicit false is “Not Collected.” Relevant source: [donation_pages.dart](/C:/Users/User/Downloads/FYP-GeoLock_Hub/frontend/geolock_hub_app/lib/donation_pages.dart:3730), [route_resolution_repository.dart](/C:/Users/User/Downloads/FYP-GeoLock_Hub/frontend/geolock_hub_app/lib/routing/route_resolution_repository.dart:210), and widget rendering around lines 4082–4132 of `donation_pages.dart`.

## Root cause and recommendation

**Confirmed:** the repeated rows represent four separate historical claims, not duplicate database records. Three were safely released after lease expiry and never had a reconciliation case or statements. The fourth is the only reconciled claim and has both no-handover statements. The backend history is internally consistent with the audit and evidence records. The confusing presentation comes from showing every historical context with the same visual prominence and labeling absent evidence “Not provided.”

**Recommended:** show the newest relevant outcome prominently, and place older attempts in a collapsed, claim-keyed history list. Keep all four claims available in history. Use “No statement recorded” for missing evidence and retain a distinct label for explicit false. Group only by verified claim ID; if duplicate claim IDs with conflicting fields ever appear, surface an integrity warning. A Flutter presentation change is sufficient for this observed issue; no database change is indicated by these records.

## Remaining limitations

The investigation used catalog/data SELECTs under explicitly read-only transactions, not the donor’s authenticated app session. The deployed function definition and underlying records establish its ownership predicate and assembled data, but no impersonation or live authenticated RPC call was made. No unrelated personal identifiers or evidence actor IDs are included.
