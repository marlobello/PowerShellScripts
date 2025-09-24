# Define variables
$storageAccountName = ""
$containerName = ""
$blobName = "file.txt"
$getParameters = "comp=blocklist"


# Get the access token from the current Az session
$token = (Get-AzAccessToken -ResourceUrl "https://storage.azure.com/").Token | ConvertFrom-SecureString -AsPlainText

# Construct the Blob service endpoint
$blobEndpoint = "https://$($storageAccountName).blob.core.windows.net/$($containerName)/$($blobName)?$($getParameters)"

$blobEndpoint

# Set the headers with the Bearer token
$headers = @{
    Authorization = "Bearer $token"
    "x-ms-version" = "2025-07-05"
}

# Make the REST API call to list blobs
$response = Invoke-RestMethod -Uri $blobEndpoint -Method Get -Headers $headers

$response