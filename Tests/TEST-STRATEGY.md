# NIC Command Center — Test Strategy

## Project Overview

NIC Command Center v2.0 is a single-file PowerShell backend (672 lines) that
serves an embedded HTML/JS web UI over a local HttpListener on port 8977.
It modifies real Windows network adapters, which makes testing it a high-stakes
exercise: a bad test that exercises real cmdlets can drop a machine off the
network.

**Stack:** PowerShell 5.1+, System.Net.HttpListener, Net cmdlets (Get-NetAdapter,
New-NetIPAddress, Set-NetIPInterface, etc.), external CLI tools (ping.exe,
tracert.exe, nslookup.exe, arp.exe).

**Test framework chosen:** Pester 5.x (the de-facto standard for PowerShell testing).

---

## Risk Profile

| Area | Risk Level | Why |
|---|---|---|
| Apply-NicConfig | CRITICAL | Mutates live network settings; any defect can cause immediate outage |
| Run-Ping / Run-Traceroute / Run-DnsLookup | HIGH | Pass user-controlled strings to external CLI processes — command injection risk |
| Run-Command | MEDIUM | Whitelist protects against injection, but whitelist completeness must be verified |
| Get-NicDataJson | MEDIUM | No mutations, but bad data can mislead the user into wrong configurations |
| Run-PortScan | LOW | .NET TcpClient, no shell spawning; edge cases around invalid port ranges |
| HTTP routing / 404 / CORS | LOW | Standard boilerplate; failure modes are cosmetic not dangerous |

---

## Testing Pyramid

```
                    ┌──────────────────────────────┐
                    │   E2E / Integration (8%)     │   7+ tests
                    │   Real HTTP server            │   Admin required
                    ├──────────────────────────────┤
                    │   Security (17%)             │   45+ tests
                    │   Injection, XSS, whitelist   │
                    ├──────────────────────────────┤
                    │   Unit (75%)                 │   75+ tests
                    │   Mocked cmdlets, fast, safe  │
                    └──────────────────────────────┘
```

Unit tests are the primary workhorse here because:
1. All mutating cmdlets can be mocked — no admin needed.
2. Execution takes seconds, not minutes.
3. They provide precise diagnosis when something breaks.

---

## Test Files

| File | Tier | Purpose |
|---|---|---|
| `Tests/Unit/Get-NicDataJson.Tests.ps1` | Unit | NIC data collection, subnet derivation, edge cases |
| `Tests/Unit/Apply-NicConfig.Tests.ps1` | Unit | Static/DHCP apply, rename, enable/disable, error handling |
| `Tests/Unit/Diagnostic-Functions.Tests.ps1` | Unit | Run-Ping, Run-SinglePing, Run-Traceroute, Run-DnsLookup, Run-PortScan, Run-ArpTable, Run-Command, Send-Resp, Read-Body |
| `Tests/Security/Security.Tests.ps1` | Security | Command injection, XSS, whitelist bypass, degenerate inputs |
| `Tests/Integration/API.Tests.ps1` | Integration | Full HTTP server round-trips (requires Admin) |
| `Tests/Helpers/TestHelpers.psm1` | Shared | Mock factories, payload builders, assertion helpers |
| `Tests/Run-Tests.ps1` | Runner | Discovers and executes tests, generates coverage/reports |

---

## P0 — Must Pass (Ship Blockers)

These scenarios represent the highest-impact failure modes.

### P0-01: Apply-NicConfig never partially applies and leaves NICs in an unknown state
**Test:** Unit — `Apply-NicConfig — error handling — returns success:false with error message`
**Why:** A partial apply (Remove-NetIPAddress succeeds, New-NetIPAddress fails) is
worse than a complete failure because the machine loses its old IP with no new
one assigned.

**Current finding:** The function does NOT wrap Remove-NetIPAddress +
New-NetIPAddress in a single atomic transaction.  If New-NetIPAddress throws,
the machine is left with no IP.  This is a critical production defect that the
`FailOnApply` mock in the test suite will expose.

**Recommendation:** Add a pre-flight IP validation step before removing the
existing address.

### P0-02: Command injection via diagnostic tool inputs
**Test:** Security — `Run-Ping/Traceroute/DnsLookup — target input validation`
**Why:** The backend passes `$d.target` directly to `ping -n $d.count -w 2000 $d.target`.
In PowerShell, the call operator `&` is not used here — the external command is
called via `2>&1|Out-String` in a string interpolation context which is safe for
simple cases, but payloads with newlines or backticks in the hostname passed to
`nslookup` may behave unexpectedly.

