#Requires -Modules Pester
<#
.SYNOPSIS
    Security-focused tests for NIC Command Center.

.DESCRIPTION
    Tests command injection, XSS, CSRF, and other security concerns across
    all input vectors that reach the PowerShell backend.

    ARCHITECTURE OF RISK:
    The backend passes certain inputs directly to external processes:
      - Run-Ping:       ping -n <count> -w 2000 <target>
      - Run-Traceroute: tracert -d -w 2000 <target>
      - Run-DnsLookup:  nslookup -type=<type> <target>

    These are the highest-priority injection surfaces.  Apply-NicConfig
    passes values to PS cmdlets (not cmd.exe), which is inherently safer
    but still requires validation gates once the function is refactored.

    Run-Command uses a strict whitelist switch, making it injection-resistant
    by design — these tests verify that whitelist cannot be bypassed.

.NOTES
    Run with:
        Invoke-Pester -Path .\Tests\Security\Security.Tests.ps1 -Output Detailed
#>

BeforeAll {
    . "$PSScriptRoot\..\..\NIC-CommandCenter.ps1" -ErrorAction SilentlyContinue

    # Payloads that attempt to inject additional OS commands.
    # In a fixed implementation, these should either be rejected or treated
    # as literal strings passed to the subprocess (which ping/tracert/nslookup
    # will simply fail on — they do not spawn further shells).
    $script:InjectionPayloads = @(
        '8.8.8.8 & whoami',
        '8.8.8.8; whoami',
        '8.8.8.8 | whoami',
        '8.8.8.8 && dir C:\',
        '8.8.8.8 || dir C:\',
        '$(whoami)',
        '`whoami`',
        "8.8.8.8`nwhoami",
        '8.8.8.8%0awhoami',
        '127.0.0.1 -n 1 8.8.8.8 & whoami',
        '" & whoami',
        "' & whoami"
    )

    # XSS payloads that should never appear unescaped in API output that
    # the browser will render as HTML.
    $script:XssPayloads = @(
        '<script>alert(1)</script>',
        '<img src=x onerror=alert(1)>',
        '"><script>alert(1)</script>',
        "javascript:alert('xss')",
        '<svg onload=alert(1)>'
    )
}

