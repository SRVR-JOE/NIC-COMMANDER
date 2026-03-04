#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for Get-NicDataJson — the NIC data collection function.

.DESCRIPTION
    These tests mock all five underlying Net cmdlets so the function can be
    exercised without real network adapters or admin rights.  Every test
    follows Arrange-Act-Assert and is fully independent.

.NOTES
    Run with:
        Invoke-Pester -Path .\Tests\Unit\Get-NicDataJson.Tests.ps1 -Output Detailed
    Requires Pester 5.x.
#>

BeforeAll {
    # Source only the functions, not the HttpListener startup block.
    # The PS1 file runs the listener at the top level, so we dot-source
    # a sanitised version.  For now we use -ErrorAction SilentlyContinue
    # to tolerate the #Requires -RunAsAdministrator pragma.
    . "$PSScriptRoot\..\..\NIC-CommandCenter.ps1" -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Helper: build a minimal fake adapter object matching what Get-NetAdapter
#         returns.  Only the fields consumed by Get-NicDataJson are populated.
# ---------------------------------------------------------------------------
function New-FakeAdapter {
    param(
        [string]$Name = 'Test Adapter',
        [string]$Description = 'Fake NIC',
        [string]$MacAddress = 'AA:BB:CC:DD:EE:FF',
        [string]$Status = 'Up',
        [int]$InterfaceIndex = 3,
        [string]$LinkSpeed = '1 Gbps'
    )
    [PSCustomObject]@{
        Name               = $Name
        InterfaceDescription = $Description
        MacAddress         = $MacAddress
        Status             = $Status
        InterfaceIndex     = $InterfaceIndex
        LinkSpeed          = $LinkSpeed
    }
}

function New-FakeIPAddress {
    param(
        [string]$IPAddress = '192.168.1.10',
        [int]$PrefixLength = 24,
        [string]$AddressFamily = 'IPv4',
        [string]$PrefixOrigin = 'Manual'
    )
    [PSCustomObject]@{
        IPAddress     = $IPAddress
        PrefixLength  = $PrefixLength
        AddressFamily = $AddressFamily
        PrefixOrigin  = $PrefixOrigin
    }
}

function New-FakeIPInterface {
    param([string]$Dhcp = 'Disabled', [int]$NlMtu = 1500, [bool]$AutomaticMetric = $true, [int]$InterfaceMetric = 0)
    [PSCustomObject]@{
        Dhcp            = $Dhcp
        NlMtu           = $NlMtu
        AutomaticMetric = $AutomaticMetric
        InterfaceMetric = $InterfaceMetric
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-NicDataJson — JSON structure and field mapping' {

    Context 'Single static adapter with full configuration' {

        BeforeEach {
            # Wire up all underlying cmdlets to return deterministic fakes.
            Mock Get-NetAdapter {
                @(New-FakeAdapter -Name 'Primary LAN' -InterfaceIndex 3)
            }
            Mock Get-NetIPConfiguration {
                [PSCustomObject]@{ IPv4DefaultGateway = [PSCustomObject]@{ NextHop = '192.168.1.1' } }
            }
            Mock Get-NetIPAddress {
                param($InterfaceAlias, $AddressFamily)
                if ($AddressFamily -eq 'IPv4') { New-FakeIPAddress -IPAddress '192.168.1.10' -PrefixLength 24 }
                else { $null }
            }
            Mock Get-NetIPInterface { New-FakeIPInterface -Dhcp 'Disabled' -NlMtu 1500 }
            Mock Get-DnsClientServerAddress {
                [PSCustomObject]@{ ServerAddresses = @('8.8.8.8', '8.8.4.4') }
            }
            Mock Get-DnsClient {
                [PSCustomObject]@{ ConnectionSpecificSuffix = 'corp.local'; RegisterThisConnectionsAddress = $true }
            }
            Mock Get-NetAdapterAdvancedProperty { @() }
            Mock Get-NetAdapterBinding { [PSCustomObject]@{ Enabled = $false } }
        }

        It 'returns valid JSON' {
            $result = Get-NicDataJson
            { $result | ConvertFrom-Json } | Should -Not -Throw
        }

        It 'contains exactly one entry for one adapter' {
            $result = Get-NicDataJson | ConvertFrom-Json
            $result | Should -HaveCount 1
        }

        It 'maps name field correctly' {
            $result = (Get-NicDataJson | ConvertFrom-Json)[0]
            $result.name | Should -Be 'Primary LAN'
        }

        It 'maps IPv4 address correctly' {
            $result = (Get-NicDataJson | ConvertFrom-Json)[0]
            $result.ip | Should -Be '192.168.1.10'
        }

        It 'derives subnet mask from /24 prefix' {
            $result = (Get-NicDataJson | ConvertFrom-Json)[0]
            $result.subnet | Should -Be '255.255.255.0'
        }

        It 'maps gateway correctly' {
            $result = (Get-NicDataJson | ConvertFrom-Json)[0]
            $result.gateway | Should -Be '192.168.1.1'
        }

        It 'maps primary DNS correctly' {
            $result = (Get-NicDataJson | ConvertFrom-Json)[0]
            $result.dns1 | Should -Be '8.8.8.8'
        }

        It 'maps secondary DNS correctly' {
            $result = (Get-NicDataJson | ConvertFrom-Json)[0]
            $result.dns2 | Should -Be '8.8.4.4'
        }

        It 'reports dhcp as false for a static adapter' {
            $result = (Get-NicDataJson | ConvertFrom-Json)[0]
            $result.dhcp | Should -BeFalse
        }

        It 'reports enabled as true for an Up adapter' {
            $result = (Get-NicDataJson | ConvertFrom-Json)[0]
            $result.enabled | Should -BeTrue
        }

        It 'sets dnsSuffix from DnsClient' {
            $result = (Get-NicDataJson | ConvertFrom-Json)[0]
            $result.dnsSuffix | Should -Be 'corp.local'
        }
    }

    # -----------------------------------------------------------------------
    Context 'DHCP-enabled adapter' {

        BeforeEach {
            Mock Get-NetAdapter { @(New-FakeAdapter -Name 'DHCP NIC' -InterfaceIndex 5) }
            Mock Get-NetIPConfiguration { [PSCustomObject]@{ IPv4DefaultGateway = $null } }
            Mock Get-NetIPAddress {
                param($AddressFamily)
                if ($AddressFamily -eq 'IPv4') { New-FakeIPAddress -IPAddress '192.168.1.47' -PrefixLength 24 }
                else { $null }
            }
            Mock Get-NetIPInterface { New-FakeIPInterface -Dhcp 'Enabled' }
            Mock Get-DnsClientServerAddress { [PSCustomObject]@{ ServerAddresses = @('192.168.1.1') } }
            Mock Get-DnsClient { [PSCustomObject]@{ ConnectionSpecificSuffix = ''; RegisterThisConnectionsAddress = $true } }
            Mock Get-NetAdapterAdvancedProperty { @() }
            Mock Get-NetAdapterBinding { [PSCustomObject]@{ Enabled = $false } }
        }

        It 'reports dhcp as true' {
            $result = (Get-NicDataJson | ConvertFrom-Json)[0]
            $result.dhcp | Should -BeTrue
        }

        It 'sets gateway to empty string when no gateway is present' {
            $result = (Get-NicDataJson | ConvertFrom-Json)[0]
            $result.gateway | Should -Be ''
        }
    }

    # -----------------------------------------------------------------------
    Context 'Disabled adapter' {

        BeforeEach {
            Mock Get-NetAdapter { @(New-FakeAdapter -Name 'Spare' -Status 'Disabled' -InterfaceIndex 7) }
            Mock Get-NetIPConfiguration { [PSCustomObject]@{ IPv4DefaultGateway = $null } }
            Mock Get-NetIPAddress { $null }
            Mock Get-NetIPInterface { New-FakeIPInterface -Dhcp 'Disabled' }
            Mock Get-DnsClientServerAddress { [PSCustomObject]@{ ServerAddresses = @() } }
            Mock Get-DnsClient { [PSCustomObject]@{ ConnectionSpecificSuffix = ''; RegisterThisConnectionsAddress = $true } }
            Mock Get-NetAdapterAdvancedProperty { @() }
            Mock Get-NetAdapterBinding { [PSCustomObject]@{ Enabled = $false } }
        }

        It 'reports enabled as false' {
            $result = (Get-NicDataJson | ConvertFrom-Json)[0]
            $result.enabled | Should -BeFalse
        }

        It 'returns empty ip string when no IP is configured' {
            $result = (Get-NicDataJson | ConvertFrom-Json)[0]
            $result.ip | Should -Be ''
        }

        It 'returns empty dns1 when no DNS servers are present' {
            $result = (Get-NicDataJson | ConvertFrom-Json)[0]
            $result.dns1 | Should -Be ''
        }
    }

    # -----------------------------------------------------------------------
    Context 'No adapters present' {

        BeforeEach {
            Mock Get-NetAdapter { @() }
        }

        It 'returns a valid JSON array' {
            $result = Get-NicDataJson
            { $result | ConvertFrom-Json } | Should -Not -Throw
        }

        It 'returns an empty array (or empty-equivalent)' {
            # ConvertFrom-Json returns $null for "[]" in PS 5.1
            $result = Get-NicDataJson | ConvertFrom-Json
            # Accept null (empty array serialised by ConvertTo-Json -Compress)
            # or an actual empty array.
            ($result -eq $null -or @($result).Count -eq 0) | Should -BeTrue
        }
    }

    # -----------------------------------------------------------------------
    Context 'Multiple adapters' {

        BeforeEach {
            Mock Get-NetAdapter {
                @(
                    (New-FakeAdapter -Name 'Adapter A' -InterfaceIndex 3),
                    (New-FakeAdapter -Name 'Adapter B' -InterfaceIndex 5),
                    (New-FakeAdapter -Name 'Adapter C' -InterfaceIndex 7)
                )
            }
            Mock Get-NetIPConfiguration { [PSCustomObject]@{ IPv4DefaultGateway = $null } }
            Mock Get-NetIPAddress { $null }
            Mock Get-NetIPInterface { New-FakeIPInterface }
            Mock Get-DnsClientServerAddress { [PSCustomObject]@{ ServerAddresses = @() } }
            Mock Get-DnsClient { [PSCustomObject]@{ ConnectionSpecificSuffix = ''; RegisterThisConnectionsAddress = $true } }
            Mock Get-NetAdapterAdvancedProperty { @() }
            Mock Get-NetAdapterBinding { [PSCustomObject]@{ Enabled = $false } }
        }

        It 'returns one entry per adapter' {
            $result = Get-NicDataJson | ConvertFrom-Json
            @($result).Count | Should -Be 3
        }

        It 'preserves adapter names' {
            $result = Get-NicDataJson | ConvertFrom-Json
            $result[0].name | Should -Be 'Adapter A'
            $result[1].name | Should -Be 'Adapter B'
            $result[2].name | Should -Be 'Adapter C'
        }
    }

    # -----------------------------------------------------------------------
    Context 'Subnet mask derivation — boundary prefix lengths' {

        function Test-SubnetDerivation {
            param([int]$PrefixLength, [string]$ExpectedMask)
            Mock Get-NetAdapter { @(New-FakeAdapter -InterfaceIndex 3) }
            Mock Get-NetIPConfiguration { [PSCustomObject]@{ IPv4DefaultGateway = $null } }
            Mock Get-NetIPAddress {
                param($AddressFamily)
                if ($AddressFamily -eq 'IPv4') { New-FakeIPAddress -PrefixLength $PrefixLength }
                else { $null }
            }
            Mock Get-NetIPInterface { New-FakeIPInterface }
            Mock Get-DnsClientServerAddress { [PSCustomObject]@{ ServerAddresses = @() } }
            Mock Get-DnsClient { [PSCustomObject]@{ ConnectionSpecificSuffix = ''; RegisterThisConnectionsAddress = $true } }
            Mock Get-NetAdapterAdvancedProperty { @() }
            Mock Get-NetAdapterBinding { [PSCustomObject]@{ Enabled = $false } }

            $result = (Get-NicDataJson | ConvertFrom-Json)[0]
            $result.subnet | Should -Be $ExpectedMask
        }

        It 'derives 255.0.0.0 from /8'        { Test-SubnetDerivation  8  '255.0.0.0' }
        It 'derives 255.255.0.0 from /16'     { Test-SubnetDerivation 16  '255.255.0.0' }
        It 'derives 255.255.255.0 from /24'   { Test-SubnetDerivation 24  '255.255.255.0' }
        It 'derives 255.255.255.128 from /25' { Test-SubnetDerivation 25  '255.255.255.128' }
        It 'derives 255.255.255.252 from /30' { Test-SubnetDerivation 30  '255.255.255.252' }
        It 'derives 255.255.255.255 from /32' { Test-SubnetDerivation 32  '255.255.255.255' }
    }

    # -----------------------------------------------------------------------
    Context 'Adapter with a very long name (255 characters)' {

        BeforeEach {
            $longName = 'A' * 255
            Mock Get-NetAdapter { @(New-FakeAdapter -Name $longName -InterfaceIndex 3) }
            Mock Get-NetIPConfiguration { [PSCustomObject]@{ IPv4DefaultGateway = $null } }
            Mock Get-NetIPAddress { $null }
            Mock Get-NetIPInterface { New-FakeIPInterface }
            Mock Get-DnsClientServerAddress { [PSCustomObject]@{ ServerAddresses = @() } }
            Mock Get-DnsClient { [PSCustomObject]@{ ConnectionSpecificSuffix = ''; RegisterThisConnectionsAddress = $true } }
            Mock Get-NetAdapterAdvancedProperty { @() }
            Mock Get-NetAdapterBinding { [PSCustomObject]@{ Enabled = $false } }
        }

        It 'returns valid JSON with long adapter name' {
            { Get-NicDataJson | ConvertFrom-Json } | Should -Not -Throw
        }

        It 'preserves the full long name' {
            $result = (Get-NicDataJson | ConvertFrom-Json)[0]
            $result.name.Length | Should -Be 255
        }
    }

    # -----------------------------------------------------------------------
    Context 'Adapter with special characters in name' {

        BeforeEach {
            # Double-quotes and backslashes are the most dangerous for JSON.
            $weirdName = 'NIC "With" Special\Chars'
            Mock Get-NetAdapter { @(New-FakeAdapter -Name $weirdName -InterfaceIndex 3) }
            Mock Get-NetIPConfiguration { [PSCustomObject]@{ IPv4DefaultGateway = $null } }
            Mock Get-NetIPAddress { $null }
            Mock Get-NetIPInterface { New-FakeIPInterface }
            Mock Get-DnsClientServerAddress { [PSCustomObject]@{ ServerAddresses = @() } }
            Mock Get-DnsClient { [PSCustomObject]@{ ConnectionSpecificSuffix = ''; RegisterThisConnectionsAddress = $true } }
            Mock Get-NetAdapterAdvancedProperty { @() }
            Mock Get-NetAdapterBinding { [PSCustomObject]@{ Enabled = $false } }
        }

        It 'returns valid JSON (ConvertTo-Json escapes special chars)' {
            { Get-NicDataJson | ConvertFrom-Json } | Should -Not -Throw
        }
    }

    # -----------------------------------------------------------------------
    Context 'IPv6-only adapter (no IPv4 address)' {

        BeforeEach {
            Mock Get-NetAdapter { @(New-FakeAdapter -InterfaceIndex 3) }
            Mock Get-NetIPConfiguration { [PSCustomObject]@{ IPv4DefaultGateway = $null } }
            Mock Get-NetIPAddress {
                param($AddressFamily)
                if ($AddressFamily -eq 'IPv6') {
                    New-FakeIPAddress -IPAddress 'fe80::1' -AddressFamily 'IPv6' -PrefixLength 64 -PrefixOrigin 'Manual'
                } else { $null }
            }
            Mock Get-NetIPInterface { New-FakeIPInterface }
            Mock Get-DnsClientServerAddress { [PSCustomObject]@{ ServerAddresses = @() } }
            Mock Get-DnsClient { [PSCustomObject]@{ ConnectionSpecificSuffix = ''; RegisterThisConnectionsAddress = $true } }
            Mock Get-NetAdapterAdvancedProperty { @() }
            Mock Get-NetAdapterBinding { [PSCustomObject]@{ Enabled = $true } }
        }

        It 'returns empty ip for missing IPv4' {
            $result = (Get-NicDataJson | ConvertFrom-Json)[0]
            $result.ip | Should -Be ''
        }

        It 'populates ipv6addr' {
            $result = (Get-NicDataJson | ConvertFrom-Json)[0]
            $result.ipv6addr | Should -Be 'fe80::1'
        }
    }

    # -----------------------------------------------------------------------
    Context 'Jumbo frames detection via advanced properties' {

        BeforeEach {
            Mock Get-NetAdapter { @(New-FakeAdapter -InterfaceIndex 3) }
            Mock Get-NetIPConfiguration { [PSCustomObject]@{ IPv4DefaultGateway = $null } }
            Mock Get-NetIPAddress { $null }
            Mock Get-NetIPInterface { New-FakeIPInterface }
            Mock Get-DnsClientServerAddress { [PSCustomObject]@{ ServerAddresses = @() } }
            Mock Get-DnsClient { [PSCustomObject]@{ ConnectionSpecificSuffix = ''; RegisterThisConnectionsAddress = $true } }
            Mock Get-NetAdapterBinding { [PSCustomObject]@{ Enabled = $false } }
            Mock Get-NetAdapterAdvancedProperty {
                @([PSCustomObject]@{ RegistryKeyword = '*JumboPacket'; DisplayValue = '9014' })
            }
        }

        It 'reports jumbo as true when JumboPacket is not Disabled and not 1514' {
            $result = (Get-NicDataJson | ConvertFrom-Json)[0]
            $result.jumbo | Should -BeTrue
        }
    }
}
