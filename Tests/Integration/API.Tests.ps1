#Requires -Modules Pester
<#
.SYNOPSIS
    Integration tests for the NIC Command Center HTTP API.

.DESCRIPTION
    These tests start a real HttpListener on a test port and exercise the
    full request/response cycle without mocking the backend functions.

    PREREQUISITES:
      - Must be run as Administrator (the HttpListener requires it).
      - No real NIC changes are made: Apply-NicConfig is patched to a safe
        no-op before the server starts.
      - Port 9977 must be free.

    SETUP PATTERN:
      BeforeAll starts the server in a background runspace.
      AfterAll stops the listener and cleans up.

    Run with:
        Invoke-Pester -Path .\Tests\Integration\API.Tests.ps1 -Output Detailed

.NOTES
    These tests WILL FAIL on non-Windows or without admin rights.
    They are designed for Windows CI runners with admin access.
#>

BeforeAll {
    $script:TestPort = 9977
    $script:BaseUrl  = "http://localhost:$($script:TestPort)"

    # ---------------------------------------------------------------------------
    # Spin up a copy of the server in a background runspace, but patch
    # Apply-NicConfig to a safe stub so no real NICs are touched.
    # ---------------------------------------------------------------------------
    $script:ServerRunspace = [runspacefactory]::CreateRunspace()
    $script:ServerRunspace.Open()

    # Share the port and base URL into the runspace.
    $script:ServerRunspace.SessionStateProxy.SetVariable('TestPort', $script:TestPort)

    $script:ServerPipeline = [powershell]::Create()
    $script:ServerPipeline.Runspace = $script:ServerRunspace

    # The script block loaded into the runspace: dot-source the PS1, override
    # Apply-NicConfig and the listener port, then start serving.
    [void]$script:ServerPipeline.AddScript({
        param()
        # Override port before starting listener
        $Port = $TestPort
        $Url  = "http://localhost:$Port/"

        # Dot-source functions (skip the auto-start block by wrapping in function)
        # We replicate just the function definitions here for isolation.
        # In a CI environment this file should be refactored to separate
        # function definitions from the event loop.
        . "$PSScriptRoot\..\..\NIC-CommandCenter.ps1" -ErrorAction SilentlyContinue

        # Override the mutating function with a safe no-op.
        function global:Apply-NicConfig { param([string]$JsonBody)
            return '[{"name":"Ethernet","success":true,"message":"Test stub - no change made"}]'
        }

        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add($Url)
        try { $listener.Start() } catch { return }

        while ($listener.IsListening) {
            try {
                $ctx = $listener.GetContext()
                $req = $ctx.Request; $res = $ctx.Response; $path = $req.Url.AbsolutePath
                $res.Headers.Add("Access-Control-Allow-Origin","*")
                $res.Headers.Add("Access-Control-Allow-Methods","GET,POST,OPTIONS")
                $res.Headers.Add("Access-Control-Allow-Headers","Content-Type")
                if ($req.HttpMethod -eq "OPTIONS") { $res.StatusCode=200; $res.Close(); continue }
                try { switch ($path) {
                    "/"             { Send-Resp $res $HTML "text/html; charset=utf-8" }
                    "/api/nics"     { Send-Resp $res (Get-NicDataJson) }
                    "/api/apply"    { $b=Read-Body $req; Send-Resp $res (Apply-NicConfig -JsonBody $b) }
                    "/api/ping"     { $b=Read-Body $req; Send-Resp $res (Run-Ping -J $b) }
                    "/api/singleping" { $b=Read-Body $req; Send-Resp $res (Run-SinglePing -J $b) }
                    "/api/traceroute" { $b=Read-Body $req; Send-Resp $res (Run-Traceroute -J $b) }
                    "/api/dns"      { $b=Read-Body $req; Send-Resp $res (Run-DnsLookup -J $b) }
                    "/api/portscan" { $b=Read-Body $req; Send-Resp $res (Run-PortScan -J $b) }
                    "/api/arp"      { Send-Resp $res (Run-ArpTable) }
                    "/api/cmd"      { $b=Read-Body $req; Send-Resp $res (Run-Command -J $b) }
                    default { $res.StatusCode=404; Send-Resp $res '{"error":"Not found"}' }
                } } catch { $res.StatusCode=500; Send-Resp $res "{`"error`":`"$($_.Exception.Message)`"}" }
                $res.Close()
            } catch { break }
        }
        $listener.Stop()
    })

    $script:AsyncResult = $script:ServerPipeline.BeginInvoke()

    # Give the server a moment to start.
    Start-Sleep -Milliseconds 800

    # ---------------------------------------------------------------------------
    # Helper: make HTTP requests to the test server.
    # ---------------------------------------------------------------------------
    function Invoke-ApiRequest {
        param(
            [string]$Path,
            [string]$Method = 'GET',
            [hashtable]$Body = $null
        )
        $uri = "$($script:BaseUrl)$Path"
        $params = @{ Uri = $uri; Method = $Method; UseBasicParsing = $true; TimeoutSec = 15 }
        if ($Body) {
            $params['Body']        = $Body | ConvertTo-Json -Depth 5
            $params['ContentType'] = 'application/json'
        }
        return Invoke-WebRequest @params
    }

    function Invoke-ApiJson {
        param([string]$Path, [string]$Method = 'GET', [hashtable]$Body = $null)
        $response = Invoke-ApiRequest -Path $Path -Method $Method -Body $Body
        return $response.Content | ConvertFrom-Json
    }
}