**Current finding:** On Windows, `ping.exe` treats the target as a DNS lookup
argument and does NOT interpret shell metacharacters.  However, `nslookup` is
more permissive — the `-type=` flag is also user-controlled.  Input validation
(allowlist regex on target field) should be added.

### P0-03: Run-Command whitelist cannot be bypassed
**Test:** Security — `Run-Command — command whitelist bypass attempts`
**Why:** The switch statement only executes known-safe cmdlets.  The default
branch returns `"Unknown: $($d.cmd)"` without executing anything.  This is
correct and must be verified to not regress.

### P0-04: Get-NicDataJson never crashes when cmdlets return null
**Test:** Unit — `Get-NicDataJson — No adapters present`
**Why:** `Get-NetAdapter` can return an empty array on machines with all adapters
uninstalled or hidden.  The function must return an empty JSON array, not throw.

---

## P1 — High Priority

### P1-01: Subnet mask derivation is correct for all common prefix lengths
`/8, /16, /24, /25, /30, /32` — boundary tests included in unit suite.

### P1-02: DHCP ↔ Static IP switching calls the right cmdlets
Static→DHCP must call `Set-NetIPInterface -Dhcp Enabled` and
`Set-DnsClientServerAddress -ResetServerAddresses`.
DHCP→Static must remove existing addresses before adding the new one.

### P1-03: IPv6 binding enable/disable respects the payload flag
`Apply-NicConfig` calls `Enable-NetAdapterBinding` or `Disable-NetAdapterBinding`
for `ms_tcpip6`.  Must not be skipped.

### P1-04: Interface metric is set correctly (auto vs. manual)
Empty metric → `AutomaticMetric Enabled`.  Non-empty metric → integer cast +
`AutomaticMetric Disabled`.  Integer cast failure is unhandled — potential crash.

### P1-05: Concurrent requests do not corrupt server state
The server loop is single-threaded but accepts requests synchronously.  Under
concurrent load, `GetContext()` blocks correctly.  Integration test covers this.

### P1-06: Adapter enable flow waits for adapter to come up
`Apply-NicConfig` calls `Start-Sleep 2` after `Enable-NetAdapter`.  If the
adapter does not respond in 2 seconds, the subsequent IP assignment will fail.
This is a known timing risk — the sleep mock in unit tests and a real-timing
integration test document the gap.

---

## P2 — Medium Priority

### P2-01: Port scan handles non-integer port values without crashing
Comma-separated ports include potential garbage from user input.

### P2-02: Very long adapter names (255 chars) produce valid JSON
`ConvertTo-Json` handles Unicode escaping correctly.

### P2-03: Adapter with name containing double-quotes produces valid JSON
`ConvertTo-Json` escapes `"` → `\"`.  Verified in unit suite.

### P2-04: IPv6-only adapter (no IPv4) reports empty `ip` field, not null
`null` vs. `""` distinction matters for the JS frontend (`n.ip` checks).

### P2-05: Rate limiting is absent — document and accept
The HTTP listener has no rate limiting.  A local denial-of-service is possible.
Accepted risk given the localhost-only deployment model.

### P2-06: CORS header is wildcard `*` — document and accept
`Access-Control-Allow-Origin: *` is intentional for local development.
Not a risk since the listener only binds to `localhost`.

---

## Edge Cases Matrix

| Scenario | Covered In |
|---|---|
| No network adapters present | Unit: `Get-NicDataJson — No adapters present` |
| Adapter with 255-char name | Unit: `Adapter with a very long name` |
| Adapter with special characters (quotes, backslashes) in name | Unit: `Adapter with special characters` |
| Adapter status = Disconnected | Unit: `Disabled adapter` section |
| Adapter status = Disabled | Unit: `Disabled adapter` section |
| IPv6-only adapter | Unit: `IPv6-only adapter` |
| VPN / virtual adapter | Integration: Detected via real Get-NetAdapter |
| Jumbo frames via advanced properties | Unit: `Jumbo frames detection` |
| DHCP → Static switch | Unit: `Apply-NicConfig — static IP assignment` |
| Static → DHCP switch | Unit: `Apply-NicConfig — DHCP mode` |
| Adapter rename | Unit: `Apply-NicConfig — adapter rename` |
| Mutating cmdlet failure mid-apply | Unit: `error handling — FailOnApply` |
| Multiple NICs, one fails | Unit: `processes subsequent NICs after one failure` |
| Malformed JSON body | Unit: `handles malformed JSON body without crashing` |
| Empty port list in portscan | Unit: `empty ports list` |
| Port 0 (below valid TCP range) | Security: `port number of 0` |
| Port 65536 (above valid TCP range) | Security: `port number of 65536` |
| Command injection in all diagnostic inputs | Security: full injection suite |
| Concurrent HTTP requests | Integration: `Concurrent requests` |
| Unknown HTTP path → 404 | Integration: `Unknown route` |

