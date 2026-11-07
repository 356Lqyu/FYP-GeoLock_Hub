# Offline password-path review after native17 diagnostic failure

**Update after owner-reported byte mismatch:** use
[NATIVE_CONSOLE_MISMATCH_REVIEW.md](NATIVE_CONSOLE_MISMATCH_REVIEW.md). The same
offline command now reports strict decoded-text parity and public console code page;
a byte mismatch alone never authorizes a password/encoding change or live retry.

27 October2026 MYT. No real password used by Codex; no live connection, DNS lookup,
full graph probe, credential/role/policy/graph change or activation performed.
Existing failure20261027T055419Z-9ea897 is preserved, not overwritten.

## Findings

Confirmed: Python selected psycopg3.3.6/pure implementation/libpq170011 and failed
at connect in3.484s with OperationalError, SQLSTATEnull and auth-rejection marker.
No observed session identity/graph or SQL executed. Native psql previously logged
in as the same intended graph login. Changing library version did not resolve the
discrepancy. The actual authentication cause is still UNPROVEN.

The native17 bootstrap verifies exact DLL path/version before connecting, keeps
its DLL search handle alive, and reenters the same bootstrap in the diagnostic
child. Offline subprocess regression independently loads that installed DLL.
Thus the latest failure cannot be dismissed as a silent return to bundled18.4.

Inspected path: Read-Host -AsSecureString → SecureStringToBSTR → PtrToStringBSTR →
libpq keyword/value quote escaping → ProcessStartInfo child Unicode environment →
Python os.environ → conninfo parsing/kwargs merge → UTF-8 conninfo.encode() →
PQconnectStart/connect_poll. Parent/child copies are transient memory; not files,
command arguments or logs. No URI or percent decoding. Extra/backslash escaping,
quotes, whitespace, Unicode and metacharacters passed a NEW end-to-end synthetic
SecureString→child environment→native17 PQconninfoParse equality test. No transport
defect was reproduced. Such tests do not prove the real entered bytes matched.

Important native difference, confirmed by PostgreSQL17 source common/sprompt.c:
psql's native hidden prompt reads narrow CRT bytes from CONIN$, in the console input
code page, removes trailing CR/LF, and supplies those bytes to libpq. Python encodes
its Unicode conninfo/password as UTF-8. These may differ for non-ASCII input when
the console code page is not UTF-8. Whether that applies to this password is UNKNOWN;
no actual character/length/ASCII statistics or fingerprints were collected.
Source: https://github.com/postgres/postgres/blob/REL_17_STABLE/src/common/sprompt.c

Native psql uses its connect-params path; installed psycopg uses nonblocking
PQconnectStart and performs its own getaddrinfo/splits resolved addresses into
attempts. Those and pooler endpoint/negotiation behavior remain possible differences,
not demonstrated causes. One psycopg connect API call can internally try multiple
resolved addresses; no higher-level automatic retry loop has been added.

The launcher removes inherited PG*/GEOLOCK_* settings. Explicit target credentials/
TLS fields override ambient values; RoleRpc also fixes hostaddr/options/target fields.
Profile file contains no password/passfile setting. Explicit nonempty password is
supplied, so default passfile/service lookup is not a demonstrated competing password
source. The initializer service's optionsread_onlyoff/timeout15 are not copied into
runtime DSNs; Python has empty startup options/timeout5. Explicit READ ONLY SQL has
not run at the reported failure. No evidence identifies these as auth causes.

## Smallest next diagnostic: OFFLINE equality comparison, no authentication

```powershell
& '.\docs\stage8\functional-routing\run_readonly_graph_probe.ps1' -PasswordTransportCheck
```

Run from an interactive Windows console. First enter the graph-login password at
the existing PowerShell hidden prompt. Then re-enter the SAME password at a native
narrow-CRT hidden console prompt mirroring PostgreSQL17's implementation. This helper
does not intercept or run the psql binary. Do not combine this mode with -Run or
-ConnectionDiagnostic; the launcher rejects combinations.

The helper uses only native17 PQconninfoParse and in-memory equality. It does not
connect to any server, resolve hosts, write an evidence file, print lengths/bytes/
characters, normalize/recode passwords, or calculate/log any hash or fingerprint.
Only MATCH/MISMATCH/INCOMPLETE statuses are printed; no credentials are output.
Launcher activation settings are absent in the child, as before. Native echo mode
is restored in finally and native buffers are cleared. Managed immutable strings
are released, not claimed to be provably erased from all process memory.

Interpretation:

* launcher_transport=MISMATCH: corruption between the single PowerShell input and
  parsed libpq password is reproduced; stop before native second prompt/network.
* launcher_transport=MATCH, native_console_bytes=MISMATCH: the two entries produce
  different bytes. Entry differences AND code-page encoding are possible; do not
  automatically change credentials, code page or password encoding.
* Both MATCH: this test did not reproduce password-transport corruption. It does
  NOT prove the typed password was correct or establish a server/pooler bug. Review
  remaining nonblocking/DNS/startup/auth negotiation differences before authorizing
  any further live diagnostic. Native17-vs18 alone is no longer a sufficient explanation.
* INCOMPLETE: console unavailable/input interrupted; no authentication occurred.

The real-password comparison result is intentionally NOT saved. Share only its
fixed statuses if useful. All local regression values are synthetic, with no real
password fingerprints. The full graph probe and connection diagnostic remain on
HOLD; neither runs automatically from this offline check.

Files changed: password_transport_check.py, the native17 bootstrap dispatch,
secure launcher offline-mode dispatch, and test_password_transport_check.py.
No production connection algorithm/security setting changed in this review.
