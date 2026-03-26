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
      - PowerShell 7.0 or later
      - Az.Accounts, Az.Compute, Az.Resources, Az.ResourceGraph modules
      - Az.Quota module (installed automatically if missing — requires internet access)
      - Reader access to all target subscriptions
      - Reader access to the Management Group (when using -ManagementGroup)
      - Management Group Reader access for Quota Group discovery

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
    [string]$Region
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
    Queries the Az.Quota module for VM family quota limits and usage in a specific
    subscription and region.

.DESCRIPTION
    Uses the Az.Quota PowerShell module cmdlets to retrieve quota data:
      Get-AzQuota      — returns quota limits per named resource
      Get-AzQuotaUsage — returns current usage per named resource

    Both cmdlets target the same scope and are merged by NameValue so callers get
    a complete object with both Limit and CurrentValue.

    Note: shareableQuota is NOT collected here. It is only meaningful in the context
    of a specific quota group and is fetched per-subscription per-group by
    Get-QuotaGroupDetails using the quotaAllocations endpoint.

    Returns an empty array if both module cmdlets return no entries.

.PARAMETER SubscriptionId
    The Azure subscription ID to query.

.PARAMETER Region
    The Azure region to query (e.g. 'eastus').

.PARAMETER ResourceManagerUrl
    Base URL of the Azure Resource Manager endpoint for the current cloud.

.OUTPUTS
    Array of PSCustomObjects with Value, LocalizedValue, CurrentValue, and Limit.
    Returns empty array on failure or when the subscription has no compute quota.
