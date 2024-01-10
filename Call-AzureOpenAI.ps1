### Call Azure OpenAI with PowerShell
### This script is not very smart, it just calls the API a number of times serially with the same body

#$token is used with AAD auth
if (-Not (Get-AzContext -ListAvailable)) {
    Connect-AzAccount
}
$token = Get-AzAccessToken -ResourceUrl "https://cognitiveservices.azure.com"

#AAD auth headers
$headers = @{
    "Authorization" = "$($token.Type) $($token.Token)"
    "Content-Type"  = "application/json"
}

#$key is used with API key auth
#$key = "GETFROMTHEAZUREPORTAL" #please roll your key after testing

#API key auth headers
#$headers = @{
#    "api-key" = $key
#    "Content-Type"  = "application/json"
#}

$endpoint = "https://chat.testing.com"
$deployment = "dev-chatCEG"

$route = "/openai/deployments/" + $deployment + "/chat/completions?api-version=2023-08-01-preview"

$uri = $endpoint + $route

$uri

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

1..5 | ForEach-Object {
    Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body
}