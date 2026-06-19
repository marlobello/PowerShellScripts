#Requires -Version 7.0

<#
.SYNOPSIS
    Retrieves Azure SQL Managed Instance pricing (PAYGO, Reserved Capacity, and Savings Plan)
    for one or more vCore sizes in a region, applies an Azure Consumption Discount (ACD), and
    exports a CSV or Markdown comparison table.

.DESCRIPTION
    Azure SQL Managed Instance (SQL MI) compute is billed per vCore-hour. An instance is
    identified by the ARM 'sku.name' (Microsoft.Sql/managedInstances), which encodes the
    service tier and hardware family in one string:

        sku.name   Service tier        Hardware family
        --------   -----------------   ------------------------------------------
        GP_Gen5    General Purpose     Standard-series (Gen5)
        GP_G8IM    General Purpose     Premium-series (Intel Xeon 8370C)
        GP_G8IH    General Purpose     Premium-series memory optimized (Xeon 8380HL)
        BC_Gen5    Business Critical   Standard-series (Gen5)
        BC_G8IM    Business Critical   Premium-series (Intel Xeon 8370C)
        BC_G8IH    Business Critical   Premium-series memory optimized (Xeon 8380HL)

    vCores are supplied separately (the ARM 'sku.capacity' property) via -VCores, and zone
    redundancy is a separate instance property exposed here as the -ZoneRedundant switch.

    For the chosen SKU the script calls the public Azure Retail Prices API once and resolves
    the per-vCore rates for:
      - Pay-As-You-Go (PAYGO)
      - 1 Year Reserved Capacity
      - 3 Year Reserved Capacity
      - 1 Year Savings Plan
      (SQL MI does not offer a 3 Year Savings Plan, so that column is always N/A.)

    Each requested vCore size is then priced as (per-vCore rate x vCores). All rates are
    normalized to an effective hourly price. Reserved Capacity prices are returned by the API
    as the full up-front cost per vCore for the term; the script converts them to an effective
    hourly rate (term cost / hours in term). When -ZoneRedundant is specified, the per-vCore
    Zone Redundancy add-on is added to each pricing option.

    The ACD column is a flat discount percentage off the PAYGO price:
        ACD price = PAYGO * (1 - ACD / 100)

    The Azure Retail Prices API is public and requires no authentication. Throttled (HTTP 429)
    and transient transport-level failures are retried with exponential back-off and jitter.

    NOTE: Only compute is priced, and all compute prices are "License Included" (the SQL Server
    license is included in the vCore rate). Azure Hybrid Benefit (AHB) is NOT applied -- the
    Retail Prices API does not publish a separate AHB/base-compute meter for SQL MI, so AHB
    pricing cannot be derived here. SQL MI storage and backup storage (PITR/LTR) are billed
    separately and are NOT included.

.PARAMETER Region
    The Azure region (ARM region name, e.g. 'eastus', 'westeurope') to price against.

.PARAMETER ACD
    Azure Consumption Discount as an integer percentage (0-100) applied to PAYGO pricing.

.PARAMETER SkuName
    The ARM managed instance SKU (Microsoft.Sql/managedInstances 'sku.name'). One of:
    'GP_Gen5', 'GP_G8IM', 'GP_G8IH', 'BC_Gen5', 'BC_G8IM', 'BC_G8IH'. Defaults to 'GP_Gen5'.

.PARAMETER VCores
    One or more vCore counts to price (e.g. 4, 8, 16, 32) -- the ARM 'sku.capacity'. Accepts
    pipeline input. Pricing is linear per vCore. Defaults to: 4, 8, 16, 24, 32, 40, 64, 80.

.PARAMETER ZoneRedundant
    When specified, adds the per-vCore Zone Redundancy add-on charge to every pricing option
    (the ARM 'zoneRedundant' instance property).

.PARAMETER OutputFormat
    Output file format: 'CSV' (default) or 'Markdown'.

.PARAMETER Currency
    ISO currency code for the returned prices (default 'USD').

