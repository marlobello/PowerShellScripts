<#
.SYNOPSIS
    Tests connectivity from the current machine to the public network endpoints
    required by Azure Arc-enabled servers.

.DESCRIPTION
    Performs three layered checks against each documented endpoint:
      1. DNS resolution (Resolve-DnsName)
      2. TCP/443 reachability (Test-NetConnection)
      3. HTTPS probe with TLS + SNI + certificate validation (Invoke-WebRequest)

    Step 3 catches problems Test-NetConnection cannot, including TLS-intercepting
    proxies, untrusted certificates, disabled TLS versions, missing cipher
    suites, and SNI-based firewall filtering. Any HTTP response (including 4xx)
    is treated as success because it proves the TLS + HTTP stack works; only
    transport, TLS, or DNS failures are reported as errors.

    Endpoint list is taken from the official Microsoft documentation:
    https://learn.microsoft.com/azure/azure-arc/servers/network-requirements

    Wildcard endpoints in the docs (e.g. *.his.arc.azure.com,
    *.guestconfiguration.azure.com, *.<region>.arcdataservices.com) are
    represented here by a known concrete subdomain that resolves in DNS.

.PARAMETER Region
    The Azure region short name (e.g. eastus, westeurope, centralus) used to
    build the regional endpoints. Defaults to 'eastus'.

.PARAMETER HisShard
    Override the Hybrid Identity Service (HIS) shard code used to build
    <shard>.his.arc.azure.com. Required if your region isn't in the built-in
    map. Examples: eus, scus, weu, sea, kc, ae.

.PARAMETER IncludeSqlArc
    Include endpoints required only for Azure Arc-enabled SQL Server.

.PARAMETER IncludeEsu
    Include endpoints required only for Extended Security Updates (ESU).

.PARAMETER SkipHttps
    Skip the HTTPS/TLS layer probe and only perform DNS + TCP checks.

.PARAMETER TimeoutSec
    Timeout in seconds for the HTTPS probe. Defaults to 15.

.EXAMPLE
    .\Test-ArcEndpoints.ps1 -Region westeurope

.EXAMPLE
    .\Test-ArcEndpoints.ps1 -Region eastus2 -IncludeSqlArc -IncludeEsu

.EXAMPLE
    .\Test-ArcEndpoints.ps1 -SkipHttps   # TCP-only, faster/lighter

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
    [string]$HisShard,
    [switch]$IncludeSqlArc,
    [switch]$IncludeEsu,
    [switch]$SkipHttps,
    [int]$TimeoutSec = 15
)

# Force TLS 1.2/1.3 for the HTTPS probe so older defaults don't mask issues.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

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

# Regional Arc endpoints — these are the ones that the azcmagent connectivity
# test calls out by name (and frequently fail in DNS for misconfigured networks).
#   <region>-gas.guestconfiguration.azure.com   (region name maps directly)
#   <shard>.his.arc.azure.com                   (region maps to a short HIS shard code)
# The HIS shard code is NOT the Azure region name. The mapping below is verified
# via DNS for the listed regions; for any other region pass -HisShard explicitly.
$hisShardMap = @{
    'eastus'             = 'eus'
    'eastus2'            = 'eus2'
    'westus2'            = 'wus2'
    'westcentralus'      = 'wcus'
    'centralus'          = 'scus'
    'southcentralus'     = 'scus'
    'northeurope'        = 'ne'
    'westeurope'         = 'weu'
    'uksouth'            = 'uks'
    'francecentral'      = 'fc'
    'germanywestcentral' = 'gwc'
    'swedencentral'      = 'sec'
    'polandcentral'      = 'plc'
    'italynorth'         = 'itn'
    'eastasia'           = 'ea'
    'southeastasia'      = 'sea'
    'koreacentral'       = 'kc'
    'australiaeast'      = 'ae'
    'brazilsouth'        = 'brs'
    'southafricanorth'   = 'san'
    'uaenorth'           = 'uaen'
    'qatarcentral'       = 'qac'
    'israelcentral'      = 'ilc'
    'indonesiacentral'   = 'idc'
    'malaysiawest'       = 'myw'
}

$regionLower = $Region.ToLowerInvariant()
$shard = if ($PSBoundParameters.ContainsKey('HisShard') -and $HisShard) {
    $HisShard
} elseif ($hisShardMap.ContainsKey($regionLower)) {
    $hisShardMap[$regionLower]
} else {
    $null
}

$endpoints += [pscustomobject]@{
    Host    = "$regionLower-gas.guestconfiguration.azure.com"
    Purpose = "Guest Configuration agent service (regional, <region>-gas.guestconfiguration.azure.com)"
}

