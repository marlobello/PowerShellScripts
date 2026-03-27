<# 
.SYNOPSIS
    Retrieves SQL Server firewall rules across subscriptions using Azure Resource Graph
    and outputs a formatted Markdown report.

.DESCRIPTION
    Efficiently queries all SQL Server firewall rules across subscriptions using Azure
    Resource Graph for optimal performance. Only queries subscriptions that contain SQL
    Servers. Output is a Markdown file written to the ./output/ directory relative to
    the script location.

.PARAMETER OutputFileName
    Optional base name for the output file (no extension). Defaults to
    'SQLFirewallRules_{yyyyMMdd}'. The .md extension is always appended; if you
    include it yourself it will not be duplicated.

.PARAMETER AllSubscriptions
    Switch to query all accessible subscriptions. If not specified, uses current context.

.PARAMETER SubscriptionId
    Optional. Specific subscription ID to query.

.EXAMPLE
    .\Get-SQLFirewallRulesFast.ps1
    Exports SQL firewall rules from the current subscription to ./output/SQLFirewallRules_{date}.md

.EXAMPLE
    .\Get-SQLFirewallRulesFast.ps1 -AllSubscriptions -OutputFileName "AllSubs-FirewallAudit"
    Exports SQL firewall rules from all subscriptions to ./output/AllSubs-FirewallAudit.md

.NOTES
    THIS CODE-SAMPLE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED 
    OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR 
    FITNESS FOR A PARTICULAR PURPOSE.

    Output file: ./output/SQLFirewallRules_{yyyyMMdd}.md (default), or
                 ./output/{OutputFileName}.md if -OutputFileName is supplied.
#>

[CmdletBinding()]
param (
    [Parameter()]
    [string]$OutputFileName,

    [Parameter()]
    [switch]$AllSubscriptions,

    [Parameter()]
    [string]$SubscriptionId
)

$scriptStart = Get-Date

# ── Prepare output directory ────────────────────────────────────────────────────
$outputDir = Join-Path $PSScriptRoot "output"
try {
    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -ErrorAction Stop | Out-Null
        Write-Host "Created output directory: $outputDir"
    }
} catch {
    throw "Failed to create output directory '$outputDir': $($_.Exception.Message)"
}

$timestamp      = $scriptStart.ToString("yyyyMMdd")
$base           = if ($OutputFileName) { $OutputFileName.Trim() } else { "SQLFirewallRules_$timestamp" }
$reportFileName = if ($base -notlike '*.md') { "$base.md" } else { $base }
$reportPath     = Join-Path $outputDir $reportFileName

