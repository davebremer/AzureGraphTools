<#
    .SYNOPSIS
    Create a delegated read only connection to mgGraph
.DESCRIPTION
    Create a delegated read only connection to mgGraph

.EXAMPLE
    Connect-toGraphRead
    Connects to the tenancy and prompts for authorisation including mfa via security key. Makes a connection with the permissions:
    User.Read.All, Directory.Read.All, Group.Read.All

.NOTES
    Requires:   PowerShell 7+, Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement
    Permissions: User.Read.All, Directory.Read.All, Group.Read.All (delegated or application)

    Author:
        Nicked from Ian Bartram
        Dave Bremer changed to Module 3/3/26
#>
function Connect-ToGraphRead {
    [cmdletBinding()]
    param()
    
    $requiredScopes = @('User.Read.All', 'Directory.Read.All', 'Group.Read.All')

    $context = Get-MgContext
    if ($null -eq $context) {
        Write-Verbose 'Connecting to Microsoft Graph...' 
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome
        $context = Get-MgContext
    }

    # Check scopes
    $missingScopes = $requiredScopes | Where-Object { $_ -notin $context.Scopes }
    if ($missingScopes) {
        Write-warning 'Current session is missing required scopes. Reconnecting...' 
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome
    }

    Write-Verbose "Connected as: $($context.Account)" 
}

# Connect-ToGraphRead -Verbose
# $mgcontext = get-mgcontext
# disconnect-mggraph
