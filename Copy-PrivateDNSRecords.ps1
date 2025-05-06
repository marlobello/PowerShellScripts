<# THIS CODE-SAMPLE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED 
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR 
FITNESS FOR A PARTICULAR PURPOSE.

This sample is not supported under any Microsoft standard support program or service. 
The script is provided AS IS without warranty of any kind. Microsoft further disclaims all
implied warranties including, without limitation, any implied warranties of merchantability
or of fitness for a particular purpose. The entire risk arising out of the use or performance
of the sample and documentation remains with you. In no event shall Microsoft, its authors,
or anyone else involved in the creation, production, or delivery of the script be liable for 
any damages whatsoever (including, without limitation, damages for loss of business profits, 
business interruption, loss of business information, or other pecuniary loss) arising out of 
the use of or inability to use the sample or documentation, even if Microsoft has been advised 
of the possibility of such damages, rising out of the use of or inability to use the sample script, 
even if Microsoft has been advised of the possibility of such damages. #>

param (
    [Parameter(Mandatory = $true)]
    [string]$PrivateZoneNamesFile,

    [Parameter(Mandatory = $true)]
    [string]$SourceTenantId,

    [Parameter(Mandatory = $true)]
    [string]$SourceSubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$SourceResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$DestinationTenantId,

    [Parameter(Mandatory = $true)]
    [string]$DestinationSubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$DestinationResourceGroupName
)

# Login to the source tenant
Write-Host "Logging in to source tenant..."
az login --tenant $SourceTenantId | Out-Null
az account set --subscription $SourceSubscriptionId

$PrivateZoneNames = Get-Content -Path $PrivateZoneNamesFile
if (-not $PrivateZoneNames) {
    Write-Error "Failed to read private zone names from file: $PrivateZoneNamesFile"
    exit 1
}

# Export private DNS zones
foreach ($zone in $PrivateZoneNames) {
    Write-Host "Exporting private DNS zone: $zone from source subscription..."
    $exportFile = "$zone.json"
    az network private-dns zone export --resource-group $SourceResourceGroupName --name $zone --file-name $exportFile
    if (-not $?) {
        Write-Error "Failed to export private DNS zone: $zone"
        exit 1
    }
}

# Login to the destination tenant
Write-Host "Logging in to destination tenant..."
az login --tenant $DestinationTenantId | Out-Null
az account set --subscription $DestinationSubscriptionId

# Import private DNS zones
foreach ($zone in $PrivateZoneNames) {
    Write-Host "Importing private DNS zone: $zone to destination subscription..."
    $importFile = "$zone.json"
    az network private-dns zone import --resource-group $DestinationResourceGroupName --name $zone --file-name $importFile
    if (-not $?) {
        Write-Error "Failed to import private DNS zone: $zone"
        exit 1
    }
}

Write-Host "Private DNS zones migration completed successfully."