<#
.SYNOPSIS
    Calls Azure OpenAI API for chat completions.

.DESCRIPTION
    This script demonstrates how to call Azure OpenAI chat completion API using either
    Azure AD authentication or API key authentication. Supports multiple iterations for testing.

.PARAMETER Endpoint
    The Azure OpenAI endpoint URL.

.PARAMETER Deployment
    The name of the Azure OpenAI deployment to use.

.PARAMETER Prompt
    The user prompt to send to the model.

.PARAMETER SystemMessage
    Optional. The system message to set context. Defaults to "You are a helpful assistant."

.PARAMETER Iterations
    Optional. Number of times to call the API. Defaults to 1.

.PARAMETER UseApiKey
    Switch to use API key authentication instead of Azure AD.

.PARAMETER ApiKey
    The API key for authentication (required if UseApiKey is specified).

.PARAMETER ApiVersion
    Optional. The API version to use. Defaults to 2024-02-15-preview

.EXAMPLE
    .\Call-AzureOpenAI.ps1 -Endpoint "https://myopenai.openai.azure.com" -Deployment "gpt-4" -Prompt "What is Azure?"

.EXAMPLE
    .\Call-AzureOpenAI.ps1 -Endpoint "https://myopenai.openai.azure.com" -Deployment "gpt-4" -Prompt "Explain AI" -Iterations 5

.EXAMPLE
    .\Call-AzureOpenAI.ps1 -Endpoint "https://myopenai.openai.azure.com" -Deployment "gpt-4" -Prompt "Hello" -UseApiKey -ApiKey "your-key-here"

.NOTES
    For Azure AD auth, requires an active Azure PowerShell session (Connect-AzAccount).
    For API key auth, provide the -UseApiKey switch and -ApiKey parameter.
#>

[CmdletBinding(DefaultParameterSetName = 'AzureAD')]
param (
    [Parameter(Mandatory = $true)]
    [string]$Endpoint,
    
    [Parameter(Mandatory = $true)]
    [string]$Deployment,
    
    [Parameter(Mandatory = $true)]
    [string]$Prompt,
    
    [Parameter()]
    [string]$SystemMessage = "You are a helpful assistant.",
    
    [Parameter()]
    [ValidateRange(1, 100)]
    [int]$Iterations = 1,
    
    [Parameter(ParameterSetName = 'ApiKey')]
    [switch]$UseApiKey,
    
    [Parameter(ParameterSetName = 'ApiKey', Mandatory = $true)]
    [string]$ApiKey,
    
    [Parameter()]
    [string]$ApiVersion = "2024-02-15-preview"
)

try {
    $route = "/openai/deployments/$Deployment/chat/completions?api-version=$ApiVersion"
    $uri = $Endpoint + $route
    
    Write-Host "Calling Azure OpenAI:" -ForegroundColor Cyan
    Write-Host "  Endpoint: $Endpoint" -ForegroundColor Gray
    Write-Host "  Deployment: $Deployment" -ForegroundColor Gray
    Write-Host "  Iterations: $Iterations" -ForegroundColor Gray
    Write-Verbose "Full URI: $uri"
    
    # Set up headers based on authentication method
    if ($UseApiKey) {
        Write-Verbose "Using API key authentication"
        $headers = @{
            "api-key"      = $ApiKey
            "Content-Type" = "application/json"
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
            "Authorization" = "$($token.Type) $($token.Token | ConvertFrom-SecureString -AsPlainText)"
            "Content-Type"  = "application/json"
        }
    }
    
    # Prepare request body
    $bodyObject = @{
        messages = @(
            @{
                role    = "system"
                content = $SystemMessage
            },
            @{
                role    = "user"
                content = $Prompt
            }
        )
    }
    
    $body = $bodyObject | ConvertTo-Json -Depth 10
    
    $responses = @()
    
    # Make API calls
    for ($i = 1; $i -le $Iterations; $i++) {
        if ($Iterations -gt 1) {
            Write-Host "`nIteration $i of $Iterations..." -ForegroundColor Yellow
        }
        
        $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body -ErrorAction Stop
        $responses += $response
        
        if ($response.choices -and $response.choices[0].message) {
            Write-Host "`nResponse:" -ForegroundColor Green
            Write-Host $response.choices[0].message.content
            
            if ($response.usage) {
                Write-Verbose "Tokens - Prompt: $($response.usage.prompt_tokens), Completion: $($response.usage.completion_tokens), Total: $($response.usage.total_tokens)"
            }
        }
        
        # Small delay between iterations
        if ($i -lt $Iterations) {
            Start-Sleep -Milliseconds 500
        }
    }
    
    if ($Iterations -gt 1) {
        $totalTokens = ($responses | ForEach-Object { $_.usage.total_tokens } | Measure-Object -Sum).Sum
        Write-Host "`nTotal tokens used across all iterations: $totalTokens" -ForegroundColor Cyan
    }
    
    return $responses
}
catch {
    Write-Error "An error occurred calling the Azure OpenAI API: $_"
    if ($_.Exception.Response) {
        Write-Error "Status Code: $($_.Exception.Response.StatusCode.value__)"
    }
    throw
}