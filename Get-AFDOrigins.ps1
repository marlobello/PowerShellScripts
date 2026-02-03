<#
.SYNOPSIS
    Collects Azure Front Door Standard/Premium (AFD) resources, their Origin Groups, Origins, and Azure App Services.
    Identifies Origin Groups without Origins and App Services not listed as an Origin.

.DESCRIPTION
    This script queries Azure Front Door Standard/Premium profiles and their origin groups, collects all origins, 
    and matches them to Azure App Services (Web Apps). It outputs a joined list of App Services and their 
    corresponding Front Door origins, and highlights App Services not listed as an origin in any group.

.PARAMETER SubscriptionId
    The Azure Subscription ID to use for all resource queries.

.PARAMETER ResourceGroupName
    Optional. Filter to a specific resource group for Front Door profiles.

.PARAMETER ExportPath
    Optional. Path to export results to CSV. Defaults to .\AFDOrigins.csv if not specified.

.EXAMPLE
    .\Get-AFDOrigins.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"
    Runs the script for the specified subscription and displays the joined list of App Services and Front Door origins.

.EXAMPLE
    .\Get-AFDOrigins.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000" -ExportPath "C:\Reports\afd-origins.csv"
    Exports results to the specified CSV file.

.EXAMPLE
    .\Get-AFDOrigins.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000" -ResourceGroupName "afd-rg"
    Filters to Front Door profiles in the specified resource group only.

.NOTES
    THIS CODE-SAMPLE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED 
    OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR 
    FITNESS FOR A PARTICULAR PURPOSE.
    
    - Requires Az PowerShell module and JoinModule (will be installed if missing)
    - You must have permission to query Front Door and App Service resources in the specified subscription

.OUTPUTS
    PSCustomObject: Joined list of App Services and Front Door origins

.LINK
    https://learn.microsoft.com/powershell/azure/new-azureps-module-az
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,
    
    [Parameter()]
    [string]$ResourceGroupName,
    
    [Parameter()]
    [string]$ExportPath = ".\AFDOrigins.csv"
)

