# Native-console mismatch: offline characterization

27 October2026 MYT. No live authentication/probe, credential reset, role/permission/
graph/policy change or activation. No real password used in tests. Existing evidence
and real-password comparison were not read, saved or fingerprinted by Codex.

## What the owner-reported result establishes

launcher_transport=MATCH establishes that the one PowerShell input survived its
SecureString/DSN/environment/libpq parsing path in that comparison. The native
second entry produced different bytes. This does NOT establish why: manual-entry
differences, code-page encoding, lossy conversion, normalization differences and
console/CRT behavior remain possible. The earlier result did not record text parity
or the actual interactive console code page. No password encoding change is justified
from that result alone. Native libpq17.11 was already confirmed; another library
upgrade/downgrade is not proposed.

## Implementation review and actual synthetic reproduction

No intentional Unicode normalization, whitespace stripping or password recoding is
present. libpq DSN escaping preserves quote/backslash and other tested characters.
Native helper mirrors the narrow CRT CONIN$ prompt pattern, disables echo/restores
mode in finally, strips only trailing CR/LF as PostgreSQL's native prompt does, and
clears native buffers. It is not interception of the actual psql binary. Different
CRT state, console editing/pasting or manual keystrokes can still matter.

New tests use fresh HIDDEN test-owned Windows consoles and synthetic keyboard events;
they never alter the user's console or read a human password. Observed on this host:

| Synthetic case | Actual native CRT result vs UTF-8 |
|---|---|
| ASCII, CP437 | Same bytes |
| Identical accented text, CP437 | Different bytes; CP437 decoding recovers reference |
| Identical accented text, CP1252 | Different bytes; CP1252 decoding recovers reference |
| Accented text, CP65001 | This runtime returned truncated multibyte input; inconclusive |
| Unrepresentable text, CP437 | Lossy substitution; cannot establish same input text |

CP65001 behavior is a local synthetic observation, not a universal Windows claim.
It prevents assuming that changing console code page fixes authentication. Prior
MISMATCH was an accurate byte inequality, but interpreting it as proven encoding
or a bad password would be a false attribution. No such automatic attribution/fix
is introduced.

## Strengthened offline check and exact next command

```powershell
& '.\docs\stage8\functional-routing\run_readonly_graph_probe.ps1' -PasswordTransportCheck
```

Run in interactive PowerShell from repo root; enter SAME password at both hidden
prompts. No connection/DNS/SQL/files/hashes, lengths, byte dumps, character statistics
or persistent password-derived fingerprints. Report only fixed equality/explanation
statuses plus the public console input code-page number. Do not add -Run or
-ConnectionDiagnostic; those combinations are rejected.

New result interpretation:

* DECODED TEXT MATCHES REFERENCE + CONSISTENT WITH CODE-PAGE ENCODING: the native
  bytes roundtrip in the observed code page to the PowerShell reference, while
  differing from UTF-8. Encoding is a strong explanation for THIS comparison.
  It still cannot prove identical keystrokes: console conversion may be many-to-one.
* DIFFERENT TEXT OR LOSSY CONVERSION: manual difference, normalization or lossy input
  cannot be separated. Do not change encoding based on this result.
* UNDECODABLE / INCONCLUSIVE: CRT/conversion/code-page mismatch; no automatic fix.
* MATCH / NO BYTE DIFFERENCE: byte mismatch not reproduced; authentication remains
  untested. Do not automatically follow with a server connection.

All native/decoded text comparisons are exact; no NFC/NFD or trimming is applied.
Real-password statuses are not written to a report. Share only the fixed statuses
and public code-page number if useful. Native helper remains an approximation of
the input path; decoding equality is evidence, not server authentication proof.

## Smallest safe authentication correction, only if later confirmed

Preserve the exact bytes of the KNOWN working native prompt into libpq17 instead of
silently decoding/re-encoding them through Unicode UTF-8. This would require a small,
explicit byte-preserving connection adapter or using native psql for the bounded
read-only diagnostic; psycopg's ordinary string DSN path performs UTF-8 encoding.
Do NOT apply blanket cp437/cp1252 conversion, URI percent-encoding, normalization,
password reset, console-code-page changes or weaker TLS. No authentication adapter
or production worker configuration was changed in this review because the real
cause remains unproven. Any subsequent bounded live test needs separate deliberate
authorization; full-size probe remains HOLD.

Regression coverage includes real synthetic CRT consoles, strict decoding/roundtrip,
ASCII and multiple code pages, lossy and normalization/manual differences, buffer/
console cleanup, existing SecureString/environment/libpq path and no-network gates.
Changed files: password_transport_check.py and its tests; new test_native_console_encoding.py.
