#$token is used with AAD auth, it assumes that you are logged in with Connect-AzAccount
#$token = Get-AzAccessToken -ResourceUrl "https://cognitiveservices.azure.com"

#$key is used with API key auth
$key = "Copy from Azure Portal" #please roll your key after testing
$endpoint = "Copy from Azure Portal"
$region = "uksouth"

$route = "/translator/text/v3.0/translate?api-version=3.0&to=de"

$body = @{
    "Text" = "Boom goes the dynamite!"
}

$body = $body | ConvertTo-Json -AsArray

#API key auth headers
$headers = @{
   "Ocp-Apim-Subscription-Key"    = $key
   "Ocp-Apim-Subscription-Region" = $region
   "Content-Type"                 = "application/json"
}

# AAD auth headers
#$headers = @{
#    "Authorization"                = "$($token.Type) $($token.Token)"
#    "Ocp-Apim-Subscription-Region" = $region
#    "Content-Type"                 = "application/json"
#}

$uri = $endpoint + $route

Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body