try {
    # Check and install JoinModule if needed
    if (-not (Get-Module -ListAvailable -Name JoinModule)) {
        Write-Host "Installing JoinModule..." -ForegroundColor Cyan
        Install-Module -Name JoinModule -Force -Scope CurrentUser -AllowClobber
    }
    
    Import-Module JoinModule -ErrorAction Stop
    
    # Check Azure authentication
    $context = Get-AzContext
    if (-not $context) {
        Write-Host "Please login to Azure" -ForegroundColor Yellow
        Connect-AzAccount
    }
    
    # Set the Azure subscription context
    Write-Verbose "Setting subscription context to: $SubscriptionId"
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    $context = Get-AzContext
    
    Write-Host "Querying Azure Front Door profiles in subscription: $($context.Subscription.Name)" -ForegroundColor Cyan
    
    # Get Front Door Standard/Premium (AFD) resources
    $frontDoors = if ($ResourceGroupName) {
        Write-Verbose "Filtering to resource group: $ResourceGroupName"
        Get-AzFrontDoorCdnProfile -ResourceGroupName $ResourceGroupName -ErrorAction Stop
    } else {
        Get-AzFrontDoorCdnProfile -ErrorAction Stop
    }
    
    if (-not $frontDoors) {
        Write-Warning "No Front Door profiles found in this subscription"
        if ($ResourceGroupName) {
            Write-Warning "Resource group filter: $ResourceGroupName"
        }
        return
    }
    
    Write-Host "Found $($frontDoors.Count) Front Door profile(s)" -ForegroundColor Green
    
    # Prepare collections using proper list type
    $afdOriginAppServiceDetails = [System.Collections.Generic.List[PSObject]]::new()
    
    # Process each Front Door
    $fdProgress = 0
    foreach ($fd in $frontDoors) {
        $fdProgress++
        Write-Progress -Activity "Processing Front Door Profiles" `
            -Status "$fdProgress of $($frontDoors.Count): $($fd.Name)" `
            -PercentComplete (($fdProgress / $frontDoors.Count) * 100)
        
        Write-Verbose "Processing Front Door: $($fd.Name)"
        
        try {
            # Get Origin Groups for this Front Door Profile
            $originGroups = Get-AzFrontDoorCdnOriginGroup `
                -ResourceGroupName $fd.ResourceGroupName `
                -ProfileName $fd.Name `
                -ErrorAction Stop
            
            if (-not $originGroups) {
                Write-Warning "  No origin groups found in Front Door: $($fd.Name)"
                continue
            }
            
            Write-Verbose "  Found $($originGroups.Count) origin group(s)"
            
            foreach ($og in $originGroups) {
                try {
                    # Get Origins for this Origin Group
                    $origins = Get-AzFrontDoorCdnOrigin `
                        -ResourceGroupName $fd.ResourceGroupName `
                        -ProfileName $fd.Name `
                        -OriginGroupName $og.Name `
                        -ErrorAction Stop
                    
                    if (-not $origins) {
                        Write-Warning "    Origin group '$($og.Name)' has no origins"
                        continue
                    }
                    
                    foreach ($origin in $origins) {
                        $afdOriginAppServiceDetails.Add([PSCustomObject]@{
                            FrontDoorName   = $fd.Name
                            ResourceGroup   = $fd.ResourceGroupName
                            OriginGroupName = $og.Name
                            OriginName      = $origin.Name
                            DefaultHostName = $origin.HostName
                            EnabledState    = $origin.EnabledState
                        })
                    }
                }
                catch {
                    Write-Warning "    Failed to get origins for group '$($og.Name)': $_"
                }
            }
        }
        catch {
            Write-Warning "  Failed to get origin groups for Front Door '$($fd.Name)': $_"
        }
    }
    
    Write-Progress -Activity "Processing Front Door Profiles" -Completed
    
    Write-Host "Found $($afdOriginAppServiceDetails.Count) Front Door origin(s)" -ForegroundColor Green
    
    # Get all App Services (Web Apps)
    Write-Host "Querying App Services..." -ForegroundColor Cyan
    $appServices = Get-AzWebApp -ErrorAction Stop | 
        Select-Object Name, DefaultHostName, ResourceGroup, State
    
    Write-Host "Found $($appServices.Count) App Service(s)" -ForegroundColor Green
    
    # Perform the join
    Write-Verbose "Joining App Services with Front Door origins..."
    $joinedList = $appServices | FullJoin-Object -On DefaultHostName -Right $afdOriginAppServiceDetails
    
    # Export results
    if ($ExportPath) {
        $joinedList | Export-Csv -Path $ExportPath -NoTypeInformation -Force
        Write-Host "Results exported to: $ExportPath" -ForegroundColor Green
    }
    
    # Display results
    Write-Host "`nApp Services and Front Door Origins:" -ForegroundColor Cyan
    $joinedList | Format-Table -AutoSize
    
    # Display summary
    $appsInAFD = ($joinedList | Where-Object { $_.FrontDoorName } | Select-Object -Unique DefaultHostName | Measure-Object).Count
    $appsNotInAFD = ($joinedList | Where-Object { $_.Name -and -not $_.FrontDoorName } | Measure-Object).Count
    $originsWithoutApp = ($joinedList | Where-Object { $_.FrontDoorName -and -not $_.Name } | Measure-Object).Count
    
    Write-Host "`nSummary:" -ForegroundColor Cyan
    Write-Host "  Total App Services: $($appServices.Count)" -ForegroundColor Gray
    Write-Host "  App Services in Front Door: $appsInAFD" -ForegroundColor Green
    Write-Host "  App Services NOT in Front Door: $appsNotInAFD" -ForegroundColor Yellow
    Write-Host "  Front Door origins without matching App Service: $originsWithoutApp" -ForegroundColor Yellow
    
    if ($appsNotInAFD -gt 0) {
        Write-Host "`nApp Services NOT configured in any Front Door:" -ForegroundColor Yellow
        $joinedList | 
            Where-Object { $_.Name -and -not $_.FrontDoorName } | 
            Select-Object Name, DefaultHostName, ResourceGroup, State |
            Format-Table -AutoSize
    }
    
    return $joinedList
}
catch {
    Write-Error "An error occurred: $_"
    Write-Error $_.ScriptStackTrace
    throw
}