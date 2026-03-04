# Changelog

## v2.1.0 — 2026-03-02

### Security Fixes
- **CRITICAL**: Fixed command injection vulnerability in ping, traceroute, and DNS lookup endpoints
- **CRITICAL**: Added CSRF token protection — external sites can no longer trigger NIC changes
- **CRITICAL**: Restricted CORS from wildcard (`*`) to same-origin only
- Fixed XSS in toast notifications (switched from innerHTML to textContent)
- Fixed XSS via single-quote injection in profile name onclick handlers
- Replaced `nslookup` with `Resolve-DnsName` to eliminate shell argument injection
- Added input validation on all network targets, IP addresses, DNS servers, ports
- Sanitized error messages in HTTP responses (no more raw exception leakage)
- Added `X-Frame-Options: DENY` and `X-Content-Type-Options: nosniff` headers
- Added Content Security Policy header on HTML responses
- Bound HTTP listener to `127.0.0.1` explicitly instead of `localhost`
- Added request body size limit (1MB)
- Added port validation and count limit (max 100) for port scanner

### Bug Fixes
- **CRITICAL**: Fixed all `-ErrorAction SilentlyContinue` in Apply-NicConfig — operations now properly report failures instead of showing "Configured OK"
- **CRITICAL**: Fixed Execute Profile button — now actually applies changes instead of just loading into UI
- **CRITICAL**: Fixed Refresh button — now re-fetches data from backend instead of re-rendering stale data
- Fixed `Test-Connection` cross-version compatibility (PS 5.x vs 7.x ResponseTime/Latency)
- Fixed empty catch block on main listener loop — server crashes now show error message
- Fixed Apply-NicConfig atomicity — validates all IPs before removing existing addresses
- Fixed OutputStream not being closed in Send-Resp (stream leak)
- Fixed `$nic.dnsSuffix -ne $null` always evaluating true for empty strings
- Fixed socket handle leak in port scan (EndConnect now always called, try/finally for cleanup)
- Fixed loading overlay hidden on fetch error — now shows retry state
- Fixed `api()` function not checking `response.ok` — HTTP errors now properly thrown
- Fixed ping monitor using `setInterval` (race condition) — now uses `setTimeout`
- Fixed `exportProfiles()` leaking Object URLs — now calls `revokeObjectURL`
- Fixed `renderQuick()` using `innerHTML +=` in loop — now builds string first (O(n) vs O(n2))
- Fixed subnet mask edit not recalculating prefix length
- Fixed port scan reporting all errors as "CLOSED" — now distinguishes OPEN/CLOSED/ERROR/INVALID
- Fixed single-adapter systems serializing as JSON object instead of array
- Fixed default subnet mask showing 255.255.255.0 when no IP assigned — now shows blank

### New Features
- Added configurable port via `param([int]$Port = 8977)`
- Added version constant and `/api/version` endpoint
- Added Import button for profiles (was non-functional placeholder)
- Added file logging for all Apply operations (`NIC-CommandCenter.log`)
- Added MTU application in Apply-NicConfig (was display-only before)
- Added dynamic status bar — shows real connection state and last refresh time
- Added IP address validation on Quick Config inputs (red border on invalid)
- Added `#Requires -Version 5.1` directive

### Accessibility
- Added `role="switch"` and `aria-checked` to all toggle buttons
- Added `aria-label` to all Quick Config table inputs
- Added `scope="col"` to table header cells
- Added `role="dialog"` and `aria-modal` to modal overlays
- Added focus management for modal open
- Added Escape key handler to dismiss modals
- Disabled inputs on disabled adapter Advanced cards (`pointer-events: none`)

### UI/UX
- Replaced Google Fonts CDN with system font stack (Segoe UI + Cascadia Code) — works offline
- Fixed `.q-wrap` overflow from `hidden` to `auto` — table now scrolls on narrow screens
- Fixed `pointer-events: all` to valid `pointer-events: auto` on modals
- Added `localStorage` error handling for quota exceeded
- Updated BAT launcher to detect UAC failure and show meaningful error

### Architecture
- Added `Test-ValidTarget` and `Test-ValidIPv4` validation functions
- Added `Write-Log` function for audit logging
- Proper README with full documentation
- Added CHANGELOG, LICENSE, .gitignore

## v2.0.0 — Initial Release

- 3-tab web UI: Quick Config, Advanced Settings, Diagnostics
- Auto-detects all network adapters
- Live configuration via PowerShell backend
- Profile save/load/export system
- Ping Monitor with multi-target support
