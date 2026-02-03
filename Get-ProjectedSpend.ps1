<#
.SYNOPSIS
    Calculates projected monthly spend based on current spend and day of month.

.DESCRIPTION
    This script calculates the projected spend for the entire month based on the current
    spend amount and the current day of the month. It assumes linear spending throughout the month.

.PARAMETER CurrentSpend
    The current spend amount. Must be a positive number.

.PARAMETER CurrentDay
    The current day of the month to calculate from. Defaults to today's date.
    Must be between 1 and the number of days in the current month.

.EXAMPLE
    .\Get-ProjectedSpend.ps1 -CurrentSpend 1500
    Calculates projected spend for the month based on $1500 spent so far today.

.EXAMPLE
    .\Get-ProjectedSpend.ps1 -CurrentSpend 3000 -CurrentDay 15
    Calculates projected spend assuming $3000 has been spent by day 15.

.OUTPUTS
    [double] The projected spend for the entire month, rounded to 2 decimal places.

.NOTES
    Assumes linear spending rate throughout the month.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "The current spend amount")]
    [ValidateRange(0, [double]::MaxValue)]
    [double]$CurrentSpend,
    
    [Parameter(HelpMessage = "The current day of the month (defaults to today)")]
    [ValidateRange(1, 31)]
    [double]$CurrentDay = (Get-Date).Day
)

$today = Get-Date
$daysInMonth = [System.DateTime]::DaysInMonth($today.Year, $today.Month)

if ($CurrentDay -gt $daysInMonth) {
    Write-Error "CurrentDay ($CurrentDay) cannot be greater than the number of days in the current month ($daysInMonth)"
    return
}

if ($CurrentDay -eq 0) {
    Write-Error "CurrentDay cannot be 0"
    return
}

$projectedSpend = ($CurrentSpend / $CurrentDay) * $daysInMonth
$projectedSpend = [math]::Round($projectedSpend, 2)

Write-Verbose "Current spend: $CurrentSpend"
Write-Verbose "Current day: $CurrentDay of $daysInMonth"
Write-Verbose "Daily average: $([math]::Round($CurrentSpend / $CurrentDay, 2))"
Write-Verbose "Projected monthly spend: $projectedSpend"

$projectedSpend