.PARAMETER OutputFileName
    Optional base name for the output file (no extension). Defaults to
    'SqlMiPricing_{region}_{yyyyMMdd}'. The correct extension is appended automatically.

.PARAMETER ListSkus
    Lists the managed instance SKUs available in -Region and exits without pricing. Only
    -Region (and optionally -Currency) are required with this switch. The names are also
    written to the pipeline so they can be reused programmatically.

.EXAMPLE
    .\Get-AzureSqlMiPricing.ps1 -Region eastus -ACD 15

    Prices the default vCore sizes for GP_Gen5 in East US with a 15% ACD (CSV).

.EXAMPLE
    .\Get-AzureSqlMiPricing.ps1 -Region westeurope -ACD 20 -SkuName BC_G8IM -VCores 8,16,32 -OutputFormat Markdown

    Prices 8/16/32 vCore Business Critical Premium-series (G8IM) instances as a Markdown report.

.EXAMPLE
    8,16,32,64 | .\Get-AzureSqlMiPricing.ps1 -Region eastus2 -ACD 10 -SkuName GP_Gen5 -ZoneRedundant

    Pipes vCore sizes in and includes the Zone Redundancy add-on in every price.

.EXAMPLE
    .\Get-AzureSqlMiPricing.ps1 -Region eastus -ListSkus

    Lists every managed instance SKU available in East US (no ACD/vCores needed).

.NOTES
    Requirements:
      - PowerShell 7.0 or later
      - Internet access to https://prices.azure.com (no authentication required)

    Output file: ./output/SqlMiPricing_{region}_{yyyyMMdd}.csv|.md
#>

[CmdletBinding(DefaultParameterSetName = 'Pricing')]
param (
    [Parameter(Mandatory = $true, HelpMessage = "Azure ARM region name (e.g. 'eastus')")]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[a-z0-9]+$', ErrorMessage = "Region must be a lowercase ARM region name (e.g. 'eastus').")]
    [string]$Region,

    [Parameter(Mandatory = $true, ParameterSetName = 'Pricing',
               HelpMessage = "Azure Consumption Discount as an integer percentage off PAYGO (0-100)")]
    [ValidateRange(0, 100)]
    [int]$ACD,

    [Parameter(Mandatory = $false, ParameterSetName = 'Pricing',
               HelpMessage = "ARM managed instance sku.name: GP_Gen5, GP_G8IM, GP_G8IH, BC_Gen5, BC_G8IM, BC_G8IH")]
    [ValidateSet('GP_Gen5', 'GP_G8IM', 'GP_G8IH', 'BC_Gen5', 'BC_G8IM', 'BC_G8IH')]
    [string]$SkuName = 'GP_Gen5',

    [Parameter(Mandatory = $false, ParameterSetName = 'Pricing',
               ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true,
               HelpMessage = "One or more vCore counts to price (e.g. 8, 16, 32). Accepts pipeline input.")]
    [ValidateRange(1, 128)]
    [int[]]$VCores = @(4, 8, 16, 24, 32, 40, 64, 80),

    [Parameter(Mandatory = $false, ParameterSetName = 'Pricing',
               HelpMessage = "Add the per-vCore Zone Redundancy add-on to every price")]
    [switch]$ZoneRedundant,

    [Parameter(Mandatory = $true, ParameterSetName = 'ListSkus',
               HelpMessage = "List the managed instance SKUs available in the region and exit.")]
    [switch]$ListSkus,

    [Parameter(Mandatory = $false, ParameterSetName = 'Pricing',
               HelpMessage = "Output format: CSV (default) or Markdown")]
    [ValidateSet('CSV', 'Markdown')]
    [string]$OutputFormat = 'CSV',

    [Parameter(Mandatory = $false, HelpMessage = "ISO currency code (default 'USD')")]
    [ValidateNotNullOrEmpty()]
    [string]$Currency = 'USD',

    [Parameter(Mandatory = $false, ParameterSetName = 'Pricing',
               HelpMessage = "Optional base name for the output file (no extension)")]
    [string]$OutputFileName
)

