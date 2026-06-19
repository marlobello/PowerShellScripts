#Requires -Version 7.0

<#
.SYNOPSIS
    Retrieves Azure App Service plan pricing (PAYGO, Reserved Instances, and Savings Plans) for
    a list of plan SKUs in a region, applies an Azure Commitment Discount (ACD), and exports a
    CSV or Markdown comparison table.

.DESCRIPTION
    For each requested App Service plan SKU the script calls the public Azure Retail Prices API
    and gathers:
      - Pay-As-You-Go (PAYGO) hourly price
      - 1 Year Reserved Instance price
      - 3 Year Reserved Instance price
      - 1 Year Savings Plan price
      - 3 Year Savings Plan price

    All rates are normalized to an effective hourly price so they can be compared directly.
    Reserved Instance prices are returned by the API as the full up-front cost for the term;
    the script converts them to an effective hourly rate (term cost / hours in term).

    The ACD column is calculated as a flat discount percentage off the PAYGO hourly price:
        ACD price = PAYGO * (1 - ACD / 100)

    Unlike Virtual Machines, App Service plan pricing is operating-system specific for ALL
    purchase options (PAYGO, Reservations and Savings Plans). Windows and Linux carry different
    prices and are published as separate products (the Linux product name ends in ' - Linux').
    The -OS parameter selects which set of prices is returned.

    The Azure Retail Prices API is public and requires no authentication. Requests that are
    throttled (HTTP 429) are retried automatically using exponential back-off with jitter.

    Output is written to the ./output/ directory relative to the script. CSV is the default;
    use -OutputFormat Markdown for a dressed-up Markdown report that includes the discount
    percentage each option provides versus PAYGO and highlights the best value per SKU.

    Not sure which plan SKUs exist? Run with -ListSkus to print every App Service plan SKU
    available in the region (with its PAYGO price) and exit, so you can pick the ones you want.

.PARAMETER Skus
    One or more Azure App Service plan SKU names (e.g. 'P1 v3', 'P2 v3', 'S1', 'I1 v2').
    Accepts an array or comma-separated list. Use -ListSkus to discover valid values.

.PARAMETER Region
    The Azure region (ARM region name, e.g. 'eastus', 'westeurope') to price against.

.PARAMETER ACD
    Azure Commitment Discount as an integer percentage (0-100) applied to PAYGO pricing.

.PARAMETER OS
    Operating system pricing to retrieve: 'Linux' (default) or 'Windows'. App Service plan
    prices differ by OS for every purchase option.

.PARAMETER OutputFormat
    Output file format: 'CSV' (default) or 'Markdown'.

.PARAMETER Currency
    ISO currency code for the returned prices (default 'USD').

.PARAMETER OutputFileName
    Optional base name for the output file (no extension). Defaults to
    'AppServicePricing_{region}_{yyyyMMdd}'. The correct extension is appended automatically.

.PARAMETER ListSkus
    Discovery mode. Lists every App Service plan SKU available in -Region (for the selected
    -OS) along with its PAYGO hourly price, then exits without producing a report.

.EXAMPLE
    .\Get-AzureAppServicePricing.ps1 -Skus 'P1 v3','P2 v3' -Region eastus -ACD 15

    Prices two Premium v3 Linux plans in East US with a 15% ACD and writes a CSV report.

.EXAMPLE
    .\Get-AzureAppServicePricing.ps1 -Skus 'P1 v3' -Region westeurope -ACD 20 -OS Windows -OutputFormat Markdown

    Produces a Markdown report for the Windows P1 v3 plan with discount percentages and
    best-value highlighting.

.EXAMPLE
    .\Get-AzureAppServicePricing.ps1 -Region eastus -ListSkus

    Lists all App Service plan SKUs (and PAYGO prices) available in East US, then exits.

.EXAMPLE
    'P1 v3','P2 v3','P3 v3' | .\Get-AzureAppServicePricing.ps1 -Region eastus -ACD 10

    Pipes plan SKU names into the script.

