#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Compute, Az.ResourceGraph

<#
.SYNOPSIS
    Finds Azure VMs on v2, v3, or v4 SKUs and assesses moves to v6 or v7.

.DESCRIPTION
    Uses Azure Resource Graph to inventory virtual machines, Azure PowerShell to
    inspect each VM and execute a guest readiness check, and Azure Compute REST APIs to
    retrieve regional SKU capabilities/restrictions and the VM's direct-resize options.

    Candidate v6/v7 sizes must provide at least the current vCPU and memory. Same-series
    targets are preferred, but the assessment also considers other v6/v7 series so legacy
    families such as B-series v2 can receive a viable migration recommendation. The report
    distinguishes:
      - Capability gaps that make a candidate incompatible with the VM configuration.
      - Direct-resize gaps, where the candidate is not currently offered by the VM's
        listAvailableSizes API. Deallocating the VM can expose additional sizes because
        a running VM is constrained by the hardware cluster where it is allocated.
      - Warnings that require workload-owner review.

    A summary CSV and a detailed JSON report are written to the output directory.

.PARAMETER SubscriptionId
    Azure subscription GUID containing the VMs to assess.

.PARAMETER ResourceGroupId
    Optional resource group name or full ARM resource group ID. When supplied, only VMs
    in that resource group are assessed.

.PARAMETER OutputDirectory
    Directory for the CSV and JSON reports. Defaults to ./output.

.PARAMETER MaxCandidates
    Maximum candidate v6/v7 SKUs retained per VM after ranking. Defaults to 10.

.PARAMETER SkipGuestCheck
    Skips Invoke-AzVMRunCommand. Guest architecture and NVMe readiness are then reported
    as not verified. Run Command is also skipped automatically for VMs that are not running.

.EXAMPLE
    ./Get-AzVmSkuUpgradeGap.ps1 -SubscriptionId '00000000-0000-0000-0000-000000000000'

