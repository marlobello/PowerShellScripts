param (
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionID
)

# Ensure the EasyPIM module is installed
if (-not (Get-Module -ListAvailable -Name EasyPIM)) {
    Install-Module -Name EasyPIM -Force -Scope CurrentUser
}

# Import the EasyPIM module
Import-Module EasyPIM
Select-AzSubscription -SubscriptionId $SubscriptionID

$tenantID = (Get-AzContext).Tenant.Id

Write-Host "Getting active permissions"
$pa = Get-PIMAzureResourceActiveAssignment -tenantID $tenantID -subscriptionID $subscriptionId | Sort-Object -Property ScopeId,RoleNamme

Write-Host "Getting eligible permissions"
$pe = Get-PIMAzureResourceEligibleAssignment -tenantID $tenantID -subscriptionID $subscriptionId | Sort-Object -Property ScopeId,RoleName

$date = Get-Date -Format "yyyy-MM-dd"

Write-Host "Exporting permissions to CSV"

$pa | Export-Csv -Path "activePermissions-$subscriptionId-$date.csv" -NoTypeInformation
$pe | Export-Csv -Path "eligiblePermissions-$subscriptionId-$date.csv" -NoTypeInformation