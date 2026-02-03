<#
.SYNOPSIS
    Generates superhero descriptions from an Excel file.

.DESCRIPTION
    This script reads an Excel file containing superhero data (role, name, color, power, enemy)
    and generates descriptive text suitable for creating comic book style images.

.PARAMETER ExcelFilePath
    Path to the Excel file containing superhero data.
    Expected columns: Column 7 (Role), 8 (Name), 9 (Color), 10 (Power), 11 (Enemy)

.PARAMETER OutputPath
    Optional. Path to export descriptions to a text file.

.EXAMPLE
    .\Create-SuperHero.ps1 -ExcelFilePath "C:\Data\Superheroes.xlsx"

.EXAMPLE
    .\Create-SuperHero.ps1 -ExcelFilePath "C:\Data\Superheroes.xlsx" -OutputPath "C:\Output\descriptions.txt"

.NOTES
    Requires Excel COM object to be available (Microsoft Excel must be installed).
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateScript({
        if (Test-Path $_ -PathType Leaf) {
            $true
        } else {
            throw "File '$_' does not exist."
        }
    })]
    [string]$ExcelFilePath,
    
    [Parameter()]
    [string]$OutputPath
)

$excel = $null
$workbook = $null

try {
    if (-not (Test-Path $ExcelFilePath)) {
        throw "Excel file not found: $ExcelFilePath"
    }
    
    Write-Host "Loading Excel file: $ExcelFilePath" -ForegroundColor Cyan
    
    # Load the Excel COM object
    $excel = New-Object -ComObject Excel.Application -ErrorAction Stop
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    
    # Open the Excel file
    $workbook = $excel.Workbooks.Open($ExcelFilePath)
    $sheet = $workbook.Sheets.Item(1)
    
    # Get the used range of the sheet
    $usedRange = $sheet.UsedRange
    
    $descriptions = [System.Collections.Generic.List[string]]::new()
    $count = 0
    
    # Iterate over each row in the used range (starting from 2 to skip headers)
    for ($row = 2; $row -le $usedRange.Rows.Count; $row++) {
        $role = $usedRange.Cells.Item($row, 7).Text
        $name = $usedRange.Cells.Item($row, 8).Text
        $color = $usedRange.Cells.Item($row, 9).Text
        $power = $usedRange.Cells.Item($row, 10).Text
        $enemy = $usedRange.Cells.Item($row, 11).Text
        
        # Skip empty rows
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }
        
        $description = "A comic book style picture of a super $role named $name whose color scheme includes $color. They use their super power of $power to fight against their arch enemy named $enemy"
        
        Write-Host $description -ForegroundColor Green
        $descriptions.Add($description)
        $count++
    }
    
    if ($OutputPath) {
        $descriptions | Out-File -FilePath $OutputPath -Encoding UTF8
        Write-Host "`nDescriptions exported to: $OutputPath" -ForegroundColor Cyan
    }
    
    Write-Host "`nProcessed $count superhero description(s)" -ForegroundColor Cyan
}
catch {
    Write-Error "An error occurred: $_"
    throw
}
finally {
    # Clean up COM objects
    if ($workbook) {
        $workbook.Close($false)
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($workbook) | Out-Null
    }
    
    if ($excel) {
        $excel.Quit()
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($excel) | Out-Null
    }
    
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}

