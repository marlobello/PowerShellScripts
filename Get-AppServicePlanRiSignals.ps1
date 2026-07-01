#Requires -Version 7.0

<#
.SYNOPSIS
    Inventories App Service Plans across one or more subscriptions and diagnoses why Azure
    Advisor may recommend fewer Reserved Instances (RIs) than current consumption suggests.

.DESCRIPTION
    For every App Service Plan (Microsoft.Web/serverfarms) in the requested subscriptions the
    script collects:
      - Plan SKU / tier / worker (capacity) count and Linux/Windows platform
      - Child Web Apps / Function Apps hosted on the plan
      - Manual scale settings and per-app scaling clues
      - Azure Monitor autoscale settings (min/default/max capacity and rules)
      - Lookback-window daily average CPU, memory, HTTP queue length and data in/out
      - Lookback-window hourly instance-count baseline (incl. % of hours above the floor)
      - Azure Advisor cost / RI recommendation details (recommended quantity, term, look-back,
        estimated savings) parsed from the recommendation ExtendedProperty
      - Existing App Service reservations already owned (via Az.Reservations, when available)

    It then performs an RI GAP ANALYSIS per plan that compares the steady-state baseline to
    Advisor's recommended quantity and the reservations you already own, and classifies WHY the
    Advisor number is what it is. Common reasons Advisor recommends fewer RIs than raw
    consumption implies:
      - Existing reservations already cover the baseline (Advisor nets them out)
      - Usage is bursty / autoscaled, so only the consistently-running floor is reservable
      - Advisor's look-back window differs from the window analyzed here
      - The plan tier/SKU is not RI-eligible (only Premium v3 / Isolated v2 qualify)

    A single result row is emitted per App Service Plan. Output is written to the ./output/
    directory relative to the script (the directory, *.csv are git-ignored). Use
    -OutputFormat Markdown for a findings report that explains each plan's RI gap.

    Reserved Instances for App Service apply to Premium v3 (Pv3) and Isolated v2 (Iv2) plans,
    and are billed at the subscription / region / SKU level rather than per individual plan, so
    recommendations and reservations are correlated to plans heuristically by region + SKU.

.PARAMETER SubscriptionIds
    One or more subscription GUIDs to inventory. The current Az context account must have
    Reader access to each subscription.

.PARAMETER LookbackDays
    Number of days of metric history to analyze for the baseline signals. Default 30 to align
    with Azure Advisor's default reservation look-back window.

.PARAMETER OutputFormat
    Output report format: 'CSV' (default) or 'Markdown'. Markdown produces a human-readable RI
    gap findings report; CSV produces one row per plan for further analysis.

.PARAMETER OutputFileName
    Optional base name for the output file (no path). The correct extension (.csv or .md) is
    appended if missing. Defaults to AppServicePlanRiSignals_<yyyyMMdd-HHmmss>.

.PARAMETER RiEligibleOnly
    Restricts output to App Service RI-eligible plans only - Premium v3 (Pv3) and Isolated v2
    (Iv2). Defaults to $true. Pass -RiEligibleOnly:$false to inventory every plan (useful for
    spotting upgrade candidates on non-eligible tiers).

.PARAMETER VerboseMetricDiscovery
    When set, logs the metric definitions discovered for each plan to aid troubleshooting.

.EXAMPLE
    $subs = @(
      "00000000-0000-0000-0000-000000000000",
      "11111111-1111-1111-1111-111111111111"
    )
    .\Get-AppServicePlanRiSignals.ps1 -SubscriptionIds $subs -OutputFormat Markdown

    Inventories both subscriptions and writes a Markdown RI gap findings report under ./output/.

.EXAMPLE
    .\Get-AppServicePlanRiSignals.ps1 -SubscriptionIds $subs -RiEligibleOnly:$false -LookbackDays 60

    Analyzes ALL plans (not just RI-eligible tiers) using a 60-day baseline window.

.NOTES
    Requires PowerShell 7+ and an existing Azure sign-in (Connect-AzAccount). The required Az
    modules (Az.Accounts, Az.Resources, Az.Monitor, Az.Websites, Az.Advisor) and the optional
    Az.Reservations module are installed (CurrentUser scope) and imported automatically if missing.

    RI recommendations and reservations are usually subscription/SKU/region/scope level, not
    per App Service Plan. This script correlates them to plans by region + SKU tokens.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]] $SubscriptionIds,

    [Parameter(Mandatory = $false)]
    [int] $LookbackDays = 30,

    [Parameter(Mandatory = $false)]
    [ValidateSet("CSV", "Markdown")]
    [string] $OutputFormat = "CSV",

    [Parameter(Mandatory = $false)]
    [string] $OutputFileName,

    [Parameter(Mandatory = $false)]
    [bool] $RiEligibleOnly = $true,

    [Parameter(Mandatory = $false)]
    [switch] $VerboseMetricDiscovery
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# -----------------------------
# Helper functions
# -----------------------------

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Initialize-RequiredModule {
    # Ensures each module is installed (CurrentUser scope) and imported. Required modules abort
    # the script on failure; optional modules only warn so the script can still run degraded.
    param(
        [string[]]$RequiredModules,
        [string[]]$OptionalModules = @()
    )

    # Ensure the NuGet provider and a trusted gallery so Install-Module never prompts.
    try {
        if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
            Write-Info "Installing NuGet package provider (CurrentUser scope)..."
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
        }
    }
    catch {
        Write-Warn "Could not bootstrap NuGet provider automatically. $($_.Exception.Message)"
    }

    $targets = @()
    foreach ($m in $RequiredModules) { $targets += [pscustomobject]@{ Name = $m; Required = $true } }
    foreach ($m in $OptionalModules) { $targets += [pscustomobject]@{ Name = $m; Required = $false } }

    foreach ($entry in $targets) {
        $name = $entry.Name

        if (Get-Module -Name $name) { continue }

        if (-not (Get-Module -ListAvailable -Name $name)) {
            Write-Info "Module $name not found; installing (CurrentUser scope)..."
            try {
                Install-Module -Name $name -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -ErrorAction Stop
            }
            catch {
                $msg = "Failed to install module $name. $($_.Exception.Message)"
                if ($entry.Required) { throw $msg } else { Write-Warn $msg; continue }
            }
        }

        try {
            Import-Module -Name $name -ErrorAction Stop
        }
        catch {
            $msg = "Failed to import module $name. $($_.Exception.Message)"
            if ($entry.Required) { throw $msg } else { Write-Warn $msg }
        }
    }
}

function Get-SafeProperty {
    param(
        [object]$Object,
        [string]$PropertyName
    )

    if ($null -eq $Object) { return $null }

    $prop = $Object.PSObject.Properties[$PropertyName]
    if ($null -ne $prop) {
        return $prop.Value
    }

    return $null
}

function ConvertTo-CompactJson {
    param([object]$Object)

    if ($null -eq $Object) { return $null }

    try {
        return ($Object | ConvertTo-Json -Depth 20 -Compress)
    }
    catch {
        return $null
    }
}

function ConvertTo-Hashtable {
    param([object]$Object)

    $ht = @{}
    if ($null -eq $Object) { return $ht }

    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            $ht["$key"] = $Object[$key]
        }
        return $ht
    }

    foreach ($prop in $Object.PSObject.Properties) {
        $ht[$prop.Name] = $prop.Value
    }
    return $ht
}