---

## Security Analysis

### Confirmed Safe (by design)
- **Run-Command:** Uses a strict switch whitelist.  The default branch returns
  a literal string, never executes the cmd value.  Verified by test.
- **Apply-NicConfig:** Passes values to PowerShell cmdlets, not cmd.exe.  PS
  cmdlets do not spawn a subshell.  Metacharacters are passed as literal string
  arguments to the .NET API.

### Risk Accepted (localhost-only deployment)
- **No authentication/authorization:** Any process running on localhost can call
  the API.  Since the tool runs as admin, a malicious local process could use
  the API to reconfigure network interfaces.  Out of scope for a local admin tool.
- **No CSRF protection:** `POST /api/apply` has no CSRF token.  Since CORS is
  `*` and the listener is on localhost, a page served from any origin could POST
  to the API.  Mitigated by: only reachable from localhost, requires admin.
- **CORS `*`:** Acceptable for local-only tools.

### Residual Risk (requires remediation)
- **Run-Ping, Run-Traceroute target validation:** No allowlist regex on target
  fields before passing to CLI.  Current PowerShell external command invocation
  is safe on Windows for these specific commands, but adding input validation
  (`target` must match `^[\w\.\-]+$`) is strongly recommended for defence in depth.
- **Run-DnsLookup type and target:** `nslookup -type=$($d.type) $d.target` —
  the type field is also unvalidated.  Should be restricted to the 8 types the
  UI exposes: `A|AAAA|MX|NS|CNAME|TXT|SOA|PTR`.
- **Apply-NicConfig IP validation:** No regex validation of IP fields before
  passing to `New-NetIPAddress`.  Invalid IPs cause a cmdlet exception which is
  caught and returned as an error message.  No security risk, but a UX issue.
- **Atomic apply:** As noted in P0-01, the remove/add sequence is not atomic.

---

## Running the Tests

### Prerequisites
```powershell
# Install Pester 5
Install-Module Pester -Force -SkipPublisherCheck
```

### Unit + Security (no admin required, ~5 seconds)
```powershell
cd C:\path\to\NIC-COMMANDER
.\Tests\Run-Tests.ps1
```

### All tiers including integration (admin required, ~30 seconds)
```powershell
# Must be in an elevated PowerShell session
.\Tests\Run-Tests.ps1 -All
```

### CI pipeline (fails with exit code 1 on any failure)
```powershell
.\Tests\Run-Tests.ps1 -CI
```

### Individual file
```powershell
Invoke-Pester -Path .\Tests\Unit\Apply-NicConfig.Tests.ps1 -Output Detailed
```

### With HTML report
```powershell
.\Tests\Run-Tests.ps1 -Report
# Generates: Tests/test-results.xml (NUnit format)
# Generates: Tests/coverage.xml (JaCoCo format)
```

---

## Coverage Targets

| Area | Target | Rationale |
|---|---|---|
| Apply-NicConfig | 90% | Highest-risk function |
| Get-NicDataJson | 85% | Data fidelity critical for UI correctness |
| Diagnostic functions | 75% | Lower risk; error paths exercised via security tests |
| HTTP routing (switch block) | 70% | Covered by integration tests |
| Overall | 75% | Pragmatic target for a single-file admin tool |

Note: 100% coverage is not the goal.  The `$HTML` string literal (lines 100–647
of the PS1) counts as many uncoverable lines.  Coverage metrics should be
computed against executable code only.

---

## Refactoring Recommendations (for testability)

The current single-file architecture makes it difficult to dot-source only the
function definitions without also triggering the HttpListener startup.  The
following structural changes would significantly improve testability:

1. **Extract functions into a module.**
   Move all `function` definitions into `NIC-CommandCenter-Functions.psm1`.
   The main PS1 just imports the module and starts the server.  Tests import
   the module directly — no `#Requires -RunAsAdministrator` conflict.

2. **Add input validation functions.**
   ```powershell
   function Test-ValidIPv4 { param([string]$IP) $IP -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' }
   function Test-ValidHostname { param([string]$H) $H -match '^[\w\.\-]{1,253}$' }
   ```
   These are pure functions that are trivially unit-testable.

3. **Wrap Apply-NicConfig in a transaction pattern.**
   Validate all fields before removing the existing IP.  Only proceed with
   removal if the new configuration is valid.

4. **Add a `$TestMode` switch to suppress `Start-Process $Url` on startup.**
   This prevents the browser from opening during test runs.