.EXAMPLE
    ./Get-AzVmSkuUpgradeGap.ps1 -SubscriptionId '00000000-0000-0000-0000-000000000000' `
        -ResourceGroupId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/prod-rg'

.NOTES
    Run from Azure Cloud Shell after selecting an account that has:
      - Reader access to the subscription and VM resources.
      - Microsoft.Compute/virtualMachines/runCommand/action on target VMs.

    Run Command executes read-only operating-system discovery commands. It does not
    install software or change VM configuration.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [Alias('ResourceGroupName')]
    [string]$ResourceGroupId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'output'),

    [Parameter()]
    [ValidateRange(1, 100)]
    [int]$MaxCandidates = 10,

    [Parameter()]
    [switch]$SkipGuestCheck
)

$ErrorActionPreference = 'Stop'
$script:ComputeSkuApiVersion = '2021-07-01'
$script:VmApiVersion = '2024-07-01'

function Resolve-ResourceGroupName {
    [CmdletBinding()]
    param (
        [string]$Value,
        [Parameter(Mandatory = $true)][string]$ExpectedSubscriptionId
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    if ($Value -match '^/subscriptions/([^/]+)/resourceGroups/([^/]+)$') {
        if ($Matches[1] -ne $ExpectedSubscriptionId) {
            throw "ResourceGroupId belongs to subscription '$($Matches[1])', not '$ExpectedSubscriptionId'."
        }
        return $Matches[2]
    }

    if ($Value -match '/') {
        throw "ResourceGroupId must be a resource group name or a full '/subscriptions/{id}/resourceGroups/{name}' ID."
    }

    return $Value
}

function Invoke-ArmGet {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Path
    )

    $request = @{ Method = 'GET' }
    if ($Path -match '^https?://') {
        $request.Uri = $Path
    } else {
        $request.Path = $Path
    }

    $response = Invoke-AzRestMethod @request
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "Azure REST GET '$Path' returned HTTP $($response.StatusCode): $($response.Content)"
    }

    if ([string]::IsNullOrWhiteSpace($response.Content)) {
        return $null
    }

    return $response.Content | ConvertFrom-Json -Depth 100
}

function Get-ArmCollection {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Path
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $nextPath = $Path

    while ($nextPath) {
        $page = Invoke-ArmGet -Path $nextPath
        foreach ($item in @($page.value)) {
            $items.Add($item)
        }
        $nextPath = $page.nextLink
    }

    return @($items)
}

function Get-GraphResults {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Query,
        [Parameter(Mandatory = $true)][string]$Subscription
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $skipToken = $null

    do {
        $parameters = @{
            Query        = $Query
            Subscription = $Subscription
            First        = 1000
        }
        if ($skipToken) {
            $parameters.SkipToken = $skipToken
        }

        $page = Search-AzGraph @parameters
        foreach ($item in @($page)) {
            $items.Add($item)
        }
        $skipToken = $page.SkipToken
    } while ($skipToken)

    return @($items)
}

function ConvertTo-CapabilityMap {
    [CmdletBinding()]
    param (
        [object[]]$Capabilities
    )

    $map = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($capability in @($Capabilities)) {
        if ($capability.name) {
            $map[$capability.name] = [string]$capability.value
        }
    }
    return $map
}

function Get-CapabilityValue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.Dictionary[string, string]]$Map,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Default = $null
    )

    if ($Map.ContainsKey($Name)) {
        return $Map[$Name]
    }
    return $Default
}

function ConvertTo-Boolean {
    [CmdletBinding()]
    param (
        [string]$Value
    )

    return $Value -match '^(?i:true|1|yes)$'
}

function ConvertTo-Decimal {
    [CmdletBinding()]
    param (
        [string]$Value
    )

    $number = 0.0
    if ([double]::TryParse(
        $Value,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$number
    )) {
        return $number
    }
    return 0.0
}

function Get-AvailableVcpuCount {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.Dictionary[string, string]]$CapabilityMap
    )

    $available = ConvertTo-Decimal (Get-CapabilityValue -Map $CapabilityMap -Name 'vCPUsAvailable')
    if ($available -gt 0) {
        return $available
    }
    return ConvertTo-Decimal (Get-CapabilityValue -Map $CapabilityMap -Name 'vCPUs')
}

function Get-SkuSeries {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$SkuName
    )

    if ($SkuName -notmatch '^Standard_([A-Za-z]+)\d') {
        return $null
    }

    $prefix = $Matches[1].ToUpperInvariant()
    if ($prefix -match '^(D|E|F|G|L|M)S$') {
        return $Matches[1]
    }
    return $prefix
}

function Test-SkuRestricted {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][object]$Sku,
        [Parameter(Mandatory = $true)][string]$Location,
        [string]$Zone
    )

    $messages = [System.Collections.Generic.List[string]]::new()
    foreach ($restriction in @($Sku.restrictions)) {
        $applies = switch ([string]$restriction.type) {
            'Location' { @($restriction.values) -contains $Location }
            'Zone' {
                $restrictedLocations = @($restriction.restrictionInfo.locations)
                $restrictedZones = @($restriction.restrictionInfo.zones)
                $locationApplies = ($restrictedLocations.Count -eq 0) -or
                    ($restrictedLocations -contains $Location) -or
                    (@($restriction.values) -contains $Location)
                $Zone -and $locationApplies -and ($restrictedZones -contains $Zone)
            }
            default    { $false }
        }

        if ($applies) {
            $reason = if ($restriction.reasonCode) { $restriction.reasonCode } else { 'Restricted' }
            $messages.Add("$($restriction.type) restriction ($reason)")
        }
    }
    return @($messages)
}

function Test-ZoneAvailable {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][object]$Sku,
        [Parameter(Mandatory = $true)][string]$Location,
        [string]$Zone
    )

    if (-not $Zone) {
        return $true
    }

    $locationInfo = @($Sku.locationInfo) | Where-Object { $_.location -eq $Location }
    return @($locationInfo.zones) -contains $Zone
}

function Get-GuestReadiness {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][ValidateSet('Windows', 'Linux')][string]$OsType
    )

    if ($OsType -eq 'Windows') {
        $scriptText = @'
$firmware = 'Unknown'
try {
    $null = Confirm-SecureBootUEFI -ErrorAction Stop
    $firmware = 'UEFI'
} catch {
    if ($_.Exception.Message -match 'not supported on this platform') { $firmware = 'BIOS' }
}
$nvme = Get-Service -Name 'stornvme' -ErrorAction SilentlyContinue
$payload = [ordered]@{
    architecture = $env:PROCESSOR_ARCHITECTURE
    osVersion = [System.Environment]::OSVersion.VersionString
    firmware = $firmware
    nvmeDriverPresent = ($null -ne $nvme)
    azureAgentPresent = ($null -ne (Get-Service -Name 'WindowsAzureGuestAgent' -ErrorAction SilentlyContinue))
}
Write-Output ('AZSKU_GUEST_JSON=' + ($payload | ConvertTo-Json -Compress))
'@
        $commandId = 'RunPowerShellScript'
    } else {
        $scriptText = @'
arch="$(uname -m 2>/dev/null)"
kernel="$(uname -r 2>/dev/null)"
if [ -d /sys/firmware/efi ]; then firmware="UEFI"; else firmware="BIOS"; fi
if modinfo nvme >/dev/null 2>&1 || [ -d /sys/module/nvme ]; then nvme=true; else nvme=false; fi
if command -v waagent >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q waagent; then agent=true; else agent=false; fi
printf 'AZSKU_GUEST_JSON={"architecture":"%s","osVersion":"%s","firmware":"%s","nvmeDriverPresent":%s,"azureAgentPresent":%s}\n' "$arch" "$kernel" "$firmware" "$nvme" "$agent"
'@
        $commandId = 'RunShellScript'
    }

    try {
        $result = Invoke-AzVMRunCommand `
            -ResourceGroupName $ResourceGroupName `
            -VMName $VmName `
            -CommandId $commandId `
            -ScriptString $scriptText `
            -ErrorAction Stop

        $message = (@($result.Value).Message -join "`n")
        if ($message -notmatch 'AZSKU_GUEST_JSON=(\{[^\r\n]+\})') {
            return [pscustomobject]@{
                Status  = 'Unparseable'
                Error   = 'Run Command completed but did not return the expected readiness payload.'
                Details = $null
            }
        }

        return [pscustomobject]@{
            Status  = 'Succeeded'
            Error   = $null
            Details = ($Matches[1] | ConvertFrom-Json)
        }
    } catch {
        return [pscustomobject]@{
            Status  = 'Failed'
            Error   = $_.Exception.Message
            Details = $null
        }
    }
}