function Get-FirstHashValue {
    param(
        [hashtable]$Hash,
        [string[]]$CandidateKeys
    )

    if ($null -eq $Hash -or $Hash.Count -eq 0) { return $null }

    foreach ($candidate in $CandidateKeys) {
        foreach ($key in $Hash.Keys) {
            if ($key -ieq $candidate -and $null -ne $Hash[$key] -and "$($Hash[$key])".Trim() -ne "") {
                return $Hash[$key]
            }
        }
    }
    return $null
}

function ConvertTo-DelimitedString {
    param(
        [object[]]$Items,
        [string]$Separator = "; "
    )

    if ($null -eq $Items -or $Items.Count -eq 0) {
        return $null
    }

    return ($Items | Where-Object { $_ } | ForEach-Object { "$_" }) -join $Separator
}

function Get-ResourceGroupFromId {
    param([string]$ResourceId)

    if ([string]::IsNullOrWhiteSpace($ResourceId)) {
        return $null
    }

    $match = [regex]::Match($ResourceId, "/resourceGroups/([^/]+)", "IgnoreCase")
    if ($match.Success) {
        return $match.Groups[1].Value
    }

    return $null
}

function ConvertTo-NormalizedSku {
    param([string]$SkuName)

    if ([string]::IsNullOrWhiteSpace($SkuName)) {
        return $null
    }

    # Normalize common forms:
    # P3v3, P3V3, PremiumV3 P3v3, Standard_P3_v3, etc.
    $s = $SkuName.ToUpperInvariant()
    $s = $s -replace "_", ""
    $s = $s -replace "-", ""
    $s = $s -replace "STANDARD", ""
    $s = $s -replace "PREMIUMV3", ""
    $s = $s.Trim()

    return $s
}

function Get-PlanPlatformLabel {
    param([object]$PlanResource)

    # Microsoft.Web/serverfarms property "reserved" is generally true for Linux App Service Plans.
    $reserved = Get-SafeProperty -Object $PlanResource.Properties -PropertyName "reserved"

    if ($reserved -eq $true) {
        return "Linux"
    }
    elseif ($reserved -eq $false) {
        return "Windows"
    }
    else {
        return "Unknown"
    }
}

function Get-AppKindLabel {
    param([object]$App)

    $kind = Get-SafeProperty -Object $App -PropertyName "Kind"
    if ([string]::IsNullOrWhiteSpace($kind)) {
        $kind = Get-SafeProperty -Object $App -PropertyName "kind"
    }

    if ([string]::IsNullOrWhiteSpace($kind)) {
        return "Unknown"
    }

    return $kind
}

function Get-AvailableMetricNames {
    param([string]$ResourceId)

    try {
        $defs = Get-AzMetricDefinition -ResourceId $ResourceId -ErrorAction Stop
        return @($defs | ForEach-Object { $_.Name.Value })
    }
    catch {
        Write-Warn "Could not read metric definitions for $ResourceId. $($_.Exception.Message)"
        return @()
    }
}

function Resolve-MetricName {
    param(
        [string[]]$AvailableMetricNames,
        [string[]]$CandidateNames
    )

    foreach ($candidate in $CandidateNames) {
        $match = $AvailableMetricNames | Where-Object { $_ -ieq $candidate } | Select-Object -First 1
        if ($match) { return $match }
    }

    return $null
}

function Get-MetricDailyStats {
    param(
        [string]$ResourceId,
        [string]$MetricName,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [timespan]$TimeGrain = ([TimeSpan]::FromDays(1))
    )

    if ([string]::IsNullOrWhiteSpace($MetricName)) {
        return [pscustomobject]@{
            MetricName = $null
            Avg       = $null
            Min       = $null
            Max       = $null
            Points    = 0
        }
    }

    try {
        $metric = Get-AzMetric `
            -ResourceId $ResourceId `
            -MetricName $MetricName `
            -TimeGrain $TimeGrain `
            -StartTime $StartTime `
            -EndTime $EndTime `
            -AggregationType Average `
            -ErrorAction Stop

        $values = @(
            $metric.Data |
                Where-Object { $null -ne $_.Average } |
                ForEach-Object { [double]$_.Average }
        )

        if ($values.Count -eq 0) {
            return [pscustomobject]@{
                MetricName = $MetricName
                Avg       = $null
                Min       = $null
                Max       = $null
                Points    = 0
            }
        }

        return [pscustomobject]@{
            MetricName = $MetricName
            Avg       = [math]::Round(($values | Measure-Object -Average).Average, 2)
            Min       = [math]::Round(($values | Measure-Object -Minimum).Minimum, 2)
            Max       = [math]::Round(($values | Measure-Object -Maximum).Maximum, 2)
            Points    = $values.Count
        }
    }
    catch {
        Write-Warn "Metric query failed for $MetricName on $ResourceId. $($_.Exception.Message)"
        return [pscustomobject]@{
            MetricName = $MetricName
            Avg       = $null
            Min       = $null
            Max       = $null
            Points    = 0
        }
    }
}

function Get-Percentile {
    param(
        [double[]]$SortedValues,
        [double]$Percentile
    )

    if ($SortedValues.Count -eq 0) { return $null }
    if ($SortedValues.Count -eq 1) { return $SortedValues[0] }

    $rank = ($Percentile / 100) * ($SortedValues.Count - 1)
    $lower = [math]::Floor($rank)
    $upper = [math]::Ceiling($rank)

    if ($lower -eq $upper) {
        return $SortedValues[$lower]
    }

    $weight = $rank - $lower
    return ($SortedValues[$lower] * (1 - $weight)) + ($SortedValues[$upper] * $weight)
}

function Get-MetricHourlyBaseline {
    param(
        [string]$ResourceId,
        [string]$MetricName,
        [datetime]$StartTime,
        [datetime]$EndTime
    )

    if ([string]::IsNullOrWhiteSpace($MetricName)) {
        return [pscustomobject]@{
            MetricName            = $null
            HourlyAvg             = $null
            HourlyMin             = $null
            HourlyMax             = $null
            HourlyP05             = $null
            HourlyP50             = $null
            HourlyP95             = $null
            HoursWithMetricValue  = 0
            PctHoursAboveBaseline = $null
        }
    }

    try {
        $metric = Get-AzMetric `
            -ResourceId $ResourceId `
            -MetricName $MetricName `
            -TimeGrain ([TimeSpan]::FromHours(1)) `
            -StartTime $StartTime `
            -EndTime $EndTime `
            -AggregationType Average `
            -ErrorAction Stop

        $values = @(
            $metric.Data |
                Where-Object { $null -ne $_.Average } |
                ForEach-Object { [double]$_.Average } |
                Sort-Object
        )

        if ($values.Count -eq 0) {
            return [pscustomobject]@{
                MetricName            = $MetricName
                HourlyAvg             = $null
                HourlyMin             = $null
                HourlyMax             = $null
                HourlyP05             = $null
                HourlyP50             = $null
                HourlyP95             = $null
                HoursWithMetricValue  = 0
                PctHoursAboveBaseline = $null
            }
        }

        # Floor = integer baseline the steady minimum sits at (~p05). The share of hours
        # running strictly above that floor signals bursty / autoscaled usage that Advisor
        # will NOT reserve, which is a primary reason its RI count looks low vs peak usage.
        $p05   = Get-Percentile -SortedValues $values -Percentile 5
        $floor = [math]::Floor([double]$p05)
        $hoursAbove = @($values | Where-Object { $_ -gt $floor }).Count
        $pctAbove = [math]::Round(($hoursAbove / $values.Count) * 100, 1)

        return [pscustomobject]@{
            MetricName            = $MetricName
            HourlyAvg             = [math]::Round(($values | Measure-Object -Average).Average, 2)
            HourlyMin             = [math]::Round(($values | Measure-Object -Minimum).Minimum, 2)
            HourlyMax             = [math]::Round(($values | Measure-Object -Maximum).Maximum, 2)
            HourlyP05             = [math]::Round($p05, 2)
            HourlyP50             = [math]::Round((Get-Percentile -SortedValues $values -Percentile 50), 2)
            HourlyP95             = [math]::Round((Get-Percentile -SortedValues $values -Percentile 95), 2)
            HoursWithMetricValue  = $values.Count
            PctHoursAboveBaseline = $pctAbove
        }
    }
    catch {
        Write-Warn "Hourly metric query failed for $MetricName on $ResourceId. $($_.Exception.Message)"
        return [pscustomobject]@{
            MetricName            = $MetricName
            HourlyAvg             = $null
            HourlyMin             = $null
            HourlyMax             = $null
            HourlyP05             = $null
            HourlyP50             = $null
            HourlyP95             = $null
            HoursWithMetricValue  = 0
            PctHoursAboveBaseline = $null
        }
    }
}

