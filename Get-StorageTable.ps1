<#
.SYNOPSIS
    Retrieves all rows from an Azure Storage Table.

.DESCRIPTION
    This script connects to an Azure Storage Account and retrieves all rows from a specified
    table. Uses the modern Az.Storage module.

.PARAMETER SubscriptionName
    The name of the Azure subscription.

.PARAMETER ResourceGroupName
    The name of the resource group containing the storage account.

.PARAMETER StorageAccountName
    The name of the storage account.

.PARAMETER TableName
    The name of the table to query.

.PARAMETER ExportPath
    Optional. Path to export results to CSV.

.EXAMPLE
    .\Get-StorageTable.ps1 -SubscriptionName "MySubscription" -ResourceGroupName "MyRG" -StorageAccountName "mystorageacct" -TableName "MyTable"

.EXAMPLE
    .\Get-StorageTable.ps1 -SubscriptionName "MySubscription" -ResourceGroupName "MyRG" -StorageAccountName "mystorageacct" -TableName "MyTable" -ExportPath "C:\output.csv"

.NOTES
    Requires Az.Storage module. Will be installed automatically if not present.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionName,
    
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,
    
    [Parameter(Mandatory = $true)]
    [string]$TableName,
    
    [Parameter()]
    [string]$ExportPath
)

try {
    # Ensure Az.Storage module is installed
    if (-not (Get-Module -ListAvailable -Name Az.Storage)) {
        Write-Host "Installing Az.Storage module..." -ForegroundColor Cyan
        Install-Module -Name Az.Storage -Force -Scope CurrentUser -AllowClobber
    }
    
    Import-Module Az.Storage -ErrorAction Stop
    
    # Ensure user is logged in
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context) {
        Write-Host "Please login to Azure" -ForegroundColor Yellow
        Connect-AzAccount
    }
    
    # Set subscription context
    if ($context.Subscription.Name -ne $SubscriptionName) {
        Write-Host "Switching to subscription: $SubscriptionName" -ForegroundColor Cyan
        Set-AzContext -SubscriptionName $SubscriptionName -ErrorAction Stop | Out-Null
    }
    
    Write-Host "Getting storage account..." -ForegroundColor Cyan
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop
    $storageContext = $storageAccount.Context
    
    Write-Host "Accessing table: $TableName" -ForegroundColor Cyan
    $table = Get-AzStorageTable -Name $TableName -Context $storageContext -ErrorAction Stop
    
    Write-Host "Retrieving table rows..." -ForegroundColor Cyan
    
    # Get table client using Azure.Data.Tables
    $cloudTable = $table.CloudTable
    
    # Query all entities
    $query = New-Object Microsoft.Azure.Cosmos.Table.TableQuery
    $rows = $cloudTable.ExecuteQuery($query)
    
    if ($rows) {
        $rowCount = ($rows | Measure-Object).Count
        Write-Host "Retrieved $rowCount row(s)" -ForegroundColor Green
        
        if ($ExportPath) {
            $rows | Select-Object * | Export-Csv -Path $ExportPath -NoTypeInformation -Force
            Write-Host "Results exported to: $ExportPath" -ForegroundColor Green
        }
        else {
            $rows | Format-Table -AutoSize
        }
        
        return $rows
    }
    else {
        Write-Host "No rows found in table" -ForegroundColor Yellow
    }
}
catch {
    Write-Error "An error occurred: $_"
    throw
}