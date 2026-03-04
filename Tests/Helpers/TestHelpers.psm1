<#
.SYNOPSIS
    Shared test helpers for NIC-CommandCenter tests.

.DESCRIPTION
    This module provides factory functions, assertion helpers, and common
    mock setup routines used across the unit, integration, and security test
    suites.  Import this module in your BeforeAll blocks:

        Import-Module "$PSScriptRoot\..\Helpers\TestHelpers.psm1" -Force

.NOTES
    Compatible with Pester 5.x on PowerShell 5.1 and 7.x.
#>


# ===========================================================================
# MOCK ADAPTER FACTORIES
# ===========================================================================

<#
.SYNOPSIS
    Creates a minimal fake Get-NetAdapter object.
#>
function New-MockAdapter {
    [CmdletBinding()]
    param(
        [string]$Name             = 'Test Ethernet',
        [string]$Description      = 'Test Network Adapter',
        [string]$MacAddress       = 'AA:BB:CC:DD:EE:FF',
        [ValidateSet('Up','Disconnected','Disabled','NotPresent')]
        [string]$Status           = 'Up',
        [int]$InterfaceIndex      = 3,
        [string]$LinkSpeed        = '1 Gbps'
    )
    [PSCustomObject]@{
        Name                 = $Name
        InterfaceDescription = $Description
        MacAddress           = $MacAddress
        Status               = $Status
        InterfaceIndex       = $InterfaceIndex
        LinkSpeed            = $LinkSpeed
    }
}

<#
.SYNOPSIS
    Creates a fake Get-NetIPAddress result.
#>
function New-MockIPAddress {
    [CmdletBinding()]
    param(
        [string]$IPAddress    = '192.168.1.10',
        [int]$PrefixLength    = 24,
        [string]$AddressFamily = 'IPv4',
        [ValidateSet('Manual','Dhcp','RouterAdvertisement','WellKnown','Other')]
        [string]$PrefixOrigin = 'Manual'
    )
    [PSCustomObject]@{
        IPAddress     = $IPAddress
        PrefixLength  = $PrefixLength
        AddressFamily = $AddressFamily
        PrefixOrigin  = $PrefixOrigin
    }
}

<#
.SYNOPSIS
    Creates a fake Get-NetIPInterface result.
#>
function New-MockIPInterface {
    [CmdletBinding()]
    param(
        [ValidateSet('Enabled','Disabled')]
        [string]$Dhcp           = 'Disabled',
        [int]$NlMtu             = 1500,
        [bool]$AutomaticMetric  = $true,
        [int]$InterfaceMetric   = 0
    )
    [PSCustomObject]@{
        Dhcp            = $Dhcp
        NlMtu           = $NlMtu
        AutomaticMetric = $AutomaticMetric
        InterfaceMetric = $InterfaceMetric
    }
}

<#
.SYNOPSIS
    Registers all cmdlet mocks needed by Get-NicDataJson in a single call.
    Call inside a Pester Context/Describe block after BeforeEach/BeforeAll.
#>
function Set-NicDataMocks {
    [CmdletBinding()]
    param(
        [PSCustomObject[]]$Adapters    = @(New-MockAdapter),
        [string]$IPv4Address           = '192.168.1.10',
        [int]$PrefixLength             = 24,
        [string]$Gateway               = '192.168.1.1',
        [string[]]$DnsServers          = @('8.8.8.8','8.8.4.4'),
        [string]$DnsSuffix             = '',
        [string]$DhcpState             = 'Disabled',
        [bool]$IPv6Enabled             = $false
    )
    Mock Get-NetAdapter          { $Adapters }
    Mock Get-NetIPConfiguration  { [PSCustomObject]@{ IPv4DefaultGateway = if ($Gateway) { [PSCustomObject]@{ NextHop = $Gateway } } else { $null } } }
    Mock Get-NetIPAddress {
        param($AddressFamily)
        if ($AddressFamily -eq 'IPv4') { New-MockIPAddress -IPAddress $IPv4Address -PrefixLength $PrefixLength }
        else { $null }
    }
    Mock Get-NetIPInterface      { New-MockIPInterface -Dhcp $DhcpState }
    Mock Get-DnsClientServerAddress { [PSCustomObject]@{ ServerAddresses = $DnsServers } }
    Mock Get-DnsClient           { [PSCustomObject]@{ ConnectionSpecificSuffix = $DnsSuffix; RegisterThisConnectionsAddress = $true } }
    Mock Get-NetAdapterAdvancedProperty { @() }
    Mock Get-NetAdapterBinding   { [PSCustomObject]@{ Enabled = $IPv6Enabled } }
}

<#
.SYNOPSIS
    Registers all mutating cmdlet mocks needed by Apply-NicConfig.
    All mocks are no-ops by default.
#>
function Set-ApplyMocks {
    [CmdletBinding()]
    param(
        [string]$AdapterStatus = 'Up',
        [string]$AdapterName   = 'Ethernet',
        [switch]$FailOnApply   # Causes New-NetIPAddress to throw
    )
    Mock Get-NetAdapter { [PSCustomObject]@{ Status = $AdapterStatus; Name = $AdapterName } }
    Mock Rename-NetAdapter {}
    Mock Enable-NetAdapter {}
    Mock Disable-NetAdapter {}
    Mock Set-NetIPInterface {}
    Mock Set-DnsClientServerAddress {}
    Mock Remove-NetIPAddress {}
    Mock Remove-NetRoute {}
    Mock Set-DnsClient {}
    Mock Enable-NetAdapterBinding {}
    Mock Disable-NetAdapterBinding {}
    Mock Start-Sleep {}
    if ($FailOnApply) {
        Mock New-NetIPAddress { throw 'Simulated apply failure' }
    } else {
        Mock New-NetIPAddress { [PSCustomObject]@{} }
    }
}