function Get-AutoscaleSettingsForPlan {
    param(
        [string]$PlanResourceId,
        [object[]]$AllAutoscaleSettings
    )

    if ([string]::IsNullOrWhiteSpace($PlanResourceId)) {
        return @()
    }

    $normalizedPlanId = $PlanResourceId.ToLowerInvariant()

    return @(
        $AllAutoscaleSettings | Where-Object {
            $target = Get-SafeProperty -Object $_.Properties -PropertyName "targetResourceUri"
            $target -and ($target.ToLowerInvariant() -eq $normalizedPlanId)
        }
    )
}

function Get-AutoscaleSummary {
    param([object[]]$AutoscaleSettings)

    if ($null -eq $AutoscaleSettings -or $AutoscaleSettings.Count -eq 0) {
        return [pscustomobject]@{
            HasAzureMonitorAutoscale = $false
            AutoscaleSettingNames    = $null
            AutoscaleEnabledStates   = $null
            AutoscaleProfiles        = $null
            AutoscaleMinCapacity     = $null
            AutoscaleDefaultCapacity = $null
            AutoscaleMaxCapacity     = $null
            AutoscaleRuleSummary     = $null
        }
    }

    $profileSummaries = New-Object System.Collections.Generic.List[string]
    $ruleSummaries = New-Object System.Collections.Generic.List[string]
    $mins = New-Object System.Collections.Generic.List[int]
    $defs = New-Object System.Collections.Generic.List[int]
    $maxs = New-Object System.Collections.Generic.List[int]

    foreach ($setting in $AutoscaleSettings) {
        $profiles = Get-SafeProperty -Object $setting.Properties -PropertyName "profiles"

        foreach ($profile in @($profiles)) {
            $profileName = Get-SafeProperty -Object $profile -PropertyName "name"
            $capacity = Get-SafeProperty -Object $profile -PropertyName "capacity"
            $rules = Get-SafeProperty -Object $profile -PropertyName "rules"

            $min = Get-SafeProperty -Object $capacity -PropertyName "minimum"
            $default = Get-SafeProperty -Object $capacity -PropertyName "default"
            $max = Get-SafeProperty -Object $capacity -PropertyName "maximum"

            if ($min -match "^\d+$") { $mins.Add([int]$min) }
            if ($default -match "^\d+$") { $defs.Add([int]$default) }
            if ($max -match "^\d+$") { $maxs.Add([int]$max) }

            $profileSummaries.Add("$profileName min=$min default=$default max=$max rules=$(@($rules).Count)")

            foreach ($rule in @($rules)) {
                $metricTrigger = Get-SafeProperty -Object $rule -PropertyName "metricTrigger"
                $scaleAction = Get-SafeProperty -Object $rule -PropertyName "scaleAction"

                $metricName = Get-SafeProperty -Object $metricTrigger -PropertyName "metricName"
                $operator = Get-SafeProperty -Object $metricTrigger -PropertyName "operator"
                $threshold = Get-SafeProperty -Object $metricTrigger -PropertyName "threshold"
                $direction = Get-SafeProperty -Object $scaleAction -PropertyName "direction"
                $type = Get-SafeProperty -Object $scaleAction -PropertyName "type"
                $value = Get-SafeProperty -Object $scaleAction -PropertyName "value"
                $cooldown = Get-SafeProperty -Object $scaleAction -PropertyName "cooldown"

                $ruleSummaries.Add("$metricName $operator $threshold => $direction $type $value cooldown=$cooldown")
            }
        }
    }

    return [pscustomobject]@{
        HasAzureMonitorAutoscale = $true
        AutoscaleSettingNames    = ConvertTo-DelimitedString -Items ($AutoscaleSettings | ForEach-Object { $_.Name })
        AutoscaleEnabledStates   = ConvertTo-DelimitedString -Items ($AutoscaleSettings | ForEach-Object { Get-SafeProperty -Object $_.Properties -PropertyName "enabled" })
        AutoscaleProfiles        = ConvertTo-DelimitedString -Items $profileSummaries
        AutoscaleMinCapacity     = if ($mins.Count -gt 0) { ($mins | Measure-Object -Minimum).Minimum } else { $null }
        AutoscaleDefaultCapacity = if ($defs.Count -gt 0) { [math]::Round(($defs | Measure-Object -Average).Average, 2) } else { $null }
        AutoscaleMaxCapacity     = if ($maxs.Count -gt 0) { ($maxs | Measure-Object -Maximum).Maximum } else { $null }
        AutoscaleRuleSummary     = ConvertTo-DelimitedString -Items $ruleSummaries
    }
}

function Get-AdvisorRecommendationsForSubscription {
    param([string]$SubscriptionId)

    try {
        $recs = @(Get-AzAdvisorRecommendation -SubscriptionId $SubscriptionId -Category Cost -ErrorAction Stop)

        # Keep RI-ish and App Service-ish cost recommendations, but don't over-filter.
        $filtered = @(
            $recs | Where-Object {
                $text = @(
                    (Get-SafeProperty -Object $_ -PropertyName "ShortDescriptionProblem")
                    (Get-SafeProperty -Object $_ -PropertyName "ShortDescriptionSolution")
                    (Get-SafeProperty -Object $_ -PropertyName "ImpactedField")
                    (Get-SafeProperty -Object $_ -PropertyName "ImpactedValue")
                    (Get-SafeProperty -Object $_ -PropertyName "RecommendationTypeId")
                    (ConvertTo-CompactJson (Get-SafeProperty -Object $_ -PropertyName "Metadata"))
                    (ConvertTo-CompactJson (Get-SafeProperty -Object $_ -PropertyName "ExtendedProperty"))
                ) -join " "

                $text -match "reserved|reservation|reserved instance|App Service|serverfarm|Premium|P[0-9]"
            }
        )

        return $filtered
    }
    catch {
        Write-Warn "Could not retrieve Advisor cost recommendations for subscription $SubscriptionId. $($_.Exception.Message)"
        return @()
    }
}

