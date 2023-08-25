#$token is used with AAD auth, it assumes that you are logged in with Connect-AzAccount
$token = Get-AzAccessToken -ResourceUrl "https://cognitiveservices.azure.com"

#$key is used with API key auth
#$key = "accesskeyFromTheAzurePortal" #please roll your key after testing

$region = "eastus"

#$route = "/translate?api-version=3.0&to=de";
$route = "/translator/text/v3.0/translate?api-version=3.0&to=de"

$body = @{
    "Text" = "Boom goes the dynamite!"
}

$body = $body | ConvertTo-Json -AsArray

# API key auth headers
#$headers = @{
#   "Ocp-Apim-Subscription-Key"    = $key
#   "Ocp-Apim-Subscription-Region" = $region
#   "Content-Type"                 = "application/json"
#}

# AAD auth headers
$headers = @{
    "Authorization"                = "$($token.Type) $($token.Token)"
    "Ocp-Apim-Subscription-Region" = $region
    "Content-Type"                 = "application/json"
}

$uri = $endpoint + $route


1..10 | ForEach-Object (
{
    $uri
    Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body
})
