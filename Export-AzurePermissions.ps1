<#
.SYNOPSIS
    Exports active and eligible Azure RBAC role assignments using PIM.

.DESCRIPTION
    This script uses the EasyPIM module to export both active and eligible role assignments
    for a specified Azure subscription. Results are exported to timestamped CSV files.

.PARAMETER SubscriptionId
    The Azure Subscription ID to export permissions for.

.PARAMETER OutputPath
    Optional. Directory to save the export files. Defaults to current directory.

.EXAMPLE
    .\Export-AzurePermissions.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"

.EXAMPLE
    .\Export-AzurePermissions.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000" -OutputPath "C:\Reports"

.NOTES
    Requires EasyPIM module. Will be installed automatically if not present.
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,
    
    [Parameter()]
    [string]$OutputPath = "."
)

try {
    # Ensure the EasyPIM module is installed
    if (-not (Get-Module -ListAvailable -Name EasyPIM)) {
        Write-Host "Installing EasyPIM module..." -ForegroundColor Cyan
        Install-Module -Name EasyPIM -Force -Scope CurrentUser -AllowClobber
    }
    
    Import-Module EasyPIM -ErrorAction Stop
    
    Write-Verbose "Setting subscription context"
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    
    $context = Get-AzContext
    $tenantId = $context.Tenant.Id
    
    Write-Host "Exporting permissions for subscription: $($context.Subscription.Name)" -ForegroundColor Cyan
    Write-Host "Tenant ID: $tenantId" -ForegroundColor Cyan
    
    # Get active permissions
    Write-Host "`nGetting active permissions..." -ForegroundColor Yellow
    $activePermissions = Get-PIMAzureResourceActiveAssignment -tenantID $tenantId -subscriptionID $SubscriptionId -ErrorAction Stop | 
        Sort-Object -Property ScopeId, RoleName
    
    # Get eligible permissions
    Write-Host "Getting eligible permissions..." -ForegroundColor Yellow
    $eligiblePermissions = Get-PIMAzureResourceEligibleAssignment -tenantID $tenantId -subscriptionID $SubscriptionId -ErrorAction Stop | 
        Sort-Object -Property ScopeId, RoleName
    
    $date = Get-Date -Format "yyyy-MM-dd-HHmm"
    $subscriptionName = $context.Subscription.Name -replace '[\\/:*?"<>|]', '_'  # Remove invalid filename characters
    
    # Ensure output path exists
    if (-not (Test-Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }
    
    $activeFile = Join-Path $OutputPath "activePermissions-$subscriptionName-$date.csv"
    $eligibleFile = Join-Path $OutputPath "eligiblePermissions-$subscriptionName-$date.csv"
    
    Write-Host "`nExporting permissions to CSV..." -ForegroundColor Yellow
    
    if ($activePermissions) {
        $activePermissions | Export-Csv -Path $activeFile -NoTypeInformation -Force
        Write-Host "Active permissions exported to: $activeFile" -ForegroundColor Green
        Write-Host "  - $($activePermissions.Count) active assignment(s)" -ForegroundColor Gray
    }
    else {
        Write-Host "No active permissions found" -ForegroundColor Yellow
    }
    
    if ($eligiblePermissions) {
        $eligiblePermissions | Export-Csv -Path $eligibleFile -NoTypeInformation -Force
        Write-Host "Eligible permissions exported to: $eligibleFile" -ForegroundColor Green
        Write-Host "  - $($eligiblePermissions.Count) eligible assignment(s)" -ForegroundColor Gray
    }
    else {
        Write-Host "No eligible permissions found" -ForegroundColor Yellow
    }
    
    # Display summary
    if ($activePermissions -or $eligiblePermissions) {
        Write-Host "`nSummary:" -ForegroundColor Cyan
        
        if ($activePermissions) {
            Write-Host "Active Roles:" -ForegroundColor Cyan
            $activePermissions | Group-Object RoleName | 
                Select-Object Name, Count | 
                Sort-Object Count -Descending |
                Format-Table -AutoSize
        }
        
        if ($eligiblePermissions) {
            Write-Host "Eligible Roles:" -ForegroundColor Cyan
            $eligiblePermissions | Group-Object RoleName | 
                Select-Object Name, Count | 
                Sort-Object Count -Descending |
                Format-Table -AutoSize
        }
    }
}
catch {
    Write-Error "An error occurred: $_"
    Write-Error $_.ScriptStackTrace
    throw
}