function Get-AdvisorMatchesForPlan {
    param(
        [object[]]$AdvisorRecommendations,
        [object]$PlanResource,
        [string]$SkuName,
        [string]$Location,
        [string]$Platform
    )

    if ($null -eq $AdvisorRecommendations -or $AdvisorRecommendations.Count -eq 0) {
        return @()
    }

    $normalizedSku = ConvertTo-NormalizedSku -SkuName $SkuName
    $normalizedLocation = if ($Location) { $Location.ToLowerInvariant() } else { $null }
    $normalizedPlatform = if ($Platform) { $Platform.ToLowerInvariant() } else { $null }

    $recMatches = New-Object System.Collections.Generic.List[object]

    foreach ($rec in $AdvisorRecommendations) {
        $extProps = ConvertTo-Hashtable -Object (Get-SafeProperty -Object $rec -PropertyName "ExtendedProperty")
        $metaProps = Get-SafeProperty -Object $rec -PropertyName "Metadata"

        $blob = @(
            (Get-SafeProperty -Object $rec -PropertyName "ShortDescriptionProblem")
            (Get-SafeProperty -Object $rec -PropertyName "ShortDescriptionSolution")
            (Get-SafeProperty -Object $rec -PropertyName "ImpactedField")
            (Get-SafeProperty -Object $rec -PropertyName "ImpactedValue")
            (Get-SafeProperty -Object $rec -PropertyName "RecommendationTypeId")
            (ConvertTo-CompactJson $metaProps)
            (ConvertTo-CompactJson $extProps)
        ) -join " "

        $normalizedBlob = $blob.ToUpperInvariant() -replace "_", "" -replace "-", ""

        $score = 0

        if ($normalizedSku -and $normalizedBlob.Contains($normalizedSku)) {
            $score += 5
        }

        if ($normalizedLocation -and ($blob.ToLowerInvariant() -match [regex]::Escape($normalizedLocation))) {
            $score += 2
        }

        if ($normalizedPlatform -and ($blob.ToLowerInvariant() -match [regex]::Escape($normalizedPlatform))) {
            $score += 1
        }

        # If the recommendation is resource-specific and points at this plan, score hard.
        $planId = $PlanResource.ResourceId
        if ($planId -and ($blob.ToLowerInvariant() -match [regex]::Escape($planId.ToLowerInvariant()))) {
            $score += 10
        }

        if ($score -gt 0) {
            # Pull Advisor's actual recommended quantity / term / savings from ExtendedProperty.
            $recQtyRaw = Get-FirstHashValue -Hash $extProps -CandidateKeys @("qty", "quantity", "reservationQuantity", "displayQty", "recommendedQuantity")
            $recQty = $null
            if ("$recQtyRaw" -match "^\d+(\.\d+)?$") { $recQty = [int][math]::Round([double]$recQtyRaw) }

            $recMatches.Add([pscustomobject]@{
                    Score                = $score
                    RecommendationId     = Get-SafeProperty -Object $rec -PropertyName "Name"
                    Impact               = Get-SafeProperty -Object $rec -PropertyName "Impact"
                    ImpactedField        = Get-SafeProperty -Object $rec -PropertyName "ImpactedField"
                    ImpactedValue        = Get-SafeProperty -Object $rec -PropertyName "ImpactedValue"
                    RecommendationTypeId = Get-SafeProperty -Object $rec -PropertyName "RecommendationTypeId"
                    Problem              = Get-SafeProperty -Object $rec -PropertyName "ShortDescriptionProblem"
                    Solution             = Get-SafeProperty -Object $rec -PropertyName "ShortDescriptionSolution"
                    LastUpdated          = Get-SafeProperty -Object $rec -PropertyName "LastUpdated"
                    RecommendedQuantity  = $recQty
                    RecommendedSku       = Get-FirstHashValue -Hash $extProps -CandidateKeys @("displaySKU", "sku", "displaySku", "reservedResourceType")
                    RecommendedRegion    = Get-FirstHashValue -Hash $extProps -CandidateKeys @("region", "location", "displayLocation")
                    Term                 = Get-FirstHashValue -Hash $extProps -CandidateKeys @("term", "displayTerm")
                    LookbackDays         = Get-FirstHashValue -Hash $extProps -CandidateKeys @("lookbackPeriod", "lookBackPeriod", "displayLookbackPeriod")
                    Scope                = Get-FirstHashValue -Hash $extProps -CandidateKeys @("scope", "displayScope", "appliedScopeType")
                    EstimatedSavings     = Get-FirstHashValue -Hash $extProps -CandidateKeys @("savingsAmount", "annualSavingsAmount", "costSaving", "savingsCurrency")
                    ExtendedProperties   = ConvertTo-CompactJson $extProps
                })
        }
    }

    return @($recMatches | Sort-Object Score -Descending)
}

function Get-RiInterpretation {
    param(
        [string]$SkuName,
        [string]$Tier,
        [int]$CurrentCapacity,
        [object]$InstanceBaseline,
        [bool]$HasAutoscale,
        [int]$AutoscaleMin,
        [int]$AutoscaleMax,
        [object[]]$AdvisorMatches
    )

    $notes = New-Object System.Collections.Generic.List[string]

    if ($Tier -notmatch "Premium|Isolated") {
        $notes.Add("Non-Premium/Isolated tier; App Service RI eligibility may not apply.")
    }

    if ($SkuName -notmatch "P\d") {
        $notes.Add("SKU does not look like a Premium P-series SKU.")
    }

    if ($HasAutoscale) {
        $notes.Add("Azure Monitor autoscale exists; RI sizing should anchor to steady minimum/baseline, not peak scale-out.")
        if ($null -ne $AutoscaleMin -and $null -ne $AutoscaleMax) {
            $notes.Add("Autoscale range observed: min=$AutoscaleMin max=$AutoscaleMax.")
        }
    }
    else {
        $notes.Add("No Azure Monitor autoscale setting found for the plan; current worker capacity may be the steady baseline unless automatic scaling/per-app scaling is in use.")
    }

    if ($null -ne $InstanceBaseline -and $null -ne $InstanceBaseline.HourlyMin) {
        $notes.Add("Observed hourly capacity baseline: min=$($InstanceBaseline.HourlyMin) p05=$($InstanceBaseline.HourlyP05) p50=$($InstanceBaseline.HourlyP50) max=$($InstanceBaseline.HourlyMax) over $($InstanceBaseline.HoursWithMetricValue)h.")

        $steadyFloor = $null
        if ($null -ne $InstanceBaseline.HourlyP05) {
            $steadyFloor = [int][math]::Floor([double]$InstanceBaseline.HourlyP05)
        }
        if ($null -ne $steadyFloor -and $steadyFloor -ge 1) {
            $notes.Add("Suggested RI quantity floor (~p05 of observed capacity): $steadyFloor instance(s) of $SkuName.")
        }
    }
    elseif ($CurrentCapacity -ge 1) {
        $notes.Add("No instance-count baseline metric available; current capacity ($CurrentCapacity) is the best steady-state proxy for RI quantity.")
    }

    if ($null -ne $AdvisorMatches -and $AdvisorMatches.Count -gt 0) {
        $top = $AdvisorMatches | Select-Object -First 1
        $notes.Add("Azure Advisor cost recommendation correlated (score=$($top.Score)): $($top.Problem)")
    }
    else {
        $notes.Add("No correlated Azure Advisor cost/RI recommendation found for this plan.")
    }

    return (ConvertTo-DelimitedString -Items $notes)
}