# ===========================================================================
# JSON PAYLOAD BUILDERS
# ===========================================================================

<#
.SYNOPSIS
    Builds a JSON payload for a single static-IP NIC configuration.
#>
function Build-StaticNicPayload {
    [CmdletBinding()]
    param(
        [string]$OriginalName = 'Ethernet',
        [string]$Name         = 'Ethernet',
        [string]$IP           = '192.168.1.10',
        [string]$Subnet       = '255.255.255.0',
        [int]$Prefix          = 24,
        [string]$Gateway      = '192.168.1.1',
        [string]$Dns1         = '8.8.8.8',
        [string]$Dns2         = '8.8.4.4',
        [bool]$IPv6           = $false,
        [string]$Metric       = '',
        [bool]$Enabled        = $true
    )
    @(@{
        originalName = $OriginalName; name = $Name; dhcp = $false; enabled = $Enabled
        ip = $IP; subnet = $Subnet; prefix = $Prefix; gateway = $Gateway
        dns1 = $Dns1; dns2 = $Dns2; ipv6 = $IPv6; metric = $Metric
        dnsSuffix = $null; registerDns = $true
    }) | ConvertTo-Json -Depth 5
}

<#
.SYNOPSIS
    Builds a JSON payload for a single DHCP NIC configuration.
#>
function Build-DhcpNicPayload {
    [CmdletBinding()]
    param(
        [string]$Name    = 'Ethernet',
        [bool]$Enabled   = $true,
        [bool]$IPv6      = $false
    )
    @(@{
        originalName = $Name; name = $Name; dhcp = $true; enabled = $Enabled
        ip = ''; subnet = ''; prefix = 24; gateway = ''
        dns1 = ''; dns2 = ''; ipv6 = $IPv6; metric = ''
        dnsSuffix = $null; registerDns = $true
    }) | ConvertTo-Json -Depth 5
}


# ===========================================================================
# ASSERTION HELPERS
# ===========================================================================

<#
.SYNOPSIS
    Asserts that a string is valid JSON.
#>
function Assert-ValidJson {
    param([string]$Json, [string]$Because = 'response should be valid JSON')
    { $Json | ConvertFrom-Json } | Should -Not -Throw -Because $Because
}

<#
.SYNOPSIS
    Asserts that a parsed NIC object has all expected top-level fields.
#>
function Assert-NicObjectShape {
    param([PSCustomObject]$Nic)
    $requiredFields = @(
        'name','hw','mac','status','enabled','ip','subnet','prefix',
        'gateway','dns1','dns2','dhcp','mtu','ipv6'
    )
    foreach ($field in $requiredFields) {
        $Nic.PSObject.Properties.Name | Should -Contain $field `
            -Because "NIC object must contain field '$field'"
    }
}

<#
.SYNOPSIS
    Asserts that a string matches IPv4 dotted-decimal format or is empty.
#>
function Assert-IPv4OrEmpty {
    param([string]$Value, [string]$FieldName = 'IP field')
    if ($Value -and $Value -ne '') {
        $Value | Should -Match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' `
            -Because "$FieldName must be IPv4 dotted-decimal or empty string"
    }
}

<#
.SYNOPSIS
    Known-good injection payloads for security testing.
#>
function Get-InjectionPayloads {
    return @(
        '8.8.8.8 & whoami',
        '8.8.8.8; whoami',
        '8.8.8.8 | whoami',
        '8.8.8.8 && dir C:\',
        '$(whoami)',
        '`whoami`',
        "8.8.8.8`nwhoami",
        '" & whoami',
        "'; DROP TABLE adapters; --"
    )
}

<#
.SYNOPSIS
    Known XSS payloads for output encoding tests.
#>
function Get-XssPayloads {
    return @(
        '<script>alert(1)</script>',
        '<img src=x onerror=alert(1)>',
        '"><script>alert(1)</script>',
        "javascript:alert('xss')",
        '<svg onload=alert(1)>'
    )
}


# ===========================================================================
# SUBNET MASK UTILITIES (for test assertions)
# ===========================================================================

<#
.SYNOPSIS
    Converts a CIDR prefix length to dotted-decimal subnet mask.
    Used to verify the backend's mask derivation logic.
#>
function Convert-PrefixToMask {
    param([int]$PrefixLength)
    $bits = ('1' * $PrefixLength).PadRight(32, '0')
    return "{0}.{1}.{2}.{3}" -f `
        [Convert]::ToInt32($bits.Substring(0, 8), 2),
        [Convert]::ToInt32($bits.Substring(8, 8), 2),
        [Convert]::ToInt32($bits.Substring(16, 8), 2),
        [Convert]::ToInt32($bits.Substring(24, 8), 2)
}

Export-ModuleMember -Function @(
    'New-MockAdapter', 'New-MockIPAddress', 'New-MockIPInterface',
    'Set-NicDataMocks', 'Set-ApplyMocks',
    'Build-StaticNicPayload', 'Build-DhcpNicPayload',
    'Assert-ValidJson', 'Assert-NicObjectShape', 'Assert-IPv4OrEmpty',
    'Get-InjectionPayloads', 'Get-XssPayloads',
    'Convert-PrefixToMask'
)
