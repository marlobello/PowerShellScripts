<# 
.SYNOPSIS
    Finds V1 Hybrid Runbook Workers that need migration to V2.

.DESCRIPTION
    This script identifies V1 Hybrid Runbook Workers across Automation Accounts.
    V1 workers are deprecated and should be migrated to V2 (extension-based).

.PARAMETER SubscriptionId
    The Azure Subscription ID to query.

.PARAMETER ExportPath
    Optional. Path to export results to CSV.

.EXAMPLE
    .\Get-V1HybridRunbookWorkers.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"

.EXAMPLE
    .\Get-V1HybridRunbookWorkers.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000" -ExportPath ".\v1-workers.csv"

.NOTES
    THIS CODE-SAMPLE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED 
    OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR 
    FITNESS FOR A PARTICULAR PURPOSE.
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,
    
    [Parameter()]
    [string]$ExportPath
)

try {
    if (-not (Get-Module -ListAvailable -Name Az.Automation)) {
        Write-Warning "Az.Automation module not found. Installing..."
        Install-Module -Name Az.Automation -Force -Scope CurrentUser -AllowClobber
    }
    
    Write-Verbose "Setting subscription context to: $SubscriptionId"
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    
    $context = Get-AzContext
    Write-Host "Searching for V1 Hybrid Runbook Workers in subscription: $($context.Subscription.Name)" -ForegroundColor Cyan
    
    $automationAccounts = Get-AzAutomationAccount -ErrorAction Stop
    
    if (-not $automationAccounts) {
        Write-Host "No Automation Accounts found in this subscription." -ForegroundColor Yellow
        return
    }
    
    Write-Host "Found $($automationAccounts.Count) Automation Account(s). Checking for V1 workers..." -ForegroundColor Cyan
    
    $v1Workers = [System.Collections.Generic.List[PSObject]]::new()
    
    foreach ($automationAccount in $automationAccounts) {
        Write-Verbose "Checking: $($automationAccount.AutomationAccountName)"
        
        try {
            $hybridWorkerGroups = Get-AzAutomationHybridWorkerGroup `
                -ResourceGroupName $automationAccount.ResourceGroupName `
                -AutomationAccountName $automationAccount.AutomationAccountName `
                -ErrorAction Stop
            
            foreach ($group in $hybridWorkerGroups) {
                try {
                    $hybridWorkers = Get-AzAutomationHybridRunbookWorker `
                        -ResourceGroupName $automationAccount.ResourceGroupName `
                        -AutomationAccountName $automationAccount.AutomationAccountName `
                        -HybridRunbookWorkerGroupName $group.Name `
                        -ErrorAction Stop
                    
                    foreach ($worker in $hybridWorkers) {
                        if ($worker.WorkerType -ne "HybridV2") {
                            $workerInfo = [PSCustomObject]@{
                                SubscriptionId      = $context.Subscription.Id
                                SubscriptionName    = $context.Subscription.Name
                                ResourceGroup       = $automationAccount.ResourceGroupName
                                AutomationAccount   = $automationAccount.AutomationAccountName
                                WorkerGroup         = $group.Name
                                WorkerName          = $worker.WorkerName
                                WorkerType          = $worker.WorkerType
                                RegistrationTime    = $worker.RegistrationDateTime
                            }
                            
                            $v1Workers.Add($workerInfo)
                        }
                    }
                }
                catch {
                    Write-Warning "Failed to get workers for group '$($group.Name)': $_"
                }
            }
        }
        catch {
            Write-Warning "Failed to get worker groups for '$($automationAccount.AutomationAccountName)': $_"
        }
    }
    
    if ($v1Workers.Count -gt 0) {
        Write-Host "`nFound $($v1Workers.Count) V1 Hybrid Runbook Worker(s) requiring migration:" -ForegroundColor Yellow
        
        if ($ExportPath) {
            $v1Workers | Export-Csv -Path $ExportPath -NoTypeInformation -Force
            Write-Host "Results exported to: $ExportPath" -ForegroundColor Green
        }
        
        $v1Workers | Format-Table -AutoSize
        
        Write-Host "`nSummary by Automation Account:" -ForegroundColor Cyan
        $v1Workers | Group-Object AutomationAccount | 
            Select-Object Name, Count | 
            Format-Table -AutoSize
        
        return $v1Workers
    }
    else {
        Write-Host "`nNo V1 Hybrid Runbook Workers found. All workers are V2!" -ForegroundColor Green
    }
}
catch {
    Write-Error "An error occurred: $_"
    throw
}