.NOTES
    Requirements:
      - PowerShell 7.0 or later
      - Internet access to https://prices.azure.com (no authentication required)

    Output file: ./output/AppServicePricing_{region}_{yyyyMMdd}.csv|.md
#>

[CmdletBinding(DefaultParameterSetName = 'Price')]
param (
    [Parameter(ParameterSetName = 'Price', Mandatory = $true, ValueFromPipeline = $true,
               ValueFromPipelineByPropertyName = $true,
               HelpMessage = "One or more App Service plan SKU names (e.g. 'P1 v3'). Accepts pipeline input.")]
    [ValidateNotNullOrEmpty()]
    [Alias('SkuName', 'Name')]
    [string[]]$Skus,

    [Parameter(Mandatory = $true, HelpMessage = "Azure ARM region name (e.g. 'eastus')")]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[a-z0-9]+$', ErrorMessage = "Region must be a lowercase ARM region name (e.g. 'eastus').")]
    [string]$Region,

    [Parameter(ParameterSetName = 'Price', Mandatory = $true,
               HelpMessage = "Azure Commitment Discount as an integer percentage off PAYGO (0-100)")]
    [ValidateRange(0, 100)]
    [int]$ACD,

    [Parameter(Mandatory = $false, HelpMessage = "OS pricing to retrieve: Linux (default) or Windows")]
    [ValidateSet('Linux', 'Windows')]
    [string]$OS = 'Linux',

    [Parameter(ParameterSetName = 'Price', Mandatory = $false, HelpMessage = "Output format: CSV (default) or Markdown")]
    [ValidateSet('CSV', 'Markdown')]
    [string]$OutputFormat = 'CSV',

    [Parameter(Mandatory = $false, HelpMessage = "ISO currency code (default 'USD')")]
    [ValidateNotNullOrEmpty()]
    [string]$Currency = 'USD',

    [Parameter(ParameterSetName = 'Price', Mandatory = $false, HelpMessage = "Optional base name for the output file (no extension)")]
    [string]$OutputFileName,

    [Parameter(ParameterSetName = 'List', Mandatory = $true, HelpMessage = "List available plan SKUs in the region and exit")]
    [switch]$ListSkus
)

