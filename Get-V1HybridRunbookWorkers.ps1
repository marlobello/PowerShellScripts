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
    [string]$SubscriptionId
)

# Ensure the Az module is installed
if (-not (Get-Module -ListAvailable -Name Az)) {
    Install-Module -Name Az -Force -Scope CurrentUser
}

# Set the specified subscription
Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null

# Get all Automation Accounts in the subscription
$automationAccounts = Get-AzAutomationAccount

# Loop through each Automation Account to find Hybrid Runbook Workers
foreach ($automationAccount in $automationAccounts) {

    # Get Hybrid Runbook Workers for the Automation Account
    $hybridWorkergroups = Get-AzAutomationHybridWorkerGroup -ResourceGroupName $automationAccount.ResourceGroupName -AutomationAccountName $automationAccount.AutomationAccountName

    foreach ($group in $hybridWorkergroups) {
        
        $hybridworkers = Get-AzAutomationHybridRunbookWorker -ResourceGroupName $automationAccount.ResourceGroupName -AutomationAccountName $automationAccount.AutomationAccountName -HybridRunbookWorkerGroupName $group.Name

        foreach ($worker in $hybridworkers) {
            if ($worker.WorkerType -ne "HybridV2") {
                Write-Output "Resource Group: $($automationAccount.ResourceGroupName)"
                Write-Output "Automation Account: $($automationAccount.AutomationAccountName)"
                Write-Output "Hybrid Worker Group: $($group.Name)"
                Write-Output "Worker Name: $($worker.WorkerName)"
                Write-Output "Worker Type: $($worker.WorkerType)"
            }
        }
    }
}