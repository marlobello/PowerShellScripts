<#
.SYNOPSIS
    Translates text using Azure Cognitive Services Translator API.

.DESCRIPTION
    This script demonstrates how to call Azure Translator API using Azure AD authentication
    or API key authentication. Supports translating text to multiple target languages.

.PARAMETER Endpoint
    The Azure Translator endpoint URL.

.PARAMETER Region
    The Azure region where the Translator resource is deployed.

.PARAMETER Text
    The text to translate.

.PARAMETER TargetLanguages
    Array of target language codes (e.g., "de", "fr", "es").

.PARAMETER UseApiKey
    Switch to use API key authentication instead of Azure AD.

.PARAMETER ApiKey
    The API key for authentication (required if UseApiKey is specified).

.PARAMETER ApiVersion
    Optional. The API version to use. Defaults to 3.0

.EXAMPLE
    .\Call-CognitiveTranslate.ps1 -Endpoint "https://mytranslator.cognitiveservices.azure.com" -Region "uksouth" -Text "Hello world" -TargetLanguages "de","fr"

.EXAMPLE
    .\Call-CognitiveTranslate.ps1 -Endpoint "https://mytranslator.cognitiveservices.azure.com" -Region "uksouth" -Text "Hello" -TargetLanguages "es" -UseApiKey -ApiKey "your-key-here"

.NOTES
    For Azure AD auth, requires an active Azure PowerShell session (Connect-AzAccount).
    For API key auth, provide the -UseApiKey switch and -ApiKey parameter.
#>

[CmdletBinding(DefaultParameterSetName = 'AzureAD')]
param (
    [Parameter(Mandatory = $true)]
    [string]$Endpoint,
    
    [Parameter(Mandatory = $true)]
    [string]$Region,
    
    [Parameter(Mandatory = $true)]
    [string]$Text,
    
    [Parameter(Mandatory = $true)]
    [string[]]$TargetLanguages,
    
    [Parameter(ParameterSetName = 'ApiKey')]
    [switch]$UseApiKey,
    
    [Parameter(ParameterSetName = 'ApiKey', Mandatory = $true)]
    [string]$ApiKey,
    
    [Parameter()]
    [string]$ApiVersion = "3.0"
)

try {
    # Build the route with all target languages
    $languageParams = ($TargetLanguages | ForEach-Object { "to=$_" }) -join "&"
    $route = "/translator/text/v$ApiVersion/translate?api-version=$ApiVersion&$languageParams"
    $uri = $Endpoint + $route
    
    Write-Host "Translating text to: $($TargetLanguages -join ', ')" -ForegroundColor Cyan
    Write-Verbose "Endpoint: $uri"
    
    # Prepare request body
    $body = @{
        "Text" = $Text
    } | ConvertTo-Json -AsArray
    
    # Set up headers based on authentication method
    if ($UseApiKey) {
        Write-Verbose "Using API key authentication"
        $headers = @{
            "Ocp-Apim-Subscription-Key"    = $ApiKey
            "Ocp-Apim-Subscription-Region" = $Region
            "Content-Type"                 = "application/json"
        }
    }
    else {
        Write-Verbose "Using Azure AD authentication"
        
        # Ensure user is logged in
        $context = Get-AzContext -ErrorAction Stop
        if (-not $context) {
            Write-Host "Please login to Azure" -ForegroundColor Yellow
            Connect-AzAccount
        }
        
        $token = Get-AzAccessToken -ResourceUrl "https://cognitiveservices.azure.com" -ErrorAction Stop
        $headers = @{
            "Authorization"                = "$($token.Type) $($token.Token | ConvertFrom-SecureString -AsPlainText)"
            "Ocp-Apim-Subscription-Region" = $Region
            "Content-Type"                 = "application/json"
        }
    }
    
    # Make the REST API call
    $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body -ErrorAction Stop
    
    Write-Host "`nTranslation Results:" -ForegroundColor Green
    foreach ($result in $response) {
        foreach ($translation in $result.translations) {
            Write-Host "  [$($translation.to)]: $($translation.text)" -ForegroundColor Yellow
        }
    }
    
    return $response
}
catch {
    Write-Error "An error occurred calling the Translator API: $_"
    if ($_.Exception.Response) {
        Write-Error "Status Code: $($_.Exception.Response.StatusCode.value__)"
    }
    throw
}