function Get-AppServiceReservations {
    # Returns normalized reservation records relevant to App Service (Premium v3 / Isolated v2).
    # Requires the optional Az.Reservations module; returns @() (with a warning) if unavailable.
    $records = New-Object System.Collections.Generic.List[object]

    if (-not (Get-Module -ListAvailable -Name Az.Reservations)) {
        Write-Warn "Az.Reservations module not installed; existing reservations will not be evaluated. Install with: Install-Module Az.Reservations -Scope CurrentUser"
        return @()
    }

    try {
        Import-Module Az.Reservations -ErrorAction Stop
        $reservations = @(Get-AzReservation -ErrorAction Stop)
    }
    catch {
        Write-Warn "Could not enumerate reservations. $($_.Exception.Message)"
        return @()
    }

    foreach ($r in $reservations) {
        $state = "$(Get-SafeProperty -Object $r -PropertyName 'ProvisioningState')"
        if ([string]::IsNullOrWhiteSpace($state)) { $state = "$(Get-SafeProperty -Object $r -PropertyName 'DisplayProvisioningState')" }

        $resourceType = "$(Get-SafeProperty -Object $r -PropertyName 'ReservedResourceType')"

        $skuRaw = Get-SafeProperty -Object $r -PropertyName 'SkuName'
        if ($null -eq $skuRaw) {
            $skuObj = Get-SafeProperty -Object $r -PropertyName 'Sku'
            $skuRaw = if ($skuObj -is [string]) { $skuObj } else { Get-SafeProperty -Object $skuObj -PropertyName 'Name' }
        }

        $qtyRaw = Get-SafeProperty -Object $r -PropertyName 'Quantity'
        if ($null -eq $qtyRaw) {
            $prop = Get-SafeProperty -Object $r -PropertyName 'Property'
            $qtyRaw = Get-SafeProperty -Object $prop -PropertyName 'Quantity'
        }
        $qty = 0
        if ("$qtyRaw" -match "^\d+(\.\d+)?$") { $qty = [int][math]::Round([double]$qtyRaw) }

        $region = "$(Get-SafeProperty -Object $r -PropertyName 'Location')"
        if ([string]::IsNullOrWhiteSpace($region)) { $region = "$(Get-SafeProperty -Object $r -PropertyName 'Region')" }

        $normalizedSku = ConvertTo-NormalizedSku -SkuName "$skuRaw"

        # Keep only App Service-ish reservations.
        $isAppService = ($resourceType -match "AppService|App Service") -or ($normalizedSku -match "P\d")
        if (-not $isAppService) { continue }

        $records.Add([pscustomobject]@{
                DisplayName          = "$(Get-SafeProperty -Object $r -PropertyName 'DisplayName')"
                SkuName              = "$skuRaw"
                NormalizedSku        = $normalizedSku
                Region               = $region.ToLowerInvariant()
                Quantity             = $qty
                Term                 = "$(Get-SafeProperty -Object $r -PropertyName 'Term')"
                AppliedScopeType     = "$(Get-SafeProperty -Object $r -PropertyName 'AppliedScopeType')"
                ProvisioningState    = $state
                ReservedResourceType = $resourceType
            })
    }

    return @($records)
}

function Get-PlanReservedQuantity {
    param(
        [object[]]$Reservations,
        [string]$NormalizedSku,
        [string]$Region
    )

    if ($null -eq $Reservations -or $Reservations.Count -eq 0 -or [string]::IsNullOrWhiteSpace($NormalizedSku)) {
        return 0
    }

    $regionLc = if ($Region) { $Region.ToLowerInvariant() } else { $null }
    $sum = 0
    foreach ($r in $Reservations) {
        if ($r.ProvisioningState -and ($r.ProvisioningState -notmatch "Succeeded")) { continue }
        $skuMatch = $r.NormalizedSku -and ($r.NormalizedSku -eq $NormalizedSku -or $r.NormalizedSku.Contains($NormalizedSku) -or $NormalizedSku.Contains($r.NormalizedSku))
        $regionMatch = (-not $regionLc) -or (-not $r.Region) -or ($r.Region -eq $regionLc)
        if ($skuMatch -and $regionMatch) { $sum += [int]$r.Quantity }
    }
    return $sum
}

function Get-RiGapAnalysis {
    param(
        [string]$SkuName,
        [string]$Tier,
        [int]$CurrentCapacity,
        [object]$InstanceBaseline,
        [bool]$HasAutoscale,
        [object]$TopAdvisor,
        [int]$ReservedQuantity,
        [bool]$ReservationsEvaluated,
        [int]$LookbackDays
    )

    # Steady baseline = the consistently-running instance count Advisor will reserve. Prefer the
    # observed hourly p05 (autoscale); otherwise fall back to the current fixed capacity.
    $steadyBaseline = $CurrentCapacity
    $baselineSource = "current fixed capacity"
    if ($null -ne $InstanceBaseline -and $null -ne $InstanceBaseline.HourlyP05) {
        $steadyBaseline = [int][math]::Floor([double]$InstanceBaseline.HourlyP05)
        $baselineSource = "observed hourly p05 capacity"
    }
    if ($steadyBaseline -lt 0) { $steadyBaseline = 0 }

    $advisorQty = if ($TopAdvisor -and $null -ne $TopAdvisor.RecommendedQuantity) { [int]$TopAdvisor.RecommendedQuantity } else { $null }

    # Reservable steady demand not already covered by owned reservations.
    $uncovered = $steadyBaseline - $ReservedQuantity
    if ($uncovered -lt 0) { $uncovered = 0 }

    # Gap between what steady demand justifies and what Advisor is recommending.
    $gap = $null
    if ($null -ne $advisorQty) {
        $gap = $uncovered - $advisorQty
        if ($gap -lt 0) { $gap = 0 }
    }

    $reasons = New-Object System.Collections.Generic.List[string]

    $isEligible = ($Tier -match "Premium|Isolated") -and ($SkuName -match "P\dv3|I\dv2|P\d")
    if (-not $isEligible) {
        $reasons.Add("Plan tier/SKU '$Tier/$SkuName' is not App Service RI-eligible (only Premium v3 / Isolated v2 qualify), so Advisor will not recommend RIs for it.")
    }

    if ($ReservationsEvaluated -and $ReservedQuantity -gt 0) {
        $reasons.Add("You already own ~$ReservedQuantity matching reservation instance(s) for this SKU/region; Advisor nets these out, lowering its recommended quantity.")
    }
    elseif (-not $ReservationsEvaluated) {
        $reasons.Add("Existing reservations were not evaluated (Az.Reservations unavailable); already-owned RIs are the most common reason Advisor recommends fewer than consumption implies.")
    }

    if ($null -ne $InstanceBaseline -and $null -ne $InstanceBaseline.PctHoursAboveBaseline) {
        $pct = $InstanceBaseline.PctHoursAboveBaseline
        if ($pct -ge 25) {
            $reasons.Add("Usage is bursty/autoscaled: ~$pct% of hours run above the steady floor ($steadyBaseline). Advisor reserves only the consistently-running floor, not peak/burst capacity, so its count looks low vs peak consumption.")
        }
        else {
            $reasons.Add("Usage is fairly steady: only ~$pct% of hours run above the floor ($steadyBaseline), so the baseline is a sound RI target.")
        }
    }

    if ($HasAutoscale) {
        $reasons.Add("Autoscale is enabled; sizing should anchor to the steady minimum, not the autoscale maximum.")
    }

    if ($null -ne $advisorQty) {
        if ($gap -gt 0) {
            $advLb = if ($TopAdvisor) { $TopAdvisor.LookbackDays } else { $null }
            $reasons.Add("Steady demand justifies ~$uncovered uncovered RI(s) but Advisor recommends $advisorQty (gap of $gap). Compare Advisor look-back ($advLb) vs analyzed window ($LookbackDays days) and reservation scope.")
        }
        else {
            $reasons.Add("Advisor's recommended quantity ($advisorQty) meets or exceeds uncovered steady demand ($uncovered); no shortfall detected.")
        }
    }
    else {
        $reasons.Add("No Advisor reservation quantity was found for this plan; the steady baseline suggests ~$uncovered reservable instance(s) of $SkuName after existing reservations.")
    }

    return [pscustomobject]@{
        SteadyBaselineInstances = $steadyBaseline
        BaselineSource          = $baselineSource
        AdvisorRecommendedQty   = $advisorQty
        ReservedQuantity        = $ReservedQuantity
        UncoveredSteadyDemand   = $uncovered
        AdvisorVsDemandGap      = $gap
        RiEligible              = $isEligible
        GapReason               = (ConvertTo-DelimitedString -Items $reasons)
    }
}