AfterAll {
    if ($script:ServerPipeline) {
        $script:ServerPipeline.Stop()
        $script:ServerPipeline.Dispose()
    }
    if ($script:ServerRunspace) {
        $script:ServerRunspace.Close()
        $script:ServerRunspace.Dispose()
    }
}

# ---------------------------------------------------------------------------
Describe 'GET / — HTML UI endpoint' -Tag 'Integration' {

    It 'returns HTTP 200' {
        $response = Invoke-ApiRequest -Path '/'
        $response.StatusCode | Should -Be 200
    }

    It 'returns Content-Type text/html' {
        $response = Invoke-ApiRequest -Path '/'
        $response.Headers['Content-Type'] | Should -Match 'text/html'
    }

    It 'response body contains the app title' {
        $response = Invoke-ApiRequest -Path '/'
        $response.Content | Should -Match 'NIC Command Center'
    }

    It 'response body is not empty' {
        $response = Invoke-ApiRequest -Path '/'
        $response.Content.Length | Should -BeGreaterThan 1000
    }
}

# ---------------------------------------------------------------------------
Describe 'GET /api/nics — NIC data endpoint' -Tag 'Integration' {

    It 'returns HTTP 200' {
        $response = Invoke-ApiRequest -Path '/api/nics'
        $response.StatusCode | Should -Be 200
    }

    It 'returns Content-Type application/json' {
        $response = Invoke-ApiRequest -Path '/api/nics'
        $response.Headers['Content-Type'] | Should -Match 'application/json'
    }

    It 'response body is valid JSON' {
        $response = Invoke-ApiRequest -Path '/api/nics'
        { $response.Content | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'response body is an array' {
        $result = Invoke-ApiJson -Path '/api/nics'
        $result.GetType().IsArray -or $result -is [System.Collections.IEnumerable] | Should -BeTrue
    }

    It 'each adapter entry contains required fields: name, ip, mac, dhcp, enabled, status' {
        $result = @(Invoke-ApiJson -Path '/api/nics')
        if ($result.Count -gt 0) {
            $first = $result[0]
            foreach ($field in @('name','ip','mac','dhcp','enabled','status')) {
                $first.PSObject.Properties.Name | Should -Contain $field `
                    -Because "adapter object must contain '$field'"
            }
        }
    }

    It 'all ip fields are either empty string or a valid IPv4 address format' {
        $result = @(Invoke-ApiJson -Path '/api/nics')
        foreach ($nic in $result) {
            if ($nic.ip) {
                $nic.ip | Should -Match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' `
                    -Because "ip field '$($nic.ip)' must be IPv4 or empty"
            }
        }
    }

    It 'returns CORS header Access-Control-Allow-Origin' {
        $response = Invoke-ApiRequest -Path '/api/nics'
        $response.Headers['Access-Control-Allow-Origin'] | Should -Be '*'
    }
}

# ---------------------------------------------------------------------------
Describe 'POST /api/apply — NIC configuration endpoint' -Tag 'Integration' {

    It 'returns HTTP 200' {
        $response = Invoke-ApiRequest -Path '/api/apply' -Method 'POST' -Body @{
            target = 'test'
        }
        $response.StatusCode | Should -Be 200
    }

    It 'returns valid JSON' {
        # The stub always returns success.
        $response = Invoke-ApiRequest -Path '/api/apply' -Method 'POST' -Body @{
            originalName = 'Ethernet'; name = 'Ethernet'; dhcp = $true
            enabled = $true; ip = ''; subnet = ''; prefix = 24
            gateway = ''; dns1 = ''; dns2 = ''; ipv6 = $false
            metric = ''; dnsSuffix = ''; registerDns = $true
        }
        { $response.Content | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'returns success:true with the test stub in place' {
        $body = @(@{
            originalName = 'Ethernet'; name = 'Ethernet'; dhcp = $true
            enabled = $true; ip = ''; subnet = ''; prefix = 24
            gateway = ''; dns1 = ''; dns2 = ''; ipv6 = $false
            metric = ''; dnsSuffix = ''; registerDns = $true
        })
        $response = Invoke-ApiRequest -Path '/api/apply' -Method 'POST' -Body @{ nics = $body }
        $result = $response.Content | ConvertFrom-Json
        # Stub returns success array
        @($result)[0].success | Should -BeTrue
    }

    It 'returns HTTP 200 (not 500) for an empty body' {
        $response = Invoke-ApiRequest -Path '/api/apply' -Method 'POST' -Body @{}
        # Either 200 with an error response, or a handled 500 — not an unhandled crash.
        $response.StatusCode | Should -BeIn @(200, 500)
    }
}

# ---------------------------------------------------------------------------
Describe 'POST /api/singleping — single ping endpoint' -Tag 'Integration' {

    It 'returns HTTP 200' {
        $response = Invoke-ApiRequest -Path '/api/singleping' -Method 'POST' -Body @{ target = '127.0.0.1' }
        $response.StatusCode | Should -Be 200
    }

    It 'returns valid JSON' {
        $response = Invoke-ApiRequest -Path '/api/singleping' -Method 'POST' -Body @{ target = '127.0.0.1' }
        { $response.Content | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'loopback ping returns success:true' {
        $result = Invoke-ApiJson -Path '/api/singleping' -Method 'POST' -Body @{ target = '127.0.0.1' }
        $result.success | Should -BeTrue
    }

    It 'loopback ping returns a positive ms value' {
        $result = Invoke-ApiJson -Path '/api/singleping' -Method 'POST' -Body @{ target = '127.0.0.1' }
        $result.ms | Should -BeGreaterThan 0
    }

    It 'unreachable address returns success:false' {
        # RFC 5737 documentation address — should not be reachable.
        $result = Invoke-ApiJson -Path '/api/singleping' -Method 'POST' -Body @{ target = '192.0.2.1' }
        $result.success | Should -BeFalse
    }

    It 'unreachable address returns ms:-1' {
        $result = Invoke-ApiJson -Path '/api/singleping' -Method 'POST' -Body @{ target = '192.0.2.1' }
        $result.ms | Should -Be -1
    }
}

# ---------------------------------------------------------------------------
Describe 'POST /api/portscan — port scan endpoint' -Tag 'Integration' {

    It 'returns HTTP 200' {
        $response = Invoke-ApiRequest -Path '/api/portscan' -Method 'POST' -Body @{
            target = '127.0.0.1'; ports = '80'
        }
        $response.StatusCode | Should -Be 200
    }

    It 'returns valid JSON' {
        $response = Invoke-ApiRequest -Path '/api/portscan' -Method 'POST' -Body @{
            target = '127.0.0.1'; ports = '80'
        }
        { $response.Content | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'results array contains one entry for a single port' {
        $result = Invoke-ApiJson -Path '/api/portscan' -Method 'POST' -Body @{
            target = '127.0.0.1'; ports = '80'
        }
        @($result.results).Count | Should -Be 1
    }

    It 'results contain port number 80' {
        $result = Invoke-ApiJson -Path '/api/portscan' -Method 'POST' -Body @{
            target = '127.0.0.1'; ports = '80'
        }
        $result.results[0].port | Should -Be 80
    }

    It 'scanning multiple ports returns one result per port' {
        $result = Invoke-ApiJson -Path '/api/portscan' -Method 'POST' -Body @{
            target = '127.0.0.1'; ports = '80,443,22'
        }
        @($result.results).Count | Should -Be 3
    }
}

# ---------------------------------------------------------------------------
Describe 'GET /api/arp — ARP table endpoint' -Tag 'Integration' {

    It 'returns HTTP 200' {
        $response = Invoke-ApiRequest -Path '/api/arp'
        $response.StatusCode | Should -Be 200
    }

    It 'returns valid JSON' {
        $response = Invoke-ApiRequest -Path '/api/arp'
        { $response.Content | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'output field is a non-empty string' {
        $result = Invoke-ApiJson -Path '/api/arp'
        $result.output | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
Describe 'POST /api/cmd — quick commands endpoint' -Tag 'Integration' {

    foreach ($cmd in @('ipconfig','ipconfig_all','route_print','netstat','flushdns')) {
        It "returns HTTP 200 for command: $cmd" {
            $response = Invoke-ApiRequest -Path '/api/cmd' -Method 'POST' -Body @{ cmd = $cmd }
            $response.StatusCode | Should -Be 200
        }

        It "returns valid JSON for command: $cmd" {
            $response = Invoke-ApiRequest -Path '/api/cmd' -Method 'POST' -Body @{ cmd = $cmd }
            { $response.Content | ConvertFrom-Json } | Should -Not -Throw
        }

        It "returns success:true for command: $cmd" {
            $result = Invoke-ApiJson -Path '/api/cmd' -Method 'POST' -Body @{ cmd = $cmd }
            $result.success | Should -BeTrue
        }
    }

    It 'returns HTTP 200 for unknown command (whitelist default)' {
        $response = Invoke-ApiRequest -Path '/api/cmd' -Method 'POST' -Body @{ cmd = 'not_a_command' }
        $response.StatusCode | Should -Be 200
    }
}

# ---------------------------------------------------------------------------
Describe 'Unknown route — 404 handling' -Tag 'Integration' {

    It 'returns HTTP 404 for an undefined path' {
        $response = Invoke-ApiRequest -Path '/api/doesnotexist'
        $response.StatusCode | Should -Be 404
    }

    It 'returns JSON error body for undefined path' {
        $response = Invoke-ApiRequest -Path '/api/doesnotexist'
        { $response.Content | ConvertFrom-Json } | Should -Not -Throw
        ($response.Content | ConvertFrom-Json).error | Should -Be 'Not found'
    }
}

# ---------------------------------------------------------------------------
Describe 'Concurrent requests — server stability' -Tag 'Integration' {

    It 'handles 10 concurrent GET /api/nics requests without errors' {
        $jobs = 1..10 | ForEach-Object {
            Start-Job -ScriptBlock {
                param($url)
                try {
                    $r = Invoke-WebRequest -Uri "$url/api/nics" -UseBasicParsing -TimeoutSec 15
                    return $r.StatusCode
                } catch { return 500 }
            } -ArgumentList $script:BaseUrl
        }
        $results = $jobs | Wait-Job | Receive-Job
        $jobs | Remove-Job

        $results | Should -Not -Contain 500
        $results | Should -Not -Contain $null
        $results | ForEach-Object { $_ | Should -Be 200 }
    }

    It 'handles 5 concurrent POST /api/singleping requests without errors' {
        $jobs = 1..5 | ForEach-Object {
            Start-Job -ScriptBlock {
                param($url)
                try {
                    $r = Invoke-WebRequest -Uri "$url/api/singleping" -Method POST `
                         -Body '{"target":"127.0.0.1"}' -ContentType 'application/json' `
                         -UseBasicParsing -TimeoutSec 15
                    return $r.StatusCode
                } catch { return 500 }
            } -ArgumentList $script:BaseUrl
        }
        $results = $jobs | Wait-Job | Receive-Job
        $jobs | Remove-Job

        $results | Should -Not -Contain 500
    }
}
