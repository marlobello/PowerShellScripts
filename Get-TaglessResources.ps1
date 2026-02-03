<# 
.SYNOPSIS
    Finds all Azure resources without tags in a subscription.

.DESCRIPTION
    This script uses Azure Resource Graph to efficiently query all resources without tags
    in the specified subscription(s). Results can be exported to CSV for further analysis.

.PARAMETER SubscriptionName
    Optional. The name of the subscription to query. If not provided, uses current context.

.PARAMETER SubscriptionId
    Optional. The subscription ID to query. If not provided, uses current context.

.PARAMETER ExportPath
    Optional. Path to export results to CSV. If not provided, only displays results.

.PARAMETER AllSubscriptions
    Switch to query all accessible subscriptions.

.EXAMPLE
    .\Get-TaglessResources.ps1 -SubscriptionName "MySubscription"
    Finds tagless resources in the specified subscription.

.EXAMPLE
    .\Get-TaglessResources.ps1 -AllSubscriptions -ExportPath "C:\tagless-resources.csv"
    Finds tagless resources across all subscriptions and exports to CSV.

.NOTES
    THIS CODE-SAMPLE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED 
    OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR 
    FITNESS FOR A PARTICULAR PURPOSE.
#>

[CmdletBinding(DefaultParameterSetName = 'ByName')]
param (
    [Parameter(ParameterSetName = 'ByName')]
    [String]$SubscriptionName,
    
    [Parameter(ParameterSetName = 'ById')]
    [String]$SubscriptionId,
    
    [Parameter()]
    [String]$ExportPath,
    
    [Parameter()]
    [Switch]$AllSubscriptions
)

try {
    $context = Get-AzContext -ErrorAction Stop
    
    if (-not $context) {
        Write-Host "Please login to Azure" -ForegroundColor Yellow
        Connect-AzAccount
        $context = Get-AzContext
    }
    
    $subscriptions = @()
    
    if ($AllSubscriptions) {
        Write-Verbose "Querying all accessible subscriptions..."
        $subscriptions = Get-AzSubscription | Select-Object -ExpandProperty Id
    }
    elseif ($SubscriptionId) {
        Write-Verbose "Using subscription ID: $SubscriptionId"
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
        $subscriptions = @($SubscriptionId)
    }
    elseif ($SubscriptionName) {
        Write-Verbose "Using subscription name: $SubscriptionName"
        if ($context.Subscription.Name -ne $SubscriptionName) {
            Set-AzContext -SubscriptionName $SubscriptionName | Out-Null
        }
        $subscriptions = @((Get-AzContext).Subscription.Id)
    }
    else {
        Write-Verbose "Using current subscription context: $($context.Subscription.Name)"
        $subscriptions = @($context.Subscription.Id)
    }
    
    $query = @"
resources
| where isnull(tags) or array_length(todynamic(tags)) == 0
| project subscriptionId, resourceGroup, name, type, location, id
| order by subscriptionId asc, resourceGroup asc, name asc
"@
    
    Write-Host "Querying for tagless resources..." -ForegroundColor Cyan
    
    if ($AllSubscriptions) {
        $taglessResources = Search-AzGraph -Query $query -First 1000
    }
    else {
        $taglessResources = Search-AzGraph -Query $query -Subscription $subscriptions -First 1000
    }
    
    if ($taglessResources) {
        $count = $taglessResources.Count
        Write-Host "`nFound $count tagless resource$(if($count -ne 1){'s'})" -ForegroundColor Green
        
        if ($ExportPath) {
            $taglessResources | Export-Csv -Path $ExportPath -NoTypeInformation -Force
            Write-Host "Results exported to: $ExportPath" -ForegroundColor Green
        }
        else {
            $taglessResources | Format-Table -Property subscriptionId, resourceGroup, name, type, location -AutoSize
        }
        
        return $taglessResources
    }
    else {
        Write-Host "`nNo tagless resources found!" -ForegroundColor Green
    }
}
catch {
    Write-Error "An error occurred: $_"
    throw
}
