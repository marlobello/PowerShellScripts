#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Compute, Az.Resources, Az.ResourceGraph

<#
.SYNOPSIS
    Analyzes Azure VM quota usage (granted vs. used) across multiple subscriptions with
    logical-to-physical availability zone translation and outputs a Markdown report.

.DESCRIPTION
    This script queries Azure VM quota usage across subscriptions defined by a Management
    Group or an explicit subscription list. For each CPU family and region requested, it
    reports quota utilization and maps each subscription's logical availability zones to
    the underlying physical zones.

    The core question this report answers is: "How much of my quota am I using, and where?"
    This information helps customers decide whether to create an Azure Quota Group (shared
    quota pool) or request additional quota for a specific subscription.

    Output is a timestamped Markdown file written to the ./output/ directory relative to
    the script location. The output/ directory is excluded from git via .gitignore.

.PARAMETER ManagementGroup
    A single Management Group object (from Get-AzManagementGroup) or a Management Group
    name/ID string. All subscriptions within the group are enumerated recursively.
    Mutually exclusive with -Subscriptions.

.PARAMETER Subscriptions
    One or more Subscription objects (from Get-AzSubscription) or subscription ID strings.
    Mutually exclusive with -ManagementGroup.

.PARAMETER CpuFamilies
    One or more CPU family identifiers. Accepts:
      - Exact Azure API family name strings (e.g. 'standardDSv5Family', 'standardESv5Family')
      - PSResourceSku objects from Get-AzComputeResourceSku (the Family property is extracted)
    Multiple families can be passed as an array or as a comma-separated string.

.PARAMETER Region
    The Azure region to analyze (e.g. 'eastus', 'westeurope'). Only one region is
    supported per run to keep the report focused.

.PARAMETER Threads
    Number of parallel threads for processing subscriptions. Default is 4.
    Set to 0 for auto-detection based on CPU count. Maximum is 40.

.EXAMPLE
    .\Get-AzQuotaUsageReport.ps1 -ManagementGroup "MyMG" -CpuFamilies "standardDSv5Family" -Region "eastus"

    Analyzes DSv5 quota in eastus for all subscriptions under the MyMG management group.

.EXAMPLE
    $subs = Get-AzSubscription | Where-Object { $_.Name -like "Prod-*" }
    .\Get-AzQuotaUsageReport.ps1 -Subscriptions $subs -CpuFamilies "standardDSv5Family","standardESv5Family" -Region "westeurope"

    Analyzes DSv5 and ESv5 quota in westeurope for all matching Production subscriptions.

.EXAMPLE
    $skus = Get-AzComputeResourceSku -Location "eastus" | Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Family -like '*Dv5*' }
    .\Get-AzQuotaUsageReport.ps1 -Subscriptions "00000000-0000-0000-0000-000000000000" -CpuFamilies $skus -Region "eastus"

    Uses PSResourceSku objects to define which CPU families to analyze.

.NOTES
    Requirements:
      - PowerShell 7.0 or later (ForEach-Object -Parallel support)
      - Az.Accounts, Az.Compute, Az.Resources modules
      - Reader access to all target subscriptions
      - Reader access to the Management Group (when using -ManagementGroup)

    Output file: ./output/QuotaReport_{region}_{yyyyMMdd}.md
#>

[CmdletBinding(DefaultParameterSetName = 'BySubscription')]
param (
    [Parameter(Mandatory = $true, ParameterSetName = 'ByManagementGroup',
               HelpMessage = "A single Management Group object (from Get-AzManagementGroup) or name/ID string")]
    [object]$ManagementGroup,

    [Parameter(Mandatory = $true, ParameterSetName = 'BySubscription',
               HelpMessage = "Subscription object(s) from Get-AzSubscription or subscription ID string(s)")]
    [object[]]$Subscriptions,

    [Parameter(Mandatory = $true, HelpMessage = "CPU family name string(s) (e.g. 'standardDSv5Family') or PSResourceSku objects")]
    [object[]]$CpuFamilies,

    [Parameter(Mandatory = $true, HelpMessage = "Single Azure region to analyze (e.g. 'eastus')")]
    [string]$Region,

    [Parameter(Mandatory = $false, HelpMessage = "Parallel threads (0 = auto-detect, max 40)")]
    [ValidateRange(0, 40)]
    [int]$Threads = 4
)

# ================================================================================
# HELPER FUNCTIONS
# ================================================================================