try {
    Write-Host "Finding SQL Server firewall rules..." -ForegroundColor Cyan

    # Build query to get all SQL firewall rules using Resource Graph
    $query = @"
resources
| where type =~ 'Microsoft.Sql/servers/firewallRules'
| extend serverName = tostring(split(id, '/')[8])
| extend ruleName = name
| project 
    subscriptionId,
    resourceGroup,
    serverName,
    ruleName,
    startIpAddress = properties.startIpAddress,
    endIpAddress = properties.endIpAddress,
    location
| order by subscriptionId asc, resourceGroup asc, serverName asc, ruleName asc
"@

    $subscriptions = @()

    if ($SubscriptionId) {
        $subscriptions = @($SubscriptionId)
        Write-Verbose "Querying subscription: $SubscriptionId"
        $firewallRules = Search-AzGraph -Query $query -Subscription $subscriptions -First 1000
    } elseif ($AllSubscriptions) {
        Write-Verbose "Querying all accessible subscriptions"
        $firewallRules = Search-AzGraph -Query $query -First 1000
    } else {
        $context = Get-AzContext -ErrorAction Stop
        $subscriptions = @($context.Subscription.Id)
        Write-Verbose "Querying current subscription: $($context.Subscription.Name)"
        $firewallRules = Search-AzGraph -Query $query -Subscription $subscriptions -First 1000
    }

    # Handle pagination
    while ($firewallRules.SkipToken) {
        Write-Verbose "Fetching additional results..."
        $moreResults   = Search-AzGraph -Query $query -Subscription $subscriptions -First 1000 -SkipToken $firewallRules.SkipToken
        $firewallRules += $moreResults
    }

    # ── Build Markdown report ───────────────────────────────────────────────────
    $md = [System.Collections.Generic.List[string]]::new()

    $md.Add("# SQL Server Firewall Rules Report")
    $md.Add("")
    $md.Add("| | |")
    $md.Add("|---|---|")
    $md.Add("| **Generated** | $($scriptStart.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC |")
    $scopeLabel = if ($SubscriptionId) { "``$SubscriptionId``" } elseif ($AllSubscriptions) { "All accessible subscriptions" } else { "Current context subscription" }
    $md.Add("| **Scope** | $scopeLabel |")

    if (-not $firewallRules -or $firewallRules.Count -eq 0) {
        $md.Add("| **Rules Found** | 0 |")
        $md.Add("")
        $md.Add("_No SQL Server firewall rules found in the queried scope._")
        $md -join "`n" | Out-File -FilePath $reportPath -Encoding UTF8 -Force
        Write-Host "No SQL Server firewall rules found." -ForegroundColor Yellow
        Write-Host "Report written to: $reportPath" -ForegroundColor Green
        return
    }

    $uniqueSubs    = @($firewallRules | Select-Object -ExpandProperty subscriptionId -Unique)
    $uniqueServers = @($firewallRules | Select-Object -ExpandProperty serverName -Unique)

    $md.Add("| **Total Rules** | $($firewallRules.Count) |")
    $md.Add("| **Subscriptions** | $($uniqueSubs.Count) |")
    $md.Add("| **SQL Servers** | $($uniqueServers.Count) |")
    $md.Add("")
    $md.Add("---")
    $md.Add("")

    # ── Summary table ────────────────────────────────────────────────────────────
    $md.Add("## Summary by SQL Server")
    $md.Add("")
    $md.Add("| Subscription ID | Resource Group | Server | Location | Rule Count |")
    $md.Add("|---|---|---|---|---:|")

    $firewallRules |
        Group-Object subscriptionId, resourceGroup, serverName |
        ForEach-Object {
            $sample = $_.Group[0]
            $md.Add("| ``$($sample.subscriptionId)`` | $($sample.resourceGroup) | $($sample.serverName) | $($sample.location) | $($_.Count) |")
        }

    $md.Add("")
    $md.Add("---")
    $md.Add("")

    # ── Detail section: grouped by subscription → server ─────────────────────────
    $md.Add("## Firewall Rules by Server")
    $md.Add("")

    foreach ($subId in ($firewallRules | Select-Object -ExpandProperty subscriptionId -Unique | Sort-Object)) {
        $subRules = @($firewallRules | Where-Object { $_.subscriptionId -eq $subId })
        $md.Add("### Subscription: ``$subId``")
        $md.Add("")

        foreach ($serverName in ($subRules | Select-Object -ExpandProperty serverName -Unique | Sort-Object)) {
            $serverRules = @($subRules | Where-Object { $_.serverName -eq $serverName })
            $rg       = $serverRules[0].resourceGroup
            $location = $serverRules[0].location

            $md.Add("#### $serverName")
            $md.Add("")
            $md.Add("| | |")
            $md.Add("|---|---|")
            $md.Add("| **Resource Group** | $rg |")
            $md.Add("| **Location** | $location |")
            $md.Add("| **Rules** | $($serverRules.Count) |")
            $md.Add("")
            $md.Add("| Rule Name | Start IP | End IP |")
            $md.Add("|---|---|---|")

            foreach ($rule in ($serverRules | Sort-Object ruleName)) {
                $md.Add("| $($rule.ruleName) | $($rule.startIpAddress) | $($rule.endIpAddress) |")
            }

            $md.Add("")
        }

        $md.Add("---")
        $md.Add("")
    }

    # ── Write report ─────────────────────────────────────────────────────────────
    try {
        $md -join "`n" | Out-File -FilePath $reportPath -Encoding UTF8 -Force -ErrorAction Stop
    } catch {
        throw "Failed to write report to '$reportPath': $($_.Exception.Message)"
    }

    $elapsed = [math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
    Write-Host "Found $($firewallRules.Count) rule(s) across $($uniqueServers.Count) server(s)." -ForegroundColor Green
    Write-Host "Report written to: $reportPath" -ForegroundColor Green
    Write-Host "Total time        : $elapsed`s"

    return $firewallRules

} catch {
    Write-Error "An error occurred: $_"
    throw
}