# ---------------------------------------------------------------------------
Describe 'Run-Command — command whitelist bypass attempts' {

    Context 'Injection via cmd field' {

        It 'does not execute injected payload when ";" separator is used' {
            $payload = '{"cmd":"ipconfig; whoami"}'
            $result  = Run-Command -J $payload | ConvertFrom-Json
            # The switch default fires — output will contain "Unknown:"
            $result.output | Should -Match 'Unknown'
        }

        It 'does not execute injected payload when "&" separator is used' {
            $result = Run-Command -J '{"cmd":"ipconfig & whoami"}' | ConvertFrom-Json
            $result.output | Should -Match 'Unknown'
        }

        It 'does not execute injected payload via PowerShell subexpression' {
            $result = Run-Command -J '{"cmd":"$(whoami)"}' | ConvertFrom-Json
            $result.output | Should -Match 'Unknown'
        }

        It 'does not execute injected payload via backtick subexpression' {
            $result = Run-Command -J '{"cmd":"``whoami``"}' | ConvertFrom-Json
            $result.output | Should -Match 'Unknown'
        }

        It 'rejects every injection variant via the whitelist' {
            foreach ($payload in $script:InjectionPayloads) {
                $json   = "{`"cmd`":`"$($payload -replace '"','\"')`"}"
                $result = Run-Command -J $json | ConvertFrom-Json
                $result.output | Should -Match 'Unknown' `
                    -Because "cmd='$payload' should not match any whitelist entry"
            }
        }

        It 'handles an empty cmd string without throwing' {
            { Run-Command -J '{"cmd":""}' | ConvertFrom-Json } | Should -Not -Throw
        }

        It 'handles a null cmd field without throwing' {
            { Run-Command -J '{"cmd":null}' | ConvertFrom-Json } | Should -Not -Throw
        }

        It 'handles an extremely long cmd string without throwing' {
            $longCmd = 'A' * 10000
            { Run-Command -J "{`"cmd`":`"$longCmd`"}" | ConvertFrom-Json } | Should -Not -Throw
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Run-Ping — target input validation' {

    Context 'Injection via target field' {

        It 'returns valid JSON (does not crash) for each injection payload' {
            foreach ($payload in $script:InjectionPayloads) {
                $escapedPayload = $payload -replace '"', '\"'
                $json = "{`"target`":`"$escapedPayload`",`"count`":1}"
                { Run-Ping -J $json | ConvertFrom-Json } | Should -Not -Throw `
                    -Because "target='$payload' must not crash the backend"
            }
        }

        It 'does not produce "whoami" in the output for OS-injection attempts' {
            # If injection succeeded, the output would contain the username.
            # ping.exe does not interpret shell metacharacters — it passes them
            # to the underlying OS DNS resolver which will fail.
            foreach ($payload in $script:InjectionPayloads) {
                $escapedPayload = $payload -replace '"', '\"'
                $json   = "{`"target`":`"$escapedPayload`",`"count`":1}"
                $result = Run-Ping -J $json | ConvertFrom-Json
                # The output should never contain the current username
                # (which would indicate successful command injection).
                $result.output | Should -Not -Match $env:USERNAME `
                    -Because "command injection should not produce shell output"
            }
        }
    }

    Context 'Degenerate target values' {

        It 'handles empty target string without crashing' {
            { Run-Ping -J '{"target":"","count":1}' | ConvertFrom-Json } | Should -Not -Throw
        }

        It 'handles very long hostname without crashing' {
            $longHost = ('a' * 253) + '.com'
            { Run-Ping -J "{`"target`":`"$longHost`",`"count`":1}" | ConvertFrom-Json } |
                Should -Not -Throw
        }

        It 'handles extremely large count value without crashing' {
            { Run-Ping -J '{"target":"127.0.0.1","count":999999}' | ConvertFrom-Json } |
                Should -Not -Throw
        }

        It 'handles negative count value without crashing' {
            { Run-Ping -J '{"target":"127.0.0.1","count":-1}' | ConvertFrom-Json } |
                Should -Not -Throw
        }

        It 'handles null target without crashing' {
            { Run-Ping -J '{"target":null,"count":1}' | ConvertFrom-Json } | Should -Not -Throw
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Run-SinglePing — target input validation' {

    Context 'Injection via target field' {

        It 'returns valid JSON for injection payloads (Test-Connection rejects them)' {
            # Test-Connection is a cmdlet; it does not invoke a shell.
            # It will throw on invalid hostnames which the catch block handles.
            Mock Test-Connection { throw 'Hostname not found' }
            foreach ($payload in $script:InjectionPayloads) {
                $escapedPayload = $payload -replace '"', '\"'
                { Run-SinglePing -J "{`"target`":`"$escapedPayload`"}" | ConvertFrom-Json } |
                    Should -Not -Throw
            }
        }

        It 'returns success:false for injected payloads' {
            Mock Test-Connection { throw 'Hostname not found' }
            foreach ($payload in $script:InjectionPayloads) {
                $escapedPayload = $payload -replace '"', '\"'
                $result = Run-SinglePing -J "{`"target`":`"$escapedPayload`"}" | ConvertFrom-Json
                $result.success | Should -BeFalse
            }
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Run-Traceroute — target input validation' {

    Context 'Injection via target field' {

        It 'returns valid JSON for injection payloads' {
            foreach ($payload in $script:InjectionPayloads) {
                $escapedPayload = $payload -replace '"', '\"'
                { Run-Traceroute -J "{`"target`":`"$escapedPayload`"}" | ConvertFrom-Json } |
                    Should -Not -Throw
            }
        }

        It 'does not include whoami output in traceroute response' {
            foreach ($payload in $script:InjectionPayloads) {
                $escapedPayload = $payload -replace '"', '\"'
                $result = Run-Traceroute -J "{`"target`":`"$escapedPayload`"}" | ConvertFrom-Json
                $result.output | Should -Not -Match $env:USERNAME
            }
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Run-DnsLookup — target and type input validation' {

    Context 'Injection via target field' {

        It 'returns valid JSON for injection payloads in target' {
            foreach ($payload in $script:InjectionPayloads) {
                $escapedPayload = $payload -replace '"', '\"'
                { Run-DnsLookup -J "{`"target`":`"$escapedPayload`",`"type`":`"A`"}" | ConvertFrom-Json } |
                    Should -Not -Throw
            }
        }
    }

    Context 'Injection via type field' {

        It 'returns valid JSON when type is injected' {
            # "type" is passed as -type=<value> to nslookup.
            # Verify invalid values do not crash the backend.
            $injectedTypes = @('A; whoami', 'A & whoami', '$(whoami)', 'A%0awhoami')
            foreach ($t in $injectedTypes) {
                $escapedType = $t -replace '"', '\"'
                { Run-DnsLookup -J "{`"target`":`"8.8.8.8`",`"type`":`"$escapedType`"}" | ConvertFrom-Json } |
                    Should -Not -Throw
            }
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Run-PortScan — target and ports input validation' {

    Context 'Injection via target field' {

        It 'returns valid JSON for injection payloads in target' {
            foreach ($payload in $script:InjectionPayloads) {
                $escapedPayload = $payload -replace '"', '\"'
                { Run-PortScan -J "{`"target`":`"$escapedPayload`",`"ports`":`"80`"}" | ConvertFrom-Json } |
                    Should -Not -Throw
            }
        }
    }

    Context 'Injection via ports field' {

        It 'handles non-numeric characters in ports list gracefully' {
            # Non-integer port values should produce CLOSED results (TcpClient cast fails).
            $badPorts = @('80;whoami', '80|whoami', '80,$(cat /etc/passwd)', '80 & dir')
            foreach ($p in $badPorts) {
                $escapedP = $p -replace '"', '\"'
                { Run-PortScan -J "{`"target`":`"127.0.0.1`",`"ports`":`"$escapedP`"}" | ConvertFrom-Json } |
                    Should -Not -Throw
            }
        }

        It 'handles a port number of 0 (below valid range)' {
            { Run-PortScan -J '{"target":"127.0.0.1","ports":"0"}' | ConvertFrom-Json } |
                Should -Not -Throw
        }

        It 'handles a port number of 65536 (above valid range)' {
            { Run-PortScan -J '{"target":"127.0.0.1","ports":"65536"}' | ConvertFrom-Json } |
                Should -Not -Throw
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Apply-NicConfig — injection via NIC config fields' {

    BeforeEach {
        Mock Get-NetAdapter { [PSCustomObject]@{ Status = 'Up'; Name = 'Ethernet' } }
        Mock Rename-NetAdapter {}
        Mock Set-NetIPInterface {}
        Mock Set-DnsClientServerAddress {}
        Mock Remove-NetIPAddress {}
        Mock Remove-NetRoute {}
        Mock New-NetIPAddress { [PSCustomObject]@{} }
        Mock Set-DnsClient {}
        Mock Enable-NetAdapterBinding {}
        Mock Disable-NetAdapterBinding {}
        Mock Start-Sleep {}
    }

    Context 'IP address field injection' {

        It 'does not crash when IP field contains command injection characters' {
            # PS cmdlets do not spawn a shell, so metacharacters are safe.
            # New-NetIPAddress will throw on an invalid IP — caught by try/catch.
            $payload = @(@{
                originalName = 'Ethernet'; name = 'Ethernet'; dhcp = $false; enabled = $true
                ip = '192.168.1.1; whoami'; subnet = '255.255.255.0'; prefix = 24
                gateway = '192.168.1.1'; dns1 = ''; dns2 = ''
                ipv6 = $false; metric = ''; dnsSuffix = $null; registerDns = $true
            }) | ConvertTo-Json -Depth 5

            { Apply-NicConfig -JsonBody $payload | ConvertFrom-Json } | Should -Not -Throw
        }

        It 'reports failure (not success) when IP contains invalid characters' {
            Mock New-NetIPAddress { throw 'Invalid IP address' }
            $payload = @(@{
                originalName = 'Ethernet'; name = 'Ethernet'; dhcp = $false; enabled = $true
                ip = '999.999.999.999'; subnet = '255.255.255.0'; prefix = 24
                gateway = ''; dns1 = ''; dns2 = ''
                ipv6 = $false; metric = ''; dnsSuffix = $null; registerDns = $true
            }) | ConvertTo-Json -Depth 5

            $result = Apply-NicConfig -JsonBody $payload | ConvertFrom-Json
            $result.success | Should -BeFalse
        }
    }

    Context 'Adapter name injection' {

        It 'does not crash when adapter name contains shell metacharacters' {
            Mock Rename-NetAdapter {}
            $payload = @(@{
                originalName = 'Ethernet'; name = 'Ethernet; whoami'; dhcp = $true; enabled = $true
                ip = ''; subnet = ''; prefix = 24; gateway = ''; dns1 = ''; dns2 = ''
                ipv6 = $false; metric = ''; dnsSuffix = $null; registerDns = $true
            }) | ConvertTo-Json -Depth 5

            { Apply-NicConfig -JsonBody $payload | ConvertFrom-Json } | Should -Not -Throw
        }
    }

    Context 'DNS field injection' {

        It 'does not crash when DNS server field contains shell metacharacters' {
            $payload = @(@{
                originalName = 'Ethernet'; name = 'Ethernet'; dhcp = $false; enabled = $true
                ip = '192.168.1.10'; subnet = '255.255.255.0'; prefix = 24; gateway = '192.168.1.1'
                dns1 = '8.8.8.8 & whoami'; dns2 = ''
                ipv6 = $false; metric = ''; dnsSuffix = $null; registerDns = $true
            }) | ConvertTo-Json -Depth 5

            { Apply-NicConfig -JsonBody $payload | ConvertFrom-Json } | Should -Not -Throw
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'HTTP server — security header verification' {
    # These tests require a running server (integration-level).
    # They are defined here as stubs so they can be promoted to the
    # integration suite when a test server is available.

    It '[STUB] response includes Access-Control-Allow-Origin: * header' {
        Set-ItResult -Skipped -Because 'Requires running HTTP server — promote to Integration tests'
    }

    It '[STUB] response does NOT include X-Powered-By or Server disclosure headers' {
        Set-ItResult -Skipped -Because 'Requires running HTTP server — promote to Integration tests'
    }

    It '[STUB] OPTIONS preflight returns 200' {
        Set-ItResult -Skipped -Because 'Requires running HTTP server — promote to Integration tests'
    }
}

# ---------------------------------------------------------------------------
Describe 'JSON response — XSS in output fields' {

    Context 'Adapter name with XSS payload passes through JSON safely' {

        It 'ConvertTo-Json encodes < and > in adapter name (JSON-level escaping)' {
            # Get-NicDataJson uses ConvertTo-Json which encodes unicode escapes
            # for characters like <, >, &.  The front-end esc() function in JS
            # handles HTML encoding.  This test verifies the backend layer.
            Mock Get-NetAdapter { @([PSCustomObject]@{
                Name = '<script>alert(1)</script>'; InterfaceDescription = 'Test'
                MacAddress = 'AA:BB:CC:DD:EE:FF'; Status = 'Up'
                InterfaceIndex = 3; LinkSpeed = '1 Gbps'
            }) }
            Mock Get-NetIPConfiguration { [PSCustomObject]@{ IPv4DefaultGateway = $null } }
            Mock Get-NetIPAddress { $null }
            Mock Get-NetIPInterface { [PSCustomObject]@{ Dhcp='Disabled'; NlMtu=1500; AutomaticMetric=$true; InterfaceMetric=0 } }
            Mock Get-DnsClientServerAddress { [PSCustomObject]@{ ServerAddresses = @() } }
            Mock Get-DnsClient { [PSCustomObject]@{ ConnectionSpecificSuffix=''; RegisterThisConnectionsAddress=$true } }
            Mock Get-NetAdapterAdvancedProperty { @() }
            Mock Get-NetAdapterBinding { [PSCustomObject]@{ Enabled = $false } }

            $rawJson = Get-NicDataJson

            # The raw JSON string should NOT contain a literal unescaped <script> tag.
            # ConvertTo-Json uses \u003c for < and \u003e for > by default in PS 5.x.
            $rawJson | Should -Not -Match '<script>'
        }
    }

    Context 'Diagnostic output — XSS in target names' {

        It 'diagnostic output is a plain string returned in a JSON envelope (safe for textContent assignment)' {
            # The JS UI uses `o.textContent = r.output` — not innerHTML — so
            # XSS from diagnostic output is already mitigated by the UI.
            # This test documents that the backend returns raw output as a
            # JSON string (not pre-rendered HTML), confirming the API contract.
            Mock Test-Connection { [PSCustomObject]@{ ResponseTime = 1 } }
            $xssTarget = '<script>alert(1)</script>'
            # SinglePing target is echoed back in the JSON, not in output
            $result = Run-SinglePing -J "{`"target`":`"$($xssTarget -replace '"','\"')`"}" | ConvertFrom-Json
            # The JSON should round-trip correctly
            $result.target | Should -Be $xssTarget
            # And the whole response must be valid JSON
            $result | Should -Not -BeNullOrEmpty
        }
    }
}