<#
.SYNOPSIS
    Recursively extracts subscription IDs from a Management Group tree node.

.DESCRIPTION
    Traverses the Children of a Management Group object returned by
    Get-AzManagementGroup -Expand -Recurse. Each child is either a subscription
    (Type matching '*/subscriptions') or a nested management group. This function
    recurses into nested groups to collect all subscription IDs in the hierarchy.

.PARAMETER Node
    A Management Group node object with a Children property (e.g. the result of
    Get-AzManagementGroup -Expand -Recurse, or a child node within that result).

.OUTPUTS
    Array of subscription ID strings found anywhere in the subtree.
#>
function Get-SubscriptionsFromNode {
    param (
        [object]$Node,
        [System.Collections.Generic.HashSet[string]]$Accumulator
    )

    if ($null -eq $Node.Children) { return }

    foreach ($child in $Node.Children) {
        if ($child.Type -like "*/subscriptions") {
            $Accumulator.Add($child.Name) | Out-Null
        } elseif ($child.Type -like "*managementGroups") {
            Get-SubscriptionsFromNode -Node $child -Accumulator $Accumulator
        }
    }
}

<#
.SYNOPSIS
    Resolves a mixed collection of Management Group and Subscription inputs to a
    flat, deduplicated list of subscription IDs.

.DESCRIPTION
    Accepts Management Group objects/strings and Subscription objects/strings in any
    combination. Management Groups are expanded recursively to collect all subscriptions
    beneath them. Subscription objects have their ID extracted. String values for
    subscriptions are used directly as IDs. Returns a deduplicated list.

.PARAMETER ManagementGroupInput
    Array of Management Group objects (PSManagementGroup) or name/ID strings.

.PARAMETER SubscriptionInput
    Array of Subscription objects (PSAzureSubscription) or subscription ID strings.

.OUTPUTS
    Deduplicated array of subscription ID strings.
#>
function Resolve-Subscriptions {
    param (
        [object[]]$ManagementGroupInput,
        [object[]]$SubscriptionInput
    )

    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($item in $ManagementGroupInput) {
        $mgId = if ($item -is [string]) {
            $item
        } elseif ($null -ne $item.Name) {
            $item.Name
        } else {
            Write-Warning "Unable to resolve Management Group from input: $item"
            continue
        }

        Write-Host "  Expanding Management Group: $mgId"
        try {
            $mgTree = Get-AzManagementGroup -GroupName $mgId -Expand -Recurse -ErrorAction Stop
            Get-SubscriptionsFromNode -Node $mgTree -Accumulator $ids
        } catch {
            Write-Warning "Failed to expand Management Group '$mgId': $($_.Exception.Message)"
        }
    }

    foreach ($item in $SubscriptionInput) {
        $subId = if ($item -is [string]) {
            $item
        } elseif ($null -ne $item.Id) {
            $item.Id
        } elseif ($null -ne $item.SubscriptionId) {
            $item.SubscriptionId
        } else {
            Write-Warning "Unable to resolve subscription ID from input: $item"
            continue
        }

        $ids.Add($subId) | Out-Null
    }

    return @($ids)
}

<#
.SYNOPSIS
    Normalizes a mixed collection of CPU family inputs to a flat, deduplicated
    list of family name strings.

.DESCRIPTION
    Accepts exact Azure API family name strings (e.g. 'standardDSv5Family') or
    PSResourceSku objects (from Get-AzComputeResourceSku). For SKU objects, the
    Family property is extracted. Comma-separated strings are split and trimmed.
    Returns a deduplicated list of family name strings.

.PARAMETER FamilyInput
    Array of CPU family name strings or PSResourceSku objects.

.OUTPUTS
    Deduplicated array of CPU family name strings.
#>
function Resolve-CpuFamilies {
    param (
        [object[]]$FamilyInput
    )

    $seen     = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $families = [System.Collections.Generic.List[string]]::new()

    foreach ($item in $FamilyInput) {
        if ($item -is [string]) {
            foreach ($part in ($item -split ',')) {
                $trimmed = $part.Trim()
                if ($trimmed -and $seen.Add($trimmed)) {
                    $families.Add($trimmed)
                }
            }
        } elseif ($null -ne $item.Family) {
            $family = $item.Family
            if ($family -and $seen.Add($family)) {
                $families.Add($family)
            }
        } else {
            Write-Warning "Unable to resolve CPU family from input: $item"
        }
    }

    return @($families)
}

