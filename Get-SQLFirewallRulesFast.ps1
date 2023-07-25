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

$SQLFirewallRules = @()

# resource graph query to get all SQL Servers
$SQLServers = Search-AzGraph -Query "resources | where type =~ 'Microsoft.Sql/servers' | sort by subscriptionId | project subscriptionId"

#iterate through each subscription WHICH ACTUALLY HAS A SQL SERVER
foreach($SQLServer in $SQLServers)
{
    
    #check current subscription context
    $context = Get-AzContext
    if($context.Subscription.Id -ne $SQLServer.subscriptionId)
    {
        #set the current subscription
        Set-AzContext -Subscription $SQLServer.subscriptionId
    }

    #get all SQL servers
    $sqlservers = Get-AzSqlServer

    #iterate through each SQL server
    foreach($sqlserver in $sqlservers)
    {
        #get all firewall rules for the SQL server
        $firewallrules = Get-AzSqlServerFirewallRule -ServerName $sqlserver.ServerName -ResourceGroupName $sqlserver.ResourceGroupName

        #iterate through each firewall rule
        foreach($firewallrule in $firewallrules)
        {
            #write the firewall rule to the console
            #Write-Output $firewallrule | Format-Table -Property ResourceGroupName, ServerName, FirewallRuleName, StartIpAddress, EndIpAddress
            $SQLFirewallRules += $firewallrule
        }
    }
}

$SqlFirewallRules | Export-Csv -Path ".\SQLFirewallRules.csv" -NoTypeInformation
