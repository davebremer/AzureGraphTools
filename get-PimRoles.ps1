<#
.SYNOPSIS
    Returns PIM-activatable Entra roles (and optionally PIM-for-Groups) for the current Graph context.

.DESCRIPTION
    Enumerates Privileged Identity Management (PIM) assignments that the identity associated
    with the current Microsoft Graph context (Get-MgContext) is eligible to activate.

    By default, this function returns:
        - Microsoft Entra ID (directory) roles

    Optionally, it can also return:
        - PIM-for-Groups eligible memberships and ownerships

    All data is retrieved exclusively via Microsoft Graph.
    Azure RBAC / Azure resource PIM roles are intentionally excluded.

    If there is no active Microsoft Graph connection, the function throws a terminating error
    with a clear, actionable message.

.PARAMETER IncludeGroups
    Include PIM-for-Groups eligible memberships and ownerships.

.PARAMETER PageSize
    Page size used for Graph paging. This does not limit total results; it controls
    how many objects are retrieved per request.

.EXAMPLE
    Get-PimRoles

    Returns the Microsoft Entra ID roles that the currently connected identity
    is eligible to activate via Privileged Identity Management.

.EXAMPLE
    Get-PimRoles -IncludeGroups

    Returns Microsoft Entra ID roles and additionally includes any
    PIM-for-Groups eligible memberships or ownerships.

.NOTES
    Author: Dave Bremer (with heavy Copilot coaching and drafting)

    Output schema intentionally normalised for pipeline use:
        - DisplayName
        - UserPrincipalName
        - PrincipalDisplayName
        - PrincipalId
        - Identity
#>
function Get-PimRoles {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [switch] $IncludeGroups,

        [Parameter()]
        [ValidateRange(10, 999)]
        [int] $PageSize = 200
    )

    BEGIN {
        Write-Verbose "Initialising PIM role discovery using current Microsoft Graph context."

        $ctx = Get-MgContext
        if (-not $ctx) {
            throw "No active Microsoft Graph connection found. Run Connect-MgGraph with appropriate scopes and retry."
        }

        Write-Debug ("Graph context detected. TenantId={0}, Account={1}, AuthType={2}" -f `
            $ctx.TenantId, $ctx.Account, $ctx.AuthType)

        $UserPrincipalName    = $ctx.Account
        $PrincipalId          = $null
        $PrincipalDisplayName = $UserPrincipalName

        if ($UserPrincipalName) {
            try {
                Write-Verbose "Resolving Graph principal details for $UserPrincipalName"
                $user = Get-MgUser -UserId $UserPrincipalName -Property Id,DisplayName,UserPrincipalName
                $PrincipalId          = $user.Id
                $PrincipalDisplayName = $user.DisplayName
            }
            catch {
                Write-Verbose "Unable to resolve principal details from Graph. Continuing with calling-principal context."
                Write-Debug $_
            }
        }

        function Invoke-PagedGraph {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [scriptblock] $Invoker,

                [Parameter()]
                [int] $Top = 200
            )

            $skip = 0
            do {
                Write-Debug "Requesting Graph page: Top=$Top Skip=$skip"
                $page = & $Invoker $Top $skip
                foreach ($item in @($page)) {
                    $item
                }
                $returned = @($page).Count
                $skip += $Top
            }
            while ($returned -ge $Top)
        }
    }

    PROCESS {

        # ------------------------------------------------------------
        # Microsoft Entra ID Roles (default)
        # ------------------------------------------------------------
        Write-Verbose "Querying PIM-eligible Microsoft Entra ID roles."

        try {
            Invoke-PagedGraph -Top $PageSize -Invoker {
                param($Top, $Skip)
                Invoke-MgFilterRoleManagementDirectoryRoleEligibilityScheduleInstanceByCurrentUser `
                    -On 'principal' `
                    -Top $Top `
                    -Skip $Skip `
                    -ExpandProperty roleDefinition
            } | ForEach-Object {
                Write-Debug ("Found Entra role eligibility: RoleDefinitionId={0}" -f $_.RoleDefinitionId)

                [pscustomobject]@{
                    Category               = 'MicrosoftEntraRoles'
                    DisplayName            = $_.RoleDefinition.DisplayName
                    RoleDefinitionId       = $_.RoleDefinitionId
                    DirectoryScopeId       = $_.DirectoryScopeId
                    MemberType             = $_.MemberType

                    UserPrincipalName      = $UserPrincipalName
                    PrincipalDisplayName   = $PrincipalDisplayName
                    PrincipalId            = $_.PrincipalId
                    Identity               = $UserPrincipalName

                    Source                 = 'Graph:DirectoryRoleEligibility'
                    Raw                    = $_
                }
            }
        }
        catch {
            Write-Verbose "Failed to retrieve Entra role eligibilities."
            Write-Debug $_
        }

        # ------------------------------------------------------------
        # PIM for Groups (optional)
        # ------------------------------------------------------------
        if ($IncludeGroups) {
            Write-Verbose "Querying PIM-for-Groups eligible memberships."

            try {
                Invoke-PagedGraph -Top $PageSize -Invoker {
                    param($Top, $Skip)
                    Invoke-MgFilterIdentityGovernancePrivilegedAccessGroupEligibilityScheduleInstanceByCurrentUser `
                        -On 'principal' `
                        -Top $Top `
                        -Skip $Skip `
                        -ExpandProperty group
                } | ForEach-Object {
                    Write-Debug ("Found group eligibility: GroupId={0}, AccessId={1}" -f $_.GroupId, $_.AccessId)

                    [pscustomobject]@{
                        Category               = 'Groups'
                        DisplayName            = $_.Group.DisplayName
                        GroupId                = $_.GroupId
                        AccessId               = $_.AccessId

                        UserPrincipalName      = $UserPrincipalName
                        PrincipalDisplayName   = $PrincipalDisplayName
                        PrincipalId            = $_.PrincipalId
                        Identity               = $UserPrincipalName

                        Source                 = 'Graph:PIMForGroups'
                        Raw                    = $_
                    }
                }
            }
            catch {
                Write-Verbose "Failed to retrieve PIM-for-Groups eligibilities."
                Write-Debug $_
            }
        }
    }

    END {
        Write-Verbose "PIM role discovery completed."
    }
}
