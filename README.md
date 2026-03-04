# NIC Command Center v2.1

A self-contained Windows network interface configurator with a web-based UI. Runs as a local PowerShell HTTP server — no installation required.

## Features

- **Quick Config** — View and configure all NICs in a table: IP, subnet, gateway, DNS, DHCP toggle
- **Advanced Settings** — MTU, VLAN, metrics, IPv6, DNS suffix, Wake on LAN, jumbo frames, QoS
- **Diagnostics** — Ping, traceroute, DNS lookup, port scan, ARP table, quick commands
- **Ping Monitor** — Real-time multi-target ping dashboard with latency history charts
- **Profiles** — Save, load, export/import NIC configurations for different venues/networks

## Requirements

| Requirement | Details |
|---|---|
| OS | Windows 8.1 / Server 2012 R2 or later |
| PowerShell | 5.1+ (built-in on Windows 10/11) |
| Privileges | Administrator (required for NIC configuration) |
| Dependencies | None — fully self-contained |

## Quick Start

1. **Download** the latest release ZIP from [Releases](https://github.com/SRVR-JOE/NIC-COMMANDER/releases)
2. **Extract** to any folder
3. **Double-click** `NIC-CommandCenter.bat` and approve the UAC prompt
4. The web UI opens automatically at `http://127.0.0.1:8977`

### Alternative Launch

```powershell
# Right-click PowerShell > Run as Administrator
.\NIC-CommandCenter.ps1

# Custom port
.\NIC-CommandCenter.ps1 -Port 9000
```

## Configuration

### Port Override

Default port is `8977`. Change it via command line:

```powershell
.\NIC-CommandCenter.ps1 -Port 9000
```

### Profiles

- Profiles are stored in your browser's `localStorage`
- Use **Export** to save profiles as a JSON file (portable across machines)
- Use **Import** to load profiles from a JSON file
- **Execute** loads a profile AND applies it to the NICs immediately

### Logging

Apply operations are logged to `NIC-CommandCenter.log` in the same directory as the script. This provides an audit trail of all network configuration changes.

## Security

- Listens on `127.0.0.1` only — not accessible from other machines
- CSRF token protection on all mutating API endpoints
- Input validation on all diagnostic targets and network configuration fields
- No external dependencies or CDN resources — fully offline capable

## Diagnostics

| Tool | Description |
|---|---|
| Ping | ICMP ping with configurable count (uses `Test-Connection`) |
| Traceroute | Hop-by-hop path trace |
| DNS Lookup | Query A, AAAA, MX, NS, CNAME, TXT, SOA, PTR records |
| Port Scan | TCP connect scan on specified ports |
| ARP Table | View and flush the ARP cache |
| Quick Commands | ipconfig, route print, netstat, flush DNS, DHCP release/renew |
| Ping Monitor | Real-time multi-target monitoring with latency graphs |

## Known Limitations

- **Single-threaded**: Long-running operations (traceroute, large ping) will briefly block other requests
- **Browser localStorage**: Profiles are per-browser — use Export/Import to transfer between browsers
- **Windows only**: Requires Windows PowerShell and the NetTCPIP module

## Troubleshooting

| Issue | Solution |
|---|---|
| "Could not start on port 8977" | Another process is using the port. Use `-Port 9000` or close the conflicting process |
| UAC prompt doesn't appear | Right-click the `.bat` file > Run as Administrator |
| Empty adapter list | Check that the Network Connections service is running |
| Fonts look different | The tool uses system fonts (Segoe UI, Cascadia Code). Install Windows Terminal for best monospace rendering |

## License

MIT License. See [LICENSE](LICENSE).