<#
.SYNOPSIS
    Queries the Microsoft.Quota REST API for VM family quota in a specific subscription
    and region.

.DESCRIPTION
    The Microsoft.Quota extension API uses the ARM child-provider pattern:
      {scope}/providers/Microsoft.Quota/quotas   — returns limits only
      {scope}/providers/Microsoft.Quota/usages   — returns current usage only

    Both endpoints are called and merged by name so callers get a complete object
    with both Limit and CurrentValue, in the same shape as the Get-AzVMUsage
    expanded output.

    Key difference from Get-AzVMUsage: name/localizedValue live under
    properties.name.value / properties.name.localizedValue (not at root).
    The outer entry.name is a plain string (the resource name), not an object.

.PARAMETER SubscriptionId
    The Azure subscription ID to query.

.PARAMETER Region
    The Azure region to query (e.g. 'eastus').

.PARAMETER ResourceManagerUrl
    Base URL of the Azure Resource Manager endpoint for the current cloud.

.OUTPUTS
    Array of PSCustomObjects with Value, LocalizedValue, CurrentValue, and Limit —
    same shape as the Get-AzVMUsage expanded output. Returns empty array on failure
    or when the subscription has no compute quota in the region.
#>
function Get-QuotaFromApi {
    param (
        [string]$SubscriptionId,
        [string]$Region,
        [string]$ResourceManagerUrl
    )

    try {
        $scope = "subscriptions/$SubscriptionId/providers/Microsoft.Compute/locations/$Region"
        $base  = "{0}{1}/providers/Microsoft.Quota" -f $ResourceManagerUrl, $scope

        # Fetch limits and usages from their separate endpoints and merge by name key
        $quotaResp  = Invoke-AzRest -Method GET -Uri "$base/quotas?api-version=2023-02-01" -ErrorAction SilentlyContinue
        $usageResp  = Invoke-AzRest -Method GET -Uri "$base/usages?api-version=2023-02-01"  -ErrorAction SilentlyContinue

        $quotaEntries = if ($quotaResp.StatusCode -eq 200) { ($quotaResp.Content | ConvertFrom-Json).value } else { @() }
        $usageEntries = if ($usageResp -and $usageResp.StatusCode -eq 200) { ($usageResp.Content | ConvertFrom-Json).value } else { @() }

        if ($quotaEntries.Count -eq 0) { return @() }

        # Build a usage lookup: outer entry.name (plain string) -> currentValue
        $usageLookup = @{}
        foreach ($u in $usageEntries) {
            if ($u.name -and $u.properties.usages) {
                $usageLookup[$u.name] = [int]$u.properties.usages.value
            }
        }

        $result = foreach ($entry in $quotaEntries) {
            # Name lives under properties.name (an object), not the root entry.name (a plain string)
            $nameValue   = $entry.properties.name.value
            $nameDisplay = $entry.properties.name.localizedValue
            if ([string]::IsNullOrEmpty($nameValue)) { continue }

            [PSCustomObject]@{
                Value          = $nameValue
                LocalizedValue = $nameDisplay
                CurrentValue   = if ($usageLookup.ContainsKey($entry.name)) { $usageLookup[$entry.name] } else { 0 }
                Limit          = if ($entry.properties.limit) { [int]$entry.properties.limit.value } else { 0 }
            }
        }

        return @($result)
    } catch {
        return @()
    }
}

<#
.SYNOPSIS
    Retrieves logical-to-physical availability zone mappings for a specific
    subscription and region.

.DESCRIPTION
    Calls the Azure Resource Manager REST API to fetch location metadata for a
    subscription. Filters the result to the target region and returns an array
    of zone mapping objects, each with LogicalZone and PhysicalZone properties.

    This mapping is subscription-specific: the same physical datacenter (e.g.
    eastus-az1) may appear as logical zone 1 in one subscription and logical
    zone 2 in another. The mapping is needed to compare capacity across
    subscriptions using a common physical reference.

.PARAMETER SubscriptionId
    The Azure subscription ID to query.

.PARAMETER Region
    The Azure region name to filter zone mappings for (e.g. 'eastus').

.PARAMETER ResourceManagerUrl
    The base URL of the Azure Resource Manager endpoint for the current cloud
    environment (e.g. 'https://management.azure.com/').

.OUTPUTS
    Array of PSCustomObjects with LogicalZone (string) and PhysicalZone (string)
    properties. Returns empty array if no zone mappings are found.
