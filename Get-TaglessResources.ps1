[CmdletBinding()]
param (
    [Parameter()]
    [String]
    $SubscriptionName
)

$context = Get-AzContext

if(!$context)
{
    Write-Host "Please login to Azure"
    Connect-AzAccount
}

if($context.Subscription.Name -ne $SubscriptionName)
{
    Write-Host "Changing subscription to $SubscriptionName"
    Select-AzSubscription -SubscriptionName $SubscriptionName
}

### Get all resources in the subscription

$resources = Get-AzResource
$taglessresouces = $resources | Where-Object {$_.Tags -eq $null}

Write-Output "Tagless resources in $SubscriptionName"
$taglessresouces | Format-Table -Property ResourceGroupName, Name, ResourceType, Location
