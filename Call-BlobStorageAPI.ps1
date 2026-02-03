<#
.SYNOPSIS
    Makes REST API calls to Azure Blob Storage using Azure AD authentication.

.DESCRIPTION
    This script demonstrates how to call Azure Blob Storage REST API using Bearer token
    authentication from the current Azure PowerShell session.

.PARAMETER StorageAccountName
    The name of the storage account.

.PARAMETER ContainerName
    The name of the blob container.

.PARAMETER BlobName
    The name of the blob to query.

.PARAMETER GetParameters
    Optional. Query parameters to append to the request (e.g., "comp=blocklist").

.PARAMETER ApiVersion
    Optional. The API version to use. Defaults to 2025-07-05

.EXAMPLE
    .\Call-BlobStorageAPI.ps1 -StorageAccountName "mystorageaccount" -ContainerName "mycontainer" -BlobName "file.txt"

.EXAMPLE
    .\Call-BlobStorageAPI.ps1 -StorageAccountName "mystorageaccount" -ContainerName "mycontainer" -BlobName "file.txt" -GetParameters "comp=blocklist"

.NOTES
    Requires an active Azure PowerShell session (Connect-AzAccount).
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,
    
    [Parameter(Mandatory = $true)]
    [string]$ContainerName,
    
    [Parameter(Mandatory = $true)]
    [string]$BlobName,
    
    [Parameter()]
    [string]$GetParameters,
    
    [Parameter()]
    [string]$ApiVersion = "2025-07-05"
)

try {
    # Ensure user is logged in
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context) {
        Write-Host "Please login to Azure" -ForegroundColor Yellow
        Connect-AzAccount
        $context = Get-AzContext
    }
    
    Write-Verbose "Getting access token for storage API"
    $token = (Get-AzAccessToken -ResourceUrl "https://storage.azure.com/" -ErrorAction Stop).Token | 
        ConvertFrom-SecureString -AsPlainText
    
    # Construct the Blob service endpoint
    $blobEndpoint = "https://$StorageAccountName.blob.core.windows.net/$ContainerName/$BlobName"
    
    if ($GetParameters) {
        $blobEndpoint += "?$GetParameters"
    }
    
    Write-Host "Calling Blob Storage API:" -ForegroundColor Cyan
    Write-Host "  Endpoint: $blobEndpoint" -ForegroundColor Gray
    
    # Set the headers with the Bearer token
    $headers = @{
        Authorization  = "Bearer $token"
        "x-ms-version" = $ApiVersion
    }
    
    # Make the REST API call
    $response = Invoke-RestMethod -Uri $blobEndpoint -Method Get -Headers $headers -ErrorAction Stop
    
    Write-Host "`nResponse received successfully" -ForegroundColor Green
    
    return $response
}
catch {
    Write-Error "An error occurred calling the Blob Storage API: $_"
    if ($_.Exception.Response) {
        Write-Error "Status Code: $($_.Exception.Response.StatusCode.value__)"
        Write-Error "Status Description: $($_.Exception.Response.StatusDescription)"
    }
    throw
}