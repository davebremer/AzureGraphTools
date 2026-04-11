
<#
    .SYNOPSIS
        Returns a MicrosoftGraphUser object of the currently logged in user calling the script
    .DESCRIPTION
        Returns a MicrosoftGraphUser object of the currently logged in user calling the script - returned from get-mguser

    .EXAMPLE
        Get-CurrentEntraIdentity

        DisplayName      Id                                   Mail                                      UserPrincipalName 
        -----------      --                                   ----                                      -----------------
        Bilbo Baggins    fe5ad870-4f44-4314-9626-19df4e6c122a bilbo.baggins@example.com                 bilbo.baggins@example.com

    .NOTES
        Author:
            Dave Bremer 17/3/26    

#>
function Get-CurrentEntraIdentity {
    [CmdletBinding()]
    param()

    ### https://learn.microsoft.com/graph/api/overview?view=graph-rest-1.0
    $me = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/me'
    get-mguser -userid $me.userprincipalname
    
}

# Get-CurrentEntraIdentity