if ($shard) {
    $endpoints += [pscustomobject]@{
        Host    = "$shard.his.arc.azure.com"
        Purpose = "Hybrid Identity Service (regional shard '$shard' for $regionLower)"
    }
} else {
    Write-Warning ("No HIS shard code is mapped for region '{0}'. The agent will require <shard>.his.arc.azure.com; pass -HisShard <code> to test it." -f $regionLower)
}

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

    $dnsOk     = $false
    $tcpOk     = $false
    $httpsOk   = $false
    $remoteIp  = $null
    $httpCode  = $null
    $errorMsg  = $null

    # 1) DNS
    try {
        $null  = Resolve-DnsName -Name $ep.Host -Type A -ErrorAction Stop -QuickTimeout
        $dnsOk = $true
    } catch {
        $errorMsg = "DNS: $($_.Exception.Message)"
    }

    # 2) TCP/443
    if ($dnsOk) {
        try {
            $tnc      = Test-NetConnection -ComputerName $ep.Host -Port $Port -WarningAction SilentlyContinue
            $tcpOk    = [bool]$tnc.TcpTestSucceeded
            $remoteIp = if ($tnc.RemoteAddress) { $tnc.RemoteAddress.IPAddressToString } else { $null }
            if (-not $tcpOk) { $errorMsg = 'TCP: connection refused or timed out' }
        } catch {
            $errorMsg = "TCP: $($_.Exception.Message)"
        }
    }

    # 3) HTTPS / TLS / cert / SNI
    if ($tcpOk -and -not $SkipHttps) {
        $url = "https://$($ep.Host)/"

        # Try HEAD first; some servers (e.g. download.microsoft.com) reject HEAD
        # at the transport layer, so fall back to a small GET. Either way, any
        # HTTP response (incl. 4xx/5xx) means TLS + HTTP succeeded.
        foreach ($method in 'Head','Get') {
            try {
                $resp     = Invoke-WebRequest -Uri $url -Method $method -UseBasicParsing `
                                              -TimeoutSec $TimeoutSec -MaximumRedirection 0 `
                                              -ErrorAction Stop
                $httpsOk  = $true
                $httpCode = [int]$resp.StatusCode
                $errorMsg = $null
                break
            } catch {
                # PS 5.1 throws WebException; PS 7+ throws HttpResponseException.
                # Both expose a .Response with .StatusCode when an HTTP reply was received.
                $ex   = $_.Exception
                $code = $null
                if ($ex.PSObject.Properties['Response'] -and $ex.Response) {
                    try { $code = [int]$ex.Response.StatusCode } catch { $code = $null }
                }
                if ($code) {
                    $httpsOk  = $true
                    $httpCode = $code
                    $errorMsg = $null
                    break
                } else {
                    $errorMsg = "HTTPS ($method): $($ex.Message)"
                    # try next method
                }
            }
        }
    }

    $succeeded = if ($SkipHttps) { $tcpOk } else { $tcpOk -and $httpsOk }

    if ($succeeded)        { Write-Host 'OK'       -ForegroundColor Green }
    elseif (-not $dnsOk)   { Write-Host 'DNS FAIL' -ForegroundColor Red }
    elseif (-not $tcpOk)   { Write-Host 'TCP FAIL' -ForegroundColor Red }
    else                   { Write-Host 'TLS FAIL' -ForegroundColor Red }

    [pscustomobject]@{
        Endpoint      = $ep.Host
        Purpose       = $ep.Purpose
        Port          = $Port
        DnsResolved   = $dnsOk
        RemoteAddress = $remoteIp
        TcpOk         = $tcpOk
        HttpsOk       = if ($SkipHttps) { $null } else { $httpsOk }
        HttpStatus    = $httpCode
        Succeeded     = $succeeded
        Error         = $errorMsg
    }
}

Write-Host ('-' * 80)
$cols = @('Endpoint','DnsResolved','TcpOk')
if (-not $SkipHttps) { $cols += @('HttpsOk','HttpStatus') }
$cols += @('Succeeded','Purpose')
$results | Format-Table $cols -AutoSize | Out-Host

$failed = $results | Where-Object { -not $_.Succeeded }
if ($failed) {
    Write-Host ("{0} of {1} endpoints FAILED:" -f $failed.Count, $results.Count) -ForegroundColor Red
    $failed | ForEach-Object {
        $line = " - {0}  ({1})" -f $_.Endpoint, $_.Purpose
        if ($_.Error) { $line += "  [{0}]" -f $_.Error }
        Write-Host $line -ForegroundColor Red
    }
    exit 1
} else {
    $layer = if ($SkipHttps) { "TCP/$Port" } else { "TCP/$Port + HTTPS" }
    Write-Host ("All {0} endpoints reachable ({1})." -f $results.Count, $layer) -ForegroundColor Green
    exit 0
}