#>
function Get-ZonePeers {
    param (
        [string]$SubscriptionId,
        [string]$Region,
        [string]$ResourceManagerUrl
    )

    try {
        $uri      = "{0}subscriptions/{1}/locations?api-version=2022-12-01" -f $ResourceManagerUrl, $SubscriptionId
        $response = Invoke-AzRest -Method GET -Uri $uri -ErrorAction Stop
        $locations = ($response.Content | ConvertFrom-Json).value

        $regionEntry  = $locations | Where-Object { $_.name -eq $Region -and $_.type -eq "Region" }
        $zoneMappings = $regionEntry.availabilityZoneMappings

        if (-not $zoneMappings) {
            return @()
        }

        $result = foreach ($zm in $zoneMappings) {
            if ([string]::IsNullOrEmpty($zm.logicalZone) -or [string]::IsNullOrEmpty($zm.physicalZone)) {
                continue
            }
            [PSCustomObject]@{
                LogicalZone  = $zm.logicalZone
                PhysicalZone = $zm.physicalZone
            }
        }

        return @($result)
    } catch {
        Write-Warning "Failed to get zone peers for subscription $SubscriptionId`: $($_.Exception.Message)"
        return @()
    }
}

<#
.SYNOPSIS
    Collects quota usage and availability zone data for a single subscription.

.DESCRIPTION
    Core per-subscription analysis function, designed to run in parallel across
    multiple subscriptions. For the target subscription and region, this function:

      1. Sets the Az context to the subscription
      2. Retrieves logical-to-physical availability zone mappings
      3. Gets compute resource SKUs (filtered to virtualMachines and requested families)
      4. Gets current VM quota usage via the Microsoft.Quota REST API (Get-AzVMUsage as fallback)
      5. Joins SKU data to quota data by CPU family
      6. Returns structured objects per family, each containing:
           - Subscription metadata (TenantId, Id, Name)
           - Family quota totals (CoresUsed, CoresLimit, UtilizationPct)
           - Per-SKU detail (zones, restrictions) as a nested array

.PARAMETER SubscriptionId
    The Azure subscription ID to analyze.

.PARAMETER Region
    The Azure region to query (e.g. 'eastus').

.PARAMETER CpuFamilies
    Array of CPU family name strings to include (e.g. 'standardDSv5Family').

.PARAMETER ResourceManagerUrl
    Base URL of the Azure Resource Manager endpoint for the current cloud.

.OUTPUTS
    Array of PSCustomObjects, one per CPU family per subscription. Each object
    includes TenantId, SubscriptionId, SubscriptionName, Family, FamilyDisplayName,
    CoresUsed, CoresLimit, UtilizationPct, and a SKUDetails array.
