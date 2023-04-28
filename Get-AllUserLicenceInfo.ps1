#Connect to Azure AD
Connect-AzureAD

#Get all AAD Users
$users = Get-AzureADUser -All $true

$alluserlicenses = @()

foreach($user in $users)
{
    #Get all licences for each user
    $licences = Get-AzureADUserLicenseDetail -ObjectId $user.ObjectId

    #If the user has no licences, write the user to the console
    if($null -eq $licences)
    {
        Write-Output $user.DisplayName + " has no licences:"
    }

    #If the user has licences, write the user and the licences to the console
    else
    {
        Write-Output $user.DisplayName + " has the following licences:"

        foreach($licence in $licences)
        {
            Write-Output $licence.ServicePlanName
            $alluserlicenses += $licence.ServicePlanName
        }
    }
}

