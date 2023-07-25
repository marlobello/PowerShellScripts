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

[CmdletBinding()]
param (
    [Parameter()]
    [String]
    $SubscriptionName
)

$context = Get-AzContext

if (!$context) {
    Write-Host "Please login to Azure"
    Connect-AzAccount
}

if ($context.Subscription.Name -ne $SubscriptionName) {
    Write-Host "Changing subscription to $SubscriptionName"
    Select-AzSubscription -SubscriptionName $SubscriptionName
}


$blobInventory = @()

Write-Host "Getting all storage accounts in " -NoNewline; Write-Host $SubscriptionName -ForegroundColor Yellow

# Get all blob storage accounts in the subscription
$storageAccounts = Get-AzStorageAccount | Where-Object { $_.Kind -eq "StorageV2" }

# Iterate through each storage account
foreach ($storageAccount in $storageAccounts) {
    Write-Host "`tGetting all containers in " -NoNewline; Write-Host $storageAccount.StorageAccountName -ForegroundColor Cyan

    # create a new storage context
    $storageContext = New-AzStorageContext -StorageAccountName $storageAccount.StorageAccountName

    # Get all containers in the storage account
    $containers = Get-AzStorageContainer -Context $storageContext

    # Iterate through each container
    foreach ($container in $containers) {
        Write-Host "`t`tGetting all blobs in " -NoNewline; Write-Host  $container.Name -ForegroundColor Blue
        
        $MaxReturn = 1000
        $Token = $Null
        do {
            $blobs = Get-AzStorageBlob -Container $container.Name -Context $storageContext -MaxCount $MaxReturn  -ContinuationToken $Token
            # Iterate through each blob
            foreach ($blob in $blobs) {
                Write-Host "`t`t`tFound blob " -NoNewline; Write-Host $blob.Name -ForegroundColor Green
            
                $blobInfo = [PSCustomObject]@{
                    SubscriptionName   = $context.Subscription.Name
                    ResourceGroupName  = $storageAccount.ResourceGroupName
                    StorageAccountName = $storageAccount.StorageAccountName
                    StorageAccountTags = $storageAccount.Tags
                    Container          = $container.Name
                    Name               = $blob.Name
                    BlobType           = $blob.BlobType
                    AccessTier         = $blob.AccessTier
                    ContentType        = $blob.ContentType
                    Length             = $blob.Length
                    LastModified       = $blob.LastModified.ToString("s")
                }

                # Add the blob to the blob inventory
                $blobInventory += $blobInfo

            }
            if ($blobs.Length -le 0) { Break; }
            $Token = $Blobs[$blobs.Count - 1].ContinuationToken;
        }
        While ($null -ne $Token)
    }
}

#$blobInventory | Export-Csv -Path ".\StorageAccountBlobInventory.csv" -NoTypeInformation
$blobInventory

