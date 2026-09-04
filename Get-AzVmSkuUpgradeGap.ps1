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

function ConvertTo-GenerationName {
    [CmdletBinding()]
    param (
        [string]$Value
    )

    switch -Regex ($Value) {
        '^(?i:V1|Gen1|Generation1)$' { return 'Gen1' }
        '^(?i:V2|Gen2|Generation2)$' { return 'Gen2' }
        default                      { return 'Unknown' }
    }
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
$nvmeDriverPath = Join-Path $env:SystemRoot 'System32\drivers\stornvme.sys'
$nvmeStart = Get-ItemPropertyValue `
    -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme' `
    -Name Start `
    -ErrorAction SilentlyContinue
$manaDriver = @(
    Get-ChildItem -Path (Join-Path $env:SystemRoot 'System32\drivers\mana*.sys') -ErrorAction SilentlyContinue
    Get-ChildItem `
        -Path (Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository\*mana*') `
        -Filter '*.sys' `
        -Recurse `
        -ErrorAction SilentlyContinue
) | Select-Object -First 1
$tempDriveLetters = @(
    Get-Volume -ErrorAction SilentlyContinue |
        Where-Object FileSystemLabel -Match '^Temporary Storage$' |
        ForEach-Object { "$($_.DriveLetter):" }
)
$pageFiles = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
$tempDiskInUse = @(
    $pageFiles | Where-Object { $_.Name.Substring(0, 2) -in $tempDriveLetters }
).Count -gt 0
$nestedVirtualization = @(
    Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue |
        Where-Object VirtualizationFirmwareEnabled
).Count -gt 0
$rdmaDevice = @(
    Get-NetAdapterRdma -ErrorAction SilentlyContinue |
        Where-Object Enabled
).Count -gt 0
$thirdPartyBootDrivers = @(
    Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue |
        Where-Object StartMode -In @('Boot', 'System') |
        Where-Object {
            $driverPath = [Environment]::ExpandEnvironmentVariables(($_.PathName -replace '^"|"$', ''))
            if ($driverPath -match '^[^ ]+\.sys') { $driverPath = $Matches[0] }
            if (-not (Test-Path $driverPath)) { return $false }
            $signature = Get-AuthenticodeSignature -FilePath $driverPath -ErrorAction SilentlyContinue
            $signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft'
        }
)
$payload = [ordered]@{
    architecture = $env:PROCESSOR_ARCHITECTURE
    osVersion = [System.Environment]::OSVersion.VersionString
    firmware = $firmware
    nvmeDriverPresent = (Test-Path $nvmeDriverPath)
    nvmeBootReady = ((Test-Path $nvmeDriverPath) -and $nvmeStart -eq 0)
    fstabUsesStableNames = $null
    nvmeIoTimeoutConfigured = $null
    manaDriverPresent = ($null -ne $manaDriver)
    manaDriverVersion = if ($manaDriver) { $manaDriver.VersionInfo.FileVersion } else { $null }
    manaKernelSupported = $null
    temporaryDiskUsageDetected = $tempDiskInUse
    hardCodedScsiPathCount = 0
    thirdPartyKernelDriverCount = $thirdPartyBootDrivers.Count
    nestedVirtualizationDetected = $nestedVirtualization
    rdmaDevicePresent = $rdmaDevice
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
if { modinfo nvme >/dev/null 2>&1 && modinfo nvme_core >/dev/null 2>&1; } || { [ -d /sys/module/nvme ] && [ -d /sys/module/nvme_core ]; }; then
    nvme=true
else
    nvme=false
fi

nvme_boot=null
modules_builtin="/lib/modules/$kernel/modules.builtin"
if [ -f "$modules_builtin" ] &&
   grep -Eq 'drivers/nvme/host/nvme\.ko' "$modules_builtin" &&
   grep -Eq 'drivers/nvme/host/nvme[-_]core\.ko' "$modules_builtin"; then
    nvme_boot=true
else
    initramfs=""
    for candidate in "/boot/initrd.img-$kernel" "/boot/initramfs-$kernel.img" "/boot/initramfs-$kernel"; do
        if [ -f "$candidate" ]; then initramfs="$candidate"; break; fi
    done
    if [ -n "$initramfs" ] && command -v lsinitramfs >/dev/null 2>&1; then
        if lsinitramfs "$initramfs" 2>/dev/null | grep -Eq 'drivers/nvme/host/nvme\.ko' &&
           lsinitramfs "$initramfs" 2>/dev/null | grep -Eq 'drivers/nvme/host/nvme[-_]core\.ko'; then
            nvme_boot=true
        else
            nvme_boot=false
        fi
    elif [ -n "$initramfs" ] && command -v lsinitrd >/dev/null 2>&1; then
        if lsinitrd "$initramfs" 2>/dev/null | grep -Eq 'drivers/nvme/host/nvme\.ko' &&
           lsinitrd "$initramfs" 2>/dev/null | grep -Eq 'drivers/nvme/host/nvme[-_]core\.ko'; then
            nvme_boot=true
        else
            nvme_boot=false
        fi
    fi
fi

if [ -f /etc/fstab ] && awk '$1 !~ /^#/ && $1 ~ "^/dev/(sd|vd|xvd)[a-z]|^/dev/disk/azure/scsi" { found=1 } END { exit found ? 0 : 1 }' /etc/fstab; then
    stable_fstab=false
else
    stable_fstab=true
fi

if modinfo mana >/dev/null 2>&1 ||
   grep -Eq 'drivers/net/ethernet/microsoft/mana/mana\.ko' "/lib/modules/$kernel/modules.builtin" 2>/dev/null ||
   find "/lib/modules/$kernel/kernel" -name 'mana.ko*' -print -quit 2>/dev/null | grep -q .; then
    mana_driver=true
else
    mana_driver=false
fi
if [ "$(printf '%s\n' '5.15' "$kernel" | sort -V | head -n1)" = "5.15" ]; then mana_kernel=true; else mana_kernel=false; fi

resource_mount="$(awk -F= '/^[[:space:]]*ResourceDisk.MountPoint=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' /etc/waagent.conf 2>/dev/null)"
if [ -z "$resource_mount" ]; then resource_mount="/mnt/resource"; fi
if mountpoint -q "$resource_mount" 2>/dev/null &&
   [ "$(du -sx --block-size=1 "$resource_mount" 2>/dev/null | awk '{print $1+0}')" -gt 1048576 ]; then
    temp_disk_in_use=true
else
    temp_disk_in_use=false
fi

hardcoded_paths=0
for scan_root in /etc/systemd/system /usr/local/bin; do
    if [ -e "$scan_root" ]; then
        count="$(grep -RIlE '^[[:space:]]*[^#[:space:]].*(/dev/(sd|vd|xvd)[a-z]|/dev/disk/azure/scsi)' "$scan_root" 2>/dev/null | wc -l)"
        hardcoded_paths=$((hardcoded_paths + count))
    fi
done

third_party_modules=0
for module_root in "/lib/modules/$kernel/extra" "/lib/modules/$kernel/updates" "/lib/modules/$kernel/weak-updates"; do
    if [ -d "$module_root" ]; then
        count="$(find "$module_root" -type f -name '*.ko*' 2>/dev/null | wc -l)"
        third_party_modules=$((third_party_modules + count))
    fi
done

if grep -Eq '(^|[[:space:]])(vmx|svm)([[:space:]]|$)' /proc/cpuinfo 2>/dev/null; then nested_virtualization=true; else nested_virtualization=false; fi
if [ -d /sys/class/infiniband ] && find /sys/class/infiniband -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then rdma_device=true; else rdma_device=false; fi

if { [ -r /sys/module/nvme_core/parameters/io_timeout ] &&
     [ "$(cat /sys/module/nvme_core/parameters/io_timeout 2>/dev/null)" = "240" ]; } ||
   grep -RqsE '^[[:space:]]*options[[:space:]]+nvme_core[[:space:]].*io_timeout=240([[:space:]]|$)' /etc/modprobe.d 2>/dev/null; then
    nvme_timeout=true
else
    nvme_timeout=false
fi

if command -v waagent >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q waagent; then agent=true; else agent=false; fi
printf 'AZSKU_GUEST_JSON={"architecture":"%s","osVersion":"%s","firmware":"%s","nvmeDriverPresent":%s,"nvmeBootReady":%s,"fstabUsesStableNames":%s,"nvmeIoTimeoutConfigured":%s,"manaDriverPresent":%s,"manaDriverVersion":null,"manaKernelSupported":%s,"temporaryDiskUsageDetected":%s,"hardCodedScsiPathCount":%s,"thirdPartyKernelDriverCount":%s,"nestedVirtualizationDetected":%s,"rdmaDevicePresent":%s,"azureAgentPresent":%s}\n' "$arch" "$kernel" "$firmware" "$nvme" "$nvme_boot" "$stable_fstab" "$nvme_timeout" "$mana_driver" "$mana_kernel" "$temp_disk_in_use" "$hardcoded_paths" "$third_party_modules" "$nested_virtualization" "$rdma_device" "$agent"
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

function Get-VmMigrationContext {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][object]$Vm,
        [Parameter(Mandatory = $true)][object]$VmModel
    )

    $collectionWarnings = [System.Collections.Generic.List[string]]::new()

    $ade = [pscustomobject]@{
        Status               = 'Unknown'
        OsVolumeEncrypted    = $null
        DataVolumesEncrypted = $null
    }
    try {
        $encryption = Get-AzVMDiskEncryptionStatus `
            -ResourceGroupName $Vm.resourceGroup `
            -VMName $Vm.name `
            -ErrorAction Stop
        $ade = [pscustomobject]@{
            Status = if (
                $encryption.OsVolumeEncrypted -match '^Encrypted$' -or
                $encryption.DataVolumesEncrypted -match '^Encrypted$'
            ) { 'Enabled' } else { 'NotEnabled' }
            OsVolumeEncrypted    = [string]$encryption.OsVolumeEncrypted
            DataVolumesEncrypted = [string]$encryption.DataVolumesEncrypted
        }
    } catch {
        $collectionWarnings.Add("Azure Disk Encryption status unavailable: $($_.Exception.Message)")
    }

    $imageReference = $VmModel.StorageProfile.ImageReference
    $imageType = if ($imageReference.Id) {
        'CustomOrGalleryImage'
    } elseif ($imageReference.Publisher) {
        'Marketplace'
    } else {
        'SpecializedDisk'
    }
    $imageDescription = if ($imageReference.Id) {
        [string]$imageReference.Id
    } elseif ($imageReference.Publisher) {
        '{0}:{1}:{2}:{3}' -f $imageReference.Publisher, $imageReference.Offer,
            $imageReference.Sku, $imageReference.Version
    } else {
        'No image reference'
    }
    $knownOsPublishers = @(
        'Canonical', 'Debian', 'MicrosoftWindowsDesktop', 'MicrosoftWindowsServer',
        'OpenLogic', 'RedHat', 'SUSE', 'Oracle'
    )
    $marketplaceAppliance = $imageType -eq 'Marketplace' -and
        $imageReference.Publisher -notin $knownOsPublishers

    $extensions = @()
    try {
        $extensions = @(
            Get-AzVMExtension `
                -ResourceGroupName $Vm.resourceGroup `
                -VMName $Vm.name `
                -ErrorAction Stop |
                ForEach-Object {
                    [pscustomobject]@{
                        Name               = $_.Name
                        Publisher          = $_.Publisher
                        ExtensionType      = $_.ExtensionType
                        TypeHandlerVersion = $_.TypeHandlerVersion
                    }
                }
        )
    } catch {
        $collectionWarnings.Add("VM extension inventory unavailable: $($_.Exception.Message)")
    }
    $driverSensitiveExtensions = @(
        $extensions | Where-Object {
            "$($_.Publisher)/$($_.ExtensionType)" -match
                '(?i)antimalware|security|encrypt|backup|snapshot|dependency|datadog|crowdstrike|falcon|qualys|trend|mcafee|symantec'
        }
    )

    $diskIops = 0.0
    $diskMbps = 0.0
    $diskPerformanceUnknown = 0
    $managedDiskIds = @(
        $VmModel.StorageProfile.OsDisk.ManagedDisk.Id
        $VmModel.StorageProfile.DataDisks.ManagedDisk.Id
    ) | Where-Object { $_ }
    foreach ($diskId in $managedDiskIds) {
        if ($diskId -notmatch '(?i)/resourceGroups/([^/]+)/providers/Microsoft\.Compute/disks/([^/]+)$') {
            $diskPerformanceUnknown++
            continue
        }
        try {
            $disk = Get-AzDisk `
                -ResourceGroupName $Matches[1] `
                -DiskName $Matches[2] `
                -ErrorAction Stop
            if ($disk.DiskIOPSReadWrite) {
                $diskIops += [double]$disk.DiskIOPSReadWrite
            } else {
                $diskPerformanceUnknown++
            }
            if ($disk.DiskMBpsReadWrite) {
                $diskMbps += [double]$disk.DiskMBpsReadWrite
            }
        } catch {
            $diskPerformanceUnknown++
            $collectionWarnings.Add("Disk performance metadata unavailable for '$diskId': $($_.Exception.Message)")
        }
    }

    return [pscustomobject]@{
        AzureDiskEncryption = $ade
        Image = [pscustomobject]@{
            Type                   = $imageType
            Reference              = $imageDescription
            MarketplaceAppliance   = $marketplaceAppliance
        }
        Placement = [pscustomobject]@{
            AvailabilitySetId          = $VmModel.AvailabilitySetReference.Id
            ProximityPlacementGroupId  = $VmModel.ProximityPlacementGroup.Id
            DedicatedHostId            = $VmModel.Host.Id
            DedicatedHostGroupId       = $VmModel.HostGroup.Id
            CapacityReservationGroupId = $VmModel.CapacityReservation.CapacityReservationGroup.Id
        }
        Extensions = $extensions
        DriverSensitiveExtensions = $driverSensitiveExtensions
        DiskPerformance = [pscustomobject]@{
            ConfiguredIOPS              = $diskIops
            ConfiguredMBps              = $diskMbps
            DisksWithUnknownPerformance = $diskPerformanceUnknown
        }
        CollectionWarnings = @($collectionWarnings)
    }
}

function ConvertTo-VmReportObject {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][object]$Vm,
        [object]$VmModel
    )

    $generationValue = if ($VmModel -and $VmModel.HyperVGeneration) {
        $VmModel.HyperVGeneration
    } else {
        $Vm.HyperVGeneration
    }

    return [pscustomobject]@{
        Id                    = $Vm.id
        Name                  = $Vm.name
        ResourceGroup         = $Vm.resourceGroup
        Location              = $Vm.location
        Zone                  = $Vm.Zone
        OsType                = $Vm.OsType
        Generation            = ConvertTo-GenerationName -Value $generationValue
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
        IpForwardingEnabled   = [bool]$Vm.IpForwardingEnabled
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
        [Parameter(Mandatory = $true)][object]$GuestReadiness,
        [object]$MigrationContext,
        [AllowEmptyCollection()]
        [object[]]$RegionUsage = @()
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
    $targetControllers = Get-CapabilityValue -Map $target -Name 'DiskControllerTypes'
    $targetControllerList = @($targetControllers -split '\s*,\s*')
    $currentController = [string]$Vm.DiskControllerType
    $requiresNvmeMigration = $currentController -and
        $targetControllers -match '(?i)NVMe' -and
        $currentController -notin $targetControllerList
    $directResize = $AvailableSizes.Contains([string]$CandidateSku.name)

    if ($targetCpus -lt $currentCpus) {
        $gaps.Add("vCPU capacity drops from $currentCpus to $targetCpus")
        $actions.Add("Choose a target with at least $currentCpus vCPUs.")
    }
    if ($targetMemory -lt $currentMemory) {
        $gaps.Add("Memory drops from $currentMemory GB to $targetMemory GB")
        $actions.Add("Choose a target with at least $currentMemory GB of memory.")
    }

    $targetFamily = [string]$CandidateSku.family
    $currentFamily = [string]$CurrentSku.family
    $familyQuota = @(
        $RegionUsage |
            Where-Object { $_.Name.Value -eq $targetFamily } |
            Select-Object -First 1
    )
    $regionalQuota = @(
        $RegionUsage |
            Where-Object {
                $_.Name.Value -eq 'cores' -or
                $_.Name.LocalizedValue -eq 'Total Regional vCPUs'
            } |
            Select-Object -First 1
    )
    $familyQuotaRequired = if ($targetFamily -eq $currentFamily) {
        [math]::Max(0, $targetCpus - $currentCpus)
    } else {
        $targetCpus
    }
    $regionalQuotaRequired = [math]::Max(0, $targetCpus - $currentCpus)
    $familyQuotaAvailable = $null
    $regionalQuotaAvailable = $null
    if ($familyQuota.Count -eq 1) {
        $familyQuotaAvailable = [double]$familyQuota[0].Limit - [double]$familyQuota[0].CurrentValue
        if ($familyQuotaAvailable -lt $familyQuotaRequired) {
            $gaps.Add("Target family quota '$targetFamily' has $familyQuotaAvailable vCPUs available; $familyQuotaRequired are required")
            $actions.Add("Request at least $([math]::Ceiling($familyQuotaRequired - $familyQuotaAvailable)) additional vCPUs of '$targetFamily' quota in $($Vm.Location).")
        }
    } else {
        $warnings.Add("Target family quota '$targetFamily' could not be verified")
        $actions.Add("Verify '$targetFamily' vCPU quota in $($Vm.Location) before resizing.")
    }
    if ($regionalQuota.Count -eq 1) {
        $regionalQuotaAvailable = [double]$regionalQuota[0].Limit - [double]$regionalQuota[0].CurrentValue
        if ($regionalQuotaAvailable -lt $regionalQuotaRequired) {
            $gaps.Add("Regional vCPU quota has $regionalQuotaAvailable vCPUs available; $regionalQuotaRequired are required")
            $actions.Add("Request at least $([math]::Ceiling($regionalQuotaRequired - $regionalQuotaAvailable)) additional regional vCPUs in $($Vm.Location).")
        }
    } else {
        $warnings.Add('Total regional vCPU quota could not be verified')
        $actions.Add("Verify total regional vCPU quota in $($Vm.Location) before resizing.")
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

    $currentGpuCount = ConvertTo-Decimal (Get-CapabilityValue -Map $current -Name 'GPUs')
    $targetGpuCount = ConvertTo-Decimal (Get-CapabilityValue -Map $target -Name 'GPUs')
    if ($currentGpuCount -gt $targetGpuCount) {
        $gaps.Add("Current SKU provides $currentGpuCount GPUs; target provides $targetGpuCount")
        $actions.Add("Choose a target with at least $currentGpuCount GPUs.")
    }
    if ($GuestReadiness.Status -eq 'Succeeded' -and
        $GuestReadiness.Details.nestedVirtualizationDetected -eq $true -and
        -not (ConvertTo-Boolean (Get-CapabilityValue -Map $target -Name 'NestedVirtualization'))) {
        $gaps.Add('Nested virtualization is exposed to the guest but is not supported by the target')
        $actions.Add('Choose a target SKU that supports nested virtualization, or remove the nested-hypervisor dependency.')
    }
    if ($GuestReadiness.Status -eq 'Succeeded' -and
        $GuestReadiness.Details.rdmaDevicePresent -eq $true -and
        -not (
            (ConvertTo-Boolean (Get-CapabilityValue -Map $target -Name 'RdmaEnabled')) -or
            (ConvertTo-Boolean (Get-CapabilityValue -Map $target -Name 'InfiniBandEnabled'))
        )) {
        $gaps.Add('An RDMA/InfiniBand device is present in the guest but the target does not support RDMA')
        $actions.Add('Choose a target SKU with the required RDMA or InfiniBand capability.')
    }

    $currentIops = ConvertTo-Decimal (Get-CapabilityValue -Map $current -Name 'UncachedDiskIOPS')
    $targetIops = ConvertTo-Decimal (Get-CapabilityValue -Map $target -Name 'UncachedDiskIOPS')
    $currentDiskBytes = ConvertTo-Decimal (Get-CapabilityValue -Map $current -Name 'UncachedDiskBytesPerSecond')
    $targetDiskBytes = ConvertTo-Decimal (Get-CapabilityValue -Map $target -Name 'UncachedDiskBytesPerSecond')
    if ($MigrationContext.DiskPerformance.ConfiguredIOPS -gt 0 -and
        $targetIops -gt 0 -and
        $MigrationContext.DiskPerformance.ConfiguredIOPS -gt $targetIops) {
        $warnings.Add("Attached disks are configured for $($MigrationContext.DiskPerformance.ConfiguredIOPS) aggregate IOPS; target caps uncached IOPS at $targetIops")
        $actions.Add('Validate observed disk demand against the target limit; choose a larger target if workload demand exceeds it.')
    } elseif ($currentIops -gt 0 -and $targetIops -gt 0 -and $targetIops -lt $currentIops) {
        $warnings.Add("Target uncached disk IOPS limit ($targetIops) is below the current SKU limit ($currentIops)")
        $actions.Add('Validate observed disk IOPS against the target limit before resizing.')
    }
    $configuredBytes = [double]$MigrationContext.DiskPerformance.ConfiguredMBps * 1MB
    if ($configuredBytes -gt 0 -and $targetDiskBytes -gt 0 -and $configuredBytes -gt $targetDiskBytes) {
        $warnings.Add("Attached disks are configured for $($MigrationContext.DiskPerformance.ConfiguredMBps) aggregate MB/s; target VM throughput is lower")
        $actions.Add('Validate observed disk throughput against the target limit; choose a larger target if workload demand exceeds it.')
    } elseif ($currentDiskBytes -gt 0 -and $targetDiskBytes -gt 0 -and $targetDiskBytes -lt $currentDiskBytes) {
        $warnings.Add('Target uncached disk-throughput limit is below the current SKU limit')
        $actions.Add('Validate observed disk throughput against the target limit before resizing.')
    }
    if ($MigrationContext.DiskPerformance.DisksWithUnknownPerformance -gt 0) {
        $warnings.Add("Performance metadata was unavailable for $($MigrationContext.DiskPerformance.DisksWithUnknownPerformance) attached disk(s)")
        $actions.Add('Verify the IOPS and throughput requirements of disks with unavailable performance metadata.')
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

    $currentGeneration = ConvertTo-GenerationName -Value $VmModel.HyperVGeneration
    $targetGenerations = Get-CapabilityValue -Map $target -Name 'HyperVGenerations'

    if ($currentGeneration -eq 'Gen1' -and $targetGenerations -and $targetGenerations -notmatch 'V1') {
        $gaps.Add("Gen1 VM is incompatible with target Hyper-V generations '$targetGenerations'")
        $actions.Add('Capture persistent application data from the OS disk, then migrate or rebuild the VM as Gen2 before selecting a Gen2-only target SKU.')
    } elseif ($currentGeneration -eq 'Gen2' -and $targetGenerations -and $targetGenerations -notmatch 'V2') {
        $gaps.Add("Gen2 VM is incompatible with target Hyper-V generations '$targetGenerations'")
        $actions.Add('Choose a target SKU that supports Gen2 VMs.')
    }

    if ($currentController -and $targetControllers -and $currentController -notin $targetControllerList) {
        if ($targetControllers -match '(?i)NVMe' -and $currentGeneration -eq 'Gen1') {
            $gaps.Add('Gen1 is not eligible for an in-place SCSI-to-NVMe migration')
            $actions.Add('Capture persistent application data from the OS disk, then migrate or rebuild the VM as Gen2 before moving to an NVMe-only SKU.')
        } elseif ($targetControllers -match '(?i)NVMe' -and $currentGeneration -eq 'Unknown') {
            $gaps.Add('VM generation could not be determined; NVMe migration requires confirmed Gen2')
            $actions.Add('Resolve the VM generation metadata and confirm Gen2 before moving to an NVMe-only SKU.')
        } elseif ($targetControllers -match '(?i)NVMe' -and $GuestReadiness.Status -eq 'Succeeded') {
            $nvmePreflightPassed = $true
            if (-not $GuestReadiness.Details.nvmeDriverPresent) {
                $nvmePreflightPassed = $false
                $gaps.Add("Target requires '$targetControllers' storage; the guest NVMe driver was not detected")
                $actions.Add('Install the NVMe driver in the guest OS before resizing, or choose a target that supports the current storage controller.')
            } elseif ($GuestReadiness.Details.nvmeBootReady -ne $true) {
                $nvmePreflightPassed = $false
                $gaps.Add("Target requires '$targetControllers' storage; the NVMe driver is not confirmed in the boot path")
                if ($Vm.OsType -eq 'Windows') {
                    $actions.Add('Configure the Windows stornvme driver for boot start before resizing.')
                } else {
                    $actions.Add('Add the nvme and nvme_core modules to the Linux initramfs/initrd, rebuild it, and rerun the assessment.')
                }
            }

            if ($Vm.OsType -eq 'Linux') {
                if ($GuestReadiness.Details.fstabUsesStableNames -eq $false) {
                    $nvmePreflightPassed = $false
                    $gaps.Add('/etc/fstab uses a mutable SCSI-style device path')
                    $actions.Add('Replace /dev/sd*, /dev/vd*, or /dev/xvd* entries in /etc/fstab with UUIDs or /dev/disk/azure paths before resizing.')
                }
                if ($GuestReadiness.Details.nvmeIoTimeoutConfigured -eq $false) {
                    $warnings.Add('nvme_core.io_timeout=240 is not configured')
                    $actions.Add('Configure nvme_core io_timeout=240 in /etc/modprobe.d, rebuild initramfs, and rerun the assessment.')
                }
            }

            if ($nvmePreflightPassed) {
                $warnings.Add("Disk controller conversion from '$currentController' to NVMe is required; automated guest preflight checks passed")
                $actions.Add('Use the Microsoft Azure NVMe Conversion script to change the disk controller to NVMe and resize to the recommended SKU.')
            }
        } elseif ($targetControllers -match '(?i)NVMe') {
            $warnings.Add('NVMe boot readiness could not be verified because the guest check did not succeed')
            $actions.Add('Run the guest readiness check successfully before changing the disk controller to NVMe.')
        } else {
            $warnings.Add("Storage controller changes from '$currentController' to '$targetControllers'; validate OS/image support")
            $actions.Add("Confirm that the OS image supports '$targetControllers' and install/enable the required storage driver before resizing.")
        }
    }

    if ($GuestReadiness.Status -eq 'Succeeded') {
        if ($GuestReadiness.Details.manaDriverPresent -ne $true) {
            $gaps.Add('MANA network driver was not detected in the guest OS')
            $actions.Add('Update the OS or install a supported MANA network driver before moving to v6/v7.')
        }
        if ($Vm.OsType -eq 'Linux' -and
            $GuestReadiness.Details.manaDriverPresent -ne $true -and
            $GuestReadiness.Details.manaKernelSupported -ne $true) {
            $gaps.Add("Linux kernel '$($GuestReadiness.Details.osVersion)' does not meet the MANA 5.15 kernel floor")
            $actions.Add('Update to a supported Linux distribution kernel with MANA support, then rerun the assessment.')
        }
        if ($requiresNvmeMigration -and $GuestReadiness.Details.hardCodedScsiPathCount -gt 0) {
            $warnings.Add("$($GuestReadiness.Details.hardCodedScsiPathCount) active configuration or script file(s) may reference SCSI-style device paths")
            $actions.Add('Review the reported configuration scope and replace active hard-coded SCSI device paths with UUIDs or stable Azure disk symlinks.')
        }
        if ($GuestReadiness.Details.thirdPartyKernelDriverCount -gt 0) {
            $warnings.Add("$($GuestReadiness.Details.thirdPartyKernelDriverCount) third-party kernel or boot driver(s) require compatibility review")
            $actions.Add('Confirm current signed versions of antivirus, backup, monitoring, and other low-level drivers support the target SKU, Secure Boot, NVMe, and MANA.')
        }
    }

    if ($requiresNvmeMigration -and $Vm.OsType -eq 'Linux') {
        if ($MigrationContext.AzureDiskEncryption.Status -eq 'Enabled') {
            $gaps.Add('Linux Azure Disk Encryption is not supported with NVMe')
            $actions.Add('Redeploy the VM with a new Gen2/NVMe-ready OS disk using encryption at host or another supported encryption model.')
        } elseif ($MigrationContext.AzureDiskEncryption.Status -eq 'Unknown') {
            $warnings.Add('Linux Azure Disk Encryption status could not be verified')
            $actions.Add('Verify that Azure Disk Encryption is not enabled before starting the NVMe migration.')
        }
    }

    if ($MigrationContext.Image.Type -in @('CustomOrGalleryImage', 'SpecializedDisk')) {
        $warnings.Add("$($MigrationContext.Image.Type) requires image-level Gen2, NVMe, and MANA validation")
        $actions.Add('Validate the source image as Gen2, NVMe-ready, and MANA-ready; rebuild the image if any prerequisite is missing.')
    } elseif ($MigrationContext.Image.MarketplaceAppliance) {
        $warnings.Add("Marketplace appliance image '$($MigrationContext.Image.Reference)' requires vendor certification")
        $actions.Add('Confirm that the appliance vendor supports the recommended VM family and MANA/NVMe configuration.')
    }

    if ($Vm.IpForwardingEnabled) {
        $warnings.Add('IP forwarding is enabled on at least one NIC')
        $actions.Add('Validate network-appliance routing and vendor support for the target family before migration.')
    }

    if ($MigrationContext.DriverSensitiveExtensions.Count -gt 0) {
        $extensionNames = @($MigrationContext.DriverSensitiveExtensions.Name) -join ', '
        $warnings.Add("Driver-sensitive VM extensions require review: $extensionNames")
        $actions.Add('Update or validate security, encryption, backup, and monitoring extensions against the target OS and VM family.')
    }
    foreach ($collectionWarning in @($MigrationContext.CollectionWarnings)) {
        $warnings.Add($collectionWarning)
        $actions.Add('Resolve metadata collection permissions or errors and rerun the assessment.')
    }

    $placement = $MigrationContext.Placement
    if ($placement.DedicatedHostId -and -not $directResize) {
        $gaps.Add('The target is not available on the current dedicated host')
        $actions.Add('Move the VM to a compatible dedicated host or host group before resizing.')
    }
    if ($placement.AvailabilitySetId -and -not $directResize) {
        $warnings.Add('Availability-set placement may prevent allocation of the target SKU')
        $actions.Add('Plan to deallocate all VMs in the availability set before resizing and verify the target SKU is available.')
    }
    if ($placement.ProximityPlacementGroupId -and -not $directResize) {
        $warnings.Add('Proximity placement group constraints may prevent target-SKU allocation')
        $actions.Add('Verify target capacity in the proximity placement group; temporarily remove or recreate placement if required.')
    }
    if ($placement.CapacityReservationGroupId) {
        $warnings.Add('The VM is associated with a capacity reservation group')
        $actions.Add('Confirm that the capacity reservation group contains capacity for the recommended target SKU, or disassociate it before resizing.')
    }

    $currentTempDisk = [math]::Max(
        (ConvertTo-Decimal (Get-CapabilityValue -Map $current -Name 'MaxResourceVolumeMB')),
        (ConvertTo-Decimal (Get-CapabilityValue -Map $current -Name 'NVMeDiskSizeInMiB'))
    )
    $targetTempDisk = [math]::Max(
        (ConvertTo-Decimal (Get-CapabilityValue -Map $target -Name 'MaxResourceVolumeMB')),
        (ConvertTo-Decimal (Get-CapabilityValue -Map $target -Name 'NVMeDiskSizeInMiB'))
    )
    if ($requiresNvmeMigration -and $currentTempDisk -gt 0) {
        $gaps.Add('The source SKU has a temporary disk and cannot use the direct SCSI-to-NVMe conversion path')
        $actions.Add('Use a redeploy migration path and move page files, tempdb, scratch data, and other dependencies off the temporary disk.')
    }
    if ($GuestReadiness.Status -eq 'Succeeded' -and $GuestReadiness.Details.temporaryDiskUsageDetected) {
        $gaps.Add('Guest usage of the Azure temporary disk was detected')
        $actions.Add('Move page files, tempdb, scratch data, and other required data off the temporary disk before migration.')
    }
    if ($currentTempDisk -gt 0 -and $targetTempDisk -eq 0) {
        $warnings.Add('Target has no local temporary disk; verify the workload does not depend on temporary-disk data or capacity')
        $actions.Add('Move required data and workload dependencies off the temporary disk before resizing.')
    }
    if ($targetTempDisk -gt 0 -and $targetControllers -match '(?i)NVMe') {
        $warnings.Add('The target local NVMe temporary disk must be initialized and formatted at boot')
        $actions.Add('Add boot-time initialization and formatting for the local NVMe temporary disk; do not store persistent data on it.')
    }

    if ($GuestReadiness.Status -eq 'Succeeded' -and -not $GuestReadiness.Details.azureAgentPresent) {
        $warnings.Add('Azure guest agent was not detected by the in-guest check')
        $actions.Add('Install or repair the Azure VM agent before the migration.')
    }

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
        Quota                  = [pscustomobject]@{
            Family                  = $targetFamily
            FamilyRequiredVcpus     = $familyQuotaRequired
            RegionalRequiredVcpus   = $regionalQuotaRequired
            FamilyAvailableVcpus    = $familyQuotaAvailable
            RegionalAvailableVcpus  = $regionalQuotaAvailable
        }
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
    | project NicId = tolower(id),
        Accelerated = tobool(properties.enableAcceleratedNetworking),
        IpForwarding = tobool(properties.enableIPForwarding)
) on NicId
| summarize
    AcceleratedNetworking = max(toint(coalesce(Accelerated, false))),
    IpForwardingEnabled = max(toint(coalesce(IpForwarding, false))) by
    id, name, resourceGroup, subscriptionId, location, VmSize, PowerState,
    OsType = tostring(properties.storageProfile.osDisk.osType),
    Zone = tostring(zones[0]),
    SecurityType = tostring(properties.securityProfile.securityType),
    HyperVGeneration = tostring(properties.hyperVGeneration),
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
$usageByLocation = @{}
foreach ($location in @($vms.Location | Sort-Object -Unique)) {
    $skuPath = "/subscriptions/$SubscriptionId/providers/Microsoft.Compute/skus" +
        "?api-version=$script:ComputeSkuApiVersion&`$filter=location eq '$location'"
    $skusByLocation[$location] = @(
        Get-ArmCollection -Path $skuPath |
            Where-Object { $_.resourceType -eq 'virtualMachines' }
    )
    try {
        $usageByLocation[$location] = @(Get-AzVMUsage -Location $location -ErrorAction Stop)
    } catch {
        Write-Warning "Unable to retrieve VM quota usage for '$location': $($_.Exception.Message)"
        $usageByLocation[$location] = @()
    }
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
            BlockingIssues       = @()
            ReviewItems          = @()
            GuestReadiness       = $null
            MigrationContext     = $null
            Candidates           = @()
            NoCandidateReason    = $null
            AssessmentError      = "Current SKU '$($vm.VmSize)' was not returned by the regional Resource SKUs API."
        })
        continue
    }

    try {
        $vmModel = Get-AzVM -ResourceGroupName $vm.resourceGroup -Name $vm.name
        $migrationContext = Get-VmMigrationContext -Vm $vm -VmModel $vmModel
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
                    -GuestReadiness $guestReadiness `
                    -MigrationContext $migrationContext `
                    -RegionUsage $usageByLocation[$vm.location]
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
        $blockingIssues = if ($noCandidateReason) {
            @($noCandidateReason)
        } elseif ($recommended.Count -gt 0) {
            @($recommended[0].CapabilityGaps)
        } else {
            @()
        }
        $reviewItems = if ($recommended.Count -gt 0) {
            @($recommended[0].Warnings)
        } else {
            @()
        }

        $details.Add([pscustomobject]@{
            Vm                   = ConvertTo-VmReportObject -Vm $vm -VmModel $vmModel
            ReadinessStatus      = $readinessStatus
            RecommendedTargetSku = if ($recommended.Count -gt 0) { $recommended[0].Sku } else { $null }
            RequiredActions      = $requiredActions
            BlockingIssues       = $blockingIssues
            ReviewItems          = $reviewItems
            GuestReadiness       = $guestReadiness
            MigrationContext     = $migrationContext
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
            BlockingIssues       = @()
            ReviewItems          = @()
            GuestReadiness       = $null
            MigrationContext     = $null
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
    [pscustomobject]@{
        SubscriptionId          = $SubscriptionId
        ResourceGroup           = $detail.Vm.ResourceGroup
        VmName                  = $detail.Vm.Name
        Location                = $detail.Vm.Location
        Zone                    = $detail.Vm.Zone
        OsType                  = $detail.Vm.OsType
        Generation              = $detail.Vm.Generation
        CurrentSku              = $detail.Vm.CurrentSku
        ReadinessStatus         = $detail.ReadinessStatus
        RecommendedTargetSku    = $detail.RecommendedTargetSku
        RequiredActions         = ($detail.RequiredActions -join '; ')
        GuestCheck              = $detail.GuestReadiness.Status
        AzureDiskEncryption     = $detail.MigrationContext.AzureDiskEncryption.Status
        ImageType               = $detail.MigrationContext.Image.Type
        PlacementConstraints    = @(
            $detail.MigrationContext.Placement.PSObject.Properties |
                Where-Object Value |
                ForEach-Object Name
        ) -join '; '
        DriverSensitiveExtensions = @($detail.MigrationContext.DriverSensitiveExtensions.Name) -join '; '
        ConfiguredDiskIOPS      = $detail.MigrationContext.DiskPerformance.ConfiguredIOPS
        ConfiguredDiskMBps      = $detail.MigrationContext.DiskPerformance.ConfiguredMBps
        CompatibleCandidates    = ($compatible.Sku -join '; ')
        DirectResizeCandidates  = ($direct.Sku -join '; ')
        CapabilityGaps          = (@($detail.BlockingIssues | Sort-Object -Unique) -join '; ')
        Warnings                = (@($detail.ReviewItems | Sort-Object -Unique) -join '; ')
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