#>
function Get-SubscriptionQuotaData {
    param (
        [string]$SubscriptionId,
        [string]$Region,
        [string[]]$CpuFamilies,
        [string]$ResourceManagerUrl
    )

    $startTime = Get-Date

    try {
        $subscription = Get-AzSubscription -SubscriptionId $SubscriptionId -WarningAction SilentlyContinue -ErrorAction Stop
        Set-AzContext -SubscriptionId $SubscriptionId -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null

        Write-Host "  Querying: $($subscription.Name) ($SubscriptionId)"

        # ── Resource provider registration check ────────────────────────────────
        # Microsoft.Compute must be registered — without it no quota, SKU, or zone
        # data is available. Get-AzResourceProvider returns one row per resource type
        # so we take the first row's RegistrationState as the provider-level answer.
        # Microsoft.Quota is NOT checked here: the provider can be listed as
        # "NotRegistered" yet the Quota API still responds (it is a platform-level
        # endpoint, not a per-subscription resource deployment). The existing fallback
        # to Get-AzVMUsage handles any case where the Quota API does not respond.
        $computeProvider = Get-AzResourceProvider -ProviderNamespace Microsoft.Compute `
            -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($computeProvider.RegistrationState -ne 'Registered') {
            $state = if ($computeProvider) { $computeProvider.RegistrationState } else { 'unknown' }
            Write-Warning "Skipping subscription '$($subscription.Name)': Microsoft.Compute is not registered (state: '$state'). Register it with: Register-AzResourceProvider -ProviderNamespace Microsoft.Compute"
            return @()
        }

        # Get zone mapping (logical → physical) for this subscription + region
        $zonePeers = Get-ZonePeers -SubscriptionId $SubscriptionId -Region $Region -ResourceManagerUrl $ResourceManagerUrl

        # Build a fast lookup hashtable: logicalZone string → physicalZone string
        $zoneMap = @{}
        foreach ($zp in $zonePeers) {
            $zoneMap[$zp.LogicalZone] = $zp.PhysicalZone
        }

        # Get all VM SKUs in this region (unfiltered — we filter per-family below once
        # canonical API names are resolved from the usage data)
        $allComputeSkus = Get-AzComputeResourceSku -Location $Region -ErrorAction SilentlyContinue |
            Where-Object { $_.ResourceType -eq 'virtualMachines' }

        # Build a VM instance count lookup: vmSize (lowercase) -> count of deployed VMs in this region.
        # Uses Azure Resource Graph for a single efficient API call with server-side aggregation,
        # rather than fetching all VM objects and filtering client-side.
        $vmCountLookup = @{}
        $argQuery = @"
resources
| where type == "microsoft.compute/virtualmachines"
| where location == "$Region"
| summarize count = count() by vmSize = tostring(properties.hardwareProfile.vmSize)
"@
        $argResults = Search-AzGraph -Query $argQuery -Subscription $SubscriptionId -ErrorAction SilentlyContinue
        foreach ($row in $argResults) {
            if ($row.vmSize) {
                $vmCountLookup[$row.vmSize.ToLower()] = [int]$row.count
            }
        }

        # Primary quota source: Microsoft.Quota REST API (merges /quotas + /usages for complete data)
        $quotaApiResults = Get-QuotaFromApi -SubscriptionId $SubscriptionId -Region $Region -ResourceManagerUrl $ResourceManagerUrl

        # Fallback quota source: classic Compute usage API (Get-AzVMUsage)
        # Used when the Quota API returns no data (e.g. unsupported environment or transient failure)
        $vmUsageExpanded = if ($quotaApiResults.Count -eq 0) {
            Get-AzVMUsage -Location $Region -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty Name -Property CurrentValue, Limit
        } else { @() }

        # If both sources are empty this subscription has no compute quota in this region at all —
        # emit one subscription-level message rather than per-family noise.
        $hasAnyQuotaData = ($quotaApiResults.Count -gt 0) -or ($vmUsageExpanded.Count -gt 0)
        if (-not $hasAnyQuotaData) {
            Write-Warning "Subscription '$($subscription.Name)' has no compute quota data in region '$Region'. Skipping all families for this subscription."
            return @()
        }

        $results = foreach ($family in $CpuFamilies) {
            # Match against BOTH the API key (Value) and the display name (LocalizedValue).
            # Try the Quota API first, then fall back to the classic Get-AzVMUsage data.
            $familyUsage = $quotaApiResults |
                Where-Object { $_.Value -eq $family -or $_.LocalizedValue -eq $family }

            if (-not $familyUsage -and $vmUsageExpanded.Count -gt 0) {
                $familyUsage = $vmUsageExpanded |
                    Where-Object { $_.Value -eq $family -or $_.LocalizedValue -eq $family }
            }

            # Resolve the canonical API-key name to use for SKU filtering
            $canonicalFamilyName = if ($familyUsage) { $familyUsage.Value } else { $family }

            # Distinguish between "family not in usage data" and "family found with 0 limit"
            $familyFound = $null -ne $familyUsage
            if (-not $familyFound) {
                Write-Warning "Family '$family' was not found in quota data for region '$Region' in subscription '$($subscription.Name)'. Both the Microsoft.Quota API and Get-AzVMUsage were tried. Verify the name matches the Value or LocalizedValue from: Get-AzVMUsage -Location '$Region' | Select-Object -ExpandProperty Name | Select-Object Value, LocalizedValue"
            }

            $coresUsed  = if ($familyFound) { [int]$familyUsage.CurrentValue } else { 0 }
            $coresLimit = if ($familyFound) { [int]$familyUsage.Limit } else { 0 }
            $utilPct    = if ($coresLimit -gt 0) { [math]::Round(($coresUsed / $coresLimit) * 100, 1) } else { 0 }
            $displayName= if ($familyFound) { $familyUsage.LocalizedValue } else { $family }
            $quotaStatus= if (-not $familyFound) { 'NotFound' } elseif ($coresLimit -eq 0) { 'ZeroLimit' } else { 'OK' }

            # Filter SKUs using the resolved canonical API name
            $familySkus  = $allComputeSkus | Where-Object { $_.Family -eq $canonicalFamilyName }
            $skuDetails  = foreach ($sku in $familySkus) {
                $logicalZones = @($sku.LocationInfo.Zones | Sort-Object)

                $logicalRestricted = @()
                $regionRestricted  = $false

                foreach ($restriction in $sku.Restrictions) {
                    if ($restriction.Type -eq "Zone") {
                        $logicalRestricted = @($restriction.RestrictionInfo.Zones | Sort-Object)
                    } elseif ($restriction.Type -eq "Location") {
                        $regionRestricted = $true
                    }
                }

                # Build annotated zone pairs: "1/eastus-az2 ✅" or "2/eastus-az1 ⚠️"
                $annotatedZones = $logicalZones | ForEach-Object {
                    $logical  = $_
                    $physical = if ($zoneMap.ContainsKey($logical)) { $zoneMap[$logical] } else { $logical }
                    $icon     = if ($logical -in $logicalRestricted) { "⚠️" } else { "✅" }
                    "$logical/$physical $icon"
                }

                [PSCustomObject]@{
                    Size             = $sku.Name
                    CurrentCount     = $vmCountLookup[$sku.Name.ToLower()] ?? 0
                    Zones            = if ($annotatedZones.Count -gt 0) { $annotatedZones -join ", " } else { "—" }
                    RegionRestricted = $regionRestricted
                }
            }

            [PSCustomObject]@{
                TenantId         = $subscription.TenantId
                SubscriptionId   = $subscription.Id
                SubscriptionName = $subscription.Name
                Family           = $family
                FamilyDisplayName= $displayName
                CoresUsed        = $coresUsed
                CoresLimit       = $coresLimit
                UtilizationPct   = $utilPct
                QuotaStatus      = $quotaStatus
                SKUDetails       = @($skuDetails)
            }
        }

        $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
        Write-Host "  Completed: $($subscription.Name) in $elapsed`s"

        return @($results)

    } catch {
        Write-Warning "Failed to query subscription $SubscriptionId`: $($_.Exception.Message)"
        return @()
    }
}