function Write-MarkdownReport {
    param(
        [object[]]$Results,
        [string]$Path,
        [int]$LookbackDays,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [bool]$ReservationsEvaluated
    )

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# App Service Plan - Reserved Instance Gap Findings")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("- Generated: $(Get-Date -Format 'u')")
    [void]$sb.AppendLine("- Lookback window: $($StartTime.ToString('u')) -> $($EndTime.ToString('u')) ($LookbackDays days)")
    [void]$sb.AppendLine("- Existing reservations evaluated: $ReservationsEvaluated")
    [void]$sb.AppendLine("- Plans analyzed: $($Results.Count)")
    [void]$sb.AppendLine()

    [void]$sb.AppendLine("## Overview")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("| Plan | SKU | Tier | Region | Current | Baseline | Reserved | Advisor Qty | Uncovered | Gap |")
    [void]$sb.AppendLine("|------|-----|------|--------|--------:|---------:|---------:|------------:|----------:|----:|")
    foreach ($r in $Results) {
        $reserved = if ($ReservationsEvaluated) { "$($r.EstimatedReservedQuantity)" } else { "n/a" }
        $advQty   = if ($null -ne $r.RecommendedRiQuantity) { "$($r.RecommendedRiQuantity)" } else { "-" }
        $gapTxt   = if ($null -ne $r.AdvisorVsDemandGap) { "$($r.AdvisorVsDemandGap)" } else { "-" }
        [void]$sb.AppendLine("| $($r.PlanName) | $($r.SkuName) | $($r.Tier) | $($r.Location) | $($r.Capacity) | $($r.SteadyBaselineInstances) | $reserved | $advQty | $($r.UncoveredSteadyDemand) | $gapTxt |")
    }
    [void]$sb.AppendLine()

    [void]$sb.AppendLine("## Per-plan findings")
    [void]$sb.AppendLine()
    $ordered = $Results | Sort-Object @{ Expression = { if ($null -ne $_.AdvisorVsDemandGap) { $_.AdvisorVsDemandGap } else { -1 } }; Descending = $true }
    foreach ($r in $ordered) {
        [void]$sb.AppendLine("### $($r.PlanName)  ($($r.SkuName), $($r.Location))")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("- Subscription: ``$($r.SubscriptionId)``")
        [void]$sb.AppendLine("- Tier / platform: $($r.Tier) / $($r.Platform); RI-eligible: $($r.RiEligible)")
        [void]$sb.AppendLine("- Current capacity: $($r.Capacity); steady baseline: $($r.SteadyBaselineInstances) (from $($r.BaselineSource))")
        $pctTxt = if ($null -ne $r.PctHoursAboveBaseline) { "$($r.PctHoursAboveBaseline)%" } else { "n/a" }
        [void]$sb.AppendLine("- Hours above floor: $pctTxt; autoscale: $($r.HasAutoscale)")
        $resTxt = if ($ReservationsEvaluated) { "$($r.EstimatedReservedQuantity)" } else { "not evaluated" }
        [void]$sb.AppendLine("- Existing reservations (est.): $resTxt")
        $advQtyTxt = if ($null -ne $r.RecommendedRiQuantity) { "$($r.RecommendedRiQuantity)" } else { "none found" }
        [void]$sb.AppendLine("- Advisor recommended qty: $advQtyTxt; term: $($r.RiTerm); Advisor look-back: $($r.AdvisorLookbackDays)")
        $gapTxt2 = if ($null -ne $r.AdvisorVsDemandGap) { "$($r.AdvisorVsDemandGap)" } else { "-" }
        [void]$sb.AppendLine("- Uncovered steady demand: $($r.UncoveredSteadyDemand); Advisor-vs-demand gap: $gapTxt2")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("**Why Advisor's RI number looks the way it does:**")
        [void]$sb.AppendLine()
        foreach ($reason in (($r.RiGapReason -split "; ") | Where-Object { $_ })) {
            [void]$sb.AppendLine("- $reason")
        }
        [void]$sb.AppendLine()
    }

    $sb.ToString() | Out-File -FilePath $Path -Encoding utf8 -Force
}

# -----------------------------
# Main execution
# -----------------------------

$scriptStart = Get-Date
$endTime     = $scriptStart.ToUniversalTime()
$startTime   = $endTime.AddDays(-[math]::Abs($LookbackDays))

# Ensure required (and optional) Az modules are installed and imported.
Initialize-RequiredModule `
    -RequiredModules @("Az.Accounts", "Az.Resources", "Az.Monitor", "Az.Websites", "Az.Advisor") `
    -OptionalModules @("Az.Reservations")

# Verify Azure context
$azContext = Get-AzContext -ErrorAction SilentlyContinue
if ($null -eq $azContext -or $null -eq $azContext.Account) {
    throw "No Azure context found. Please run Connect-AzAccount before running this script."
}
Write-Info "Using Azure context: $($azContext.Account.Id) (Tenant: $($azContext.Tenant.TenantId))"
Write-Info "Lookback window: $($startTime.ToString('u')) -> $($endTime.ToString('u')) ($LookbackDays day(s))"

# Prepare output directory (./output/ is git-ignored)
$outputDir = Join-Path $PSScriptRoot "output"
try {
    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -ErrorAction Stop | Out-Null
        Write-Info "Created output directory: $outputDir"
    }
}
catch {
    throw "Failed to create output directory '$outputDir': $($_.Exception.Message)"
}

$timestamp = $scriptStart.ToString("yyyyMMdd-HHmmss")
$extension = if ($OutputFormat -eq "Markdown") { ".md" } else { ".csv" }
$outName = if ($OutputFileName) {
    $base = $OutputFileName.Trim()
    if ($base -notlike "*$extension") { "$base$extension" } else { $base }
}
else {
    "AppServicePlanRiSignals_$timestamp$extension"
}
$outputPath = Join-Path $outputDir $outName

# Existing reservations (tenant-visible) - fetched once; optional Az.Reservations module.
$reservationsEvaluated = $null -ne (Get-Module -ListAvailable -Name Az.Reservations)
$reservations = @(Get-AppServiceReservations)
if ($reservationsEvaluated) {
    Write-Info "Found $($reservations.Count) App Service-relevant reservation(s) to net against demand."
}

