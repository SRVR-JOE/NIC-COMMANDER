#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for Apply-NicConfig — the NIC configuration application function.

.DESCRIPTION
    Mocks all mutating Net cmdlets so the function can be tested without
    admin rights or a real adapter.  Validates that the correct cmdlets are
    called with the correct parameters for each configuration scenario.

.NOTES
    Run with:
        Invoke-Pester -Path .\Tests\Unit\Apply-NicConfig.Tests.ps1 -Output Detailed
#>

BeforeAll {
    . "$PSScriptRoot\..\..\NIC-CommandCenter.ps1" -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Build-StaticPayload {
    param(
        [string]$OriginalName = 'Ethernet',
        [string]$Name        = 'Ethernet',
        [string]$IP          = '192.168.1.10',
        [string]$Subnet      = '255.255.255.0',
        [int]$Prefix         = 24,
        [string]$Gateway     = '192.168.1.1',
        [string]$Dns1        = '8.8.8.8',
        [string]$Dns2        = '8.8.4.4',
        [bool]$Dhcp          = $false,
        [bool]$Enabled       = $true,
        [bool]$IPv6          = $false
    )
    @(@{
        originalName = $OriginalName; name = $Name; ip = $IP; subnet = $Subnet
        prefix = $Prefix; gateway = $Gateway; dns1 = $Dns1; dns2 = $Dns2
        dhcp = $Dhcp; enabled = $Enabled; ipv6 = $IPv6
        metric = ''; dnsSuffix = $null; registerDns = $true
    }) | ConvertTo-Json -Depth 5
}

function Build-DhcpPayload {
    param([string]$Name = 'Ethernet', [bool]$Enabled = $true)
    @(@{
        originalName = $Name; name = $Name; dhcp = $true; enabled = $Enabled
        ip = ''; subnet = ''; prefix = 24; gateway = ''; dns1 = ''; dns2 = ''
        ipv6 = $false; metric = ''; dnsSuffix = $null; registerDns = $true
    }) | ConvertTo-Json -Depth 5
}

# ---------------------------------------------------------------------------
Describe 'Apply-NicConfig — static IP assignment' {

    BeforeEach {
        Mock Get-NetAdapter {
            [PSCustomObject]@{ Status = 'Up'; Name = 'Ethernet' }
        }
        Mock Rename-NetAdapter {}
        Mock Enable-NetAdapter {}
        Mock Disable-NetAdapter {}
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

    It 'returns valid JSON' {
        $result = Apply-NicConfig -JsonBody (Build-StaticPayload)
        { $result | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'reports success for a valid static configuration' {
        $result = (Apply-NicConfig -JsonBody (Build-StaticPayload))[0] | ConvertFrom-Json
        ($result | Where-Object { $_.name -eq 'Ethernet' }).success | Should -BeTrue
    }

    It 'calls New-NetIPAddress with the provided IP' {
        Apply-NicConfig -JsonBody (Build-StaticPayload -IP '10.0.0.50' -Prefix 24 -Gateway '10.0.0.1')
        Should -Invoke New-NetIPAddress -Times 1 -ParameterFilter {
            $IPAddress -eq '10.0.0.50' -and $PrefixLength -eq 24 -and $DefaultGateway -eq '10.0.0.1'
        }
    }

    It 'calls Set-DnsClientServerAddress with both DNS servers' {
        Apply-NicConfig -JsonBody (Build-StaticPayload -Dns1 '1.1.1.1' -Dns2 '1.0.0.1')
        Should -Invoke Set-DnsClientServerAddress -Times 1 -ParameterFilter {
            $ServerAddresses -contains '1.1.1.1' -and $ServerAddresses -contains '1.0.0.1'
        }
    }

    It 'calls Remove-NetIPAddress before assigning a new IP (clean-up step)' {
        Apply-NicConfig -JsonBody (Build-StaticPayload)
        Should -Invoke Remove-NetIPAddress -Times 1
    }

    It 'calls Remove-NetRoute before assigning a new IP (clean-up step)' {
        Apply-NicConfig -JsonBody (Build-StaticPayload)
        Should -Invoke Remove-NetRoute -Times 1
    }

    It 'disables IPv6 binding when ipv6 is false' {
        Apply-NicConfig -JsonBody (Build-StaticPayload -IPv6 $false)
        Should -Invoke Disable-NetAdapterBinding -Times 1 -ParameterFilter {
            $ComponentID -eq 'ms_tcpip6'
        }
    }

    It 'enables IPv6 binding when ipv6 is true' {
        Apply-NicConfig -JsonBody (Build-StaticPayload -IPv6 $true)
        Should -Invoke Enable-NetAdapterBinding -Times 1 -ParameterFilter {
            $ComponentID -eq 'ms_tcpip6'
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Apply-NicConfig — DHCP mode' {

    BeforeEach {
        Mock Get-NetAdapter { [PSCustomObject]@{ Status = 'Up'; Name = 'Ethernet' } }
        Mock Rename-NetAdapter {}
        Mock Set-NetIPInterface {}
        Mock Set-DnsClientServerAddress {}
        Mock Remove-NetIPAddress {}
        Mock Remove-NetRoute {}
        Mock New-NetIPAddress {}
        Mock Set-DnsClient {}
        Mock Enable-NetAdapterBinding {}
        Mock Disable-NetAdapterBinding {}
        Mock Start-Sleep {}
    }

    It 'calls Set-NetIPInterface -Dhcp Enabled' {
        Apply-NicConfig -JsonBody (Build-DhcpPayload)
        Should -Invoke Set-NetIPInterface -Times 1 -ParameterFilter {
            $Dhcp -eq 'Enabled'
        }
    }

    It 'calls Set-DnsClientServerAddress -ResetServerAddresses' {
        Apply-NicConfig -JsonBody (Build-DhcpPayload)
        Should -Invoke Set-DnsClientServerAddress -Times 1 -ParameterFilter {
            $ResetServerAddresses -eq $true
        }
    }

    It 'does NOT call New-NetIPAddress for DHCP mode' {
        Apply-NicConfig -JsonBody (Build-DhcpPayload)
        Should -Invoke New-NetIPAddress -Times 0
    }

    It 'reports success' {
        $result = (Apply-NicConfig -JsonBody (Build-DhcpPayload)) | ConvertFrom-Json
        ($result | Where-Object { $_.name -eq 'Ethernet' }).success | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
Describe 'Apply-NicConfig — adapter disable/enable' {

    BeforeEach {
        Mock Get-NetAdapter { [PSCustomObject]@{ Status = 'Up'; Name = 'Ethernet' } }
        Mock Rename-NetAdapter {}
        Mock Enable-NetAdapter {}
        Mock Disable-NetAdapter {}
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

    It 'calls Disable-NetAdapter when enabled is false and exits loop' {
        $payload = @(@{
            originalName = 'Ethernet'; name = 'Ethernet'; enabled = $false; dhcp = $true
            ip = ''; subnet = ''; prefix = 24; gateway = ''; dns1 = ''; dns2 = ''
            ipv6 = $false; metric = ''; dnsSuffix = $null; registerDns = $true
        }) | ConvertTo-Json -Depth 5

        Apply-NicConfig -JsonBody $payload
        Should -Invoke Disable-NetAdapter -Times 1
    }

    It 'calls Enable-NetAdapter when adapter is currently Disabled but payload sets enabled true' {
        Mock Get-NetAdapter { [PSCustomObject]@{ Status = 'Disabled'; Name = 'Ethernet' } }
        Apply-NicConfig -JsonBody (Build-DhcpPayload -Enabled $true)
        Should -Invoke Enable-NetAdapter -Times 1
    }
}

# ---------------------------------------------------------------------------
Describe 'Apply-NicConfig — adapter rename' {

    BeforeEach {
        Mock Get-NetAdapter { [PSCustomObject]@{ Status = 'Up'; Name = 'OldName' } }
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

    It 'calls Rename-NetAdapter when name differs from originalName' {
        $payload = @(@{
            originalName = 'OldName'; name = 'NewName'; dhcp = $true; enabled = $true
            ip = ''; subnet = ''; prefix = 24; gateway = ''; dns1 = ''; dns2 = ''
            ipv6 = $false; metric = ''; dnsSuffix = $null; registerDns = $true
        }) | ConvertTo-Json -Depth 5

        Apply-NicConfig -JsonBody $payload
        Should -Invoke Rename-NetAdapter -Times 1 -ParameterFilter {
            $Name -eq 'OldName' -and $NewName -eq 'NewName'
        }
    }

    It 'does NOT call Rename-NetAdapter when name is unchanged' {
        Apply-NicConfig -JsonBody (Build-DhcpPayload -Name 'Ethernet')
        Should -Invoke Rename-NetAdapter -Times 0
    }
}

# ---------------------------------------------------------------------------
Describe 'Apply-NicConfig — error handling' {

    BeforeEach {
        Mock Get-NetAdapter { [PSCustomObject]@{ Status = 'Up'; Name = 'Ethernet' } }
        Mock Rename-NetAdapter {}
        Mock Set-NetIPInterface {}
        Mock Set-DnsClientServerAddress {}
        Mock Remove-NetIPAddress {}
        Mock Remove-NetRoute {}
        Mock Set-DnsClient {}
        Mock Enable-NetAdapterBinding {}
        Mock Disable-NetAdapterBinding {}
        Mock Start-Sleep {}
    }

    It 'returns success:false with an error message when New-NetIPAddress throws' {
        Mock New-NetIPAddress { throw 'Simulated cmdlet failure' }

        $result = (Apply-NicConfig -JsonBody (Build-StaticPayload)) | ConvertFrom-Json
        $entry = $result | Where-Object { $_.name -eq 'Ethernet' }
        $entry.success | Should -BeFalse
        $entry.message | Should -Match 'Simulated cmdlet failure'
    }

    It 'processes subsequent NICs after one failure' {
        # First NIC will throw; second should still report success.
        Mock New-NetIPAddress {
            if ($InterfaceAlias -eq 'Ethernet') { throw 'Fail on first NIC' }
            [PSCustomObject]@{}
        }
        Mock Get-NetAdapter {
            [PSCustomObject]@{ Status = 'Up'; Name = 'Ethernet' }
        }

        $twoNicPayload = @(
            @{ originalName='Ethernet';  name='Ethernet';  dhcp=$false; enabled=$true; ip='10.0.0.1';  subnet='255.255.255.0'; prefix=24; gateway=''; dns1=''; dns2=''; ipv6=$false; metric=''; dnsSuffix=$null; registerDns=$true },
            @{ originalName='Ethernet2'; name='Ethernet2'; dhcp=$true;  enabled=$true; ip='';         subnet='';             prefix=24; gateway=''; dns1=''; dns2=''; ipv6=$false; metric=''; dnsSuffix=$null; registerDns=$true }
        ) | ConvertTo-Json -Depth 5

        $result = Apply-NicConfig -JsonBody $twoNicPayload | ConvertFrom-Json
        @($result).Count | Should -Be 2
    }

    It 'returns valid JSON even when all NICs fail' {
        Mock New-NetIPAddress { throw 'Total failure' }
        $result = Apply-NicConfig -JsonBody (Build-StaticPayload)
        { $result | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'handles malformed JSON body without crashing the process' {
        # ConvertFrom-Json will throw; function should propagate or catch.
        # We just verify it does not hang or corrupt the host process.
        { Apply-NicConfig -JsonBody 'THIS IS NOT JSON' } | Should -Throw
    }
}

# ---------------------------------------------------------------------------
Describe 'Apply-NicConfig — interface metric' {

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

    It 'sets AutomaticMetric Enabled when metric field is empty' {
        Apply-NicConfig -JsonBody (Build-StaticPayload)
        Should -Invoke Set-NetIPInterface -AtLeast 1 -ParameterFilter {
            $AutomaticMetric -eq 'Enabled'
        }
    }

    It 'sets explicit metric and disables AutomaticMetric when metric is provided' {
        $payload = @(@{
            originalName = 'Ethernet'; name = 'Ethernet'; dhcp = $false; enabled = $true
            ip = '192.168.1.10'; subnet = '255.255.255.0'; prefix = 24; gateway = '192.168.1.1'
            dns1 = ''; dns2 = ''; ipv6 = $false; metric = '10'
            dnsSuffix = $null; registerDns = $true
        }) | ConvertTo-Json -Depth 5

        Apply-NicConfig -JsonBody $payload
        Should -Invoke Set-NetIPInterface -AtLeast 1 -ParameterFilter {
            $InterfaceMetric -eq 10 -and $AutomaticMetric -eq 'Disabled'
        }
    }
}
