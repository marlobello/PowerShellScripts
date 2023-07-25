<# THIS CODE-SAMPLE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED 
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR 
FITNESS FOR A PARTICULAR PURPOSE.

This sample is not supported under any Microsoft standard support program or service. 
The script is provided AS IS without warranty of any kind. Microsoft further disclaims all
implied warranties including, without limitation, any implied warranties of merchantability
or of fitness for a particular purpose. The entire risk arising out of the use or performance
of the sample and documentation remains with you. In no event shall Microsoft, its authors,
or anyone else involved in the creation, production, or delivery of the script be liable for 
any damages whatsoever (including, without limitation, damages for loss of business profits, 
business interruption, loss of business information, or other pecuniary loss) arising out of 
the use of or inability to use the sample or documentation, even if Microsoft has been advised 
of the possibility of such damages, rising out of the use of or inability to use the sample script, 
even if Microsoft has been advised of the possibility of such damages. #>

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
