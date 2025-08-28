
<#
THIS CODE-SAMPLE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED 
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
even if Microsoft has been advised of the possibility of such damages.

.SYNOPSIS
    Collects Azure Front Door Standard/Premium (AFD) resources, their Origin Groups, Origins, and Azure App Services.
    Identifies Origin Groups without Origins and App Services not listed as an Origin.

.DESCRIPTION
    This script queries Azure Front Door Standard/Premium profiles and their origin groups, collects all origins, and matches them to Azure App Services (Web Apps).
    It outputs a joined list of App Services and their corresponding Front Door origins, and highlights App Services not listed as an origin in any group.
    The script requires the Az PowerShell module and the JoinModule for join operations.

.PARAMETER SubscriptionId
    The Azure Subscription ID to use for all resource queries.

.EXAMPLE
    .\Get-AFDOrigins.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"
    Runs the script for the specified subscription and outputs the joined list of App Services and Front Door origins.

.NOTES
    - Requires Az PowerShell module and JoinModule (will be installed if missing)
    - You must have permission to query Front Door and App Service resources in the specified subscription
    - Outputs a joined list of App Services and Front Door origins

.OUTPUTS
    PSCustomObject: Joined list of App Services and Front Door origins

.LINK
    https://learn.microsoft.com/powershell/azure/new-azureps-module-az
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId
)

if (-not (Get-Module -ListAvailable -Name JoinModule)) {
    Write-Host "Installing JoinModule..."
    Install-Module -Name JoinModule -Force -Scope CurrentUser
}

Import-Module JoinModule -ErrorAction Stop

# Login to Azure if not already authenticated
if (-not (Get-AzContext)) {
    Connect-AzAccount
}

# Set the Azure subscription context
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

# Prepare collections
$afdOriginAppServiceDetails = @()

# Get all Front Door Standard/Premium (AFD) resources
$frontDoors = Get-AzFrontDoorCdnProfile

foreach ($fd in $frontDoors) {
    $resourceGroup = $fd.ResourceGroupName
    $profileName = $fd.Name

    # Get Origin Groups for this Front Door Profile
    $originGroups = Get-AzFrontDoorCdnOriginGroup -ResourceGroupName $resourceGroup -ProfileName $profileName
    foreach ($og in $originGroups) {
        # Get Origins for this Origin Group
        $origins = Get-AzFrontDoorCdnOrigin -ResourceGroupName $resourceGroup -ProfileName $profileName -OriginGroupName $og.Name

        foreach ($origin in $origins) {
            $afdOriginAppServiceDetails += [PSCustomObject]@{
                FrontDoorName   = $fd.Name
                OriginGroupName = $og.Name
                DefaultHostName = $origin.HostName
            }
        }
    }
}

# Get all App Services (Web Apps)
$appServices = Get-AzWebApp | Select Name, DefaultHostName

$joinedList = $appServices | FullJoin-Object -On DefaultHostName -Right $afdOriginAppServiceDetails

$joinedList | Format-Table