begin {

# ================================================================================
# CONSTANTS
# ================================================================================

$script:RetailApiBaseUri = 'https://prices.azure.com/api/retail/prices'
# Preview API version is required for the savingsPlan array to be returned.
$script:RetailApiVersion = '2023-01-01-preview'
$script:HoursPerYear     = 8760   # 365 * 24

# Maps each ARM managed instance sku.name to its display tier/series and the corresponding
# Azure Retail Prices productName for the compute meters.
$script:SkuMap = [ordered]@{
    'GP_Gen5' = @{
        Tier        = 'General Purpose'
        Series      = 'Standard-series (Gen5)'
        ProductName = 'SQL Managed Instance General Purpose - Compute Gen5'
    }
    'GP_G8IM' = @{
        Tier        = 'General Purpose'
        Series      = 'Premium-series (G8IM)'
        ProductName = 'SQL Managed Instance General Purpose - Premium Series Compute'
    }
    'GP_G8IH' = @{
        Tier        = 'General Purpose'
        Series      = 'Premium-series memory optimized (G8IH)'
        ProductName = 'SQL Managed Instance General Purpose - Premium Series Memory Optimized Compute'
    }
    'BC_Gen5' = @{
        Tier        = 'Business Critical'
        Series      = 'Standard-series (Gen5)'
        ProductName = 'SQL Managed Instance Business Critical - Compute Gen5'
    }
    'BC_G8IM' = @{
        Tier        = 'Business Critical'
        Series      = 'Premium-series (G8IM)'
        ProductName = 'SQL Managed Instance Business Critical - Premium Series Compute'
    }
    'BC_G8IH' = @{
        Tier        = 'Business Critical'
        Series      = 'Premium-series memory optimized (G8IH)'
        ProductName = 'SQL Managed Instance Business Critical - Premium Series Memory Optimized Compute'
    }
}

# ================================================================================
# HELPER FUNCTIONS
# ================================================================================

function Invoke-RetailPriceQuery {
    <#
    .SYNOPSIS
        Calls the Azure Retail Prices API for a single OData filter, transparently following
        pagination and retrying throttled/transient requests with exponential back-off.

    .OUTPUTS
        [object[]] The combined Items collection across all pages.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Filter,
        [Parameter(Mandatory = $true)][string]$Currency
    )

    $encodedFilter = [uri]::EscapeDataString($Filter)
    $uri = '{0}?api-version={1}&currencyCode={2}&$filter={3}' -f `
        $script:RetailApiBaseUri, $script:RetailApiVersion, $Currency, $encodedFilter

    $allItems = [System.Collections.Generic.List[object]]::new()

    while (-not [string]::IsNullOrEmpty($uri)) {
        $response = Invoke-WithExponentialBackoff -ScriptBlock {
            Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop
        }

        if ($response.Items) {
            foreach ($item in $response.Items) { $allItems.Add($item) }
        }

        $uri = $response.NextPageLink
    }

    return $allItems
}

function Invoke-WithExponentialBackoff {
    <#
    .SYNOPSIS
        Executes a script block, retrying on HTTP 429 (throttling), transient 5xx errors, and
        transport-level failures (dropped connections / timeouts) using exponential back-off
        with jitter.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $false)][int]$MaxAttempts = 6,
        [Parameter(Mandatory = $false)][double]$BaseDelaySeconds = 2
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $ScriptBlock
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            # Retry on throttling (429), transient server errors (5xx), and transport-level
            # failures that carry no HTTP status code (dropped/reset connections or timeouts).
            $isTransportError = ($null -eq $statusCode)
            $isRetryable = ($statusCode -eq 429) -or ($statusCode -ge 500 -and $statusCode -le 599) -or $isTransportError

            if (-not $isRetryable -or $attempt -eq $MaxAttempts) {
                throw
            }

            $delay = $BaseDelaySeconds * [math]::Pow(2, $attempt - 1) + (Get-Random -Minimum 0.0 -Maximum 1.0)
            Write-Warning ("Request failed ({0}). Retry {1}/{2} in {3:N1}s..." -f `
                ($statusCode ? "HTTP $statusCode" : $_.Exception.Message), $attempt, $MaxAttempts, $delay)
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-MeterRates {
    <#
    .SYNOPSIS
        Extracts per-vCore hourly PAYGO, 1/3 Year Reserved and 1/3 Year Savings Plan rates for
        a single SQL MI compute meter (a specific skuName within a productName).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory = $true)][string]$SkuName
    )

    $meterItems = $Items | Where-Object { $_.skuName -eq $SkuName }

    $consumption = $meterItems | Where-Object { $_.type -eq 'Consumption' } | Select-Object -First 1
    $payg = if ($consumption) { [double]$consumption.retailPrice } else { $null }

    $sav1 = $null; $sav3 = $null
    if ($consumption -and $consumption.savingsPlan) {
        $sp1 = $consumption.savingsPlan | Where-Object { $_.term -eq '1 Year' }  | Select-Object -First 1
        $sp3 = $consumption.savingsPlan | Where-Object { $_.term -eq '3 Years' } | Select-Object -First 1
        if ($sp1) { $sav1 = [double]$sp1.retailPrice }
        if ($sp3) { $sav3 = [double]$sp3.retailPrice }
    }

    # Sanity guard: a Savings Plan rate can never exceed the meter's own PAYGO rate (it must be
    # a discount). Some preview meters (e.g. certain premium Zone Redundancy add-ons) publish
    # inconsistent values; discard those so they don't inflate a combined price above PAYGO.
    if ($null -ne $payg) {
        if ($null -ne $sav1 -and $sav1 -ge $payg) { $sav1 = $null }
        if ($null -ne $sav3 -and $sav3 -ge $payg) { $sav3 = $null }
    }

    # Reserved Capacity retailPrice is the full per-vCore cost for the term -> normalize hourly.
    $res1Item = $meterItems | Where-Object { $_.type -eq 'Reservation' -and $_.reservationTerm -eq '1 Year'  } | Select-Object -First 1
    $res3Item = $meterItems | Where-Object { $_.type -eq 'Reservation' -and $_.reservationTerm -eq '3 Years' } | Select-Object -First 1
    $res1 = if ($res1Item) { [double]$res1Item.retailPrice / $script:HoursPerYear } else { $null }
    $res3 = if ($res3Item) { [double]$res3Item.retailPrice / ($script:HoursPerYear * 3) } else { $null }

    return [pscustomobject]@{
        Payg = $payg
        Res1 = $res1
        Res3 = $res3
        Sav1 = $sav1
        Sav3 = $sav3
    }
}

