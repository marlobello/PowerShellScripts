<#
.SYNOPSIS
    Updates metric alert rule scopes to monitor multiple subscriptions.

.DESCRIPTION
    This script updates Azure metric alert rules to monitor resources across multiple subscriptions.
    It retrieves alert rules from a specified resource group, identifies target subscriptions by name pattern,
    and updates each alert rule's scope to include all matching subscriptions.

.PARAMETER AlertRuleSubscription
    Name of the subscription containing the metric alert rules. Default: Platform

.PARAMETER AlertRuleResourceGroup
    Name of the resource group containing the metric alert rules. Default: hb-monitoring-rg

.PARAMETER AlertRulePattern
    Pattern to match alert rule names. Uses -match operator. Default: sql-

.PARAMETER SubscriptionPattern
    Pattern to match subscription names that should be monitored. Uses -match operator. Default: (empty = all subscriptions)

.PARAMETER WhatIf
    Shows what would happen if the script runs without actually making changes.

.EXAMPLE
    .\Add-SubscriptionsToMetricAlertRule-Improved.ps1

    Updates SQL alert rules in the default resource group to monitor all subscriptions.

.EXAMPLE
    .\Add-SubscriptionsToMetricAlertRule-Improved.ps1 -AlertRulePattern "vm-" -SubscriptionPattern "Production"

    Updates VM alert rules to monitor only subscriptions with "Production" in their name.

.EXAMPLE
    .\Add-SubscriptionsToMetricAlertRule-Improved.ps1 -WhatIf

    Shows which alert rules would be updated without making changes.

.NOTES
    Author: HellzBellz Infrastructure Team
    Requires: Az.Accounts, Az.Monitor modules
    Requires: Appropriate Azure RBAC permissions (Monitoring Contributor or higher)
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory = $false)]
    [string]$AlertRuleSubscription = 'Platform',

    [Parameter(Mandatory = $false)]
    [string]$AlertRuleResourceGroup = 'hb-monitoring-rg',

    [Parameter(Mandatory = $false)]
    [string]$AlertRulePattern = 'sql-',

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionPattern = ''
)

#Requires -Modules Az.Accounts, Az.Monitor

# Script configuration
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'Continue'

#region Helper Functions

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Type = 'Info'
    )

    $colors = @{
        'Info'    = 'Cyan'
        'Success' = 'Green'
        'Warning' = 'Yellow'
        'Error'   = 'Red'
    }

    $prefix = switch ($Type) {
        'Info'    { '[INFO]' }
        'Success' { '[SUCCESS]' }
        'Warning' { '[WARNING]' }
        'Error'   { '[ERROR]' }
    }

    Write-Host "$prefix $Message" -ForegroundColor $colors[$Type]
}

function Test-Prerequisites {
    Write-Status 'Checking prerequisites...' -Type Info

    # Check Az.Monitor module
    $azMonitorModule = Get-Module -Name Az.Monitor -ListAvailable | Select-Object -First 1
    if (-not $azMonitorModule) {
        throw 'Az.Monitor module is not installed. Install with: Install-Module -Name Az.Monitor -AllowClobber -Scope CurrentUser'
    }

    # Check Azure context
    try {
        $context = Get-AzContext
        if (-not $context) {
            throw 'Not connected to Azure. Run Connect-AzAccount first.'
        }
        Write-Status "Connected as: $($context.Account.Id)" -Type Success
    }
    catch {
        throw "Failed to get Azure context: $_"
    }

    Write-Status 'Prerequisites check passed' -Type Success
}

#endregion

#region Main Logic

