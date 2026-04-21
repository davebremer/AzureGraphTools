<#
.SYNOPSIS
    Returns Entra ID group memberships for a user (by UPN), including on-premises sync state.

.DESCRIPTION
    Uses Microsoft Graph PowerShell SDK cmdlets to retrieve Entra ID group memberships for a user identified by UPN.

    This version is optimized for performance at scale:
    - It uses the typed "AsGroup" cmdlets (Get-MgUserMemberOfAsGroup / Get-MgUserTransitiveMemberOfAsGroup)
      so the Graph SDK returns group objects directly.
    - This avoids the expensive per-object resolution pattern (Get-MgGroup for every directoryObject Id),
      which can cause extreme slowness and throttling when processing many users.

    By default, the function returns direct group memberships. If -Transitive is specified, it returns transitive
    (nested) group memberships.

    If there is no current Microsoft Graph connection, the function calls Connect-ToGraphRead (if available).

    By default, GroupDescription is sanitized to replace carriage returns and line feeds with a pipe character (|)
    to avoid Export-Csv producing multi-line fields that Excel may interpret as new rows.
    Use -NoCleanup to output the original raw Description text.

.PARAMETER UserPrincipalName
    The User Principal Name (UPN) of the user whose group memberships you want to retrieve.

.PARAMETER Transitive
    If specified, returns transitive (nested) group memberships in addition to direct memberships.

.PARAMETER PageSize
    Optional. Controls the page size used by the Graph SDK while paging through results.
    This can be helpful when troubleshooting throttling or very large result sets.
    If not specified, the Graph SDK default is used.

.PARAMETER NoCleanup
    If specified, GroupDescription is output exactly as returned by Microsoft Graph (raw).
    If not specified, GroupDescription is sanitized by replacing CR/LF/newlines with the '|' character.

.EXAMPLE
    Get-EntraUserGroupMembership -UserPrincipalName 'jane.doe@contoso.com'
    Returns direct Entra ID group memberships (groups only) for the specified user, including whether each group is synced from on-premises AD.

.EXAMPLE
    Get-EntraUserGroupMembership -UserPrincipalName 'jane.doe@contoso.com' -Transitive
    Returns both direct and nested (transitive) group memberships (groups only) for the specified user, including whether each group is synced from on-premises AD.

.EXAMPLE
    'jane.doe@contoso.com','john.smith@contoso.com' | Get-EntraUserGroupMembership -PageSize 999
    Returns group memberships for multiple users by piping UPN strings into the function, using a larger page size to reduce the number of Graph round-trips.

.EXAMPLE
    Get-EntraUserGroupMembership -UserPrincipalName 'jane.doe@contoso.com' -NoCleanup | Export-Csv .\groups.csv -NoTypeInformation
    Exports raw group descriptions (including any embedded newlines). This may cause Excel to misinterpret rows if descriptions contain CR/LF.

.EXAMPLE
    $F1users | Get-EntraUserGroupMembership -PageSize 200
    If there are a large number being processed, lower the page size. Definitly if doing thousands.

.LINK
    https://learn.microsoft.com/en-us/powershell/module/microsoft.graph.users/get-mgusermemberofasgroup

.LINK
    https://learn.microsoft.com/en-us/powershell/module/microsoft.graph.users/get-mgusertransitivememberofasgroup

.NOTES
    Requires Microsoft Graph PowerShell SDK (Microsoft.Graph.* modules).

    This function uses:
    - Get-MgUserMemberOfAsGroup or Get-MgUserTransitiveMemberOfAsGroup (Microsoft.Graph.Users)

    Author: Dave Bremer heavily using copilot - created 2026-04-21
#>
function Get-EntraUserGroupMembership {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('UPN', 'UserId', 'Identity')]
        [ValidateNotNullOrEmpty()]
        [string]$UserPrincipalName,

        [Parameter()]
        [switch]$Transitive,

        [Parameter()]
        [ValidateRange(1, 999)]
        [int]$PageSize,

        [Parameter()]
        [switch]$NoCleanup
    )

    BEGIN {
        try {
            $ctx = Get-MgContext -ErrorAction Stop
        }
        catch {
            $ctx = $null
        }

        if (-not $ctx -or -not $ctx.Account) {
            Write-Verbose "No active Microsoft Graph connection detected. Attempting to call Connect-ToGraphRead."
            if (Get-Command -Name 'Connect-ToGraphRead' -ErrorAction SilentlyContinue) {
                Connect-ToGraphRead
            }
            else {
                Write-Debug "Connect-ToGraphRead was not found in the current session. Proceeding and relying on existing auth (if any)."
            }
        }
        else {
            Write-Verbose ("Using existing Microsoft Graph connection (Account: {0}, Tenant: {1})" -f $ctx.Account, $ctx.TenantId)
        }

        $GroupPropertyList = @(
            'Id'
            'DisplayName'
            'Description'
            'Mail'
            'MailEnabled'
            'SecurityEnabled'
            'GroupTypes'
            'OnPremisesSyncEnabled'
        )
    }

    PROCESS {
        Write-Verbose ("Retrieving group memberships for {0} (Transitive={1})." -f $UserPrincipalName, [bool]$Transitive)

        $membershipType = 'Direct'
        if ($Transitive) {
            $membershipType = 'Transitive'
        }

        $commonParams = @{
            UserId      = $UserPrincipalName
            All         = $true
            Property    = $GroupPropertyList
            ErrorAction = 'Stop'
        }

        if ($PSBoundParameters.ContainsKey('PageSize')) {
            $commonParams.PageSize = $PageSize
            Write-Debug ("Using PageSize={0} for Graph paging." -f $PageSize)
        }
        else {
            Write-Debug "Using Graph SDK default PageSize for paging."
        }

        try {
            if ($Transitive) {
                $groups = Get-MgUserTransitiveMemberOfAsGroup @commonParams
            }
            else {
                $groups = Get-MgUserMemberOfAsGroup @commonParams
            }
        }
        catch {
            $msg = "Failed to retrieve group memberships for '$UserPrincipalName' (Transitive=$([bool]$Transitive)). $($_.Exception.Message)"
            Write-Error -Message $msg
            return
        }

        foreach ($grp in $groups) {
            $groupTypesText = $null
            if ($null -ne $grp.GroupTypes -and $grp.GroupTypes.Count -gt 0) {
                $groupTypesText = ($grp.GroupTypes -join ',')
            }

            $descriptionOut = $grp.Description
            if (-not $NoCleanup -and -not [string]::IsNullOrEmpty($descriptionOut)) {
                # Replace any CR/LF/newline variants with a pipe to keep CSV one-record-per-line friendly (especially for Excel).
                $descriptionOut = ($descriptionOut -replace "(\r\n|\r|\n)", "|")
            }

            [pscustomobject]@{
                UserPrincipalName     = $UserPrincipalName
                MembershipType        = $membershipType
                GroupId               = $grp.Id
                GroupDisplayName      = $grp.DisplayName
                GroupDescription      = $descriptionOut
                Mail                  = $grp.Mail
                MailEnabled           = [bool]$grp.MailEnabled
                SecurityEnabled       = [bool]$grp.SecurityEnabled
                GroupTypes            = $groupTypesText
                OnPremisesSyncEnabled = $grp.OnPremisesSyncEnabled
            }
        }
    }

    END {
    }
}