function Add-Rate {
    # Adds two nullable rates. If either operand is null the result is null (an incomplete
    # price cannot be formed, e.g. a base+add-on combination where one component is missing).
    param([object]$A, [object]$B)
    if ($null -eq $A -or $null -eq $B) { return $null }
    return [double]$A + [double]$B
}

function Get-SqlMiAvailableSku {
    <#
    .SYNOPSIS
        Returns the ARM managed instance SKUs (sku.name) available in a region, by matching the
        compute productNames present in the Retail Prices API against the known SKU map.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Region,
        [Parameter(Mandatory = $true)][string]$Currency
    )

    $filter = "serviceName eq 'SQL Managed Instance' and armRegionName eq '$Region' and contains(productName,'Compute')"
    $items  = Invoke-RetailPriceQuery -Filter $filter -Currency $Currency
    $present = $items | Select-Object -ExpandProperty productName -Unique

    return $script:SkuMap.Keys | Where-Object { $present -contains $script:SkuMap[$_].ProductName }
}

function Get-SqlMiVCoreRates {
    <#
    .SYNOPSIS
        Resolves the per-vCore hourly rates for a SQL MI compute productName, optionally
        including the Zone Redundancy add-on.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Region,
        [Parameter(Mandatory = $true)][string]$ProductName,
        [Parameter(Mandatory = $true)][bool]$ZoneRedundant,
        [Parameter(Mandatory = $true)][string]$Currency
    )

    $filter = "serviceName eq 'SQL Managed Instance' and armRegionName eq '$Region' and productName eq '$ProductName'"
    $items  = Invoke-RetailPriceQuery -Filter $filter -Currency $Currency

    if (-not $items -or $items.Count -eq 0) {
        return $null
    }

    $base = Get-MeterRates -Items $items -SkuName 'vCore'

    if (-not $ZoneRedundant) {
        return $base
    }

    # Zone Redundancy is a separately billed per-vCore add-on; combine each option with base.
    $zr = Get-MeterRates -Items $items -SkuName 'vCore ZR Zone Redundancy'
    return [pscustomobject]@{
        Payg = Add-Rate $base.Payg $zr.Payg
        Res1 = Add-Rate $base.Res1 $zr.Res1
        Res3 = Add-Rate $base.Res3 $zr.Res3
        Sav1 = Add-Rate $base.Sav1 $zr.Sav1
        Sav3 = Add-Rate $base.Sav3 $zr.Sav3
    }
}

