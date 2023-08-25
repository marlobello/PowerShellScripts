$token = Get-AzAccessToken -ResourceUrl "https://cognitiveservices.azure.com"

#$key = "ccd54aa75663485990f889302caf4b6c"
#$endpoint = "https://api.cognitive.microsofttranslator.com"
#$endpoint = "https://test-cogsvc.cognitiveservices.azure.com"
$endpoint = "https://cog.cloud.marlo.bellz.com"
$region = "eastus"

#$route = "/translate?api-version=3.0&to=de";
$route = "/translator/text/v3.0/translate?api-version=3.0&to=de"

$body = @{
    "Text" = "Boom goes the dynamite!"
}

$body = $body | ConvertTo-Json -AsArray

#$headers = @{
#   "Ocp-Apim-Subscription-Key"    = $key
#   "Ocp-Apim-Subscription-Region" = $region
#   "Content-Type"                 = "application/json"
#}

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
