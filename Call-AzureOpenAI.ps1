### Call Azure OpenAI with PowerShell

#$token is used with AAD auth
$token = Get-AzAccessToken -ResourceUrl "https://cognitiveservices.azure.com"

#$key is used with API key auth
#$key = "accesskeyFromTheAzurePortal" #please roll your key after testing

$endpoint = "endpointFromTheAzurePortal"
$deployment = "deploymentnamefromAzureAIStudio"

$route = "/openai/deployments/" + $deployment + "/chat/completions?api-version=2023-03-15-preview"

$body = @'
{
    "messages":
    [
        {
            "role": "system",
            "content": "You are a helpful assistant."
        },
        {
            "role": "user",
            "content": "Does Azure OpenAI support customer managed keys?"
        },
        {
            "role": "assistant",
            "content": "Yes, customer managed keys are supported by Azure OpenAI."
        },
        {
            "role": "user",
            "content": "Do other Azure AI services support this too?"
        }
    ]
}
'@

#AAD auth headers
$headers = @{
    "Authorization" = "$($token.Type) $($token.Token)"
    "Content-Type"  = "application/json"
}

#API key auth headers
#$headers = @{
#    "api-key" = $key
#    "Content-Type"  = "application/json"
#}

$uri = $endpoint + $route

$uri

1..100 | ForEach-Object {
    Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body
}