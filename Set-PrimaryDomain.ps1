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

param(
    [Parameter(Mandatory=$true)]
    [string]$Subscription,

    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory=$true)]
    [string]$PrimaryDomain
)

# Set the Azure subscription context
Set-AzContext -Subscription $Subscription

# Get all VMs in the specified resource group
$vms = Get-AzVM -ResourceGroupName $ResourceGroupName

foreach ($vm in $vms) {
    # Check if the VM is running Windows OS
    if ($vm.StorageProfile.OsDisk.OsType -eq "Windows") {
        Write-Host "Issuing Run Command on Windows VM: $($vm.Name)"

        $script = @"
        reg.exe add HKLM\SYSTEM\CurrentControlSet\services\Tcpip\Parameters /v 'Domain' /t REG_SZ /d '$($PrimaryDomain)' /f
"@

        try {
            Invoke-AzVMRunCommand `
                -ResourceGroupName $ResourceGroupName `
                -VMName $vm.Name `
                -CommandId 'RunPowerShellScript' `
                -ScriptString $script
            
            Write-Host "Successfully updated primary domain on VM: $($vm.Name)" -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to update primary domain on VM: $($vm.Name). Error: $($_.Exception.Message)"
        }
    }
    else {
        Write-Host "Skipping non-Windows VM: $($vm.Name) (OS Type: $($vm.StorageProfile.OsDisk.OsType))" -ForegroundColor Yellow
    }
}