<#
.SYNOPSIS
    Builds the Markdown content for the quota usage report.

.DESCRIPTION
    Generates a well-structured Markdown document from the collected quota data.
    The report has three sections:

      1. Header — run metadata (timestamp, region, families, subscription count)
      2. Cross-Subscription Summary — one table row per family showing aggregated
         totals across all subscriptions, with a ⚠️ warning for utilization > 80%
      3. Per-Subscription Detail — one section per subscription, with a heading
         per CPU family showing used/limit, and a table of SKUs with both logical
         and physical zone information side-by-side

.PARAMETER Results
    Array of quota result objects as returned by Get-SubscriptionQuotaData.

.PARAMETER Region
    The Azure region that was analyzed.

.PARAMETER CpuFamilies
    Ordered list of CPU family strings that were requested.

.PARAMETER GeneratedAt
    The datetime the report was generated (used in the header).

.OUTPUTS
    A single string containing the complete Markdown document.
#>
function New-MarkdownReport {
    param (
        [object[]]$Results,
        [string]$Region,
        [string[]]$CpuFamilies,
        [datetime]$GeneratedAt
    )

    $md = [System.Collections.Generic.List[string]]::new()

    # ── Header ─────────────────────────────────────────────────────────────────
    $md.Add("# Azure Quota Usage Report")
    $md.Add("")
    $md.Add("| | |")
    $md.Add("|---|---|")
    $md.Add("| **Generated** | $($GeneratedAt.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC |")
    $md.Add("| **Region** | ``$Region`` |")
    $md.Add("| **CPU Families** | $($CpuFamilies -join ', ') |")
    $uniqueSubs = $Results |
        Group-Object -Property SubscriptionId |
        ForEach-Object { $_.Group[0] } |
        Select-Object SubscriptionId, SubscriptionName |
        Sort-Object SubscriptionName
    $md.Add("| **Subscriptions Analyzed** | $($uniqueSubs.Count) |")
    $md.Add("")

    $md.Add("### Subscriptions Queried")
    $md.Add("")
    $md.Add("| Subscription Name | Subscription ID |")
    $md.Add("|---|---|")
    foreach ($sub in $uniqueSubs) {
        $md.Add("| $($sub.SubscriptionName) | ``$($sub.SubscriptionId)`` |")
    }
    $md.Add("")
    $md.Add("---")
    $md.Add("")

    # ── Cross-Subscription Summary ─────────────────────────────────────────────
    $md.Add("## Cross-Subscription Summary")
    $md.Add("")
    $md.Add("Aggregated quota totals across all subscriptions for each CPU family.")
    $md.Add("")
    $md.Add("| CPU Family | Total Used | Total Limit | Utilization | Subs w/ >80% |")
    $md.Add("|---|---:|---:|---:|---:|")

    foreach ($family in $CpuFamilies) {
        $familyResults = @($Results | Where-Object { $_.Family -eq $family })
        if ($familyResults.Count -eq 0) { continue }

        $totalUsed  = ($familyResults | Measure-Object -Property CoresUsed  -Sum).Sum
        $totalLimit = ($familyResults | Measure-Object -Property CoresLimit -Sum).Sum
        $highCount  = @($familyResults | Where-Object { $_.UtilizationPct -gt 80 }).Count
        $utilPct    = if ($totalLimit -gt 0) { [math]::Round(($totalUsed / $totalLimit) * 100, 1) } else { 0 }

        $displayName = ($familyResults | Where-Object { $_.FamilyDisplayName -ne $family } | Select-Object -First 1).FamilyDisplayName
        if ([string]::IsNullOrEmpty($displayName)) { $displayName = $family }

        $utilDisplay = if ($utilPct -gt 80) { "⚠️ $utilPct%" } else { "$utilPct%" }

        $md.Add("| $displayName | $totalUsed | $totalLimit | $utilDisplay | $highCount |")
    }

    $md.Add("")
    $md.Add("> ⚠️ Indicates utilization above 80%. Consider requesting additional quota or creating an Azure Quota Group.")
    $md.Add("")
    $md.Add("---")
    $md.Add("")

    # ── Per-Subscription Detail ─────────────────────────────────────────────────
    $md.Add("## Per-Subscription Detail")
    $md.Add("")

    foreach ($sub in $uniqueSubs) {
        $md.Add("### $($sub.SubscriptionName) - ``$($sub.SubscriptionId)``")
        $md.Add("")

        $subResults = @($Results | Where-Object { $_.SubscriptionId -eq $sub.SubscriptionId })

        foreach ($family in $CpuFamilies) {
            $familyResult = $subResults | Where-Object { $_.Family -eq $family }

            if (-not $familyResult) {
                $md.Add("#### $family")
                $md.Add("")
                $md.Add("_Family not found in this subscription for region ``$Region``._")
                $md.Add("")
                continue
            }

            $utilDisplay  = "$($familyResult.UtilizationPct)%"
            $warnPrefix   = if ($familyResult.UtilizationPct -gt 80) { "⚠️ " } else { "" }
            $limitDisplay = switch ($familyResult.QuotaStatus) {
                'NotFound'  { "⚠️ Family name not matched in usage data — verify the exact name with ``Get-AzVMUsage``" }
                'ZeroLimit' { "0 quota assigned (limit is 0 — quota must be requested)" }
                default     { "$($familyResult.CoresUsed)/$($familyResult.CoresLimit) vCPUs ($utilDisplay used)" }
            }

            $md.Add("#### $warnPrefix$($familyResult.FamilyDisplayName) — $limitDisplay")
            $md.Add("")

            $skuList = @($familyResult.SKUDetails)
            if ($skuList.Count -gt 0) {
                $md.Add("| Current Count | Size | Zones (Logical/Physical) | Region Status |")
                $md.Add("|:---:|---|---|:---:|")

                foreach ($sku in ($skuList | Sort-Object Size)) {
                    $zones       = if ([string]::IsNullOrEmpty($sku.Zones)) { "—" } else { $sku.Zones }
                    $regionRestr = if ($sku.RegionRestricted) { "⚠️ Restricted" } else { "✅ Not Restricted" }

                    $md.Add("| $($sku.CurrentCount) | $($sku.Size) | $zones | $regionRestr |")
                }
            } else {
                $md.Add("_No individual SKUs found for this family in region ``$Region``._")
            }

            $md.Add("")
        }

        $md.Add("---")
        $md.Add("")
    }

    return $md -join "`n"
}