$results = [System.Collections.Generic.List[object]]::new()

$subIndex = 0
foreach ($subId in $SubscriptionIds) {
    $subIndex++
    Write-Progress -Activity "Inventorying App Service Plans" -Id 0 `
        -Status "Subscription $subIndex of $($SubscriptionIds.Count): $subId" `
        -PercentComplete (($subIndex / [math]::Max($SubscriptionIds.Count, 1)) * 100)

    try {
        Set-AzContext -SubscriptionId $subId -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Warn "Could not set context to subscription $subId. $($_.Exception.Message)"
        continue
    }

    Write-Info "Processing subscription $subId"

    # App Service Plans (serverfarms) with expanded ARM properties
    $plans = @()
    try {
        $plans = @(Get-AzResource -ResourceType "Microsoft.Web/serverfarms" -ExpandProperties -ErrorAction Stop)
    }
    catch {
        Write-Warn "Could not enumerate App Service Plans in $subId. $($_.Exception.Message)"
        continue
    }

    if ($plans.Count -eq 0) {
        Write-Info "No App Service Plans found in subscription $subId."
        continue
    }

    # All web/function apps in the subscription (filtered per-plan below)
    $allApps = @()
    try {
        $allApps = @(Get-AzWebApp -ErrorAction Stop)
    }
    catch {
        Write-Warn "Could not enumerate Web Apps in $subId. $($_.Exception.Message)"
    }

    # All autoscale settings in the subscription (raw ARM shape)
    $allAutoscale = @()
    try {
        $allAutoscale = @(Get-AzResource -ResourceType "Microsoft.Insights/autoscaleSettings" -ExpandProperties -ErrorAction Stop)
    }
    catch {
        Write-Warn "Could not enumerate autoscale settings in $subId. $($_.Exception.Message)"
    }

    # Advisor cost recommendations for the subscription
    $advisorRecs = @(Get-AdvisorRecommendationsForSubscription -SubscriptionId $subId)

    $planIndex = 0
    foreach ($plan in $plans) {
        $planIndex++
        $planName = $plan.Name
        Write-Progress -Activity "Plans in $subId" -Id 1 -ParentId 0 `
            -Status "$planIndex of $($plans.Count): $planName" `
            -PercentComplete (($planIndex / [math]::Max($plans.Count, 1)) * 100)

        $sku        = Get-SafeProperty -Object $plan -PropertyName "Sku"
        $skuName    = Get-SafeProperty -Object $sku -PropertyName "Name"
        $tier       = Get-SafeProperty -Object $sku -PropertyName "Tier"
        $capacity   = Get-SafeProperty -Object $sku -PropertyName "Capacity"
        $capacityInt = 0
        if ("$capacity" -match "^\d+$") { $capacityInt = [int]$capacity }

        if ($RiEligibleOnly) {
            $isRiEligible = ($tier -match "PremiumV3|IsolatedV2") -or ($skuName -match "^(P\w*v3|I\dv2)$")
            if (-not $isRiEligible) { continue }
        }

        $platform      = Get-PlanPlatformLabel -PlanResource $plan
        $resourceGroup = if ($plan.ResourceGroupName) { $plan.ResourceGroupName } else { Get-ResourceGroupFromId -ResourceId $plan.ResourceId }

        $props             = Get-SafeProperty -Object $plan -PropertyName "Properties"
        $numberOfWorkers   = Get-SafeProperty -Object $props -PropertyName "numberOfWorkers"
        $perSiteScaling    = Get-SafeProperty -Object $props -PropertyName "perSiteScaling"
        $maxElasticWorkers = Get-SafeProperty -Object $props -PropertyName "maximumElasticWorkerCount"
        $zoneRedundant     = Get-SafeProperty -Object $props -PropertyName "zoneRedundant"

        # Child apps hosted on this plan
        $planApps = @(
            $allApps | Where-Object {
                $sfId = Get-SafeProperty -Object $_ -PropertyName "ServerFarmId"
                $sfId -and ($sfId.ToLowerInvariant() -eq $plan.ResourceId.ToLowerInvariant())
            }
        )
        $webAppCount      = @($planApps | Where-Object { (Get-AppKindLabel -App $_) -notmatch "functionapp" }).Count
        $functionAppCount = @($planApps | Where-Object { (Get-AppKindLabel -App $_) -match "functionapp" }).Count
        $appNames         = ConvertTo-DelimitedString -Items ($planApps | ForEach-Object { $_.Name })

        # Autoscale
        $planAutoscale    = @(Get-AutoscaleSettingsForPlan -PlanResourceId $plan.ResourceId -AllAutoscaleSettings $allAutoscale)
        $autoscaleSummary = Get-AutoscaleSummary -AutoscaleSettings $planAutoscale

        # Metric discovery + collection
        $availableMetrics = Get-AvailableMetricNames -ResourceId $plan.ResourceId
        if ($VerboseMetricDiscovery) {
            Write-Info "Metrics for $planName`: $($availableMetrics -join ', ')"
        }

        $cpuMetric      = Resolve-MetricName -AvailableMetricNames $availableMetrics -CandidateNames @("CpuPercentage")
        $memMetric      = Resolve-MetricName -AvailableMetricNames $availableMetrics -CandidateNames @("MemoryPercentage")
        $httpQMetric    = Resolve-MetricName -AvailableMetricNames $availableMetrics -CandidateNames @("HttpQueueLength")
        $bytesInMetric  = Resolve-MetricName -AvailableMetricNames $availableMetrics -CandidateNames @("BytesReceived")
        $bytesOutMetric = Resolve-MetricName -AvailableMetricNames $availableMetrics -CandidateNames @("BytesSent")

        $cpuStats   = Get-MetricDailyStats -ResourceId $plan.ResourceId -MetricName $cpuMetric      -StartTime $startTime -EndTime $endTime
        $memStats   = Get-MetricDailyStats -ResourceId $plan.ResourceId -MetricName $memMetric      -StartTime $startTime -EndTime $endTime
        $httpQStats = Get-MetricDailyStats -ResourceId $plan.ResourceId -MetricName $httpQMetric    -StartTime $startTime -EndTime $endTime
        $bytesIn    = Get-MetricDailyStats -ResourceId $plan.ResourceId -MetricName $bytesInMetric  -StartTime $startTime -EndTime $endTime
        $bytesOut   = Get-MetricDailyStats -ResourceId $plan.ResourceId -MetricName $bytesOutMetric -StartTime $startTime -EndTime $endTime

        # Instance-count baseline from autoscale ObservedCapacity, where autoscale exists
        $instanceBaseline = $null
        if ($planAutoscale.Count -gt 0) {
            $autoscaleResourceId = $planAutoscale[0].ResourceId
            $instanceBaseline = Get-MetricHourlyBaseline -ResourceId $autoscaleResourceId -MetricName "ObservedCapacity" -StartTime $startTime -EndTime $endTime
        }

        # Advisor correlation
        $advisorMatches = @(Get-AdvisorMatchesForPlan -AdvisorRecommendations $advisorRecs -PlanResource $plan -SkuName $skuName -Location $plan.Location -Platform $platform)
        $topAdvisor     = $advisorMatches | Select-Object -First 1

        # Existing reservations covering this SKU/region (already-owned RIs Advisor nets out)
        $normalizedPlanSku = ConvertTo-NormalizedSku -SkuName $skuName
        $reservedQty = Get-PlanReservedQuantity -Reservations $reservations -NormalizedSku $normalizedPlanSku -Region $plan.Location

        # RI gap analysis: baseline vs Advisor recommendation vs owned reservations + reason
        $gapAnalysis = Get-RiGapAnalysis `
            -SkuName $skuName `
            -Tier $tier `
            -CurrentCapacity $capacityInt `
            -InstanceBaseline $instanceBaseline `
            -HasAutoscale ([bool]$autoscaleSummary.HasAzureMonitorAutoscale) `
            -TopAdvisor $topAdvisor `
            -ReservedQuantity ([int]$reservedQty) `
            -ReservationsEvaluated $reservationsEvaluated `
            -LookbackDays $LookbackDays

        # RI interpretation heuristic
        $riInterpretation = Get-RiInterpretation `
            -SkuName $skuName `
            -Tier $tier `
            -CurrentCapacity $capacityInt `
            -InstanceBaseline $instanceBaseline `
            -HasAutoscale ([bool]$autoscaleSummary.HasAzureMonitorAutoscale) `
            -AutoscaleMin ([int]($autoscaleSummary.AutoscaleMinCapacity)) `
            -AutoscaleMax ([int]($autoscaleSummary.AutoscaleMaxCapacity)) `
            -AdvisorMatches $advisorMatches

        $results.Add([pscustomobject]@{
                SubscriptionId            = $subId
                ResourceGroup             = $resourceGroup
                PlanName                  = $planName
                Location                  = $plan.Location
                Platform                  = $platform
                SkuName                   = $skuName
                Tier                      = $tier
                Capacity                  = $capacityInt
                NumberOfWorkers           = $numberOfWorkers
                PerSiteScaling            = $perSiteScaling
                MaximumElasticWorkerCount = $maxElasticWorkers
                ZoneRedundant             = $zoneRedundant
                WebAppCount               = $webAppCount
                FunctionAppCount          = $functionAppCount
                HostedApps                = $appNames
                HasAutoscale              = $autoscaleSummary.HasAzureMonitorAutoscale
                AutoscaleMinCapacity      = $autoscaleSummary.AutoscaleMinCapacity
                AutoscaleDefaultCapacity  = $autoscaleSummary.AutoscaleDefaultCapacity
                AutoscaleMaxCapacity      = $autoscaleSummary.AutoscaleMaxCapacity
                AutoscaleRuleSummary      = $autoscaleSummary.AutoscaleRuleSummary
                CpuAvgPct                 = $cpuStats.Avg
                CpuMaxPct                 = $cpuStats.Max
                MemoryAvgPct              = $memStats.Avg
                MemoryMaxPct              = $memStats.Max
                HttpQueueAvg              = $httpQStats.Avg
                HttpQueueMax              = $httpQStats.Max
                BytesReceivedAvg          = $bytesIn.Avg
                BytesSentAvg              = $bytesOut.Avg
                InstanceBaselineMin       = if ($instanceBaseline) { $instanceBaseline.HourlyMin } else { $null }
                InstanceBaselineP05       = if ($instanceBaseline) { $instanceBaseline.HourlyP05 } else { $null }
                InstanceBaselineP50       = if ($instanceBaseline) { $instanceBaseline.HourlyP50 } else { $null }
                InstanceBaselineP95       = if ($instanceBaseline) { $instanceBaseline.HourlyP95 } else { $null }
                InstanceBaselineMax       = if ($instanceBaseline) { $instanceBaseline.HourlyMax } else { $null }
                PctHoursAboveBaseline     = if ($instanceBaseline) { $instanceBaseline.PctHoursAboveBaseline } else { $null }
                SteadyBaselineInstances   = $gapAnalysis.SteadyBaselineInstances
                BaselineSource            = $gapAnalysis.BaselineSource
                EstimatedReservedQuantity = $reservedQty
                RecommendedRiQuantity     = if ($topAdvisor) { $topAdvisor.RecommendedQuantity } else { $null }
                RiTerm                    = if ($topAdvisor) { $topAdvisor.Term } else { $null }
                AdvisorLookbackDays       = if ($topAdvisor) { $topAdvisor.LookbackDays } else { $null }
                EstimatedRiSavings        = if ($topAdvisor) { $topAdvisor.EstimatedSavings } else { $null }
                UncoveredSteadyDemand     = $gapAnalysis.UncoveredSteadyDemand
                AdvisorVsDemandGap        = $gapAnalysis.AdvisorVsDemandGap
                RiEligible                = $gapAnalysis.RiEligible
                RiGapReason               = $gapAnalysis.GapReason
                AdvisorMatchCount         = $advisorMatches.Count
                TopAdvisorScore           = if ($topAdvisor) { $topAdvisor.Score } else { $null }
                TopAdvisorProblem         = if ($topAdvisor) { $topAdvisor.Problem } else { $null }
                TopAdvisorSolution        = if ($topAdvisor) { $topAdvisor.Solution } else { $null }
                RiInterpretation          = $riInterpretation
                PlanResourceId            = $plan.ResourceId
            })
    }
    Write-Progress -Activity "Plans in $subId" -Id 1 -ParentId 0 -Completed
}
Write-Progress -Activity "Inventorying App Service Plans" -Id 0 -Completed

if ($results.Count -eq 0) {
    Write-Warn "No App Service Plans were inventoried. Verify subscription access and -RiEligibleOnly filtering (pass -RiEligibleOnly:`$false to include all tiers)."
    return
}

