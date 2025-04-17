[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]
    $ExcelFilePath
)

# Load the Excel COM object
$excel = New-Object -ComObject Excel.Application

# Open the Excel file
$workbook = $excel.Workbooks.Open($ExcelFilePath)
$sheet = $workbook.Sheets.Item(1)

# Get the used range of the sheet
$usedRange = $sheet.UsedRange

# Iterate over each row in the used range
for ($row = 1; $row -le $usedRange.Rows.Count; $row++) {
    $role = $usedRange.Cells.Item($row, 7).Text
    $name = $usedRange.Cells.Item($row, 8).Text
    $color = $usedRange.Cells.Item($row, 9).Text
    $power = $usedRange.Cells.Item($row, 10).Text
    $enemy = $usedRange.Cells.Item($row, 11).Text


    Write-Host "A comic book style picture of a super $role named $name whose color scheme includes $color . They use their super power of $power fight against their arch enemy named $enemy"

}