# ================================================================================
# MAIN SCRIPT EXECUTION
# ================================================================================

$scriptStart = Get-Date

# ── Normalize region input ──────────────────────────────────────────────────────
$Region = $Region.Trim().ToLower()

# ── Verify Azure context ────────────────────────────────────────────────────────
$azContext = Get-AzContext -ErrorAction SilentlyContinue
if ($null -eq $azContext -or $null -eq $azContext.Account) {
    throw "No Azure context found. Please run Connect-AzAccount before running this script."
}
Write-Host "Using Azure context: $($azContext.Account.Id) (Tenant: $($azContext.Tenant.TenantId))"

# ── Auto-detect thread count ─────────────────────────────────────────────────────
if ($Threads -eq 0) {
    $Threads = [System.Environment]::ProcessorCount
    Write-Host "Auto-detected thread count: $Threads"
}

# ── Resolve subscriptions ───────────────────────────────────────────────────────
Write-Host "`nResolving subscriptions..."
$mgInput  = if ($PSCmdlet.ParameterSetName -eq 'ByManagementGroup') { @($ManagementGroup) } else { @() }
$subInput = if ($PSCmdlet.ParameterSetName -eq 'BySubscription')    { $Subscriptions }      else { @() }

$resolvedSubscriptionIds = Resolve-Subscriptions -ManagementGroupInput $mgInput -SubscriptionInput $subInput

