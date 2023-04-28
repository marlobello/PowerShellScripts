$SQLFirewallRules = @()

# Get all azure subscriptions
$subscriptions = Get-AzSubscription

#iterate through each subscription
foreach($subscription in $subscriptions)
{
    #set the current subscription
    Set-AzContext -Subscription $subscription

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
