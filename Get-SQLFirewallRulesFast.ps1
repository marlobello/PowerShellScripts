$SQLFirewallRules = @()

# resource graph query to get all SQL Servers
$SQLServers = Search-AzGraph -Query "where type =~ 'Microsoft.Sql/servers' | sort by subscriptionId | project subscriptionId"

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
