[CmdletBinding()]
param (
    [Parameter()]
    [int]
    $CurrentSpend,
    [Parameter()]
    [int]
    $DaysDelayed = 3
)

$daysInMonth = [System.DateTime]::DaysInMonth((Get-Date).Year, (Get-Date).Month)
$currentDay = (Get-Date).Day - $DaysDelayed

$projectedSpend = $CurrentSpend / $currentDay * $daysInMonth

$projectedSpend = [math]::Round($projectedSpend, 2)

$projectedSpend