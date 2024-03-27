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

# resource graph query to get all Windows Servers with the MMA extension
$WindowsServersWithMMA = Search-AzGraph -Query 'resources
| where type == "microsoft.compute/virtualmachines" and properties.storageProfile.osDisk.osType == "Windows"
| project id, subscriptionId, resourceGroup, name, os = properties.storageProfile.osDisk.osType
| join (resources | where type == "microsoft.compute/virtualmachines/extensions" | project vmResourceId = tostring(split(id,"/extensions/")[0]), extensionResourceId = id, exentensionPublisher = properties.publisher, extensionType = properties.type) on $left.id == $right.vmResourceId
| where extensionType == "MicrosoftMonitoringAgent"
| sort by subscriptionId'

#iterate through each subscription WHICH ACTUALLY HAS A SERVER
foreach($Server in $WindowsServersWithMMA)
{
    
    #check current subscription context
    $context = Get-AzContext
    if($context.Subscription.Id -ne $Server.subscriptionId)
    {
        #set the current subscription
        Set-AzContext -Subscription $Server.subscriptionId
    }

    Remove-AzVMExtension -ResourceGroupName $Server.resourceGroup -VMName $Server.name -Name "MicrosoftMonitoringAgent" -Force -AsJob
}


# resource graph query to get all Linux Servers with the MMA extension
$LinuxServersWithMMA = Search-AzGraph -Query 'resources
| where type == "microsoft.compute/virtualmachines" and properties.storageProfile.osDisk.osType == "Linux"
| project id, subscriptionId, resourceGroup, name, os = properties.storageProfile.osDisk.osType
| join (resources | where type == "microsoft.compute/virtualmachines/extensions" | project vmResourceId = tostring(split(id,"/extensions/")[0]), extensionResourceId = id, exentensionPublisher = properties.publisher, extensionType = properties.type) on $left.id == $right.vmResourceId
| where extensionType == "OmsAgentForLinux"
| sort by subscriptionId'

foreach($Server in $LinuxServersWithMMA)
{
    
    #check current subscription context
    $context = Get-AzContext
    if($context.Subscription.Id -ne $Server.subscriptionId)
    {
        #set the current subscription
        Set-AzContext -Subscription $Server.subscriptionId
    }

    Remove-AzVMExtension -ResourceGroupName $Server.resourceGroup -VMName $Server.name -Name "OmsAgentForLinux" -Force -AsJob
}