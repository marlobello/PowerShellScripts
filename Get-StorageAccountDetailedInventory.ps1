<#
.SYNOPSIS
    Creates a detailed inventory of all blobs in Azure Storage Accounts.

.DESCRIPTION
    This script inventories all blobs across storage accounts in a subscription, capturing detailed
    metadata including blob type, access tier, content type, size, and last modified date.
    Results are exported to CSV for analysis.

.PARAMETER SubscriptionName
    The name of the Azure subscription to inventory.

.PARAMETER StorageKinds
    Optional. Array of storage account kinds to include. Defaults to @("StorageV2").
    Valid values: Storage, StorageV2, BlobStorage, FileStorage, BlockBlobStorage

.PARAMETER ResourceGroupName
    Optional. Filter to storage accounts in a specific resource group.

.PARAMETER StorageAccountName
    Optional. Filter to a specific storage account.

.PARAMETER ExportPath
    Optional. Path to export results to CSV. Defaults to .\StorageAccountBlobInventory.csv

.EXAMPLE
    .\Get-StorageAccountDetailedInventory.ps1 -SubscriptionName "MySubscription"
    Inventories all StorageV2 accounts in the subscription.

.EXAMPLE
    .\Get-StorageAccountDetailedInventory.ps1 -SubscriptionName "MySubscription" -ResourceGroupName "storage-rg"
    Inventories storage accounts in a specific resource group.

.EXAMPLE
    .\Get-StorageAccountDetailedInventory.ps1 -SubscriptionName "MySubscription" -StorageKinds @("StorageV2","BlobStorage")
    Inventories multiple storage account kinds.

.EXAMPLE
    .\Get-StorageAccountDetailedInventory.ps1 -SubscriptionName "MySubscription" -StorageAccountName "mystorageacct"
    Inventories a specific storage account.

.NOTES
    THIS CODE-SAMPLE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED 
    OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR 
    FITNESS FOR A PARTICULAR PURPOSE.
    
    - For large storage accounts, this script may take significant time to complete
    - Consider using Azure Storage Inventory feature for very large accounts
    - Uses Azure AD authentication to storage accounts
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [String]$SubscriptionName,
    
    [Parameter()]
    [ValidateSet("Storage", "StorageV2", "BlobStorage", "FileStorage", "BlockBlobStorage")]
    [string[]]$StorageKinds = @("StorageV2"),
    
    [Parameter()]
    [string]$ResourceGroupName,
    
    [Parameter()]
    [string]$StorageAccountName,
    
    [Parameter()]
    [string]$ExportPath = ".\StorageAccountBlobInventory.csv"
)