function ConvertTo-VmReportObject {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][object]$Vm,
        [object]$VmModel
    )

    return [pscustomobject]@{
        Id                    = $Vm.id
        Name                  = $Vm.name
        ResourceGroup         = $Vm.resourceGroup
        Location              = $Vm.location
        Zone                  = $Vm.Zone
        OsType                = $Vm.OsType
        CurrentSku            = $Vm.VmSize
        Series                = Get-SkuSeries -SkuName $Vm.VmSize
        PowerState            = $Vm.PowerState
        SecurityType          = $Vm.SecurityType
        DiskControllerType    = $Vm.DiskControllerType
        AcceleratedNetworking = [bool]$Vm.AcceleratedNetworking
        EphemeralOsDisk       = [bool]$Vm.EphemeralOsDisk
        UltraSsdEnabled       = [bool]$Vm.UltraSsdEnabled
        EncryptionAtHost      = [bool]$Vm.EncryptionAtHost
        HibernationEnabled    = [bool]$Vm.HibernationEnabled
        DataDiskCount         = if ($VmModel) { @($VmModel.StorageProfile.DataDisks).Count } else { $null }
        NicCount              = if ($VmModel) { @($VmModel.NetworkProfile.NetworkInterfaces).Count } else { $null }
    }
}

function Get-CandidateAssessment {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][object]$Vm,
        [Parameter(Mandatory = $true)][object]$VmModel,
        [Parameter(Mandatory = $true)][object]$CurrentSku,
        [Parameter(Mandatory = $true)][object]$CandidateSku,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$AvailableSizes,
        [Parameter(Mandatory = $true)][object]$GuestReadiness
    )

    $current = ConvertTo-CapabilityMap -Capabilities $CurrentSku.capabilities
    $target = ConvertTo-CapabilityMap -Capabilities $CandidateSku.capabilities
    $gaps = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $actions = [System.Collections.Generic.List[string]]::new()

    $currentCpus = Get-AvailableVcpuCount -CapabilityMap $current
    $targetCpus = Get-AvailableVcpuCount -CapabilityMap $target
    $currentMemory = ConvertTo-Decimal (Get-CapabilityValue -Map $current -Name 'MemoryGB')
    $targetMemory = ConvertTo-Decimal (Get-CapabilityValue -Map $target -Name 'MemoryGB')

    if ($targetCpus -lt $currentCpus) {
        $gaps.Add("vCPU capacity drops from $currentCpus to $targetCpus")
        $actions.Add("Choose a target with at least $currentCpus vCPUs.")
    }
    if ($targetMemory -lt $currentMemory) {
        $gaps.Add("Memory drops from $currentMemory GB to $targetMemory GB")
        $actions.Add("Choose a target with at least $currentMemory GB of memory.")
    }

    $dataDiskCount = @($VmModel.StorageProfile.DataDisks).Count
    $targetDataDisks = ConvertTo-Decimal (Get-CapabilityValue -Map $target -Name 'MaxDataDiskCount')
    if ($targetDataDisks -lt $dataDiskCount) {
        $gaps.Add("$dataDiskCount data disks are attached; target supports $targetDataDisks")
        $actions.Add("Detach or consolidate data disks, or choose a target that supports at least $dataDiskCount data disks.")
    }

    $nicCount = @($VmModel.NetworkProfile.NetworkInterfaces).Count
    $targetNics = ConvertTo-Decimal (Get-CapabilityValue -Map $target -Name 'MaxNetworkInterfaces')
    if ($targetNics -lt $nicCount) {
        $gaps.Add("$nicCount NICs are attached; target supports $targetNics")
        $actions.Add("Remove excess NICs, or choose a target that supports at least $nicCount NICs.")
    }

    if ((ConvertTo-Boolean (Get-CapabilityValue -Map $current -Name 'PremiumIO')) -and
        -not (ConvertTo-Boolean (Get-CapabilityValue -Map $target -Name 'PremiumIO'))) {
        $gaps.Add('Current SKU supports Premium Storage but target does not')
        $actions.Add('Choose a target that supports Premium Storage.')
    }

    if ($Vm.AcceleratedNetworking -and
        -not (ConvertTo-Boolean (Get-CapabilityValue -Map $target -Name 'AcceleratedNetworkingEnabled'))) {
        $gaps.Add('Accelerated Networking is enabled but target does not support it')
        $actions.Add('Choose a target that supports Accelerated Networking, or disable Accelerated Networking on every NIC before resizing.')
    }

    if ($Vm.EphemeralOsDisk -and
        -not (ConvertTo-Boolean (Get-CapabilityValue -Map $target -Name 'EphemeralOSDiskSupported'))) {
        $gaps.Add('Ephemeral OS disk is configured but target does not support it')
        $actions.Add('Choose a target that supports Ephemeral OS disks, or recreate the VM with a managed OS disk.')
    }

    if ($Vm.UltraSsdEnabled -and
        -not (ConvertTo-Boolean (Get-CapabilityValue -Map $target -Name 'UltraSSDAvailable'))) {
        $gaps.Add('Ultra Disk compatibility is enabled but target does not support Ultra Disk')
        $actions.Add('Choose a target that supports Ultra Disk, or detach Ultra Disks and disable Ultra Disk compatibility before resizing.')
    }

    if ($Vm.EncryptionAtHost -and
        -not (ConvertTo-Boolean (Get-CapabilityValue -Map $target -Name 'EncryptionAtHostSupported'))) {
        $gaps.Add('Encryption at host is enabled but target does not support it')
        $actions.Add('Choose a target that supports encryption at host.')
    }

    if ($Vm.HibernationEnabled -and
        -not (ConvertTo-Boolean (Get-CapabilityValue -Map $target -Name 'HibernationSupported'))) {
        $gaps.Add('Hibernation is enabled but target does not support it')
        $actions.Add('Disable hibernation before resizing, or choose a target that supports hibernation.')
    }

    if ($Vm.SecurityType -in @('TrustedLaunch', 'ConfidentialVM')) {
        $hyperVGenerations = Get-CapabilityValue -Map $target -Name 'HyperVGenerations'
        if ($hyperVGenerations -notmatch 'V2') {
            $gaps.Add("$($Vm.SecurityType) requires generation 2 support")
            $actions.Add("Choose a generation 2 target that supports $($Vm.SecurityType).")
        }
        if ($Vm.SecurityType -eq 'TrustedLaunch' -and
            (ConvertTo-Boolean (Get-CapabilityValue -Map $target -Name 'TrustedLaunchDisabled'))) {
            $gaps.Add('Trusted Launch is enabled but disabled for the target SKU')
            $actions.Add('Choose a target SKU that supports Trusted Launch.')
        }
    }

    if (-not (Test-ZoneAvailable -Sku $CandidateSku -Location $Vm.Location -Zone $Vm.Zone)) {
        $gaps.Add("Target is not offered in availability zone $($Vm.Zone)")
        $actions.Add("Choose a target available in zone $($Vm.Zone), or redeploy the VM into a supported zone.")
    }
    foreach ($restriction in @(Test-SkuRestricted -Sku $CandidateSku -Location $Vm.Location -Zone $Vm.Zone)) {
        $gaps.Add($restriction)
        $actions.Add('Choose an unrestricted target SKU or request the required SKU access/quota for this subscription and zone.')
    }

    $currentArchitecture = Get-CapabilityValue -Map $current -Name 'CpuArchitectureType'
    $targetArchitecture = Get-CapabilityValue -Map $target -Name 'CpuArchitectureType'
    if ($currentArchitecture -and $targetArchitecture -and
        $currentArchitecture -ne $targetArchitecture) {
        $gaps.Add("Current SKU architecture '$currentArchitecture' is incompatible with target architecture '$targetArchitecture'")
        $actions.Add("Choose a $currentArchitecture target; changing CPU architecture requires rebuilding the VM with a compatible OS image.")
    } elseif ($GuestReadiness.Status -eq 'Succeeded' -and $targetArchitecture) {
        $guestArchitecture = [string]$GuestReadiness.Details.architecture
        $guestIsArm = $guestArchitecture -match '^(?i:arm64|aarch64)$'
        $targetIsArm = $targetArchitecture -match '^(?i:arm64)$'
        if ($guestIsArm -ne $targetIsArm) {
            $gaps.Add("Guest architecture '$guestArchitecture' is incompatible with target architecture '$targetArchitecture'")
            $actions.Add("Choose a target compatible with guest architecture '$guestArchitecture'.")
        }
    }

    if ($GuestReadiness.Status -ne 'Succeeded') {
        $warnings.Add("Guest readiness was not verified ($($GuestReadiness.Status))")
        $actions.Add('Start the VM if necessary and rerun the assessment without -SkipGuestCheck to validate guest architecture, Azure agent, and NVMe readiness.')
    }

    $currentController = [string]$Vm.DiskControllerType
    $targetControllers = Get-CapabilityValue -Map $target -Name 'DiskControllerTypes'
    $targetControllerList = @($targetControllers -split '\s*,\s*')
    if ($currentController -and $targetControllers -and $currentController -notin $targetControllerList) {
        if ($targetControllers -match '(?i)NVMe' -and
            $GuestReadiness.Status -eq 'Succeeded' -and
            -not $GuestReadiness.Details.nvmeDriverPresent) {
            $gaps.Add("Target requires '$targetControllers' storage; the guest NVMe driver was not detected")
            $actions.Add('Install and enable the NVMe driver in the guest OS before resizing, or choose a target that supports the current storage controller.')
        } else {
            $warnings.Add("Storage controller changes from '$currentController' to '$targetControllers'; validate OS/image support")
            $actions.Add("Confirm that the OS image supports '$targetControllers' and install/enable the required storage driver before resizing.")
        }
    }

    $currentTempDisk = ConvertTo-Decimal (Get-CapabilityValue -Map $current -Name 'MaxResourceVolumeMB')
    $targetTempDisk = ConvertTo-Decimal (Get-CapabilityValue -Map $target -Name 'MaxResourceVolumeMB')
    if ($currentTempDisk -gt 0 -and $targetTempDisk -eq 0) {
        $warnings.Add('Target has no local temporary disk; verify the workload does not depend on temporary-disk data or capacity')
        $actions.Add('Move required data and workload dependencies off the temporary disk before resizing.')
    }

    if ($GuestReadiness.Status -eq 'Succeeded' -and -not $GuestReadiness.Details.azureAgentPresent) {
        $warnings.Add('Azure guest agent was not detected by the in-guest check')
        $actions.Add('Install or repair the Azure VM agent before the migration.')
    }

    $directResize = $AvailableSizes.Contains([string]$CandidateSku.name)
    if (-not $directResize) {
        $warnings.Add('Not currently returned by listAvailableSizes; deallocation, another cluster, quota, or capacity may be required')
        $actions.Add('Deallocate the VM, confirm regional vCPU-family quota and SKU capacity, then retry the resize.')
    }

    $version = if ($CandidateSku.name -match '_v([67])$') { [int]$Matches[1] } else { 99 }
    $currentSeries = Get-SkuSeries -SkuName $Vm.VmSize
    $targetSeries = Get-SkuSeries -SkuName $CandidateSku.name
    $seriesPreference = if ($targetSeries -eq $currentSeries) {
        0
    } elseif ($currentSeries -eq 'B' -and $targetSeries -in @('D', 'E', 'F')) {
        1
    } else {
        2
    }
    $score = ($gaps.Count * 100000) +
        ($seriesPreference * 10000) +
        ($(if ($directResize) { 0 } else { 1000 })) +
        ([math]::Max(0, $targetCpus - $currentCpus) * 100) +
        [math]::Max(0, $targetMemory - $currentMemory) +
        $version

    $readinessStatus = if ($gaps.Count -gt 0) {
        'Blocked'
    } elseif ($warnings.Count -gt 0) {
        'ReadyAfterActions'
    } else {
        'ReadyToResize'
    }

    return [pscustomobject]@{
        Sku                    = [string]$CandidateSku.name
        Series                 = $targetSeries
        Version                = $version
        vCPUs                  = $targetCpus
        MemoryGB               = $targetMemory
        DirectResizeAvailable  = $directResize
        Compatible             = ($gaps.Count -eq 0)
        ReadinessStatus        = $readinessStatus
        SeriesPreference       = $seriesPreference
        GapCount               = $gaps.Count
        WarningCount           = $warnings.Count
        CapabilityGaps         = @($gaps)
        Warnings               = @($warnings)
        RequiredActions        = @($actions | Sort-Object -Unique)
        Score                  = $score
    }
}

