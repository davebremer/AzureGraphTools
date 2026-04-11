<#
.SYNOPSIS
    Get a list of all Entra licenses that a user is assigned along with how the license was assigned.

.DESCRIPTION
    Get a list of all Entra licenses that a user is assigned along with how the license was assigned.

    Note: when using export-csv make sure to encode as utf8BOM otherwise any n-dash (ie "-") is rendered in ansi and appears as "â€“" when opening in Excel

    The fields returned are:
    UserID          : UPN of the user
    DisplayName     : Display name of the user
    AccountEnabled  : True/False - is the account enabled
    AssignedLicense : "Friendly" name of the license
    Assignment      : The name of the group that was used to assign the license, or "Direct"

.EXAMPLE
    get-userlicenses -userid "bilbo.baggins@silverfernfarms.co.nz"

    The licenses assigned to Bilbo Baggins will be returned along with the assignment method
    

.EXAMPLE
    get-aduser -filter "name -like '*smith*'" -Properties UserPrincipalName | select @{Name='UserID'; Expression={ $_.UserPrincipalName }} | get-userlicenses
        ok - this sucks. I've got aliases for UserPrincipalName but it doesn't seem to stick. So have to rename it to meet the parameter when passing through the pipeline

        BUT it does when piping from a get-mguser type - see next example

.EXAMPLE
    Get-LicenseAssignments "Microsoft 365 F3" | get-userlicenses | export-csv "myoutput.csv" -Encoding -Encoding utf8BOM

    this works quite happily. NotProperty as opposed to Note type passed from get-aduser

.NOTES
    Requires:   PowerShell 7+, Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement
    Permissions: User.Read.All, Directory.Read.All, Group.Read.All (delegated or application)

    AUTHOR:
    Dave Bremer updates
#>

function Get-userLicenses {
    [cmdletBinding()]
   
    param(
            [Parameter(
                Mandatory,
                ValueFromPipelineByPropertyName
            )]
            [Alias('UserPrincipalName')]
            [string]$UserIdget
        )


BEGIN{
     # get a connection if we don't have the rights
    $required = @('User.Read.All', 'Directory.Read.All', 'Group.Read.All')
    $granted  = Get-MgContext | Select-Object -ExpandProperty Scopes
    $missing  = $required | Where-Object { $_ -notin $granted }
    if ($missing) {
        Write-Verbose ("Missing the following: {0}`nso connecting with: {1}" -f ($missing -join ', '),($required -join ', '))
        Connect-ToGraphRead
    }

    # build the friendlyname hashtable
    $fn = Get-FriendlyLicenseNames
}

PROCESS{
    
    # Resolve the user object
    $user = Get-MgUser -UserId $UserID -Property Id,DisplayName,accountenabled,LicenseAssignmentStates,UserPrincipalName

    if (-not $user) {
        throw "User not found: $UserID"
    }

    #process each license in the LicenseAssignmentStates    
    foreach ($l in $user.LicenseAssignmentStates) {
        
        #get the "friendly" license name of each skuid
        $licname = $fn[$l.skuid]
    
        $assignedBy = "Direct" # set the assignedby to Direct - over-write if theres a group used
        if ($l.assignedbygroup -ne $null){
            $assignedBy = (Get-MgGroup -GroupId $l.assignedbygroup | Select-Object DisplayName).displayname
        } 

        # output to the pipeline as a custom object
        [PSCustomObject]@{
            UserID            = $user.UserPrincipalName
            DisplayName       = $user.DisplayName
            AccountEnabled    = $user.AccountEnabled
            AssignedLicense   = $licname
            Assignment        = $assignedBy
        }
    }
}

END{}
}

#Get-userLicenses "dave.bremer@silverfernfarms.co.nz"
# get-aduser -filter "name -like '*smith*'" -Properties UserPrincipalName | select @{Name='UserID'; Expression={ $_.UserPrincipalName }} | get-userlicenses