if ($resolvedSubscriptionIds.Count -eq 0) {
    throw "No subscriptions resolved from the provided -ManagementGroup / -Subscriptions input."
}
Write-Host "Resolved $($resolvedSubscriptionIds.Count) subscription(s)"

# ── Resolve CPU families ────────────────────────────────────────────────────────
Write-Host "`nResolving CPU families..."
$resolvedFamilies = Resolve-CpuFamilies -FamilyInput $CpuFamilies

if ($resolvedFamilies.Count -eq 0) {
    throw "No CPU families resolved from the provided -CpuFamilies input."
}
Write-Host "Resolved $($resolvedFamilies.Count) family/families: $($resolvedFamilies -join ', ')"

# ── Prepare output directory ────────────────────────────────────────────────────
$outputDir = Join-Path $PSScriptRoot "output"
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
    Write-Host "`nCreated output directory: $outputDir"
}

$timestamp      = $scriptStart.ToString("yyyyMMdd")
$reportFileName = "QuotaReport_${Region}_${timestamp}.md"
$reportPath     = Join-Path $outputDir $reportFileName

# ── Capture resource manager URL before entering parallel scope ─────────────────
$resourceManagerUrl = $azContext.Environment.ResourceManagerUrl

Write-Host "`nQuerying $($resolvedSubscriptionIds.Count) subscription(s) across $($resolvedFamilies.Count) family/families in $Region using $Threads thread(s)..."
Write-Host "This may take a few minutes for large subscription sets.`n"

# ── Run parallel quota data collection ─────────────────────────────────────────
# Capture function definitions as strings for re-injection into parallel runspaces
$funcGetQuotaFromApi          = ${function:Get-QuotaFromApi}.ToString()
$funcGetZonePeers             = ${function:Get-ZonePeers}.ToString()
$funcGetSubscriptionQuotaData = ${function:Get-SubscriptionQuotaData}.ToString()

$allResults = @(
    $resolvedSubscriptionIds | ForEach-Object -ThrottleLimit $Threads -Parallel {
        # Re-inject helper functions into this runspace
        ${function:Get-QuotaFromApi}          = $using:funcGetQuotaFromApi
        ${function:Get-ZonePeers}             = $using:funcGetZonePeers
        ${function:Get-SubscriptionQuotaData} = $using:funcGetSubscriptionQuotaData

        Get-SubscriptionQuotaData `
            -SubscriptionId     $_ `
            -Region             $using:Region `
            -CpuFamilies        $using:resolvedFamilies `
            -ResourceManagerUrl $using:resourceManagerUrl
    }
)

if ($allResults.Count -eq 0) {
    Write-Warning "No quota data was collected. Verify the region name and that subscriptions are accessible."
}

# ── Generate and write Markdown report ─────────────────────────────────────────
Write-Host "`nGenerating Markdown report..."
$markdownContent = New-MarkdownReport `
    -Results     $allResults `
    -Region      $Region `
    -CpuFamilies $resolvedFamilies `
    -GeneratedAt $scriptStart

$markdownContent | Out-File -FilePath $reportPath -Encoding UTF8 -Force

# ── Summary ─────────────────────────────────────────────────────────────────────
$totalElapsed = [math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)

Write-Host ""
Write-Host "Report written to: $reportPath" -ForegroundColor Green
Write-Host "Subscriptions analyzed : $($resolvedSubscriptionIds.Count)"
Write-Host "CPU families analyzed  : $($resolvedFamilies.Count)"
Write-Host "Region                 : $Region"
Write-Host "Total time             : $totalElapsed`s"