#>
function Get-QuotaFromModule {
    param (
        [string]$SubscriptionId,
        [string]$Region,
        [string]$ResourceManagerUrl
    )

    try {
        $scope = "subscriptions/$SubscriptionId/providers/Microsoft.Compute/locations/$Region"

        $quotaEntries = Get-AzQuota      -Scope $scope -ErrorAction SilentlyContinue
        $usageEntries = Get-AzQuotaUsage -Scope $scope -ErrorAction SilentlyContinue

        if ((-not $quotaEntries -or @($quotaEntries).Count -eq 0) -and
            (-not $usageEntries -or @($usageEntries).Count -eq 0)) {
            return @()
        }

        # Build a usage lookup: NameValue -> UsageValue
        $usageLookup = @{}
        foreach ($u in $usageEntries) {
            if ($u.NameValue) {
                $usageLookup[$u.NameValue] = [int]$u.UsageValue
            }
        }

        $result = foreach ($entry in $quotaEntries) {
            if ([string]::IsNullOrEmpty($entry.NameValue)) { continue }

            [PSCustomObject]@{
                Value          = $entry.NameValue
                LocalizedValue = $entry.NameLocalizedValue
                CurrentValue   = if ($usageLookup.ContainsKey($entry.NameValue)) { $usageLookup[$entry.NameValue] } else { 0 }
                Limit          = if ($null -ne $entry.Limit -and $null -ne $entry.Limit.Value) { [int]$entry.Limit.Value } else { 0 }
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
    Discovers Azure Quota Group membership for a set of subscription IDs.

.DESCRIPTION
    Traverses all management groups accessible to the current identity and queries
    the Microsoft.Quota GroupQuotas API for each. For every quota group found, the
    member subscription list is retrieved and cross-referenced against the provided
    subscription IDs.

    Returns a hashtable keyed by (lowercase) subscription ID, where each value is a
    list of group membership objects for that subscription. Subscriptions with no
    group membership have an empty list.

    Note: The GroupQuotas API is in preview (api-version 2023-06-01-preview). If the
    API is unavailable or returns errors for a management group, that group is skipped
    gracefully.

.PARAMETER SubscriptionIds
    Array of subscription IDs to check group membership for.

.PARAMETER ResourceManagerUrl
    Base URL of the Azure Resource Manager endpoint for the current cloud.

.OUTPUTS
    Hashtable: subscriptionId (lowercase) -> List of PSCustomObjects, each with
    ManagementGroup, GroupName, GroupDisplayName, GroupType, and ProvisioningState.
#>
function Get-QuotaGroupMembership {
    param (
        [string[]]$SubscriptionIds,
        [string]$ResourceManagerUrl
    )

    # Initialize result with empty lists for each subscription
    $membership = @{}
    foreach ($id in $SubscriptionIds) {
        $membership[$id.ToLower()] = [System.Collections.Generic.List[object]]::new()
    }

    try {
        $managementGroups = Get-AzManagementGroup -ErrorAction SilentlyContinue
    } catch {
        Write-Warning "Unable to list management groups for Quota Group discovery: $($_.Exception.Message)"
        return $membership
    }

    if (-not $managementGroups) { return $membership }

    foreach ($mg in $managementGroups) {
        $mgName = $mg.Name

        # NOTE: The GroupQuotas API is not yet exposed by the Az.Quota module (v0.1.3).
        # Az.Quota only covers per-subscription quota (Get-AzQuota, Get-AzQuotaUsage).
        # Invoke-AzRest is used here because no equivalent module cmdlet exists.
        # When Az.Quota adds GroupQuota cmdlets these calls should be replaced.
        $groupQuotaUri = "{0}providers/Microsoft.Management/managementGroups/{1}/providers/Microsoft.Quota/groupQuotas?api-version=2023-06-01-preview" -f $ResourceManagerUrl, $mgName
        $groupResp     = Invoke-AzRest -Method GET -Uri $groupQuotaUri -ErrorAction SilentlyContinue
        if (-not $groupResp -or $groupResp.StatusCode -ne 200) { continue }

        $groups = try { ($groupResp.Content | ConvertFrom-Json).value } catch { @() }
        if (-not $groups) { continue }

        foreach ($group in $groups) {
            $groupName   = $group.name
            $displayName = $group.properties.displayName
            $groupType   = $group.properties.groupType

            $subsUri  = "{0}providers/Microsoft.Management/managementGroups/{1}/providers/Microsoft.Quota/groupQuotas/{2}/subscriptions?api-version=2023-06-01-preview" -f $ResourceManagerUrl, $mgName, $groupName
            $subsResp = Invoke-AzRest -Method GET -Uri $subsUri -ErrorAction SilentlyContinue
            if (-not $subsResp -or $subsResp.StatusCode -ne 200) { continue }

            $members = try { ($subsResp.Content | ConvertFrom-Json).value } catch { @() }
            foreach ($member in $members) {
                # The resource name IS the subscription ID in the group quota subscription resource
                $memberId = $member.name
                if ([string]::IsNullOrEmpty($memberId)) { continue }

                $key = $memberId.ToLower()
                if ($membership.ContainsKey($key)) {
                    $membership[$key].Add([PSCustomObject]@{
                        ManagementGroup   = $mgName
                        GroupName         = $groupName
                        GroupDisplayName  = if ($displayName) { $displayName } else { $groupName }
                        GroupType         = if ($groupType)   { $groupType   } else { 'Unknown'  }
                        ProvisioningState = $group.properties.provisioningState
                    })
                }
            }
        }
    }

    return $membership
}

<#
.SYNOPSIS
    Enriches Quota Group membership data with group-level quota limits and allocations.

.DESCRIPTION
    Takes the membership hashtable from Get-QuotaGroupMembership and builds a
    deduplicated list of unique groups (one object per ManagementGroup+GroupName pair).
    For each group, attempts to fetch group-level quota limits and per-subscription
    quota allocations from the Microsoft.Quota GroupQuotas preview API.

    Both sub-resources are in preview and may return 400/404 if limits have not been
    configured for the group. In that case the GroupLimits and GroupAllocations fields
    are left null and the report renders an informational note.

.PARAMETER GroupMembership
    Hashtable from Get-QuotaGroupMembership: subscriptionId (lowercase) ->
    List of group membership objects (ManagementGroup, GroupName, GroupDisplayName,
    GroupType, ProvisioningState).

.PARAMETER Region
    The Azure region to query group quota limits for (e.g. 'uksouth').

.PARAMETER ResourceManagerUrl
    Base URL of the Azure Resource Manager endpoint for the current cloud.

.OUTPUTS
    Array of PSCustomObjects, one per unique group, with properties:
    ManagementGroup, GroupName, GroupDisplayName, GroupType, MemberSubIds (List),
    GroupLimits (array or null), GroupAllocations (array or null).
#>
function Get-QuotaGroupDetails {
    param (
        [hashtable]$GroupMembership,
        [string]$Region,
        [string]$ResourceManagerUrl
    )

    # Build deduplicated group objects from the flat membership hashtable
    $groups = @{}
    foreach ($subId in $GroupMembership.Keys) {
        foreach ($grp in $GroupMembership[$subId]) {
            $key = "$($grp.ManagementGroup)|$($grp.GroupName)"
            if (-not $groups.ContainsKey($key)) {
                $groups[$key] = [PSCustomObject]@{
                    ManagementGroup        = $grp.ManagementGroup
                    GroupName              = $grp.GroupName
                    GroupDisplayName       = $grp.GroupDisplayName
                    GroupType              = $grp.GroupType
                    MemberSubIds           = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    GroupLimits            = $null
                    GroupAllocations       = $null
                    SubscriptionAllocations = @{}   # subId.ToLower() -> { resourceName -> shareableQuota }
                }
            }
            $groups[$key].MemberSubIds.Add($subId) | Out-Null
        }
    }

    # Enrich each group with quota limits, allocations, and per-subscription shareableQuota.
    # NOTE: Az.Quota v0.1.3 has no GroupQuota cmdlets (Get-AzQuotaGroupQuotaLimit etc.)
    # are not yet published. Invoke-AzRest is the only available interface today.
    foreach ($key in $groups.Keys) {
        $g    = $groups[$key]
        $base = "{0}providers/Microsoft.Management/managementGroups/{1}/providers/Microsoft.Quota/groupQuotas/{2}/resourceProviders/Microsoft.Compute/locations/{3}" -f $ResourceManagerUrl, $g.ManagementGroup, $g.GroupName, $Region

        $limResp = Invoke-AzRest -Method GET -Uri "$base/groupQuotaLimits?api-version=2023-06-01-preview" -ErrorAction SilentlyContinue
        if ($limResp -and $limResp.StatusCode -eq 200) {
            $g.GroupLimits = try { ($limResp.Content | ConvertFrom-Json).value } catch { @() }
        }

        $allocResp = Invoke-AzRest -Method GET -Uri "$base/quotaAllocations?api-version=2023-06-01-preview" -ErrorAction SilentlyContinue
        if ($allocResp -and $allocResp.StatusCode -eq 200) {
            $g.GroupAllocations = try { ($allocResp.Content | ConvertFrom-Json).value } catch { @() }
        }

        # Fetch per-subscription shareableQuota using the correct group-context endpoint:
        # GET {rm}providers/Microsoft.Management/managementGroups/{mg}/subscriptions/{subId}/
        #        providers/Microsoft.Quota/groupQuotas/{group}/resourceProviders/
        #        Microsoft.Compute/quotaAllocations/{region}?api-version=2025-03-01
        # Returns properties.resourceName and properties.shareableQuota per family.
        foreach ($subId in $g.MemberSubIds) {
            $subAllocUri  = "{0}providers/Microsoft.Management/managementGroups/{1}/subscriptions/{2}/providers/Microsoft.Quota/groupQuotas/{3}/resourceProviders/Microsoft.Compute/quotaAllocations/{4}?api-version=2025-03-01" -f $ResourceManagerUrl, $g.ManagementGroup, $subId, $g.GroupName, $Region
            Write-Verbose "  [ShareableQuota] GET $subAllocUri"
            $subAllocResp = Invoke-AzRest -Method GET -Uri $subAllocUri -ErrorAction SilentlyContinue
            if ($subAllocResp -and $subAllocResp.StatusCode -eq 200) {
                $subShareable = @{}
                $parsed = $subAllocResp.Content | ConvertFrom-Json
                Write-Verbose "  [ShareableQuota] HTTP 200 — $(@($parsed.value).Count) entries. Raw: $($subAllocResp.Content)"
                foreach ($entry in $parsed.value) {
                    # Resource name: try properties.resourceName, then properties.name.value,
                    # then fall back to the top-level name (may be a short name or full path).
                    $resourceName = $entry.properties.resourceName
                    if ([string]::IsNullOrEmpty($resourceName)) { $resourceName = $entry.properties.name.value }
                    if ([string]::IsNullOrEmpty($resourceName))  { $resourceName = $entry.name }
                    if ([string]::IsNullOrEmpty($resourceName))  { continue }

                    # shareableQuota field name varies by API version: try both spellings.
                    $sqValue = $entry.properties.shareableQuota
                    if ($null -eq $sqValue) { $sqValue = $entry.properties.sharableQuota }

                    Write-Verbose "  [ShareableQuota]   $resourceName -> sqValue=$sqValue"
                    if ($null -ne $sqValue) {
                        $subShareable[$resourceName] = [int]$sqValue
                    }
                }
                Write-Verbose "  [ShareableQuota] Stored $($subShareable.Count) entries for sub $subId"
                $g.SubscriptionAllocations[$subId.ToLower()] = $subShareable
            } else {
                $sc = if ($subAllocResp) { $subAllocResp.StatusCode } else { 'no response' }
                Write-Warning "ShareableQuota: quotaAllocations API returned HTTP $sc for sub $subId in group $($g.GroupName). Run with -Verbose for full URL."
                Write-Verbose "  [ShareableQuota] Response body: $(if ($subAllocResp) { $subAllocResp.Content } else { 'null' })"
            }
        }
    }

    return @($groups.Values)
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
      4. Gets current VM quota usage via the Az.Quota module (Get-AzVMUsage as fallback)
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
        # data is available for the subscription.
        #
        # IMPORTANT: Get-AzResourceProvider has no -SubscriptionId parameter and
        # relies solely on the current Az context. We use Invoke-AzRest instead —
        # the subscription ID is embedded directly in the URL and is context-independent.
        $providerUri   = "{0}subscriptions/{1}/providers/Microsoft.Compute?api-version=2021-04-01" -f $ResourceManagerUrl, $SubscriptionId
        $providerResp  = Invoke-AzRest -Method GET -Uri $providerUri -ErrorAction SilentlyContinue
        $providerState = if ($providerResp -and $providerResp.StatusCode -eq 200) {
            ($providerResp.Content | ConvertFrom-Json).registrationState
        } else { $null }

        if ($providerState -ne 'Registered') {
            $state = if ($providerState) { $providerState } else { 'unknown' }
            Write-Warning "Skipping subscription '$($subscription.Name)': Microsoft.Compute is not registered (state: '$state'). Register it with: Register-AzResourceProvider -ProviderNamespace Microsoft.Compute"
            return @()
        }

        # ── Microsoft.Quota registration warning ────────────────────────────────
        # This is an informational warning only — Microsoft.Quota sometimes reports
        # NotRegistered even when the Quota REST API responds correctly (it is a
        # platform-level endpoint, not a per-subscription deployment). We still
        # attempt the Az.Quota module call and fall back to Get-AzVMUsage if needed.
        $quotaProvUri   = "{0}subscriptions/{1}/providers/Microsoft.Quota?api-version=2021-04-01" -f $ResourceManagerUrl, $SubscriptionId
        $quotaProvResp  = Invoke-AzRest -Method GET -Uri $quotaProvUri -ErrorAction SilentlyContinue
        $quotaProvState = if ($quotaProvResp -and $quotaProvResp.StatusCode -eq 200) {
            ($quotaProvResp.Content | ConvertFrom-Json).registrationState
        } else { $null }

        if ($quotaProvState -ne 'Registered') {
            $state = if ($quotaProvState) { $quotaProvState } else { 'unknown' }
            Write-Warning "Subscription '$($subscription.Name)': Microsoft.Quota is not registered (state: '$state'). The Az.Quota module may not return data; Get-AzVMUsage will be used as a fallback if needed."
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

        # Primary quota source: Az.Quota module (Get-AzQuota for limits + Get-AzQuotaUsage for usage)
        $quotaApiResults = Get-QuotaFromModule -SubscriptionId $SubscriptionId -Region $Region -ResourceManagerUrl $ResourceManagerUrl

        # Fallback quota source: classic Compute usage API (Get-AzVMUsage)
        # Used when the Az.Quota module returns no data (e.g. provider not registered or transient failure)
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

            $coresUsed      = if ($familyFound) { [int]$familyUsage.CurrentValue } else { 0 }
            $coresLimit     = if ($familyFound) { [int]$familyUsage.Limit } else { 0 }
            $utilPct        = if ($coresLimit -gt 0) { [math]::Round(($coresUsed / $coresLimit) * 100, 1) } else { 0 }
            $displayName    = if ($familyFound) { $familyUsage.LocalizedValue } else { $family }
            $quotaStatus    = if (-not $familyFound) { 'NotFound' } elseif ($coresLimit -eq 0) { 'ZeroLimit' } else { 'OK' }

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
    The report has four sections:

      1. Header — run metadata (timestamp, region, families, subscription count, group count)
      2. Cross-Subscription Summary — one table row per family showing aggregated
         totals across all subscriptions, with a ⚠️ warning for utilization > 80%
      3. Quota Group Membership — shows which subscriptions belong to Azure Quota
         Groups; subscriptions not in any group are called out for consideration
      4. Per-Subscription Detail — one section per subscription, with a heading
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

.PARAMETER GroupDetails
    Array of enriched group objects as returned by Get-QuotaGroupDetails. Each object
    has ManagementGroup, GroupName, GroupDisplayName, GroupType, MemberSubIds,
    GroupLimits, and GroupAllocations. Used to populate the Quota Group Membership
    section and annotate per-subscription headings. Pass an empty array if none.

.OUTPUTS
    A single string containing the complete Markdown document.
#>
function New-MarkdownReport {
    param (
        [object[]]$Results,
        [string]$Region,
        [string[]]$CpuFamilies,
        [datetime]$GeneratedAt,
        [object[]]$GroupDetails = @()
    )

    $md = [System.Collections.Generic.List[string]]::new()

    # Pre-compute subscription list used across multiple sections
    $uniqueSubs = $Results |
        Group-Object -Property SubscriptionId |
        ForEach-Object { $_.Group[0] } |
        Select-Object SubscriptionId, SubscriptionName |
        Sort-Object SubscriptionName

    # Build reverse lookup for per-subscription heading badges: subId -> [display names]
    $subToGroupNames = @{}
    foreach ($grp in $GroupDetails) {
        $displayName = if ($grp.GroupDisplayName -and $grp.GroupDisplayName -ne $grp.GroupName) { $grp.GroupDisplayName } else { $grp.GroupName }
        foreach ($sid in $grp.MemberSubIds) {
            if (-not $subToGroupNames.ContainsKey($sid)) {
                $subToGroupNames[$sid] = [System.Collections.Generic.List[string]]::new()
            }
            $subToGroupNames[$sid].Add($displayName)
        }
    }

    # ── Header ─────────────────────────────────────────────────────────────────
    $md.Add("# Azure Quota Usage Report")
    $md.Add("")
    $md.Add("| | |")
    $md.Add("|---|---|")
    $md.Add("| **Generated** | $($GeneratedAt.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC |")
    $md.Add("| **Region** | ``$Region`` |")
    $md.Add("| **CPU Families** | $($CpuFamilies -join ', ') |")
    $md.Add("| **Subscriptions Analyzed** | $($uniqueSubs.Count) |")
    $md.Add("| **Quota Groups Found** | $($GroupDetails.Count) |")
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

    # ── Quota Group Membership ─────────────────────────────────────────────────
    $md.Add("## Quota Group Membership")
    $md.Add("")

    if (-not $GroupDetails -or $GroupDetails.Count -eq 0) {
        $md.Add("No Quota Group memberships were found for the analyzed subscriptions.")
        $md.Add("")
        $md.Add("> Consider creating an [Azure Quota Group](https://learn.microsoft.com/azure/quotas/quota-groups) to share quota across subscriptions and reduce the need for individual quota increase requests.")
        $md.Add("")
        $md.Add("---")
        $md.Add("")
    } else {
        $groupedSubIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($grp in $GroupDetails) {
            foreach ($sid in $grp.MemberSubIds) { $groupedSubIds.Add($sid) | Out-Null }
        }
        $md.Add("$($GroupDetails.Count) Quota Group(s) found covering $($groupedSubIds.Count) of $($uniqueSubs.Count) analyzed subscription(s).")
        $md.Add("")

        foreach ($grp in ($GroupDetails | Sort-Object GroupDisplayName)) {
            $heading = if ($grp.GroupDisplayName -and $grp.GroupDisplayName -ne $grp.GroupName) { $grp.GroupDisplayName } else { $grp.GroupName }
            $md.Add("### $heading — $($grp.ManagementGroup)")
            $md.Add("")
            $md.Add("| | |")
            $md.Add("|---|---|")
            $md.Add("| **Group Name** | ``$($grp.GroupName)`` |")
            $md.Add("| **Group Type** | $($grp.GroupType) |")

            $memberDisplays = foreach ($sid in $grp.MemberSubIds) {
                $subInfo = $uniqueSubs | Where-Object { $_.SubscriptionId -ieq $sid } | Select-Object -First 1
                if ($subInfo) { "$($subInfo.SubscriptionName) (``$($subInfo.SubscriptionId)``)" } else { "``$sid``" }
            }
            $md.Add("| **Member Subscriptions** | $($memberDisplays -join ', ') |")
            $md.Add("")

            # ── Per-Family breakdown: Group → SKU → Subscription rows ───────────
            $memberResults = @($Results | Where-Object { $grp.MemberSubIds.Contains($_.SubscriptionId) })

            if ($memberResults.Count -gt 0) {
                foreach ($family in $CpuFamilies) {
                    $familyRows = @($memberResults | Where-Object { $_.Family -eq $family })
                    if ($familyRows.Count -eq 0) { continue }

                    $displayName = ($familyRows | Where-Object { $_.FamilyDisplayName -ne $family } | Select-Object -First 1).FamilyDisplayName
                    if ([string]::IsNullOrEmpty($displayName)) { $displayName = $family }

                    $md.Add("#### $displayName")
                    $md.Add("")
                    $md.Add("| Subscription | Used vCPUs | Limit vCPUs | Utilization | Shareable Quota |")
                    $md.Add("|---|---:|---:|---:|---:|")

                    $totalUsed      = 0
                    $totalLimit     = 0
                    $totalShareable = $null
                    $anyShareable   = $false

                    foreach ($row in ($familyRows | Sort-Object SubscriptionName)) {
                        $utilDisplay  = if ($row.UtilizationPct -gt 80) { "⚠️ $($row.UtilizationPct)%" } else { "$($row.UtilizationPct)%" }

                        # Look up shareableQuota from the group's per-subscription allocation data
                        # (fetched via the quotaAllocations endpoint in Get-QuotaGroupDetails)
                        $shareableQuota = $null
                        if ($grp.SubscriptionAllocations -and
                            $grp.SubscriptionAllocations.ContainsKey($row.SubscriptionId.ToLower())) {
                            $subAlloc = $grp.SubscriptionAllocations[$row.SubscriptionId.ToLower()]
                            if ($subAlloc.ContainsKey($row.Family)) {
                                $shareableQuota = $subAlloc[$row.Family]
                            }
                        }
                        $shareDisplay = if ($null -ne $shareableQuota) { $shareableQuota } else { "—" }
                        $md.Add("| $($row.SubscriptionName) | $($row.CoresUsed) | $($row.CoresLimit) | $utilDisplay | $shareDisplay |")

                        $totalUsed  += $row.CoresUsed
                        $totalLimit += $row.CoresLimit
                        if ($null -ne $shareableQuota) {
                            $totalShareable = ($null -eq $totalShareable) ? $shareableQuota : ($totalShareable + $shareableQuota)
                            $anyShareable   = $true
                        }
                    }

                    $totalUtil        = if ($totalLimit -gt 0) { [math]::Round(($totalUsed / $totalLimit) * 100, 1) } else { 0 }
                    $totalUtilDisplay = if ($totalUtil -gt 80) { "⚠️ $totalUtil%" } else { "$totalUtil%" }
                    $totalShareDisplay= if ($anyShareable) { $totalShareable } else { "—" }
                    $md.Add("| **Total** | **$totalUsed** | **$totalLimit** | **$totalUtilDisplay** | **$totalShareDisplay** |")
                    $md.Add("")

                    if ($anyShareable) {
                        $md.Add("> ℹ️ **Shareable Quota**: a negative value means the subscription has loaned quota to the group; positive means it has borrowed from the group. The **Total** row shows the net quota currently available from the group for this family.")
                        $md.Add("")
                    }
                }
            } else {
                $md.Add("_No quota data collected for member subscriptions._")
                $md.Add("")
            }

            # ── Group-Level Quota Limits from the GroupQuotas API (shown only if data exists)
            if ($null -ne $grp.GroupLimits -and @($grp.GroupLimits).Count -gt 0) {
                $relevantLimits = @($grp.GroupLimits | Where-Object {
                    $rName = if ($_.name) { $_.name } elseif ($_.properties.resourceName) { $_.properties.resourceName } else { $_.properties.name.value }
                    $rName -and ($CpuFamilies -contains $rName)
                })

                if ($relevantLimits.Count -gt 0) {
                    $md.Add("**Group-Level Quota Limits (``$Region``)**")
                    $md.Add("")
                    $md.Add("| CPU Family | Group Limit (vCPUs) | Available to Allocate |")
                    $md.Add("|---|---:|---:|")
                    foreach ($lim in $relevantLimits) {
                        $rName    = if ($lim.name) { $lim.name } elseif ($lim.properties.resourceName) { $lim.properties.resourceName } else { $lim.properties.name.value }
                        $limitVal = if ($lim.properties.limit.value) { [int]$lim.properties.limit.value } elseif ($lim.limit) { [int]$lim.limit } else { 0 }
                        $avail    = if ($null -ne $lim.properties.availableLimit) { [int]$lim.properties.availableLimit } else { $limitVal }
                        $md.Add("| $rName | $limitVal | $avail |")
                    }
                    $md.Add("")
                }
            }

            $md.Add("---")
            $md.Add("")
        }

        $ungroupedSubs = @($uniqueSubs | Where-Object { -not $groupedSubIds.Contains($_.SubscriptionId) })
        if ($ungroupedSubs.Count -gt 0) {
            $ungroupedNames = ($ungroupedSubs | ForEach-Object { "**$($_.SubscriptionName)**" }) -join ", "
            $md.Add("> The following analyzed subscriptions are not members of any Quota Group: $ungroupedNames")
            $md.Add("")
        }
    }

    # ── Per-Subscription Detail ─────────────────────────────────────────────────
    $md.Add("## Per-Subscription Detail")
    $md.Add("")

    foreach ($sub in $uniqueSubs) {
        $subKey        = $sub.SubscriptionId.ToLower()
        $subGroupNames = if ($subToGroupNames.ContainsKey($subKey)) { @($subToGroupNames[$subKey]) } else { @() }
        $groupBadge    = if ($subGroupNames.Count -gt 0) { " *(Quota Groups: $($subGroupNames -join ', '))*" } else { "" }

        $md.Add("### $($sub.SubscriptionName) - ``$($sub.SubscriptionId)``$groupBadge")
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

# ── Verify Az.Quota module ───────────────────────────────────────────────────────
if (-not (Get-Module -Name Az.Quota -ListAvailable)) {
    Write-Warning "Az.Quota module is not installed."
    $installAnswer = Read-Host "Install Az.Quota now for the current user? [Y/N]"
    if ($installAnswer -match '^[Yy]') {
        Write-Host "Installing Az.Quota..."
        Install-Module -Name Az.Quota -Scope CurrentUser -Force -ErrorAction Stop
        Write-Host "Az.Quota installed successfully."
    } else {
        throw "Az.Quota module is required. Install it with: Install-Module -Name Az.Quota -Scope CurrentUser"
    }
}
Import-Module Az.Quota -ErrorAction SilentlyContinue

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

$resourceManagerUrl = $azContext.Environment.ResourceManagerUrl

Write-Host "`nQuerying $($resolvedSubscriptionIds.Count) subscription(s) across $($resolvedFamilies.Count) family/families in $Region..."
Write-Host "This may take a few minutes for large subscription sets.`n"

# ── Sequential quota data collection ───────────────────────────────────────────
# Sequential execution ensures each subscription's Az context is fully set before
# any cmdlets run. Cmdlets such as Get-AzComputeResourceSku and Get-AzVMUsage have
# no -SubscriptionId parameter and rely on the current context — parallelization
# caused race conditions where the wrong subscription's data was returned.
$allResults = [System.Collections.Generic.List[object]]::new()
foreach ($subId in $resolvedSubscriptionIds) {
    $subResults = Get-SubscriptionQuotaData `
        -SubscriptionId     $subId `
        -Region             $Region `
        -CpuFamilies        $resolvedFamilies `
        -ResourceManagerUrl $resourceManagerUrl
    foreach ($r in $subResults) { $allResults.Add($r) }
}

if ($allResults.Count -eq 0) {
    Write-Warning "No quota data was collected. Verify the region name and that subscriptions are accessible."
}

# ── Discover Quota Group memberships and details ────────────────────────────────
Write-Host "`nDiscovering Quota Group memberships..."
$groupMembership = Get-QuotaGroupMembership `
    -SubscriptionIds    $resolvedSubscriptionIds `
    -ResourceManagerUrl $resourceManagerUrl

Write-Host "Fetching group quota details..."
$groupDetails = Get-QuotaGroupDetails `
    -GroupMembership    $groupMembership `
    -Region             $Region `
    -ResourceManagerUrl $resourceManagerUrl

Write-Host "Quota Groups found: $($groupDetails.Count)"

# ── Generate and write Markdown report ─────────────────────────────────────────
Write-Host "`nGenerating Markdown report..."
$markdownContent = New-MarkdownReport `
    -Results      $allResults `
    -Region       $Region `
    -CpuFamilies  $resolvedFamilies `
    -GeneratedAt  $scriptStart `
    -GroupDetails $groupDetails

$markdownContent | Out-File -FilePath $reportPath -Encoding UTF8 -Force

# ── Summary ─────────────────────────────────────────────────────────────────────
$totalElapsed = [math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)

Write-Host ""
Write-Host "Report written to: $reportPath" -ForegroundColor Green
Write-Host "Subscriptions analyzed : $($resolvedSubscriptionIds.Count)"
Write-Host "CPU families analyzed  : $($resolvedFamilies.Count)"
Write-Host "Quota groups found     : $($groupDetails.Count)"
Write-Host "Region                 : $Region"
Write-Host "Total time             : $totalElapsed`s"