$resourceGroupName = Resolve-ResourceGroupName `
    -Value $ResourceGroupId `
    -ExpectedSubscriptionId $SubscriptionId

$context = Get-AzContext
if (-not $context) {
    throw 'No Azure context is available. Run Connect-AzAccount before executing this script.'
}

Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

$resourceGroupFilter = ''
if ($resourceGroupName) {
    $escapedResourceGroup = $resourceGroupName.Replace("'", "''")
    $resourceGroupFilter = "| where resourceGroup =~ '$escapedResourceGroup'"
}

$query = @"
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| extend VmSize = tostring(properties.hardwareProfile.vmSize)
| extend PowerState = tostring(properties.extended.instanceView.powerState.code)
| where VmSize matches regex @'_v[234]$'
$resourceGroupFilter
| mv-expand Nic = properties.networkProfile.networkInterfaces to typeof(dynamic)
| extend NicId = tolower(tostring(Nic.id))
| join kind=leftouter (
    Resources
    | where type =~ 'microsoft.network/networkinterfaces'
    | project NicId = tolower(id), Accelerated = tobool(properties.enableAcceleratedNetworking)
) on NicId
| summarize AcceleratedNetworking = max(toint(coalesce(Accelerated, false))) by
    id, name, resourceGroup, subscriptionId, location, VmSize, PowerState,
    OsType = tostring(properties.storageProfile.osDisk.osType),
    Zone = tostring(zones[0]),
    SecurityType = tostring(properties.securityProfile.securityType),
    EncryptionAtHost = tobool(properties.securityProfile.encryptionAtHost),
    HibernationEnabled = tobool(properties.additionalCapabilities.hibernationEnabled),
    UltraSsdEnabled = tobool(properties.additionalCapabilities.ultraSSDEnabled),
    EphemeralOsDisk = tostring(properties.storageProfile.osDisk.diffDiskSettings.option) =~ 'Local',
    DiskControllerType = tostring(properties.storageProfile.diskControllerType)
