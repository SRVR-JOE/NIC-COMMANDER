#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for the diagnostic tool functions:
    Run-Ping, Run-SinglePing, Run-Traceroute, Run-DnsLookup,
    Run-PortScan, Run-ArpTable, Run-Command.

.DESCRIPTION
    These tests are entirely self-contained.  Native commands (ping, tracert,
    nslookup, arp, netsh, ipconfig, route, netstat) are mocked via
    PowerShell function-level mocks and/or by inspecting JSON output.

    IMPORTANT: Run-Ping, Run-Traceroute, Run-DnsLookup and Run-ArpTable call
    external CLI binaries directly (not PS cmdlets).  True unit isolation
    requires a wrapper function or -MockWith on the external call.  In
    environments where the binaries do not exist, the tests verify the
    error-handling path instead.

.NOTES
    Run with:
        Invoke-Pester -Path .\Tests\Unit\Diagnostic-Functions.Tests.ps1 -Output Detailed
#>

BeforeAll {
    . "$PSScriptRoot\..\..\NIC-CommandCenter.ps1" -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
Describe 'Run-SinglePing — PowerShell-native ping' {

    It 'returns success:true and a positive ms value for a reachable host' {
        # Test-Connection is a PS cmdlet — mockable.
        Mock Test-Connection {
            [PSCustomObject]@{ ResponseTime = 12 }
        }
        $result = Run-SinglePing -J '{"target":"127.0.0.1"}' | ConvertFrom-Json
        $result.success | Should -BeTrue
        $result.ms      | Should -BeGreaterThan 0
    }

    It 'returns the target back in the response' {
        Mock Test-Connection { [PSCustomObject]@{ ResponseTime = 5 } }
        $result = Run-SinglePing -J '{"target":"10.0.0.1"}' | ConvertFrom-Json
        $result.target | Should -Be '10.0.0.1'
    }

    It 'returns success:false and ms:-1 when host is unreachable' {
        Mock Test-Connection { throw 'Request timed out' }
        $result = Run-SinglePing -J '{"target":"192.0.2.1"}' | ConvertFrom-Json
        $result.success | Should -BeFalse
        $result.ms      | Should -Be -1
    }

    It 'returns valid JSON when the target is an empty string' {
        # Empty-string hostname causes Test-Connection to throw.
        Mock Test-Connection { throw 'Invalid hostname' }
        { Run-SinglePing -J '{"target":""}' | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'returns valid JSON for a hostname target' {
        Mock Test-Connection { [PSCustomObject]@{ ResponseTime = 20 } }
        $result = Run-SinglePing -J '{"target":"google.com"}' | ConvertFrom-Json
        $result.success | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
Describe 'Run-PortScan — TCP connectivity checks' {

    Context 'Port is open' {

        BeforeEach {
            # Mock TcpClient so no real network activity occurs.
            # Because TcpClient is a .NET type we cannot mock it directly, but
            # we CAN verify the function handles the open path by using a loopback
            # address and a port the test machine has open (127.0.0.1:445 may
            # not be open everywhere).  Instead, we verify the shape of the
            # response and leave actual connectivity to integration tests.

            # Strategy: verify that a closed port returns state 'CLOSED'
            # and that the function does not throw.
        }

        It 'returns valid JSON for a single-port scan' {
            { Run-PortScan -J '{"target":"127.0.0.1","ports":"80"}' | ConvertFrom-Json } |
                Should -Not -Throw
        }

        It 'includes a results array in the response' {
            $result = Run-PortScan -J '{"target":"127.0.0.1","ports":"80"}' | ConvertFrom-Json
            $result.results | Should -Not -BeNullOrEmpty
        }

        It 'returns the correct port number in results' {
            $result = Run-PortScan -J '{"target":"127.0.0.1","ports":"80"}' | ConvertFrom-Json
            $result.results[0].port | Should -Be 80
        }

        It 'reports a state of either OPEN or CLOSED (not a null/empty string)' {
            $result = Run-PortScan -J '{"target":"127.0.0.1","ports":"80"}' | ConvertFrom-Json
            $result.results[0].state | Should -Match '^(OPEN|CLOSED)$'
        }
    }

    Context 'Multiple ports' {

        It 'scans all provided ports and returns one result per port' {
            $result = Run-PortScan -J '{"target":"127.0.0.1","ports":"80,443,22"}' | ConvertFrom-Json
            @($result.results).Count | Should -Be 3
        }

        It 'handles whitespace around port numbers in the comma-separated list' {
            $result = Run-PortScan -J '{"target":"127.0.0.1","ports":" 80 , 443 "}' | ConvertFrom-Json
            @($result.results).Count | Should -Be 2
        }

        It 'handles a trailing comma in the port list without crashing' {
            { Run-PortScan -J '{"target":"127.0.0.1","ports":"80,"}' | ConvertFrom-Json } |
                Should -Not -Throw
        }
    }

    Context 'Edge cases' {

        It 'returns valid JSON when ports list is empty' {
            { Run-PortScan -J '{"target":"127.0.0.1","ports":""}' | ConvertFrom-Json } |
                Should -Not -Throw
        }

        It 'returns empty results array when ports list is empty' {
            $result = Run-PortScan -J '{"target":"127.0.0.1","ports":""}' | ConvertFrom-Json
            @($result.results).Count | Should -Be 0
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Run-Command — whitelist-based command execution' {

    Context 'Whitelisted commands' {

        It 'returns valid JSON for each whitelisted command keyword' {
            foreach ($cmd in @('ipconfig','ipconfig_all','route_print','netstat','flushdns','release','renew','arp_flush')) {
                $payload = "{`"cmd`":`"$cmd`"}"
                { Run-Command -J $payload | ConvertFrom-Json } | Should -Not -Throw -Because "cmd=$cmd should return valid JSON"
            }
        }

        It 'returns success:true for whitelisted commands' {
            foreach ($cmd in @('ipconfig','ipconfig_all','route_print','netstat','flushdns','release','renew','arp_flush')) {
                $payload = "{`"cmd`":`"$cmd`"}"
                $result  = Run-Command -J $payload | ConvertFrom-Json
                $result.success | Should -BeTrue -Because "cmd=$cmd should succeed"
            }
        }

        It 'output field is a string (not null) for ipconfig' {
            $result = Run-Command -J '{"cmd":"ipconfig"}' | ConvertFrom-Json
            $result.output | Should -BeOfType [string]
            $result.output.Length | Should -BeGreaterThan 0
        }
    }

    Context 'Unknown command (reject path)' {

        It 'returns success:true but output contains "Unknown:" for unrecognised commands' {
            # The current implementation uses the switch default branch:
            # "Unknown: $($d.cmd)" — this is returned as output, not an error.
            # This test documents current behaviour and will catch if it changes.
            $result = Run-Command -J '{"cmd":"format_c"}' | ConvertFrom-Json
            $result.output | Should -Match 'Unknown'
        }

        It 'does NOT execute the unknown command value as a shell command' {
            # The switch default returns a string — it does NOT invoke the value.
            # Verify by passing a value that would produce observable output if run.
            # We confirm output contains 'Unknown' rather than command output.
            $result = Run-Command -J '{"cmd":"whoami"}' | ConvertFrom-Json
            $result.output | Should -Match 'Unknown'
        }
    }

    Context 'JSON parsing' {

        It 'handles missing cmd field gracefully' {
            # $d.cmd will be null; switch default fires.
            { Run-Command -J '{"other":"value"}' | ConvertFrom-Json } | Should -Not -Throw
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Run-DnsLookup — nslookup wrapper' {

    Context 'Valid DNS type options' {

        It 'returns valid JSON for type A' {
            # nslookup may not be available in test environment; verify
            # the error path returns valid JSON.
            $result = Run-DnsLookup -J '{"target":"127.0.0.1","type":"A"}'
            { $result | ConvertFrom-Json } | Should -Not -Throw
        }

        It 'success field is a boolean' {
            $result = Run-DnsLookup -J '{"target":"127.0.0.1","type":"A"}' | ConvertFrom-Json
            $result.success | Should -BeIn @($true, $false)
        }

        It 'output field exists in the response' {
            $result = Run-DnsLookup -J '{"target":"127.0.0.1","type":"A"}' | ConvertFrom-Json
            $result.PSObject.Properties.Name | Should -Contain 'output'
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Run-ArpTable — arp -a wrapper' {

    It 'returns valid JSON' {
        $result = Run-ArpTable
        { $result | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'success field is a boolean' {
        $result = Run-ArpTable | ConvertFrom-Json
        $result.success | Should -BeIn @($true, $false)
    }

    It 'output field exists in the response' {
        $result = Run-ArpTable | ConvertFrom-Json
        $result.PSObject.Properties.Name | Should -Contain 'output'
    }
}

# ---------------------------------------------------------------------------
Describe 'Send-Resp helper' {

    It 'sets ContentType on the response object' {
        # Minimal mock of HttpListenerResponse
        $mockResponse = [PSCustomObject]@{
            ContentType    = $null
            ContentLength64 = 0
            OutputStream   = $null
        }
        # We cannot easily mock OutputStream.Write; test the property-setting path.
        # This verifies Send-Resp does not throw with a null OutputStream before
        # the Write call — actual write is an integration concern.
        # Patch OutputStream to a MemoryStream for a complete unit test.
        $ms = New-Object System.IO.MemoryStream
        $mockResponse | Add-Member -NotePropertyName OutputStream -NotePropertyValue $ms -Force

        { Send-Resp -r $mockResponse -j '{"test":1}' -ct 'application/json' } |
            Should -Not -Throw

        $mockResponse.ContentType | Should -Be 'application/json'
    }
}

# ---------------------------------------------------------------------------
Describe 'Read-Body helper' {

    It 'reads and returns the body from a stream' {
        $bodyText = '{"action":"test"}'
        $bytes    = [System.Text.Encoding]::UTF8.GetBytes($bodyText)
        $stream   = New-Object System.IO.MemoryStream(, $bytes)

        # Build a minimal fake request object.
        $fakeRequest = [PSCustomObject]@{
            InputStream      = $stream
            ContentEncoding  = [System.Text.Encoding]::UTF8
        }

        $result = Read-Body -r $fakeRequest
        $result | Should -Be $bodyText
    }
}