begin {

# ================================================================================
# CONSTANTS
# ================================================================================

$script:RetailApiBaseUri = 'https://prices.azure.com/api/retail/prices'
# Preview API version is required for the savingsPlan array to be returned.
$script:RetailApiVersion = '2023-01-01-preview'
$script:ServiceName      = 'Azure App Service'
$script:HoursPerYear     = 8760   # 365 * 24

# ================================================================================
# HELPER FUNCTIONS
# ================================================================================

function Invoke-RetailPriceQuery {
    <#
    .SYNOPSIS
        Calls the Azure Retail Prices API for a single OData filter, transparently following
        pagination and retrying throttled requests with exponential back-off.

    .PARAMETER Filter
        The OData $filter expression (unencoded).

    .PARAMETER Currency
        ISO currency code to request.

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

    .PARAMETER ScriptBlock
        The operation to execute.

    .PARAMETER MaxAttempts
        Maximum number of attempts before giving up (default 6).

    .PARAMETER BaseDelaySeconds
        Initial delay used for the exponential schedule (default 2 seconds).
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
            # failures that carry no HTTP status code (e.g. dropped/reset connections or
            # timeouts -- "An error occurred while sending the request"), which are common
            # when many requests are issued in quick succession.
            $isTransportError = ($null -eq $statusCode)
            $isRetryable = ($statusCode -eq 429) -or ($statusCode -ge 500 -and $statusCode -le 599) -or $isTransportError

            if (-not $isRetryable -or $attempt -eq $MaxAttempts) {
                throw
            }

            # Exponential back-off with jitter: base * 2^(attempt-1) + random(0..1s)
            $delay = $BaseDelaySeconds * [math]::Pow(2, $attempt - 1) + (Get-Random -Minimum 0.0 -Maximum 1.0)
            Write-Warning ("Request failed ({0}). Retry {1}/{2} in {3:N1}s..." -f `
                ($statusCode ? "HTTP $statusCode" : $_.Exception.Message), $attempt, $MaxAttempts, $delay)
            Start-Sleep -Seconds $delay
        }
    }
}

function Test-IsLinuxProduct {
    <#
    .SYNOPSIS
        Returns $true when a retail-price product represents the Linux variant of an App Service
        plan. Linux products are published with a ' - Linux' suffix on the productName; Windows
        plans carry no OS suffix.
    #>
    param([Parameter(Mandatory = $true)][string]$ProductName)
    return ($ProductName -match '(?i)\bLinux\b')
}

function Get-SkuPricing {
    <#
    .SYNOPSIS
        Resolves the PAYGO, Reserved Instance and Savings Plan effective hourly prices for a
        single App Service plan SKU and OS.

    .OUTPUTS
        [pscustomobject] with hourly rate properties (null when unavailable).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Sku,
        [Parameter(Mandatory = $true)][string]$Region,
        [Parameter(Mandatory = $true)][string]$OS,
        [Parameter(Mandatory = $true)][string]$Currency
    )

    $filter = "serviceName eq '$script:ServiceName' and armRegionName eq '$Region' and skuName eq '$Sku'"
    $items  = Invoke-RetailPriceQuery -Filter $filter -Currency $Currency

    # Constrain to genuine App Service plan meters for the requested OS. Pricing is OS-specific
    # for every purchase option, so both Consumption and Reservation meters are OS-filtered.
    $wantLinux = ($OS -eq 'Linux')
    $items = $items | Where-Object {
        $_.productName -match '^Azure App Service' -and
        ((Test-IsLinuxProduct -ProductName $_.productName) -eq $wantLinux)
    }

    # PAYGO consumption item (exclude Dev/Test consumption, which is a separate billing program).
    $paygItem = $items | Where-Object { $_.type -eq 'Consumption' } | Select-Object -First 1
    $payg = if ($paygItem) { [double]$paygItem.retailPrice } else { $null }

    # Savings Plan rates are attached to the PAYGO consumption item.
    $sp1 = $null; $sp3 = $null
    if ($paygItem -and $paygItem.savingsPlan) {
        $sp1Item = $paygItem.savingsPlan | Where-Object { $_.term -eq '1 Year' }  | Select-Object -First 1
        $sp3Item = $paygItem.savingsPlan | Where-Object { $_.term -eq '3 Years' } | Select-Object -First 1
        if ($sp1Item) { $sp1 = [double]$sp1Item.retailPrice }
        if ($sp3Item) { $sp3 = [double]$sp3Item.retailPrice }
    }

    # Reserved Instances: retailPrice is the full up-front term cost; convert to hourly.
    $resItems = $items | Where-Object { $_.type -eq 'Reservation' }
    $res1Item = $resItems | Where-Object { $_.reservationTerm -eq '1 Year'  } | Select-Object -First 1
    $res3Item = $resItems | Where-Object { $_.reservationTerm -eq '3 Years' } | Select-Object -First 1

    $res1 = if ($res1Item) { [double]$res1Item.retailPrice / $script:HoursPerYear } else { $null }
    $res3 = if ($res3Item) { [double]$res3Item.retailPrice / ($script:HoursPerYear * 3) } else { $null }

    return [pscustomobject]@{
        Sku         = $Sku
        ProductName = if ($paygItem) { $paygItem.productName } else { $null }
        Payg        = $payg
        Res1        = $res1
        Res3        = $res3
        Sav1        = $sp1
        Sav3        = $sp3
    }
}

function Get-AvailableSku {
    <#
    .SYNOPSIS
        Returns the distinct App Service plan SKUs available in a region for the requested OS,
        with the PAYGO hourly price for each (used by -ListSkus discovery mode).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Region,
        [Parameter(Mandatory = $true)][string]$OS,
        [Parameter(Mandatory = $true)][string]$Currency
    )

    $filter = "serviceName eq '$script:ServiceName' and armRegionName eq '$Region' and type eq 'Consumption'"
    $items  = Invoke-RetailPriceQuery -Filter $filter -Currency $Currency

    $wantLinux = ($OS -eq 'Linux')
    $items |
        Where-Object {
            $_.productName -match '^Azure App Service' -and
            ((Test-IsLinuxProduct -ProductName $_.productName) -eq $wantLinux)
        } |
        Sort-Object skuName, productName -Unique |
        ForEach-Object {
            [pscustomobject]@{
                SKU         = $_.skuName
                ProductName = $_.productName
                'PAYGO/hr'  = [math]::Round([double]$_.retailPrice, 5)
                MeterName   = $_.meterName
            }
        } | Sort-Object 'PAYGO/hr'
}

function Format-Rate {
    param([object]$Value, [int]$Decimals = 5)
    if ($null -eq $Value) { return 'N/A' }
    return [math]::Round([double]$Value, $Decimals)
}

function Get-DiscountPct {
    param([object]$Payg, [object]$Rate)
    if ($null -eq $Payg -or $null -eq $Rate -or $Payg -eq 0) { return $null }
    return [math]::Round((1 - ([double]$Rate / [double]$Payg)) * 100, 1)
}

# ================================================================================
# MAIN
# ================================================================================

    # Discovery mode: list available plan SKUs and exit.
    if ($PSCmdlet.ParameterSetName -eq 'List') {
        Write-Host "Discovering App Service plan SKUs in '$Region' ($OS, $Currency)..." -ForegroundColor Cyan
        $available = Get-AvailableSku -Region $Region -OS $OS -Currency $Currency
        if (-not $available) {
            Write-Warning "No App Service plan SKUs found in '$Region' for $OS. Verify the region name."
        }
        else {
            $available | Format-Table -AutoSize | Out-Host
            Write-Host ("{0} plan SKU(s) found. Re-run with -Skus '<name>' -ACD <pct> to price them." -f @($available).Count) -ForegroundColor Green
        }
        return
    }

    Write-Host "Querying Azure Retail Prices API in '$Region' ($OS, $Currency)..." -ForegroundColor Cyan
    $results = [System.Collections.Generic.List[object]]::new()
}

process {

    if ($PSCmdlet.ParameterSetName -eq 'List') { return }

    foreach ($sku in $Skus) {
        Write-Host "  - $sku" -ForegroundColor Gray
        try {
            $pricing = Get-SkuPricing -Sku $sku -Region $Region -OS $OS -Currency $Currency
        }
        catch {
            Write-Warning "Failed to retrieve pricing for '$sku': $($_.Exception.Message)"
            $pricing = [pscustomobject]@{ Sku = $sku; ProductName = $null; Payg = $null; Res1 = $null; Res3 = $null; Sav1 = $null; Sav3 = $null }
        }

        if ($null -eq $pricing.Payg) {
            Write-Warning "No PAYGO price found for '$sku' ($OS) in '$Region'. Verify the SKU name (try -ListSkus) and region."
        }

        $acdPrice = if ($null -ne $pricing.Payg) { [math]::Round($pricing.Payg * (1 - $ACD / 100.0), 5) } else { $null }

        $results.Add([pscustomobject]@{
            Sku       = $pricing.Sku
            Payg      = $pricing.Payg
            Acd       = $acdPrice
            Res1      = $pricing.Res1
            Res3      = $pricing.Res3
            Sav1      = $pricing.Sav1
            Sav3      = $pricing.Sav3
        })
    }

}

end {

if ($PSCmdlet.ParameterSetName -eq 'List') { return }

# Resolve output path.
$outputDir = Join-Path -Path $PSScriptRoot -ChildPath 'output'
if (-not (Test-Path -Path $outputDir)) {
    New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
}

if ([string]::IsNullOrWhiteSpace($OutputFileName)) {
    $OutputFileName = "AppServicePricing_{0}_{1}" -f $Region, (Get-Date -Format 'yyyyMMdd')
}

if ($OutputFormat -eq 'Markdown') {
    # ----------------------------------------------------------------------------
    # Markdown output: dressed up with discount percentages and best-value flags.
    # ----------------------------------------------------------------------------
    $outFile = Join-Path -Path $outputDir -ChildPath "$OutputFileName.md"
    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.AppendLine("# Azure App Service Pricing Comparison")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("- **Region:** ``$Region``")
    [void]$sb.AppendLine("- **Operating System:** $OS")
    [void]$sb.AppendLine("- **Currency:** $Currency")
    [void]$sb.AppendLine("- **ACD (Azure Commitment Discount):** $ACD% off PAYGO")
    [void]$sb.AppendLine("- **Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') (local)")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("> All prices are **effective hourly rates**. Reserved Instance term costs are normalized to hourly (term cost / hours in term). Percentages in parentheses are the discount versus PAYGO.")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("| SKU | PAYGO | ACD ($ACD%) | 1 Year Res. | 3 Year Res. | 1 Year Sav. | 3 Year Sav. | Best Value |")
    [void]$sb.AppendLine("|-----|------:|------:|------:|------:|------:|------:|:----------:|")

    # Renders a Markdown price cell with the discount percentage versus PAYGO in parentheses.
    function MdCell {
        param([object]$Payg, [object]$Rate, [string]$FixedPct)
        if ($null -eq $Rate) { return 'N/A' }
        $rate = Format-Rate $Rate
        if ($FixedPct) {
            return "$rate ($FixedPct)"
        }
        $pct = Get-DiscountPct -Payg $Payg -Rate $Rate
        if ($null -ne $pct) { return "$rate ($pct%)" }
        return "$rate"
    }

    foreach ($r in $results) {
        # Determine the best (lowest) priced option among all the discounted choices.
        $options = @(
            @{ Name = 'PAYGO';       Rate = $r.Payg },
            @{ Name = "ACD";         Rate = $r.Acd },
            @{ Name = '1Yr Reserved';Rate = $r.Res1 },
            @{ Name = '3Yr Reserved';Rate = $r.Res3 },
            @{ Name = '1Yr Savings'; Rate = $r.Sav1 },
            @{ Name = '3Yr Savings'; Rate = $r.Sav3 }
        ) | Where-Object { $null -ne $_.Rate }

        $best = if ($options.Count -gt 0) { ($options | Sort-Object { [double]$_.Rate } | Select-Object -First 1).Name } else { 'N/A' }

        $paygCell = if ($null -ne $r.Payg) { Format-Rate $r.Payg } else { 'N/A' }
        $acdCell  = MdCell -Payg $r.Payg -Rate $r.Acd  -FixedPct "$ACD%"
        $res1Cell = MdCell -Payg $r.Payg -Rate $r.Res1
        $res3Cell = MdCell -Payg $r.Payg -Rate $r.Res3
        $sav1Cell = MdCell -Payg $r.Payg -Rate $r.Sav1
        $sav3Cell = MdCell -Payg $r.Payg -Rate $r.Sav3

        [void]$sb.AppendLine("| **$($r.Sku)** | $paygCell | $acdCell | $res1Cell | $res3Cell | $sav1Cell | $sav3Cell | $best |")
    }

    [void]$sb.AppendLine()
    [void]$sb.AppendLine("_Source: Azure Retail Prices API (api-version $script:RetailApiVersion). App Service plan prices are OS-specific and are subject to change._")

    $sb.ToString() | Out-File -FilePath $outFile -Encoding utf8
}
else {
    # ----------------------------------------------------------------------------
    # CSV output (default).
    # ----------------------------------------------------------------------------
    $outFile = Join-Path -Path $outputDir -ChildPath "$OutputFileName.csv"

    $csvRows = foreach ($r in $results) {
        [pscustomobject]@{
            'SKU'         = $r.Sku
            'PAYGO'       = Format-Rate $r.Payg
            "ACD"         = Format-Rate $r.Acd
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
