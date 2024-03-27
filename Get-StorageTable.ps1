Install-Module Az.Storage
Install-Module AzTable

$subName = "TestSUB"
$rgName = "TestRG"
$saName = "TestSA"
$tableName = "TestTable"

#Connect-AzAccount

Select-AzAccount -Subscription $subName

$sa = Get-AzStorageAccount -ResourceGroupName $rgName -Name $saName
$ctx = $sa.Context

$table = Get-AzStorageTable -Name $tableName -Context $ctx
$rows = Get-AzTableRow -Table $table.CloudTable

$rows