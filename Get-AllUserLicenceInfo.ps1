<#
.SYNOPSIS
    Retrieves license information for all users in Azure AD using Microsoft Graph.

.DESCRIPTION
    This script connects to Microsoft Graph and retrieves license assignment information
    for all users in the tenant. It replaces the deprecated AzureAD module with Microsoft.Graph.

.PARAMETER ExportPath
    Optional. Path to export results to CSV.

.PARAMETER IncludeUnlicensed
    Switch to include users without licenses in the output.

.EXAMPLE
    .\Get-AllUserLicenceInfo.ps1

.EXAMPLE
    .\Get-AllUserLicenceInfo.ps1 -ExportPath "C:\Reports\licenses.csv" -IncludeUnlicensed

.NOTES
    Requires Microsoft.Graph.Users and Microsoft.Graph.Identity.DirectoryManagement modules.
    Will be installed automatically if not present.
#>

[CmdletBinding()]
param (
    [Parameter()]
    [string]$ExportPath,
    
    [Parameter()]
    [switch]$IncludeUnlicensed
)

try {
    # Check and install required modules
    $requiredModules = @('Microsoft.Graph.Users', 'Microsoft.Graph.Identity.DirectoryManagement')
    
    foreach ($module in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            Write-Host "Installing module: $module" -ForegroundColor Cyan
            Install-Module -Name $module -Force -Scope CurrentUser -AllowClobber
        }
    }
    
    # Import modules
    Import-Module Microsoft.Graph.Users -ErrorAction Stop
    Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
    
    # Connect to Microsoft Graph
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
    Connect-MgGraph -Scopes "User.Read.All", "Directory.Read.All" -ErrorAction Stop
    
    Write-Host "Retrieving all users..." -ForegroundColor Cyan
    $users = Get-MgUser -All -Property Id, DisplayName, UserPrincipalName, AssignedLicenses -ErrorAction Stop
    
    Write-Host "Found $($users.Count) user(s)" -ForegroundColor Green
    
    # Get all available license SKUs for friendly name mapping
    Write-Host "Retrieving license SKU information..." -ForegroundColor Cyan
    $skus = Get-MgSubscribedSku -All -ErrorAction Stop
    $skuHashTable = @{}
    foreach ($sku in $skus) {
        $skuHashTable[$sku.SkuId] = $sku.SkuPartNumber
    }
    
    $userLicenseInfo = [System.Collections.Generic.List[PSObject]]::new()
    $allLicenses = [System.Collections.Generic.List[string]]::new()
    
    $progress = 0
    foreach ($user in $users) {
        $progress++
        Write-Progress -Activity "Processing users" -Status "$progress of $($users.Count)" -PercentComplete (($progress / $users.Count) * 100)
        
        if ($user.AssignedLicenses.Count -eq 0) {
            if ($IncludeUnlicensed) {
                $userLicenseInfo.Add([PSCustomObject]@{
                    DisplayName       = $user.DisplayName
                    UserPrincipalName = $user.UserPrincipalName
                    License           = "(No licenses)"
                    LicenseCount      = 0
                })
            }
            Write-Verbose "$($user.DisplayName) has no licenses"
        }
        else {
            Write-Verbose "$($user.DisplayName) has $($user.AssignedLicenses.Count) license(s)"
            
            foreach ($license in $user.AssignedLicenses) {
                $skuPartNumber = $skuHashTable[$license.SkuId]
                if (-not $skuPartNumber) {
                    $skuPartNumber = $license.SkuId
                }
                
                $userLicenseInfo.Add([PSCustomObject]@{
                    DisplayName       = $user.DisplayName
                    UserPrincipalName = $user.UserPrincipalName
                    License           = $skuPartNumber
                    LicenseCount      = $user.AssignedLicenses.Count
                })
                
                if ($allLicenses -notcontains $skuPartNumber) {
                    $allLicenses.Add($skuPartNumber)
                }
            }
        }
    }
    
    Write-Progress -Activity "Processing users" -Completed
    
    # Display results
    Write-Host "`nUser License Information:" -ForegroundColor Cyan
    $userLicenseInfo | Format-Table -Property DisplayName, UserPrincipalName, License -GroupBy DisplayName
    
    # Export if requested
    if ($ExportPath) {
        $userLicenseInfo | Export-Csv -Path $ExportPath -NoTypeInformation -Force
        Write-Host "`nResults exported to: $ExportPath" -ForegroundColor Green
    }
    
    # Display summary
    Write-Host "`nLicense Summary:" -ForegroundColor Cyan
    Write-Host "Total users: $($users.Count)" -ForegroundColor Gray
    Write-Host "Licensed users: $(($userLicenseInfo | Select-Object -Unique UserPrincipalName | Measure-Object).Count)" -ForegroundColor Gray
    Write-Host "Unique licenses: $($allLicenses.Count)" -ForegroundColor Gray
    
    Write-Host "`nLicense Distribution:" -ForegroundColor Cyan
    $userLicenseInfo | Where-Object { $_.License -ne "(No licenses)" } | 
        Group-Object License | 
        Select-Object Name, Count | 
        Sort-Object Count -Descending |
        Format-Table -AutoSize
    
    return $userLicenseInfo
}
catch {
    Write-Error "An error occurred: $_"
    throw
}
finally {
    # Disconnect from Microsoft Graph
    Disconnect-MgGraph -ErrorAction SilentlyContinue
}
