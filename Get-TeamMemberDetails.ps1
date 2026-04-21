function Get-TeamMemberDetails {
    <#
    .SYNOPSIS
        Returns the members (and optionally owners) of a Microsoft Teams team by team name.

    .DESCRIPTION
        This function locates the Microsoft 365 Group that backs a Microsoft Teams team (by displayName),
        then retrieves members and (optionally) owners using the Microsoft Graph PowerShell SDK.

        It outputs objects only (module-friendly). If you want a CSV, pipe the output to Export-Csv.

    .PARAMETER TeamName
        The display name of the Team (and its backing Microsoft 365 Group). This parameter is mandatory.
        This parameter accepts pipeline input and pipeline input by property name.

    .PARAMETER IncludeOwners
        If specified, owners are included in the output with Role = 'Owner'. If not specified, only
        members are returned.

    .PARAMETER ExactMatchOnly
        If specified, the function requires an exact displayName match. If not specified, it will attempt
        an exact match first, then fall back to a search-based match if needed.

    .EXAMPLE
        Get-TeamMemberDetails -TeamName 'IAM Community of Practice'
        This returns member details for the backing group of the Team and outputs objects to the pipeline.

    .EXAMPLE
        'IAM Community of Practice','Another Team' | Get-TeamMemberDetails -IncludeOwners
        This pipes multiple team names into the function and returns members and owners for each team.

    .EXAMPLE
        Get-MgGroup -Filter "startsWith(displayName,'IAM')" | Select-Object -ExpandProperty DisplayName | Get-TeamMemberDetails
        This pipes group display names into the function, which then resolves each backing group and returns membership details.

    .NOTES
        Author: Dave Bremer heavily using copilot - created 13 April 2026
        Requires: Microsoft.Graph PowerShell SDK
        Required scopes: Group.Read.All
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCustomObject])]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('Name', 'DisplayName', 'Team')]
        [ValidateNotNullOrEmpty()]
        [string]$TeamName,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeOwners,

        [Parameter(Mandatory = $false)]
        [switch]$ExactMatchOnly
    )

    BEGIN {
        Write-Verbose "Preparing to retrieve Team membership (pipeline enabled)."

        # Ensure we have a Graph connection context with appropriate scopes.
        # If not, call Connect-ToGraphRead (assumed to be available in the module/session).
        $RequiredScopes = @('Group.Read.All')

        $Context = Get-MgContext
        if (-not $Context -or -not $Context.Account) {
            Write-Verbose "No Microsoft Graph context found. Calling Connect-ToGraphRead."
            Connect-ToGraphRead
            $Context = Get-MgContext
        }

        $MissingScopes = @()
        foreach ($Scope in $RequiredScopes) {
            if (-not $Context.Scopes -or ($Context.Scopes -notcontains $Scope)) {
                $MissingScopes += $Scope
            }
        }

        if ($MissingScopes.Count -gt 0) {
            Write-Verbose ("Microsoft Graph context missing required scopes: {0}. Calling Connect-ToGraphRead." -f ($MissingScopes -join ', '))
            Connect-ToGraphRead
            $Context = Get-MgContext
        }

        function Resolve-ODataQuotedString {
            <#
            .SYNOPSIS
                Escapes a string for use inside single-quoted OData filter literals.

            .DESCRIPTION
                OData filter strings are enclosed in single quotes. Any embedded single quote must be doubled.

            .PARAMETER Value
                The string to escape.

            .EXAMPLE
                Resolve-ODataQuotedString -Value ""Dave's Team""
                This returns: Dave''s Team

            
            #>
            [CmdletBinding()]
            [OutputType([string])]
            param (
                [Parameter(Mandatory = $true)]
                [string]$Value
            )

            PROCESS {
                $Value.Replace("'", "''")
            }

            END { }
        }
    }

    PROCESS {
        Write-Verbose "Retrieving Team membership for TeamName '$TeamName'."

        $EscapedTeamName = Resolve-ODataQuotedString -Value $TeamName

        Write-Verbose "Locating backing Microsoft 365 Group for Team '$TeamName' (exact match attempt)."
        Write-Debug "OData filter value (escaped): $EscapedTeamName"

        $Group = Get-MgGroup -Filter "displayName eq '$EscapedTeamName'" -ConsistencyLevel eventual -CountVariable GroupCount -ErrorAction SilentlyContinue

        if (-not $Group -and -not $ExactMatchOnly) {
            Write-Verbose "Exact match not found. Attempting search-based lookup for '$TeamName'."

            $Group = Get-MgGroup -Search """$TeamName""" -ConsistencyLevel eventual -All -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq $TeamName } |
                Select-Object -First 1
        }

        if (-not $Group) {
            Write-Error "No Microsoft 365 Group found matching TeamName '$TeamName'."
            return
        }

        if ($Group -is [System.Array] -and $Group.Count -gt 1) {
            Write-Error "More than one group matched displayName '$TeamName'. Please disambiguate the name or adjust lookup logic."
            return
        }

        $GroupId = $Group.Id
        Write-Verbose "Resolved GroupId '$GroupId' for Team '$TeamName'."

        $Output = New-Object System.Collections.Generic.List[object]

        # Members
        Write-Verbose "Retrieving members for GroupId '$GroupId'."
        $Members = @()

        try {
            $Members = Get-MgGroupMemberAsUser -GroupId $GroupId -All -ErrorAction Stop
        }
        catch {
            Write-Verbose "Get-MgGroupMemberAsUser failed. Falling back to Get-MgGroupMember and resolving users."
            Write-Debug $_.Exception.Message

            $DirectoryObjects = Get-MgGroupMember -GroupId $GroupId -All -ErrorAction Stop
            foreach ($Object in $DirectoryObjects) {
                if ($Object.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.user') {
                    $UserId = $Object.Id
                    $User = Get-MgUser -UserId $UserId -Property Id,DisplayName,UserPrincipalName,Mail,AccountEnabled -ErrorAction SilentlyContinue
                    if ($User) {
                        $Members += $User
                    }
                }
            }
        }

        foreach ($Member in $Members) {
            $Output.Add([PSCustomObject]@{
                TeamName          = $TeamName
                GroupId           = $GroupId
                Role              = 'Member'
                DisplayName       = $Member.DisplayName
                UserPrincipalName = $Member.UserPrincipalName
                Mail              = $Member.Mail
                AccountEnabled    = $Member.AccountEnabled
                Id                = $Member.Id
            })
        }

        # Owners (optional)
        if ($IncludeOwners) {
            Write-Verbose "Retrieving owners for GroupId '$GroupId'."
            $Owners = @()

            try {
                $Owners = Get-MgGroupOwnerAsUser -GroupId $GroupId -All -ErrorAction Stop
            }
            catch {
                Write-Verbose "Get-MgGroupOwnerAsUser failed. Falling back to Get-MgGroupOwner and resolving users."
                Write-Debug $_.Exception.Message

                $DirectoryOwners = Get-MgGroupOwner -GroupId $GroupId -All -ErrorAction Stop
                foreach ($Object in $DirectoryOwners) {
                    if ($Object.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.user') {
                        $UserId = $Object.Id
                        $User = Get-MgUser -UserId $UserId -Property Id,DisplayName,UserPrincipalName,Mail,AccountEnabled -ErrorAction SilentlyContinue
                        if ($User) {
                            $Owners += $User
                        }
                    }
                }
            }

            foreach ($Owner in $Owners) {
                $Output.Add([PSCustomObject]@{
                    TeamName          = $TeamName
                    GroupId           = $GroupId
                    Role              = 'Owner'
                    DisplayName       = $Owner.DisplayName
                    UserPrincipalName = $Owner.UserPrincipalName
                    Mail              = $Owner.Mail
                    AccountEnabled    = $Owner.AccountEnabled
                    Id                = $Owner.Id
                })
            }
        }

        # De-duplicate by Id (prefer Owner record when duplicates exist)
        $DeDuplicated =
            $Output |
            Group-Object -Property Id |
            ForEach-Object {
                $Grouped = $_.Group
                $OwnerRecord = $Grouped | Where-Object { $_.Role -eq 'Owner' } | Select-Object -First 1
                if ($OwnerRecord) {
                    $OwnerRecord
                }
                else {
                    $Grouped | Select-Object -First 1
                }
            }

        $DeDuplicated | Sort-Object -Property Role, DisplayName
    }

    END {
        Write-Verbose "Completed Team membership retrieval."
    }
}