function Format-Rate {
    param([object]$Value, [int]$Decimals = 4)
    if ($null -eq $Value) { return 'N/A' }
    return [math]::Round([double]$Value, $Decimals)
}

function Get-DiscountPct {
    param([object]$Payg, [object]$Rate)
    if ($null -eq $Payg -or $null -eq $Rate -or $Payg -eq 0) { return $null }
    return [math]::Round((1 - ([double]$Rate / [double]$Payg)) * 100, 1)
}

function Scale-Rate {
    # Multiplies a nullable per-vCore rate by a vCore count.
    param([object]$Rate, [int]$VCores)
    if ($null -eq $Rate) { return $null }
    return [double]$Rate * $VCores
}

# ================================================================================
# MAIN
# ================================================================================

$results = [System.Collections.Generic.List[object]]::new()
$script:Aborted = $false

# -ListSkus: enumerate the SKUs available in the region and exit.
if ($PSCmdlet.ParameterSetName -eq 'ListSkus') {
    $script:Aborted = $true   # skip the pricing process/end blocks
    Write-Host "Available SQL Managed Instance SKUs in '$Region':" -ForegroundColor Cyan
    try {
        $skuList = Get-SqlMiAvailableSku -Region $Region -Currency $Currency
    }
    catch {
        Write-Error "Failed to list SQL MI SKUs for '$Region': $($_.Exception.Message)"
        return
    }
    if (-not $skuList -or $skuList.Count -eq 0) {
        Write-Warning "No SQL MI SKUs found in '$Region'. Verify the region name."
        return
    }
    foreach ($s in $skuList) {
        Write-Host ("  {0,-8}  {1} / {2}" -f $s, $script:SkuMap[$s].Tier, $script:SkuMap[$s].Series) -ForegroundColor Gray
    }
    Write-Host "$($skuList.Count) SKU(s). Pass one via -SkuName; use -ZoneRedundant for zone redundancy and -VCores for size." -ForegroundColor Cyan
    Write-Output $skuList
    return
}

# Resolve the SKU (canonical casing) and its pricing productName.
$canonicalSku    = $script:SkuMap.Keys | Where-Object { $_ -eq $SkuName } | Select-Object -First 1
$skuInfo         = $script:SkuMap[$canonicalSku]
$tierDisplay     = $skuInfo.Tier
$seriesDisplay   = $skuInfo.Series
$productName     = $skuInfo.ProductName
$useZoneRedundant = $ZoneRedundant.IsPresent

