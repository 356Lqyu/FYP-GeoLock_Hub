# Coordination Authority Contract — LOCAL draft amendment

29 October 2026. User-approved prototype direction, **not supervisor acceptance**,
DEV deployment authority, legal retention approval or physical handover evidence.

1. **Separate interruption case.** The owning authenticated NGO may report an
   already-started IN_PROGRESS route. Reporting preserves that route, its stops,
   assignments and vehicle hold. Unresolved items enter reconciliation; no claim
   deadline changes. Ordinary pickup operations remain fenced by database state.
2. **Evidence authority.** The NGO and server-derived donor or hub administrator
   submit only their own append-only statements with expected case versions.
   No-handover means the complete goods remain with their authoritative source.
   Never-started tasks cannot become collected by this workflow. Disagreement or
   unknown custody prevents release. Amendments preserve prior statements.
3. **D03 narrow custody edges.** Add PICKUP_IN_PROGRESS → AVAILABLE for direct
   pickups, and PICKUP_IN_PROGRESS → BATCHED for every approved immutable hub
   member, only under a private transaction-bound finalizer permit. Ordinary SQL,
   client settings and existing privileged helper calls receive no such permit.
   COLLECTED has no reverse transition. Matching statements do not prove physical
   custody; the named operator remains accountable for evidence review.
4. **D04 unsafe expiry.** Expired/otherwise unsafe listings remain MANUAL_REVIEW
   with required holds. No expiry extension, withdrawal, forced release or fake
   collection is introduced. Such cases may remain unresolved in version 1.
5. **D05/D01 terminalization.** A mapped restricted resolver must verify current
   versions, exact manifest/source/binding, every item outcome and an NGO statement
   accounting for vehicle at depot and collected goods. Only then atomically end
   uncollected tasks STALE, old claims/leases RELEASED, safely reopen listings,
   archive assignments, retire this route's holds and set IN_PROGRESS → ABANDONED.
   ABANDONED means reconciled interrupted itinerary, never successful completion.
   Preserve real collection records and original itinerary/evidence. No outgoing
   ABANDONED transition; subsequent disputes must be linked incidents only.
6. **D06–D07 governance.** Evidence and receipts are immutable; no operator override.
   Access is owner/source-item scoped or separately mapped resolver access.
   Retention is provisional and needs institutional approval before real users.
   Technical administration/superuser compromise is outside SQL role isolation.
7. **D08 synthetic testing.** Trusted registry binding derives simulation labels
   on new audit events. Client flags/names do not grant synthetic status, relax
   ordinary protections, hide fixtures from discovery or retroactively relabel
   evidence. Synthetic testing needs a separately approved isolated manifest and
   visibility safeguards; it never asserts physical handover occurred.
8. **D09 compatibility.** Existing recovery SQL and cron configuration remain
   unchanged. Test report/recovery ordering, guards and vehicle holds locally.
   A required recovery change is a separate approval gate.
9. **Deployment boundary.** Default-disabled database gate and disabled Flutter
   source gate; no automatic worker integration or background finalization. Each
   future deployment, identity/grant, activation and live case action needs its own
   reviewed authorization. No permission to resolve route
   db1b455e-92d0-4d58-9fa1-5de07d7ab0f9 is conveyed by this draft.