try {
    Write-Status 'Metric Alert Rule Scope Update' -Type Info
    Write-Status "Alert Rule Subscription: $AlertRuleSubscription" -Type Info
    Write-Status "Alert Rule Resource Group: $AlertRuleResourceGroup" -Type Info
    Write-Status "Alert Rule Pattern: $AlertRulePattern" -Type Info
    Write-Status "Subscription Pattern: $(if ($SubscriptionPattern) { $SubscriptionPattern } else { 'All subscriptions' })" -Type Info

    # Prerequisites check
    Test-Prerequisites

    # Switch to subscription containing alert rules
    $currentContext = Get-AzContext
    if ($currentContext.Subscription.Name -ne $AlertRuleSubscription) {
        Write-Status "Switching to subscription: $AlertRuleSubscription" -Type Info
        try {
            Select-AzSubscription -SubscriptionName $AlertRuleSubscription -ErrorAction Stop | Out-Null
            Write-Status "Switched to subscription: $AlertRuleSubscription" -Type Success
        }
        catch {
            throw "Failed to switch to subscription '$AlertRuleSubscription'. Verify the subscription name and your access permissions."
        }
    }
    else {
        Write-Status "Already in subscription: $AlertRuleSubscription" -Type Info
    }

    # Verify resource group exists
    Write-Status "Verifying resource group: $AlertRuleResourceGroup" -Type Info
    $resourceGroup = Get-AzResourceGroup -Name $AlertRuleResourceGroup -ErrorAction SilentlyContinue
    if (-not $resourceGroup) {
        throw "Resource group '$AlertRuleResourceGroup' not found in subscription '$AlertRuleSubscription'"
    }

    # Get alert rules matching the pattern
    Write-Status "Retrieving metric alert rules matching pattern: $AlertRulePattern" -Type Info
    $alertRules = Get-AzMetricAlertRuleV2 -ResourceGroupName $AlertRuleResourceGroup -ErrorAction Stop |
        Where-Object { $_.Name -match $AlertRulePattern }

    if (-not $alertRules -or $alertRules.Count -eq 0) {
        Write-Status "No alert rules found matching pattern: $AlertRulePattern" -Type Warning
        return
    }

    Write-Status "Found $($alertRules.Count) alert rule(s) matching pattern" -Type Success

    # Get target subscriptions
    Write-Status 'Retrieving target subscriptions...' -Type Info
    $allSubscriptions = Get-AzSubscription -ErrorAction Stop

    if ($SubscriptionPattern) {
        $targetSubscriptions = $allSubscriptions | Where-Object { $_.Name -match $SubscriptionPattern }
        Write-Status "Found $($targetSubscriptions.Count) subscription(s) matching pattern: $SubscriptionPattern" -Type Success
    }
    else {
        $targetSubscriptions = $allSubscriptions
        Write-Status "Found $($targetSubscriptions.Count) subscription(s) in tenant" -Type Success
    }

    if (-not $targetSubscriptions -or $targetSubscriptions.Count -eq 0) {
        Write-Status 'No target subscriptions found' -Type Warning
        return
    }

    # Format subscription IDs as scope paths
    $subscriptionScopes = $targetSubscriptions | ForEach-Object { "/subscriptions/$($_.Id)" }

    Write-Host "`nTarget Subscriptions:" -ForegroundColor Cyan
    $targetSubscriptions | ForEach-Object { Write-Host "  - $($_.Name) ($($_.Id))" }

    Write-Host "`nAlert Rules to Update:" -ForegroundColor Cyan
    $alertRules | ForEach-Object { Write-Host "  - $($_.Name)" }

    # Confirm update
    if (-not $WhatIfPreference) {
        $confirmation = Read-Host "`nProceed with updating alert rule scopes? (y/N)"
        if ($confirmation -ne 'y') {
            Write-Status 'Update cancelled by user' -Type Warning
            return
        }
    }

    # Update each alert rule
    $successCount = 0
    $failureCount = 0

    foreach ($alertRule in $alertRules) {
        if ($PSCmdlet.ShouldProcess($alertRule.Name, 'Update metric alert rule scopes')) {
            Write-Status "Updating alert rule: $($alertRule.Name)" -Type Info

            try {
                # Get current alert rule configuration
                $alertRuleConfig = Get-AzMetricAlertRuleV2 -ResourceGroupName $AlertRuleResourceGroup -Name $alertRule.Name -ErrorAction Stop

                # Update scopes
                $updateParams = @{
                    Name              = $alertRule.Name
                    ResourceGroupName = $AlertRuleResourceGroup
                    Scope             = $subscriptionScopes
                    ErrorAction       = 'Stop'
                }

                # Preserve existing configuration
                if ($alertRuleConfig.Description) {
                    $updateParams['Description'] = $alertRuleConfig.Description
                }
                if ($alertRuleConfig.Severity) {
                    $updateParams['Severity'] = $alertRuleConfig.Severity
                }
                if ($alertRuleConfig.Enabled) {
                    $updateParams['Enabled'] = $alertRuleConfig.Enabled
                }
                if ($alertRuleConfig.WindowSize) {
                    $updateParams['WindowSize'] = $alertRuleConfig.WindowSize
                }
                if ($alertRuleConfig.EvaluationFrequency) {
                    $updateParams['EvaluationFrequency'] = $alertRuleConfig.EvaluationFrequency
                }
                if ($alertRuleConfig.TargetResourceType) {
                    $updateParams['TargetResourceType'] = $alertRuleConfig.TargetResourceType
                }
                if ($alertRuleConfig.TargetResourceRegion) {
                    $updateParams['TargetResourceRegion'] = $alertRuleConfig.TargetResourceRegion
                }
                if ($alertRuleConfig.Criteria) {
                    $updateParams['Criteria'] = $alertRuleConfig.Criteria
                }
                if ($alertRuleConfig.ActionGroupId -and $alertRuleConfig.ActionGroupId.Count -gt 0) {
                    $updateParams['ActionGroupId'] = $alertRuleConfig.ActionGroupId
                }

                # Perform update
                Add-AzMetricAlertRuleV2 @updateParams | Out-Null

                Write-Status "Successfully updated: $($alertRule.Name)" -Type Success
                $successCount++
            }
            catch {
                Write-Status "Failed to update $($alertRule.Name): $_" -Type Error
                $failureCount++
            }
        }
        else {
            Write-Status "[WhatIf] Would update alert rule: $($alertRule.Name)" -Type Info
        }
    }

    # Summary
    Write-Host "`n" -NoNewline
    Write-Status 'UPDATE SUMMARY' -Type Info
    if (-not $WhatIfPreference) {
        Write-Host "  Successfully updated: $successCount" -ForegroundColor Green
        if ($failureCount -gt 0) {
            Write-Host "  Failed: $failureCount" -ForegroundColor Red
        }
    }
}
catch {
    Write-Status "SCRIPT FAILED: $_" -Type Error
    Write-Status $_.ScriptStackTrace -Type Error
    exit 1
}

#endregion