if ($OutputFormat -eq "Markdown") {
    Write-MarkdownReport -Results $results -Path $outputPath -LookbackDays $LookbackDays -StartTime $startTime -EndTime $endTime -ReservationsEvaluated $reservationsEvaluated
    Write-Info "Wrote Markdown RI gap report for $($results.Count) plan(s) to: $outputPath"
}
else {
    $results | Export-Csv -Path $outputPath -NoTypeInformation -Force
    Write-Info "Wrote $($results.Count) plan row(s) to: $outputPath"
}

# Console summary
Write-Host "`nSummary by Tier:" -ForegroundColor Cyan
$results |
    Group-Object Tier |
    Select-Object Name, Count |
    Sort-Object Count -Descending |
    Format-Table -AutoSize

$withAdvisor = @($results | Where-Object { $_.AdvisorMatchCount -gt 0 }).Count
Write-Host "Plans with correlated Advisor cost recommendations: $withAdvisor of $($results.Count)" -ForegroundColor Cyan

if (-not $reservationsEvaluated) {
    Write-Warn "Existing reservations were NOT evaluated (Az.Reservations not installed). Already-owned RIs are the most common reason Advisor recommends fewer than consumption implies. Install with: Install-Module Az.Reservations -Scope CurrentUser"
}

$gapPlans = @($results | Where-Object { $null -ne $_.AdvisorVsDemandGap -and $_.AdvisorVsDemandGap -gt 0 })
if ($gapPlans.Count -gt 0) {
    Write-Host "`nPlans where steady demand exceeds Advisor's RI recommendation (potential under-reservation):" -ForegroundColor Yellow
    $gapPlans |
        Sort-Object AdvisorVsDemandGap -Descending |
        Select-Object PlanName, SkuName, Location, SteadyBaselineInstances, EstimatedReservedQuantity, RecommendedRiQuantity, AdvisorVsDemandGap |
        Format-Table -AutoSize
}

return $results