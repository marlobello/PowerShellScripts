#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Compute, Az.ResourceGraph

<#
.SYNOPSIS
    Finds Azure VMs on v2, v3, or v4 SKUs and assesses moves to v6 or v7.

.DESCRIPTION
    Uses Azure Resource Graph to inventory virtual machines, Azure PowerShell to
    inspect each VM and execute a guest readiness check, and Azure Compute REST APIs to
    retrieve regional SKU capabilities/restrictions and the VM's direct-resize options.

    Candidate v6/v7 sizes are limited to the VM's current SKU series and must provide at
    least the current vCPU and memory. The report distinguishes:
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
        [System.Collections.Generic.HashSet[string]]$AvailableSizes,
        [Parameter(Mandatory = $true)][object]$GuestReadiness
    )

    $current = ConvertTo-CapabilityMap -Capabilities $CurrentSku.capabilities
    $target = ConvertTo-CapabilityMap -Capabilities $CandidateSku.capabilities
    $gaps = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    $currentCpus = ConvertTo-Decimal (Get-CapabilityValue -Map $current -Name 'vCPUs')
    $targetCpus = ConvertTo-Decimal (Get-CapabilityValue -Map $target -Name 'vCPUs')
    $currentMemory = ConvertTo-Decimal (Get-CapabilityValue -Map $current -Name 'MemoryGB')
    $targetMemory = ConvertTo-Decimal (Get-CapabilityValue -Map $target -Name 'MemoryGB')

    if ($targetCpus -lt $currentCpus) {
        $gaps.Add("vCPU capacity drops from $currentCpus to $targetCpus")
    }
    if ($targetMemory -lt $currentMemory) {
        $gaps.Add("Memory drops from $currentMemory GB to $targetMemory GB")
    }

    $dataDiskCount = @($VmModel.StorageProfile.DataDisks).Count
    $targetDataDisks = ConvertTo-Decimal (Get-CapabilityValue -Map $target -Name 'MaxDataDiskCount')
    if ($targetDataDisks -lt $dataDiskCount) {
        $gaps.Add("$dataDiskCount data disks are attached; target supports $targetDataDisks")
    }

    $nicCount = @($VmModel.NetworkProfile.NetworkInterfaces).Count
    $targetNics = ConvertTo-Decimal (Get-CapabilityValue -Map $target -Name 'MaxNetworkInterfaces')
    if ($targetNics -lt $nicCount) {
        $gaps.Add("$nicCount NICs are attached; target supports $targetNics")
    }

    if ((ConvertTo-Boolean (Get-CapabilityValue -Map $current -Name 'PremiumIO')) -and
        -not (ConvertTo-Boolean (Get-CapabilityValue -Map $target -Name 'PremiumIO'))) {
        $gaps.Add('Current SKU supports Premium Storage but target does not')
    }

    if ($Vm.AcceleratedNetworking -and
        -not (ConvertTo-Boolean (Get-CapabilityValue -Map $target -Name 'AcceleratedNetworkingEnabled'))) {
        $gaps.Add('Accelerated Networking is enabled but target does not support it')
    }

    if ($Vm.EphemeralOsDisk -and
        -not (ConvertTo-Boolean (Get-CapabilityValue -Map $target -Name 'EphemeralOSDiskSupported'))) {
        $gaps.Add('Ephemeral OS disk is configured but target does not support it')
    }

    if ($Vm.UltraSsdEnabled -and
        -not (ConvertTo-Boolean (Get-CapabilityValue -Map $target -Name 'UltraSSDAvailable'))) {
        $gaps.Add('Ultra Disk compatibility is enabled but target does not support Ultra Disk')
    }

    if ($Vm.EncryptionAtHost -and
        -not (ConvertTo-Boolean (Get-CapabilityValue -Map $target -Name 'EncryptionAtHostSupported'))) {
        $gaps.Add('Encryption at host is enabled but target does not support it')
    }

    if ($Vm.HibernationEnabled -and
        -not (ConvertTo-Boolean (Get-CapabilityValue -Map $target -Name 'HibernationSupported'))) {
        $gaps.Add('Hibernation is enabled but target does not support it')
    }

    if ($Vm.SecurityType -in @('TrustedLaunch', 'ConfidentialVM')) {
        $hyperVGenerations = Get-CapabilityValue -Map $target -Name 'HyperVGenerations'
        if ($hyperVGenerations -notmatch 'V2') {
            $gaps.Add("$($Vm.SecurityType) requires generation 2 support")
        }
        if ($Vm.SecurityType -eq 'TrustedLaunch' -and
            (ConvertTo-Boolean (Get-CapabilityValue -Map $target -Name 'TrustedLaunchDisabled'))) {
            $gaps.Add('Trusted Launch is enabled but disabled for the target SKU')
        }
    }

    if (-not (Test-ZoneAvailable -Sku $CandidateSku -Location $Vm.Location -Zone $Vm.Zone)) {
        $gaps.Add("Target is not offered in availability zone $($Vm.Zone)")
    }
    foreach ($restriction in @(Test-SkuRestricted -Sku $CandidateSku -Location $Vm.Location -Zone $Vm.Zone)) {
        $gaps.Add($restriction)
    }

    $currentArchitecture = Get-CapabilityValue -Map $current -Name 'CpuArchitectureType'
    $targetArchitecture = Get-CapabilityValue -Map $target -Name 'CpuArchitectureType'
    if ($currentArchitecture -and $targetArchitecture -and
        $currentArchitecture -ne $targetArchitecture) {
        $gaps.Add("Current SKU architecture '$currentArchitecture' is incompatible with target architecture '$targetArchitecture'")
    } elseif ($GuestReadiness.Status -eq 'Succeeded' -and $targetArchitecture) {
        $guestArchitecture = [string]$GuestReadiness.Details.architecture
        $guestIsArm = $guestArchitecture -match '^(?i:arm64|aarch64)$'
        $targetIsArm = $targetArchitecture -match '^(?i:arm64)$'
        if ($guestIsArm -ne $targetIsArm) {
            $gaps.Add("Guest architecture '$guestArchitecture' is incompatible with target architecture '$targetArchitecture'")
        }
    } elseif ($targetArchitecture) {
        $warnings.Add("Guest architecture was not verified; target architecture is $targetArchitecture")
    }

    $currentController = [string]$Vm.DiskControllerType
    $targetControllers = Get-CapabilityValue -Map $target -Name 'DiskControllerTypes'
    $targetControllerList = @($targetControllers -split '\s*,\s*')
    if ($currentController -and $targetControllers -and $currentController -notin $targetControllerList) {
        if ($targetControllers -match '(?i)NVMe' -and
            $GuestReadiness.Status -eq 'Succeeded' -and
            -not $GuestReadiness.Details.nvmeDriverPresent) {
            $gaps.Add("Target requires '$targetControllers' storage; the guest NVMe driver was not detected")
        } else {
            $warnings.Add("Storage controller changes from '$currentController' to '$targetControllers'; validate OS/image support")
        }
    }

    $currentTempDisk = ConvertTo-Decimal (Get-CapabilityValue -Map $current -Name 'MaxResourceVolumeMB')
    $targetTempDisk = ConvertTo-Decimal (Get-CapabilityValue -Map $target -Name 'MaxResourceVolumeMB')
    if ($currentTempDisk -gt 0 -and $targetTempDisk -eq 0) {
        $warnings.Add('Target has no local temporary disk; verify the workload does not depend on temporary-disk data or capacity')
    }

    if ($GuestReadiness.Status -eq 'Succeeded' -and -not $GuestReadiness.Details.azureAgentPresent) {
        $warnings.Add('Azure guest agent was not detected by the in-guest check')
    }

    $directResize = $AvailableSizes.Contains([string]$CandidateSku.name)
    if (-not $directResize) {
        $warnings.Add('Not currently returned by listAvailableSizes; deallocation, another cluster, quota, or capacity may be required')
    }

    $version = if ($CandidateSku.name -match '_v([67])$') { [int]$Matches[1] } else { 99 }
    $score = ($gaps.Count * 100000) +
        ($(if ($directResize) { 0 } else { 10000 })) +
        ([math]::Max(0, $targetCpus - $currentCpus) * 100) +
        [math]::Max(0, $targetMemory - $currentMemory) +
        $version

    return [pscustomobject]@{
        Sku                    = [string]$CandidateSku.name
        Version                = $version
        vCPUs                  = $targetCpus
        MemoryGB               = $targetMemory
        DirectResizeAvailable  = $directResize
        Compatible             = ($gaps.Count -eq 0)
        CapabilityGaps         = @($gaps)
        Warnings               = @($warnings)
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
            Vm                 = ConvertTo-VmReportObject -Vm $vm
            GuestReadiness     = $null
            Candidates         = @()
            NoCandidateReason  = $null
            AssessmentError    = "Current SKU '$($vm.VmSize)' was not returned by the regional Resource SKUs API."
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
        $currentCpus = ConvertTo-Decimal (Get-CapabilityValue -Map $currentMap -Name 'vCPUs')
        $currentMemory = ConvertTo-Decimal (Get-CapabilityValue -Map $currentMap -Name 'MemoryGB')
        $series = Get-SkuSeries -SkuName $vm.VmSize

        $candidateSkus = @(
            $regionSkus | Where-Object {
                $_.name -match '_v[67]$' -and
                (Get-SkuSeries -SkuName $_.name) -eq $series
            }
        )

        $assessments = foreach ($candidateSku in $candidateSkus) {
            $candidateMap = ConvertTo-CapabilityMap -Capabilities $candidateSku.capabilities
            $candidateCpus = ConvertTo-Decimal (Get-CapabilityValue -Map $candidateMap -Name 'vCPUs')
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

        $ranked = @($assessments | Sort-Object Score, Sku | Select-Object -First $MaxCandidates)
        $noCandidateReason = if ($ranked.Count -eq 0) {
            "No same-series v6/v7 SKU with at least $currentCpus vCPUs and $currentMemory GB was found in $($vm.location)."
        } else {
            $null
        }

        $details.Add([pscustomobject]@{
            Vm              = ConvertTo-VmReportObject -Vm $vm -VmModel $vmModel
            GuestReadiness  = $guestReadiness
            Candidates      = $ranked
            NoCandidateReason = $noCandidateReason
            AssessmentError = $null
        })
    } catch {
        $details.Add([pscustomobject]@{
            Vm              = ConvertTo-VmReportObject -Vm $vm
            GuestReadiness  = $null
            Candidates      = @()
            NoCandidateReason = $null
            AssessmentError = $_.Exception.Message
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
    $gapCandidates = if ($compatible.Count -gt 0) { @() } else { @($detail.Candidates) }
    $warningCandidates = if ($compatible.Count -gt 0) { $compatible } else { @($detail.Candidates) }
    $allGaps = @(
        $gapCandidates.CapabilityGaps |
            ForEach-Object { $_ } |
            Sort-Object -Unique
    )
    if ($detail.NoCandidateReason) {
        $allGaps = @($detail.NoCandidateReason) + $allGaps
    }
    $allWarnings = @(
        $warningCandidates.Warnings |
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

$errorCount = @($summary | Where-Object { $_.AssessmentError }).Count
$readyCount = @(
    $summary | Where-Object {
        -not $_.AssessmentError -and $_.DirectResizeCandidates
    }
).Count
$deallocateCount = @(
    $summary | Where-Object {
        -not $_.AssessmentError -and
        $_.CompatibleCandidates -and
        -not $_.DirectResizeCandidates
    }
).Count
$blockedCount = $summary.Count - $readyCount - $deallocateCount - $errorCount

Write-Host ''
Write-Host 'Assessment complete.' -ForegroundColor Green
Write-Host "  Direct compatible resize available : $readyCount"
Write-Host "  Compatible after placement review  : $deallocateCount"
Write-Host "  No compatible candidate identified : $blockedCount"
Write-Host "  Assessment errors                   : $errorCount"
Write-Host "  Summary CSV                         : $csvPath"
Write-Host "  Detailed JSON                       : $jsonPath"

$summary
