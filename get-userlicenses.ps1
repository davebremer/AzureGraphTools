<#
.SYNOPSIS
    Returns the Entra ID licences assigned to a user and indicates whether each
    was assigned directly or via group-based licensing.

.DESCRIPTION
    Queries Microsoft Graph for the user’s LicenseAssignmentStates and outputs
    one row per assigned SKU.

    For each SKU, Assignment is reported as:
    - Direct (AssignedByGroup is null), or
    - The display name of the group that assigned the licence
      (AssignedByGroup contains a group id).

    This function relies on helper functions to connect to Graph (read scopes)
    and to translate SKU IDs to friendly licence names.

.PARAMETER UserId
    The user principal name (UPN) of the target user
    (for example: bilbo.baggins@silverfernfarms.co.nz).

    Accepts pipeline input by property name. If the incoming object has
    UserId, UserPrincipalName, or UPN, it can be piped to this function.

.INPUTS
    System.String. You can pipe objects that contain a UserId,
    UserPrincipalName, or UPN property.

.OUTPUTS
    System.Management.Automation.PSCustomObject.
    Outputs objects with:
    UserId, DisplayName, AccountEnabled, AssignedLicense, Assignment.

.EXAMPLE
    Get-UserLicenses -UserId "bilbo.baggins@silverfernfarms.co.nz"

.EXAMPLE
    Get-UserLicenses -UserId "bilbo.baggins@silverfernfarms.co.nz" -DirectOnly

    Returns only licences that are assigned directly to the user
    (excludes group-based licence assignments).

.EXAMPLE
    Get-UserLicenses -UserId "bilbo.baggins@silverfernfarms.co.nz" -GroupOnly

    Returns only licences that are inherited via group-based licensing
    (excludes directly assigned licences).

.EXAMPLE
    Get-MgUser -Filter "startsWith(displayName,'Smith')" -Property UserPrincipalName |
        Get-UserLicenses -GroupOnly |
        Export-Csv ".\groupLicences.csv" -NoTypeInformation -Encoding utf8BOM

    Exports only group-based licence assignments for the selected users.

.EXAMPLE
    Get-MgUser -Filter "startsWith(displayName,'Smith')" -Property UserPrincipalName |
        Select-Object @{ Name = 'UserId'; Expression = { $_.UserPrincipalName } } |
        Get-UserLicenses

.EXAMPLE
    Get-LicenseAssignments "Microsoft 365 F3" -Verbose |
        Get-UserLicenses |
        Export-Csv ".\myoutput.csv" -NoTypeInformation -Encoding utf8BOM

.NOTES
    Requires: PowerShell 7+
              Microsoft.Graph.Users
              Microsoft.Graph.Groups
              Microsoft.Graph.Identity.DirectoryManagement

    Permissions: User.Read.All, Directory.Read.All, Group.Read.All
                 (delegated or application)

    Excel (Windows) may misinterpret UTF-8 CSV files without a BOM, causing
    characters such as an en dash (–) to display as mojibake (e.g. "â€“").
    If the CSV is intended for Excel, use Export-Csv -Encoding utf8BOM.

    Author: Dave Bremer
#>
function Get-UserLicenses {
    [CmdletBinding()]
    [OutputType([pscustomobject])]

    param(
        [Parameter(
            Mandatory,
            ValueFromPipeline,
            ValueFromPipelineByPropertyName
        )]
        [Alias('UserPrincipalName', 'UPN')]
        [string]$UserId,

        [switch]$DirectOnly,
        [switch]$GroupOnly
    )


    BEGIN {
        # Sanity check: filter switches are mutually exclusive
        if ($DirectOnly -and $GroupOnly) {
            throw "You cannot specify both -DirectOnly and -GroupOnly at the same time."
        }

        # Ensure we have a Graph connection with required read scopes
        $requiredScopes = @(
            'User.Read.All',
            'Directory.Read.All',
            'Group.Read.All'
        )

        $context = Get-MgContext
        $granted = @($context?.Scopes)

        $missing = $requiredScopes | Where-Object { $_ -notin $granted }
        if ($missing) {
            Write-Verbose (
                "Missing scopes: {0}. Connecting with required scopes..." -f
                ($missing -join ', ')
            )
            Connect-ToGraphRead
        }

        # Build lookup table: SKU GUID -> friendly licence name
        $friendlyNames = Get-FriendlyLicenseNames

        # Cache groupId -> DisplayName mappings so we only query Graph once per group.
        # This avoids repeated Get-MgGroup calls (N+1 query problem) and reduces
        # latency and throttling risk when users have multiple group-assigned licences.
        $groupCache = @{}

        # Normalise GUID values (string or [Guid]) to a canonical lowercase "D" format.
        # This ensures consistent hashtable lookups when Graph returns GUIDs in
        # different types or casing (e.g. [Guid] vs string).
        $NormalizeGuid = {
            param($Value)

            if (-not $Value) {
                return $null
            }

            try {
                ([Guid]$Value).ToString('D').ToLowerInvariant()
            }
            catch {
                $null
            }
        }
    }

    PROCESS {
        # Resolve the user and request only required properties
        $user = Get-MgUser `
            -UserId   $UserId `
            -Property Id,
                      DisplayName,
                      AccountEnabled,
                      LicenseAssignmentStates,
                      UserPrincipalName `
            -ErrorAction Stop

        foreach ($license in $user.LicenseAssignmentStates) {

            # Resolve friendly licence name from SKU ID
            $skuKey  = & $NormalizeGuid $license.SkuId
            $licName = $friendlyNames[$skuKey] ?? "(Unknown licence: $skuKey)"

            $assignedBy = 'Direct'

            if ($license.AssignedByGroup) {
                $groupId = $license.AssignedByGroup

                if (-not $groupCache.ContainsKey($groupId)) {
                    try {
                        $groupCache[$groupId] =
                            (Get-MgGroup `
                                -GroupId  $groupId `
                                -Property DisplayName `
                                -ErrorAction Stop
                            ).DisplayName
                    }
                    catch {
                        $groupCache[$groupId] = "(Group not found: $groupId)"
                    }
                }

                $assignedBy = $groupCache[$groupId]
            }

            # Apply assignment-type filters if requested
            if ($DirectOnly -and $assignedBy -ne 'Direct') {
                continue
            }

            if ($GroupOnly -and $assignedBy -eq 'Direct') {
                continue
            }

            [PSCustomObject]@{
                UserId          = $user.UserPrincipalName
                DisplayName     = $user.DisplayName
                AccountEnabled  = $user.AccountEnabled
                AssignedLicense = $licName
                Assignment      = $assignedBy
            }
        }

    }

    END {}
}