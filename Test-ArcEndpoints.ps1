<#
.SYNOPSIS
    Tests connectivity from the current machine to the public network endpoints
    required by Azure Arc-enabled servers.

.DESCRIPTION
    Uses Test-NetConnection on TCP port 443 (HTTPS) against the public endpoints
    documented for Azure Arc-enabled servers. Outputs a result object per
    endpoint and a summary at the end.

    Endpoint list is taken from the official Microsoft documentation:
    https://learn.microsoft.com/azure/azure-arc/servers/network-requirements

    Wildcard endpoints in the docs (e.g. *.his.arc.azure.com,
    *.guestconfiguration.azure.com, *.<region>.arcdataservices.com) are
    represented here by a known concrete subdomain that resolves in DNS so the
    TCP test is meaningful.

.PARAMETER Region
    The Azure region short name (e.g. eastus, westeurope) used to build the
    region-specific endpoints. Defaults to 'eastus'.

.PARAMETER IncludeSqlArc
    Include endpoints required only for Azure Arc-enabled SQL Server.

.PARAMETER IncludeEsu
    Include endpoints required only for Extended Security Updates (ESU).

.EXAMPLE
    .\Test-ArcEndpoints.ps1 -Region westeurope

.EXAMPLE
    .\Test-ArcEndpoints.ps1 -Region eastus2 -IncludeSqlArc -IncludeEsu

.NOTES
    Run from the machine you intend to onboard to Azure Arc.
    Requires PowerShell 5.1+ on Windows.

    Note: *.servicebus.windows.net endpoints are region/tenant-specific and not
    tested here. To enumerate them for your region, run:
      GET https://guestnotificationservice.azure.com/urls/allowlist?api-version=2020-01-01&location=<region>
#>

[CmdletBinding()]
param(
    [string]$Region = 'eastus',
    [switch]$IncludeSqlArc,
    [switch]$IncludeEsu
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$Port                  = 443

# Core Azure Arc-enabled servers endpoints (region-agnostic)
$endpoints = @(
    [pscustomobject]@{ Host = 'management.azure.com';                          Purpose = 'Azure Resource Manager' }
    [pscustomobject]@{ Host = 'login.microsoftonline.com';                     Purpose = 'Microsoft Entra ID' }
    [pscustomobject]@{ Host = 'login.windows.net';                             Purpose = 'Microsoft Entra ID' }
    [pscustomobject]@{ Host = 'login.microsoft.com';                           Purpose = 'Microsoft Entra ID (*.login.microsoft.com)' }
    [pscustomobject]@{ Host = 'pas.windows.net';                               Purpose = 'Microsoft Entra ID' }
    [pscustomobject]@{ Host = 'download.microsoft.com';                        Purpose = 'Windows agent installation package' }
    [pscustomobject]@{ Host = 'packages.microsoft.com';                        Purpose = 'Linux agent installation packages' }
    [pscustomobject]@{ Host = 'gbl.his.arc.azure.com';                         Purpose = 'Hybrid Identity Service (global, *.his.arc.azure.com)' }
    [pscustomobject]@{ Host = 'agentserviceapi.guestconfiguration.azure.com';  Purpose = 'Guest Configuration (*.guestconfiguration.azure.com)' }
    [pscustomobject]@{ Host = 'guestnotificationservice.azure.com';            Purpose = 'Notification service for extensions' }
    [pscustomobject]@{ Host = 'dc.services.visualstudio.com';                  Purpose = 'Agent telemetry (optional, agent < 1.24)' }
    [pscustomobject]@{ Host = 'www.microsoft.com';                             Purpose = 'Intermediate certificate updates (pkiops/certs)' }
    [pscustomobject]@{ Host = 'dls.microsoft.com';                             Purpose = 'License validation (hotpatching / WS Azure Benefits / PAYG)' }
)

# Region-specific endpoint for Arc-enabled SQL Server (*.<region>.arcdataservices.com)
if ($IncludeSqlArc) {
    $endpoints += [pscustomobject]@{
        Host    = "telemetry.$Region.arcdataservices.com"
        Purpose = "Arc-enabled SQL Server data/telemetry (*.$Region.arcdataservices.com)"
    }
    $endpoints += [pscustomobject]@{
        Host    = 'graph.microsoft.com'
        Purpose = 'Microsoft Entra auth for Arc-enabled SQL Server'
    }
}

# Endpoints required only for Extended Security Updates scenarios
if ($IncludeEsu) {
    # download.microsoft.com, login.*, management.azure.com, *.his.arc.azure.com,
    # *.guestconfiguration.azure.com, www.microsoft.com/pkiops/certs are already
    # covered above; nothing extra to add today, but keep the switch for future
    # ESU-only additions and to make intent explicit.
    Write-Verbose 'ESU subset uses the same endpoints already covered above.'
}

Write-Host "Testing $($endpoints.Count) Azure Arc endpoints on TCP/$Port (region: $Region)..." -ForegroundColor Cyan
Write-Host ('-' * 80)

$results = foreach ($ep in $endpoints) {
    Write-Host ("Testing {0,-55} ... " -f $ep.Host) -NoNewline

    $dnsOk    = $false
    $tcpOk    = $false
    $remoteIp = $null

    try {
        $null     = Resolve-DnsName -Name $ep.Host -Type A -ErrorAction Stop -QuickTimeout
        $dnsOk    = $true
    } catch {
        $dnsOk = $false
    }

    if ($dnsOk) {
        try {
            $tnc      = Test-NetConnection -ComputerName $ep.Host -Port $Port -WarningAction SilentlyContinue
            $tcpOk    = [bool]$tnc.TcpTestSucceeded
            $remoteIp = if ($tnc.RemoteAddress) { $tnc.RemoteAddress.IPAddressToString } else { $null }
        } catch {
            $tcpOk = $false
        }
    }

    if ($tcpOk)        { Write-Host 'OK'        -ForegroundColor Green }
    elseif (-not $dnsOk) { Write-Host 'DNS FAIL' -ForegroundColor Red }
    else               { Write-Host 'TCP FAIL'  -ForegroundColor Red }

    [pscustomobject]@{
        Endpoint      = $ep.Host
        Purpose       = $ep.Purpose
        Port          = $Port
        DnsResolved   = $dnsOk
        RemoteAddress = $remoteIp
        Succeeded     = $tcpOk
    }
}

Write-Host ('-' * 80)
$results | Format-Table Endpoint, Port, DnsResolved, RemoteAddress, Succeeded, Purpose -AutoSize | Out-Host

$failed = $results | Where-Object { -not $_.Succeeded }
if ($failed) {
    Write-Host ("{0} of {1} endpoints FAILED:" -f $failed.Count, $results.Count) -ForegroundColor Red
    $failed | ForEach-Object { Write-Host (" - {0}  ({1})" -f $_.Endpoint, $_.Purpose) -ForegroundColor Red }
    exit 1
} else {
    Write-Host ("All {0} endpoints reachable on TCP/{1}." -f $results.Count, $Port) -ForegroundColor Green
    exit 0
}
