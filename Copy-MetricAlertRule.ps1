<#
.SYNOPSIS
Because creating metric alert rules can be tedious with lots of options, this script allows you to copy an existing alert rule but change a few key target parameters so that the alert rule can apply to other subscriptions and/or other regions. This script assumes that are targeting alert rules to entire subscriptions, not individual resources. Currently in Azure, you must create a separate alert rule for each subscription, resource type and region combination.

.DESCRIPTION
The script copies an existing alert rule, changing the target subscription and region but keeps the resource type, metric, and alerting parameters.

.PARAMETER AlertRuleSubscriptionName
The name of the subscription where the example alert rule currently exists and the new one will be created.

.PARAMETER AlertRuleResourceGroupName
The name of the resource group where the example alert rule currently exists and the new one will be created.

.PARAMETER ExampleAlertRuleName
The name of the alert rule to be copied.

.PARAMETER TargetResourceSubscriptionName
The name of the target subscription where the alert rule will be applied to.

.PARAMETER TargetResourceRegion
The region of the target resource where the alert rule will be applied to.

.PARAMETER TargetResourceTypeFriendlyName
The friendly name of the target resource type where the alert rule will be copied to (e.g., "sql" or "vm").

.EXAMPLE
.\Copy-InfrastructureAlertRules.ps1 -AlertRuleSubscriptionName "SourceSubscription" -AlertRuleResourceGroupName "SourceResourceGroup" -ExampleAlertRuleName "ExampleAlertRule" -TargetResourceSubscriptionName "TargetSubscription" -TargetResourceRegion "eastus" -TargetResourceTypeFriendlyName "vm"

This example copies an alert rule named "ExampleAlertRule" from the "SourceSubscription" subscription to the "TargetSubscription" subscription in the "eastus" region.

.NOTES
Author: Marlo Bell
Date: 14 June 2023

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
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$AlertRuleSubscriptionName,

    [Parameter(Mandatory = $true)]
    [string]$AlertRuleResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$ExampleAlertRuleName,

    [Parameter(Mandatory = $true)]
    [string]$TargetResourceSubscriptionName,

    [Parameter(Mandatory = $true)]
    [string]$TargetResourceRegion,

    [Parameter(Mandatory = $true)]
    [string]$TargetResourceTypeFriendlyName

)

$context = Get-AzContext

if(!$context)
{
    Write-Host "Please login to Azure"
    Connect-AzAccount
}

# Get the target subscription ID
Set-AzContext -SubscriptionName $TargetResourceSubscriptionName | Out-Null
$TargetSubscriptionId = (Get-AzContext).Subscription.Id

# Select the monitoring subscription
Set-AzContext -SubscriptionName $AlertRuleSubscriptionName | Out-Null

# Get example alert rule
$alert = Get-AzMetricAlertRuleV2 -ResourceGroupName $AlertRuleResourceGroupName -Name $ExampleAlertRuleName

# Create the Azure Monitor Alert Rule
$alertRuleName = $TargetResourceSubscriptionName, $TargetResourceRegion, $TargetResourceTypeFriendlyName, $alert.Criteria.MetricName, "alertrule" -join "-"
$alertRuleDescription = "Alert rule for $TargetResourceTypeFriendlyName $($alert.Criteria.MetricName) in $TargetResourceSubscriptionName and $TargetResourceRegion"

Add-AzMetricAlertRuleV2 -Name $alertRuleName `
-Description $alertRuleDescription `
-ResourceGroupName $alert.ResourceGroup `
-TargetResourceScope "/subscriptions/$TargetSubscriptionId" `
-TargetResourceRegion $TargetResourceRegion `
-TargetResourceType $alert.TargetResourceType `
-Condition $alert.Criteria `
-WindowSize $alert.WindowSize `
-Frequency $alert.EvaluationFrequency `
-Severity $alert.Severity `
-ActionGroup $alert.Actions