| order by resourceGroup asc, name asc
"@

Write-Host 'Querying Azure Resource Graph for VMs using v2-v4 SKUs...' -ForegroundColor Cyan
$vms = @(Get-GraphResults -Query $query -Subscription $SubscriptionId)
if ($vms.Count -eq 0) {
    Write-Host 'No VMs using a v2, v3, or v4 SKU were found in the requested scope.' -ForegroundColor Green
    return
}

Write-Host "Found $($vms.Count) VM(s). Loading regional Compute SKU metadata..." -ForegroundColor Cyan
$skusByLocation = @{}
foreach ($location in @($vms.Location | Sort-Object -Unique)) {
    $skuPath = "/subscriptions/$SubscriptionId/providers/Microsoft.Compute/skus" +
        "?api-version=$script:ComputeSkuApiVersion&`$filter=location eq '$location'"
    $skusByLocation[$location] = @(
        Get-ArmCollection -Path $skuPath |
            Where-Object { $_.resourceType -eq 'virtualMachines' }
    )
}

$details = [System.Collections.Generic.List[object]]::new()
$index = 0
foreach ($vm in $vms) {
    $index++
    Write-Progress `
        -Activity 'Assessing VM SKU upgrades' `
        -Status "$index of $($vms.Count): $($vm.resourceGroup)/$($vm.name)" `
        -PercentComplete (($index / $vms.Count) * 100)

    $regionSkus = @($skusByLocation[$vm.location])
    $currentSku = $regionSkus | Where-Object { $_.name -eq $vm.VmSize } | Select-Object -First 1
    if (-not $currentSku) {
        $details.Add([pscustomobject]@{
            Vm                   = ConvertTo-VmReportObject -Vm $vm
            ReadinessStatus      = 'AssessmentError'
            RecommendedTargetSku = $null
            RequiredActions      = @('Resolve the SKU metadata error and rerun the assessment.')
            GuestReadiness       = $null
            Candidates           = @()
            NoCandidateReason    = $null
            AssessmentError      = "Current SKU '$($vm.VmSize)' was not returned by the regional Resource SKUs API."
        })
        continue
    }

    try {
        $vmModel = Get-AzVM -ResourceGroupName $vm.resourceGroup -Name $vm.name
        $availablePath = "$($vm.id)/vmSizes?api-version=$script:VmApiVersion"
        $availableResponse = Invoke-ArmGet -Path $availablePath
        $availableSizes = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        foreach ($size in @($availableResponse.value)) {
            $null = $availableSizes.Add([string]$size.name)
        }

        $guestReadiness = if ($SkipGuestCheck) {
            [pscustomobject]@{ Status = 'Skipped'; Error = $null; Details = $null }
        } elseif ($vm.PowerState -ne 'PowerState/running') {
            [pscustomobject]@{
                Status = 'NotRunning'
                Error = "Run Command requires a running VM; current state is '$($vm.PowerState)'."
                Details = $null
            }
        } else {
            Get-GuestReadiness `
                -ResourceGroupName $vm.resourceGroup `
                -VmName $vm.name `
                -OsType $vm.OsType
        }

        $currentMap = ConvertTo-CapabilityMap -Capabilities $currentSku.capabilities
        $currentCpus = Get-AvailableVcpuCount -CapabilityMap $currentMap
        $currentMemory = ConvertTo-Decimal (Get-CapabilityValue -Map $currentMap -Name 'MemoryGB')
        $series = Get-SkuSeries -SkuName $vm.VmSize

        $candidateSkus = @(
            $regionSkus | Where-Object {
                $_.name -match '^Standard_[A-Za-z]+\d.*_v[67]$'
            }
        )

        $assessments = foreach ($candidateSku in $candidateSkus) {
            $candidateMap = ConvertTo-CapabilityMap -Capabilities $candidateSku.capabilities
            $candidateCpus = Get-AvailableVcpuCount -CapabilityMap $candidateMap
            $candidateMemory = ConvertTo-Decimal (Get-CapabilityValue -Map $candidateMap -Name 'MemoryGB')
            if ($candidateCpus -ge $currentCpus -and $candidateMemory -ge $currentMemory) {
                Get-CandidateAssessment `
                    -Vm $vm `
                    -VmModel $vmModel `
                    -CurrentSku $currentSku `
                    -CandidateSku $candidateSku `
                    -AvailableSizes $availableSizes `
                    -GuestReadiness $guestReadiness
            }
        }

        $rankedAll = @(
            $assessments | Sort-Object `
                @{ Expression = { if ($_.Compatible) { 0 } else { 1 } } },
                GapCount,
                SeriesPreference,
                @{ Expression = { if ($_.DirectResizeAvailable) { 0 } else { 1 } } },
                WarningCount,
                vCPUs,
                MemoryGB,
                Version,
                Sku
        )
        $noCandidateReason = if ($rankedAll.Count -eq 0) {
            "No v6/v7 SKU with at least $currentCpus vCPUs and $currentMemory GB was found in $($vm.location)."
        } else {
            $null
        }

        $recommended = @($rankedAll | Where-Object Compatible | Select-Object -First 1)
        if ($recommended.Count -eq 0) {
            $recommended = @($rankedAll | Select-Object -First 1)
        }
        $ranked = @($rankedAll | Select-Object -First $MaxCandidates)

        $readinessStatus = if ($noCandidateReason) {
            'NoTargetFound'
        } elseif ($recommended.Count -eq 0) {
            'Blocked'
        } else {
            $recommended[0].ReadinessStatus
        }
        $requiredActions = if ($noCandidateReason) {
            @('Review other VM families or regions, or select a v6/v7 target with greater vCPU and memory capacity.')
        } elseif ($readinessStatus -eq 'ReadyToResize') {
            @("No remediation is required. Resize the VM to '$($recommended[0].Sku)'.")
        } elseif ($recommended.Count -gt 0) {
            @($recommended[0].RequiredActions)
        } else {
            @('Review candidate capability gaps and choose a compatible v6/v7 target.')
        }

        $details.Add([pscustomobject]@{
            Vm                   = ConvertTo-VmReportObject -Vm $vm -VmModel $vmModel
            ReadinessStatus      = $readinessStatus
            RecommendedTargetSku = if ($recommended.Count -gt 0) { $recommended[0].Sku } else { $null }
            RequiredActions      = $requiredActions
            GuestReadiness       = $guestReadiness
            Candidates           = $ranked
            NoCandidateReason    = $noCandidateReason
            AssessmentError      = $null
        })
    } catch {
        $details.Add([pscustomobject]@{
            Vm                   = ConvertTo-VmReportObject -Vm $vm
            ReadinessStatus      = 'AssessmentError'
            RecommendedTargetSku = $null
            RequiredActions      = @('Resolve the assessment error shown in AssessmentError, then rerun the script.')
            GuestReadiness       = $null
            Candidates           = @()
            NoCandidateReason    = $null
            AssessmentError      = $_.Exception.Message
        })
    }
}
Write-Progress -Activity 'Assessing VM SKU upgrades' -Completed

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$csvPath = Join-Path $OutputDirectory "VmSkuUpgradeGaps_$timestamp.csv"
$jsonPath = Join-Path $OutputDirectory "VmSkuUpgradeGaps_$timestamp.json"

$summary = foreach ($detail in $details) {
    $compatible = @($detail.Candidates | Where-Object Compatible)
    $direct = @($compatible | Where-Object DirectResizeAvailable)
    $recommendedCandidate = @(
        $detail.Candidates |
            Where-Object Sku -eq $detail.RecommendedTargetSku |
            Select-Object -First 1
    )
    $allGaps = @(
        $recommendedCandidate.CapabilityGaps |
            ForEach-Object { $_ } |
            Sort-Object -Unique
    )
    if ($detail.NoCandidateReason) {
        $allGaps = @($detail.NoCandidateReason) + $allGaps
    }
    $allWarnings = @(
        $recommendedCandidate.Warnings |
            ForEach-Object { $_ } |
            Sort-Object -Unique
    )

    [pscustomobject]@{
        SubscriptionId          = $SubscriptionId
        ResourceGroup           = $detail.Vm.ResourceGroup
        VmName                  = $detail.Vm.Name
        Location                = $detail.Vm.Location
        Zone                    = $detail.Vm.Zone
        OsType                  = $detail.Vm.OsType
        CurrentSku              = $detail.Vm.CurrentSku
        ReadinessStatus         = $detail.ReadinessStatus
        RecommendedTargetSku    = $detail.RecommendedTargetSku
        RequiredActions         = ($detail.RequiredActions -join '; ')
        GuestCheck              = $detail.GuestReadiness.Status
        CompatibleCandidates    = ($compatible.Sku -join '; ')
        DirectResizeCandidates  = ($direct.Sku -join '; ')
        CapabilityGaps          = ($allGaps -join '; ')
        Warnings                = ($allWarnings -join '; ')
        NoCandidateReason       = $detail.NoCandidateReason
        AssessmentError         = $detail.AssessmentError
    }
}

$summary | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8
$details | ConvertTo-Json -Depth 20 | Set-Content -Path $jsonPath -Encoding utf8

$errorCount = @($summary | Where-Object ReadinessStatus -eq 'AssessmentError').Count
$readyCount = @($summary | Where-Object ReadinessStatus -eq 'ReadyToResize').Count
$actionCount = @($summary | Where-Object ReadinessStatus -eq 'ReadyAfterActions').Count
$blockedCount = @(
    $summary | Where-Object { $_.ReadinessStatus -in @('Blocked', 'NoTargetFound') }
).Count

Write-Host ''
Write-Host 'Assessment complete.' -ForegroundColor Green
Write-Host "  Ready to resize                     : $readyCount"
Write-Host "  Ready after required actions        : $actionCount"
Write-Host "  Blocked or no target identified     : $blockedCount"
Write-Host "  Assessment errors                   : $errorCount"
Write-Host "  Summary CSV                         : $csvPath"
Write-Host "  Detailed JSON                       : $jsonPath"

$summary