$zrLabel = if ($useZoneRedundant) { ' + Zone Redundancy' } else { '' }
Write-Host "Querying Azure Retail Prices API for SQL Managed Instance in '$Region'..." -ForegroundColor Cyan
Write-Host "  SKU: $canonicalSku  ($tierDisplay / $seriesDisplay$zrLabel, $Currency)" -ForegroundColor Gray

# Per-vCore rates are fixed for the chosen SKU, so fetch them once up front.
try {
    $vcoreRates = Get-SqlMiVCoreRates -Region $Region -ProductName $productName `
        -ZoneRedundant $useZoneRedundant -Currency $Currency
}
catch {
    Write-Error "Failed to retrieve SQL MI pricing for '$canonicalSku' in '$Region': $($_.Exception.Message)"
    $script:Aborted = $true
    return
}

if ($null -eq $vcoreRates) {
    Write-Error "No pricing found for SKU '$canonicalSku' in '$Region'. That SKU may not be offered in this region (use -ListSkus to check)."
    $script:Aborted = $true
    return
}

if ($null -eq $vcoreRates.Payg) {
    Write-Warning "No PAYGO rate found for '$canonicalSku' in '$Region'. Output prices may be incomplete."
}

}

process {

if ($script:Aborted) { return }

foreach ($vc in $VCores) {
    Write-Host "  - $vc vCore" -ForegroundColor Gray

    $payg = Scale-Rate $vcoreRates.Payg $vc
    # NOTE: local must not be named $acd -- PowerShell variable names are case-insensitive,
    # so $acd would alias the [int]$ACD parameter and corrupt it (rounding the price to int).
    $acdPrice = if ($null -ne $payg) { [math]::Round($payg * (1 - $ACD / 100.0), 4) } else { $null }

    $results.Add([pscustomobject]@{
        VCores = $vc
        Payg   = $payg
        Acd    = $acdPrice
        Res1   = Scale-Rate $vcoreRates.Res1 $vc
        Res3   = Scale-Rate $vcoreRates.Res3 $vc
        Sav1   = Scale-Rate $vcoreRates.Sav1 $vc
        Sav3   = Scale-Rate $vcoreRates.Sav3 $vc
    })
}

}

end {

if ($script:Aborted) { return }

# Resolve output path.
$outputDir = Join-Path -Path $PSScriptRoot -ChildPath 'output'
if (-not (Test-Path -Path $outputDir)) {
    New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
}

if ([string]::IsNullOrWhiteSpace($OutputFileName)) {
    $OutputFileName = "SqlMiPricing_{0}_{1}" -f $Region, (Get-Date -Format 'yyyyMMdd')
}

$sortedResults = $results | Sort-Object VCores

if ($OutputFormat -eq 'Markdown') {
    # ----------------------------------------------------------------------------
    # Markdown output: dressed up with discount percentages, monthly estimate and
    # best-value flags.
    # ----------------------------------------------------------------------------
    $outFile = Join-Path -Path $outputDir -ChildPath "$OutputFileName.md"
    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.AppendLine("# Azure SQL Managed Instance Pricing Comparison")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("- **Region:** ``$Region``")
    [void]$sb.AppendLine("- **SKU (sku.name):** ``$canonicalSku``")
    [void]$sb.AppendLine("- **Service Tier:** $tierDisplay")
    [void]$sb.AppendLine("- **Hardware:** $seriesDisplay")
    [void]$sb.AppendLine("- **Zone Redundant:** $useZoneRedundant")
    [void]$sb.AppendLine("- **Licensing:** License Included (Azure Hybrid Benefit not applied)")
    [void]$sb.AppendLine("- **Currency:** $Currency")
    [void]$sb.AppendLine("- **ACD (Azure Consumption Discount):** $ACD% off PAYGO")
    [void]$sb.AppendLine("- **Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') (local)")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("> All prices are **effective hourly rates** for the whole instance (per-vCore rate x vCores) and are **License Included** (SQL Server license in the rate; Azure Hybrid Benefit not applied). Reserved Capacity term costs are normalized to hourly (term cost / hours in term). Percentages in parentheses are the discount versus PAYGO. _Est. Monthly_ uses 730 hours of PAYGO. Compute only -- storage and backup are billed separately.")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("| vCores | PAYGO | Est. Monthly | ACD ($ACD%) | 1 Year Res. | 3 Year Res. | 1 Year Sav. | 3 Year Sav. | Best Value |")
    [void]$sb.AppendLine("|-------:|------:|------------:|------:|------:|------:|------:|------:|:----------:|")

    function MdCell {
        param([object]$Payg, [object]$Rate, [string]$FixedPct)
        if ($null -eq $Rate) { return 'N/A' }
        $rate = Format-Rate $Rate
        if ($FixedPct) { return "$rate ($FixedPct)" }
        $pct = Get-DiscountPct -Payg $Payg -Rate $Rate
        if ($null -ne $pct) { return "$rate ($pct%)" }
        return "$rate"
    }

    foreach ($r in $sortedResults) {
        $options = @(
            @{ Name = 'PAYGO';        Rate = $r.Payg },
            @{ Name = 'ACD';          Rate = $r.Acd },
            @{ Name = '1Yr Reserved'; Rate = $r.Res1 },
            @{ Name = '3Yr Reserved'; Rate = $r.Res3 },
            @{ Name = '1Yr Savings';  Rate = $r.Sav1 },
            @{ Name = '3Yr Savings';  Rate = $r.Sav3 }
        ) | Where-Object { $null -ne $_.Rate }

        $best = if ($options.Count -gt 0) { ($options | Sort-Object { [double]$_.Rate } | Select-Object -First 1).Name } else { 'N/A' }

        $paygCell    = if ($null -ne $r.Payg) { Format-Rate $r.Payg } else { 'N/A' }
        $monthlyCell = if ($null -ne $r.Payg) { '${0:N0}' -f ([double]$r.Payg * 730) } else { 'N/A' }
        $acdCell     = MdCell -Payg $r.Payg -Rate $r.Acd -FixedPct "$ACD%"
        $res1Cell    = MdCell -Payg $r.Payg -Rate $r.Res1
        $res3Cell    = MdCell -Payg $r.Payg -Rate $r.Res3
        $sav1Cell    = MdCell -Payg $r.Payg -Rate $r.Sav1
        $sav3Cell    = MdCell -Payg $r.Payg -Rate $r.Sav3

        [void]$sb.AppendLine("| **$($r.VCores)** | $paygCell | $monthlyCell | $acdCell | $res1Cell | $res3Cell | $sav1Cell | $sav3Cell | $best |")
    }

    [void]$sb.AppendLine()
    [void]$sb.AppendLine("_Source: Azure Retail Prices API (api-version $script:RetailApiVersion). SQL MI does not offer a 3 Year Savings Plan. Prices are subject to change._")

    $sb.ToString() | Out-File -FilePath $outFile -Encoding utf8
}
else {
    # ----------------------------------------------------------------------------
    # CSV output (default).
    # ----------------------------------------------------------------------------
    $outFile = Join-Path -Path $outputDir -ChildPath "$OutputFileName.csv"

    $csvRows = foreach ($r in $sortedResults) {
        [pscustomobject]@{
            'SKU'         = $canonicalSku
            'ZR'          = $useZoneRedundant
            'Licensing'   = 'License Included'
            'vCores'      = $r.VCores
            'PAYGO'       = Format-Rate $r.Payg
            'ACD'         = Format-Rate $r.Acd
            '1 Year Res.' = Format-Rate $r.Res1
            '3 Year Res.' = Format-Rate $r.Res3
            '1 Year Sav.' = Format-Rate $r.Sav1
            '3 Year Sav.' = Format-Rate $r.Sav3
        }
    }

    $csvRows | Export-Csv -Path $outFile -NoTypeInformation -Encoding utf8
}

Write-Host "Report written to: $outFile" -ForegroundColor Green
Write-Output $outFile

}
