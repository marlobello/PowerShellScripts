<# 
.SYNOPSIS
    Retrieves SQL Server firewall rules across subscriptions using Azure Resource Graph.

.DESCRIPTION
    This script efficiently queries all SQL Server firewall rules across subscriptions
    using Azure Resource Graph for optimal performance. Only queries subscriptions that
    contain SQL Servers.

.PARAMETER ExportPath
    Optional. Path to export results to CSV. Defaults to .\SQLFirewallRules.csv

.PARAMETER AllSubscriptions
    Switch to query all accessible subscriptions. If not specified, uses current context.

.PARAMETER SubscriptionId
    Optional. Specific subscription ID to query.

.EXAMPLE
    .\Get-SQLFirewallRulesFast.ps1
    Exports SQL firewall rules from current subscription to SQLFirewallRules.csv

.EXAMPLE
    .\Get-SQLFirewallRulesFast.ps1 -AllSubscriptions -ExportPath "C:\reports\firewall-rules.csv"
    Exports SQL firewall rules from all subscriptions to specified path.

.NOTES
    THIS CODE-SAMPLE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED 
    OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR 
    FITNESS FOR A PARTICULAR PURPOSE.
#>

[CmdletBinding()]
param (
    [Parameter()]
    [string]$ExportPath = ".\SQLFirewallRules.csv",
    
    [Parameter()]
    [switch]$AllSubscriptions,
    
    [Parameter()]
    [string]$SubscriptionId
)

try {
    Write-Host "Finding SQL Servers..." -ForegroundColor Cyan
    
    # Build query to get all SQL firewall rules using Resource Graph
    $query = @"
resources
| where type =~ 'Microsoft.Sql/servers/firewallRules'
| extend serverName = tostring(split(id, '/')[8])
| extend ruleName = name
| project 
    subscriptionId,
    resourceGroup,
    serverName,
    ruleName,
    startIpAddress = properties.startIpAddress,
    endIpAddress = properties.endIpAddress,
    location
| order by subscriptionId asc, resourceGroup asc, serverName asc, ruleName asc
"@
    
    $subscriptions = @()
    
    if ($SubscriptionId) {
        $subscriptions = @($SubscriptionId)
        Write-Verbose "Querying subscription: $SubscriptionId"
        $firewallRules = Search-AzGraph -Query $query -Subscription $subscriptions -First 1000
    }
    elseif ($AllSubscriptions) {
        Write-Verbose "Querying all accessible subscriptions"
        $firewallRules = Search-AzGraph -Query $query -First 1000
    }
    else {
        $context = Get-AzContext -ErrorAction Stop
        $subscriptions = @($context.Subscription.Id)
        Write-Verbose "Querying current subscription: $($context.Subscription.Name)"
        $firewallRules = Search-AzGraph -Query $query -Subscription $subscriptions -First 1000
    }
    
    # Handle pagination if needed
    while ($firewallRules.SkipToken) {
        Write-Verbose "Fetching additional results..."
        $moreResults = Search-AzGraph -Query $query -Subscription $subscriptions -First 1000 -SkipToken $firewallRules.SkipToken
        $firewallRules += $moreResults
    }
    
    if ($firewallRules -and $firewallRules.Count -gt 0) {
        Write-Host "Found $($firewallRules.Count) SQL Server firewall rule(s)" -ForegroundColor Green
        
        $firewallRules | Export-Csv -Path $ExportPath -NoTypeInformation -Force
        Write-Host "Results exported to: $ExportPath" -ForegroundColor Green
        
        # Display summary
        Write-Host "`nSummary by SQL Server:" -ForegroundColor Cyan
        $firewallRules | Group-Object serverName | 
            Select-Object Name, Count | 
            Sort-Object Count -Descending |
            Format-Table -AutoSize
        
        return $firewallRules
    }
    else {
        Write-Host "No SQL Server firewall rules found" -ForegroundColor Yellow
    }
}
catch {
    Write-Error "An error occurred: $_"
    throw
}