try {
    $context = Get-AzContext -ErrorAction Stop
    
    if (!$context) {
        Write-Host "Please login to Azure" -ForegroundColor Yellow
        Connect-AzAccount
        $context = Get-AzContext
    }
    
    if ($context.Subscription.Name -ne $SubscriptionName) {
        Write-Host "Switching to subscription: $SubscriptionName" -ForegroundColor Cyan
        Set-AzContext -SubscriptionName $SubscriptionName -ErrorAction Stop | Out-Null
        $context = Get-AzContext
    }
    
    Write-Host "Getting storage accounts in subscription: $SubscriptionName" -ForegroundColor Cyan
    Write-Verbose "Storage kinds filter: $($StorageKinds -join ', ')"
    
    # Get storage accounts with filters
    $storageAccounts = if ($StorageAccountName) {
        Write-Verbose "Filtering to specific storage account: $StorageAccountName"
        Get-AzStorageAccount | Where-Object { 
            $_.StorageAccountName -eq $StorageAccountName -and $_.Kind -in $StorageKinds 
        }
    }
    elseif ($ResourceGroupName) {
        Write-Verbose "Filtering to resource group: $ResourceGroupName"
        Get-AzStorageAccount -ResourceGroupName $ResourceGroupName | Where-Object { 
            $_.Kind -in $StorageKinds 
        }
    }
    else {
        Get-AzStorageAccount | Where-Object { 
            $_.Kind -in $StorageKinds 
        }
    }
    
    if (-not $storageAccounts) {
        Write-Warning "No storage accounts found matching the specified criteria"
        return
    }
    
    Write-Host "Found $($storageAccounts.Count) storage account(s)" -ForegroundColor Green
    
    # Use proper collection type for performance
    $blobInventory = [System.Collections.Generic.List[PSObject]]::new()
    
    $accountProgress = 0
    $totalBlobs = 0
    
    foreach ($storageAccount in $storageAccounts) {
        $accountProgress++
        Write-Progress -Activity "Processing storage accounts" `
            -Status "$accountProgress of $($storageAccounts.Count): $($storageAccount.StorageAccountName)" `
            -PercentComplete (($accountProgress / $storageAccounts.Count) * 100)
        
        Write-Verbose "Processing storage account: $($storageAccount.StorageAccountName)"
        
        try {
            # Create storage context using Azure AD authentication
            $storageContext = New-AzStorageContext `
                -StorageAccountName $storageAccount.StorageAccountName `
                -UseConnectedAccount `
                -ErrorAction Stop
            
            # Get all containers in the storage account
            $containers = Get-AzStorageContainer -Context $storageContext -ErrorAction Stop
            
            if (-not $containers) {
                Write-Verbose "  No containers found"
                continue
            }
            
            Write-Verbose "  Found $($containers.Count) container(s)"
            
            $containerProgress = 0
            foreach ($container in $containers) {
                $containerProgress++
                Write-Progress -Activity "Processing containers" `
                    -Status "$($storageAccount.StorageAccountName) - Container $containerProgress of $($containers.Count): $($container.Name)" `
                    -Id 1 `
                    -PercentComplete (($containerProgress / $containers.Count) * 100)
                
                $MaxReturn = 5000
                $Token = $null
                $containerBlobCount = 0
                
                do {
                    $blobs = Get-AzStorageBlob `
                        -Container $container.Name `
                        -Context $storageContext `
                        -MaxCount $MaxReturn `
                        -ContinuationToken $Token `
                        -ErrorAction Stop
                    
                    foreach ($blob in $blobs) {
                        $blobInventory.Add([PSCustomObject]@{
                            SubscriptionName   = $context.Subscription.Name
                            ResourceGroupName  = $storageAccount.ResourceGroupName
                            StorageAccountName = $storageAccount.StorageAccountName
                            StorageAccountKind = $storageAccount.Kind
                            StorageAccountSku  = $storageAccount.Sku.Name
                            StorageAccountTags = if ($storageAccount.Tags) { 
                                ($storageAccount.Tags | ConvertTo-Json -Compress) 
                            } else { 
                                $null 
                            }
                            Container          = $container.Name
                            BlobName           = $blob.Name
                            BlobType           = $blob.BlobType
                            AccessTier         = $blob.AccessTier
                            ContentType        = $blob.ContentType
                            LengthBytes        = $blob.Length
                            LengthMB           = [math]::Round($blob.Length / 1MB, 2)
                            LastModified       = $blob.LastModified
                        })
                        $containerBlobCount++
                        $totalBlobs++
                    }
                    
                    if ($blobs.Length -le 0) { break }
                    $Token = $blobs[$blobs.Count - 1].ContinuationToken
                    
                } while ($null -ne $Token)
                
                Write-Verbose "    Container '$($container.Name)': $containerBlobCount blob(s)"
            }
            
            Write-Progress -Activity "Processing containers" -Id 1 -Completed
        }
        catch {
            Write-Warning "Failed to process storage account '$($storageAccount.StorageAccountName)': $_"
        }
    }
    
    Write-Progress -Activity "Processing storage accounts" -Completed
    
    if ($blobInventory.Count -gt 0) {
        Write-Host "`nFound $totalBlobs total blob(s)" -ForegroundColor Green
        
        # Export to CSV
        $blobInventory | Export-Csv -Path $ExportPath -NoTypeInformation -Force
        Write-Host "Results exported to: $ExportPath" -ForegroundColor Green
        
        # Calculate and display summary statistics
        Write-Host "`nSummary by Storage Account:" -ForegroundColor Cyan
        $blobInventory | 
            Group-Object StorageAccountName | 
            Select-Object Name, Count, @{
                Name = "TotalSizeGB"
                Expression = { 
                    [math]::Round((($_.Group | Measure-Object -Property LengthBytes -Sum).Sum / 1GB), 2) 
                }
            } | 
            Sort-Object Count -Descending |
            Format-Table -AutoSize
        
        Write-Host "Summary by Container (Top 20):" -ForegroundColor Cyan
        $blobInventory | 
            Group-Object Container | 
            Select-Object Name, Count, @{
                Name = "TotalSizeGB"
                Expression = { 
                    [math]::Round((($_.Group | Measure-Object -Property LengthBytes -Sum).Sum / 1GB), 2) 
                }
            } | 
            Sort-Object Count -Descending |
            Select-Object -First 20 |
            Format-Table -AutoSize
        
        Write-Host "Summary by Access Tier:" -ForegroundColor Cyan
        $blobInventory | 
            Group-Object AccessTier | 
            Select-Object Name, Count, @{
                Name = "TotalSizeGB"
                Expression = { 
                    [math]::Round((($_.Group | Measure-Object -Property LengthBytes -Sum).Sum / 1GB), 2) 
                }
            } | 
            Sort-Object Count -Descending |
            Format-Table -AutoSize
        
        $totalSizeGB = [math]::Round(($blobInventory | Measure-Object -Property LengthBytes -Sum).Sum / 1GB, 2)
        Write-Host "`nTotal storage used: $totalSizeGB GB" -ForegroundColor Cyan
        
        return $blobInventory
    }
    else {
        Write-Host "No blobs found in the specified storage accounts" -ForegroundColor Yellow
    }
}
catch {
    Write-Error "An error occurred: $_"
    Write-Error $_.ScriptStackTrace
    throw
}
