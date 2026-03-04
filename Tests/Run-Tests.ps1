<#
.SYNOPSIS
    Test runner script for NIC Command Center.

.DESCRIPTION
    Discovers and runs all Pester tests in the Tests directory.
    Supports running all tests, a specific tier, or a single file.

    Usage:
        # Run all tests (unit + security only; integration excluded by default)
        .\Tests\Run-Tests.ps1

        # Run all tiers including integration (requires admin)
        .\Tests\Run-Tests.ps1 -All

        # Run only unit tests
        .\Tests\Run-Tests.ps1 -Unit

        # Run only security tests
        .\Tests\Run-Tests.ps1 -Security

        # Run integration tests (must be admin)
        .\Tests\Run-Tests.ps1 -Integration

        # Run a specific file
        .\Tests\Run-Tests.ps1 -File .\Tests\Unit\Get-NicDataJson.Tests.ps1

        # Generate HTML report
        .\Tests\Run-Tests.ps1 -Report

.NOTES
    Requires Pester 5.x:  Install-Module Pester -Force -SkipPublisherCheck
    Integration tests require running as Administrator.
#>

[CmdletBinding(DefaultParameterSetName='Default')]
param(
    [Parameter(ParameterSetName='All')]
    [switch]$All,

    [Parameter(ParameterSetName='Unit')]
    [switch]$Unit,

    [Parameter(ParameterSetName='Security')]
    [switch]$Security,

    [Parameter(ParameterSetName='Integration')]
    [switch]$Integration,

    [Parameter(ParameterSetName='File')]
    [string]$File,

    [switch]$Report,
    [switch]$CI  # Fail build on any test failure (exit code 1)
)

# ---------------------------------------------------------------------------
# Ensure Pester 5 is available
# ---------------------------------------------------------------------------
$pesterModule = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pesterModule -or $pesterModule.Version.Major -lt 5) {
    Write-Host "Pester 5.x not found.  Install with:" -ForegroundColor Red
    Write-Host "  Install-Module Pester -Force -SkipPublisherCheck" -ForegroundColor Yellow
    exit 1
}
Import-Module Pester -MinimumVersion 5.0

$TestRoot = $PSScriptRoot

# ---------------------------------------------------------------------------
# Pester configuration
# ---------------------------------------------------------------------------
$config = New-PesterConfiguration

$config.Run.PassThru  = $true
$config.Output.Verbosity = 'Detailed'

# Test paths by tier
switch ($PSCmdlet.ParameterSetName) {
    'Unit'        { $config.Run.Path = "$TestRoot\Unit" }
    'Security'    { $config.Run.Path = "$TestRoot\Security" }
    'Integration' { $config.Run.Path = "$TestRoot\Integration" }
    'File'        { $config.Run.Path = $File }
    'All'         { $config.Run.Path = $TestRoot }
    default {
        # Default: unit + security (safe to run without admin)
        $config.Run.Path = @("$TestRoot\Unit", "$TestRoot\Security")
    }
}

# Exclude integration tests from the default run unless explicitly requested.
if ($PSCmdlet.ParameterSetName -notin @('Integration', 'All')) {
    $config.Filter.ExcludeTag = @('Integration')
}

# Code coverage (unit tests only, when not running integration)
if ($PSCmdlet.ParameterSetName -in @('Unit', 'Default', '')) {
    $config.CodeCoverage.Enabled    = $true
    $config.CodeCoverage.Path       = "$TestRoot\..\NIC-CommandCenter.ps1"
    $config.CodeCoverage.OutputPath = "$TestRoot\coverage.xml"
    $config.CodeCoverage.OutputFormat = 'JaCoCo'
}

# HTML / XML reporting
if ($Report) {
    $config.TestResult.Enabled      = $true
    $config.TestResult.OutputPath   = "$TestRoot\test-results.xml"
    $config.TestResult.OutputFormat = 'NUnitXml'
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
Write-Host "`n  NIC COMMAND CENTER — Test Runner" -ForegroundColor Cyan
Write-Host "  Mode: $($PSCmdlet.ParameterSetName)" -ForegroundColor DarkGray
Write-Host "  Path: $($config.Run.Path.Value -join ', ')`n" -ForegroundColor DarkGray

$result = Invoke-Pester -Configuration $config

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "`n  Results:" -ForegroundColor Cyan
Write-Host "    Passed:  $($result.PassedCount)" -ForegroundColor Green
Write-Host "    Failed:  $($result.FailedCount)"  -ForegroundColor $(if ($result.FailedCount -gt 0) { 'Red' } else { 'Green' })
Write-Host "    Skipped: $($result.SkippedCount)" -ForegroundColor Yellow
Write-Host "    Total:   $($result.TotalCount)`n" -ForegroundColor White

if ($result.CodeCoverage) {
    $pct = [math]::Round(($result.CodeCoverage.CoveredPercent), 1)
    Write-Host "  Code Coverage: $pct%" -ForegroundColor $(if ($pct -ge 70) { 'Green' } elseif ($pct -ge 50) { 'Yellow' } else { 'Red' })
}

if ($CI -and $result.FailedCount -gt 0) {
    exit 1
}
