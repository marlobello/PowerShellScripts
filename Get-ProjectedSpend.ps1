[CmdletBinding()]
param (
    [Parameter()]
    [int]
    $CurrentSpend,
    [Parameter()]
    [float]
    $CurrentDay = (Get-Date).Day
)

$daysInMonth = [System.DateTime]::DaysInMonth((Get-Date).Year, (Get-Date).Month)

$projectedSpend = $CurrentSpend / $CurrentDay * $daysInMonth

$projectedSpend = [math]::Round($projectedSpend, 2)

$projectedSpend