<#
.SYNOPSIS
    Get-LicenseAssignments - For a given license, retrieves all assigned users and determines assignment method.

.DESCRIPTION
    Returns users assigned a given license name, including assignment method (Direct/Group) and group name when group-based.
    Uses smart resolution by default: a license name may resolve to multiple tenant SKUs (common with Frontline and Dynamics variants).

    Fast-path Graph queries are best-effort only; fallback is authoritative. Do not refactor fast-path without re-testing Dynamics + F1.

.PARAMETER Name
    Friendly license name (e.g. "Microsoft 365 F1", "Microsoft 365 F3", "Visio Plan 2").

.PARAMETER SkuId
    Optional. Provide a specific SkuId to bypass name resolution and family matching.

.PARAMETER StrictNameMatch
    Optional. Exact friendly-name matching only. No partial/contains matching and no SkuPartNumber heuristics.

.PARAMETER NoFamilyMatch
    Optional. Allows partial matching but requires the name to resolve to exactly one SKU.
    If multiple SKUs are resolved, the function throws and you should provide -SkuId.

.PARAMETER RefreshCache
    Optional. Clears the cached full user list used for fallback enumeration (useful in long-lived sessions after changes).

.PARAMETER NoCache
    Optional. Disables caching of the full user list (fetches all users fresh for this invocation).

.EXAMPLE
    Get-LicenseAssignments "Microsoft 365 F3"

    Returns all users assigned Microsoft 365 F3. Attempts fast-path Graph queries first.

.EXAMPLE
    Get-LicenseAssignments "Microsoft 365 F1"

    Returns all users assigned any Microsoft 365 F1 variant (smart mode default).

.EXAMPLE
    Get-LicenseAssignments "Visio Plan 2"

    Returns all users assigned Visio Plan 2, whether assigned directly or via group-based licensing.

.EXAMPLE
    Get-LicenseAssignments "Microsoft 365 F1" -StrictNameMatch

    Requires an exact friendly-name match. Throws if the tenant uses a different display name (e.g. "with Teams").

.EXAMPLE
    Get-LicenseAssignments "Microsoft 365 F1" -NoFamilyMatch

    Allows partial matching but requires the resolution to produce exactly one SKU.
    Throws if multiple SKUs are matched (common for Frontline/Dynamics families).

.EXAMPLE
    Get-LicenseAssignments "Microsoft 365 F1" -SkuId 44575883-256e-4a79-9da4-ebe9acabe2b2

    Bypasses smart matching and queries a specific SKU ID.

.EXAMPLE
    Get-LicenseAssignments "Microsoft 365 F1" -Verbose

    Shows resolution detail, SKU counts, and whether fast-path or fallback was used.

.EXAMPLE
    Get-LicenseAssignments "Microsoft 365 F1" -RefreshCache

    Clears the cached full user enumeration before running fallback logic.

.EXAMPLE
    Get-LicenseAssignments "Microsoft 365 F1" -NoCache

    Disables caching for this run; performs fresh full enumeration during fallback.

.EXAMPLE
    Get-LicenseAssignments "Microsoft 365 F1" |
        Export-Csv "F1_LicenseAssignments.csv" -NoTypeInformation

    Exports results to CSV.

.EXAMPLE
    Get-TenantLicenses | Where-Object Name -like "Dynamics 365*" | ForEach-Object {
        Get-LicenseAssignments -Name $_.Name -Verbose
    }

    Runs across many Dynamics licences. Fast-path is attempted only when safe; fallback handles complex families reliably.

.EXAMPLE

    "Microsoft 365 F1","Microsoft 365 F3","Visio Plan 2","Dynamics 365 Project Operations" | ForEach-Object {
        "{0,-35} {1,6}" -f $_, (Get-LicenseAssignments $_ | Measure-Object).Count
    }

    use this to validate the script still works after refactoring. Investigate any that go to 0


.NOTES
    Requires:
      PowerShell 7+
      Microsoft.Graph.Users
      Microsoft.Graph.Groups
      Microsoft.Graph.Identity.DirectoryManagement

    Permissions:
      User.Read.All
      Directory.Read.All
      Group.Read.All
#>

function Get-LicenseAssignments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter()]
        [guid]$SkuId = [guid]::Empty,

        [Parameter()]
        [switch]$StrictNameMatch,

        [Parameter()]
        [switch]$NoFamilyMatch,

        [Parameter()]
        [switch]$RefreshCache,

        [Parameter()]
        [switch]$NoCache
    )

    begin {
        # ---- ensure Graph permissions ----
        $required = @('User.Read.All', 'Directory.Read.All', 'Group.Read.All')
        $ctx = Get-MgContext
        $granted = @($ctx.Scopes)
        $missing = $required | Where-Object { $_ -notin $granted }
        if ($missing) {
            Write-Verbose ("Missing scopes: {0} — reconnecting" -f ($missing -join ', '))
            Connect-ToGraphRead
        }

        # ---- initialise caches (session scope) ----
        if (-not (Test-Path variable:script:__GLA_AllUsersCache)) { $script:__GLA_AllUsersCache = $null }
        if (-not (Test-Path variable:script:__GLA_TenantSkusCache)) { $script:__GLA_TenantSkusCache = $null }
        if (-not (Test-Path variable:script:__GLA_FriendlyMapCache)) { $script:__GLA_FriendlyMapCache = $null }
        if (-not (Test-Path variable:script:__GLA_SkuPartByIdCache)) { $script:__GLA_SkuPartByIdCache = $null }

        if ($RefreshCache) {
            Write-Verbose "RefreshCache set — clearing cached full user list"
            $script:__GLA_AllUsersCache = $null
        }

        # ---- load tenant SKUs and friendly map once per session ----
        if (-not $script:__GLA_TenantSkusCache) {
            Write-Verbose "Loading tenant subscribed SKUs (cached per session)"
            $script:__GLA_TenantSkusCache = Get-MgSubscribedSku -All | Select-Object SkuId, SkuPartNumber
        }

        if (-not $script:__GLA_SkuPartByIdCache) {
            $script:__GLA_SkuPartByIdCache = @{}
            foreach ($t in $script:__GLA_TenantSkusCache) {
                $script:__GLA_SkuPartByIdCache[[guid]$t.SkuId] = $t.SkuPartNumber
            }
        }

        if (-not $script:__GLA_FriendlyMapCache) {
            Write-Verbose "Loading friendly name map (cached per session)"
            $script:__GLA_FriendlyMapCache = Get-FriendlyLicenseNames  # GUID(string)->FriendlyName(string)
        }

        function Resolve-LicenseSkuIds {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [string]$LicenseName,

                [switch]$StrictNameMatch,
                [switch]$NoFamilyMatch
            )

            $tenantSkus = $script:__GLA_TenantSkusCache
            $friendly   = $script:__GLA_FriendlyMapCache

            # Build a HashSet of tenant skuIds for fast membership checks
            $tenantSkuIdSet = [System.Collections.Generic.HashSet[guid]]::new()
            foreach ($t in $tenantSkus) { [void]$tenantSkuIdSet.Add([guid]$t.SkuId) }

            $candidates = New-Object System.Collections.Generic.List[guid]

            # 1) Friendly-name match (preferred)
            foreach ($kv in $friendly.GetEnumerator()) {
                $gid = [guid]$kv.Key
                if (-not $tenantSkuIdSet.Contains($gid)) { continue }

                $fname = [string]$kv.Value

                if ($StrictNameMatch) {
                    if ($fname -ieq $LicenseName) { $candidates.Add($gid) }
                }
                else {
                    if ($fname -ieq $LicenseName -or $fname -like "*$LicenseName*") { $candidates.Add($gid) }
                }
            }

            if ($StrictNameMatch -and $candidates.Count -eq 0) {
                throw "StrictNameMatch: No exact friendly-name match for '$LicenseName'. Pass -SkuId or omit -StrictNameMatch."
            }

            # 2) Heuristic fallback: SkuPartNumber tokens (smart mode only)
            if (-not $StrictNameMatch -and $candidates.Count -eq 0) {
                $needle = ($LicenseName -replace '\s+', '_')
                $tokens = @($LicenseName -split '\s+' | Where-Object { $_.Length -ge 2 })

                foreach ($t in $tenantSkus) {
                    $part = [string]$t.SkuPartNumber

                    if ($part -match [regex]::Escape($needle)) {
                        $candidates.Add([guid]$t.SkuId)
                        continue
                    }

                    foreach ($tok in $tokens) {
                        if ($part -match [regex]::Escape($tok)) {
                            $candidates.Add([guid]$t.SkuId)
                            break
                        }
                    }
                }
            }

            $unique = @($candidates | Sort-Object -Unique)

            if (-not $unique -or $unique.Count -eq 0) {
                throw "Could not resolve any tenant SkuId(s) for '$LicenseName'. Pass -SkuId explicitly."
            }

            if ($NoFamilyMatch -and $unique.Count -gt 1) {
                $list = ($unique | ForEach-Object { $_.Guid }) -join ', '
                throw "NoFamilyMatch: '$LicenseName' resolved to multiple SKUs ($($unique.Count)). Pass -SkuId or use -StrictNameMatch. SKUs: $list"
            }

            Write-Verbose ("Resolved '{0}' to {1} tenant SkuId(s)" -f $LicenseName, $unique.Count)
            return ,$unique
        }

        # Determine which SKU IDs to match
        if ($SkuId -and $SkuId -ne [guid]::Empty) {
            $skuIds = @($SkuId)
        }
        else {
            $skuIds = Resolve-LicenseSkuIds -LicenseName $Name -StrictNameMatch:$StrictNameMatch -NoFamilyMatch:$NoFamilyMatch
        }

        $script:__GLA_TargetSkuIds = $skuIds
        Write-Debug ("Target SKUs for '{0}': {1}" -f $Name, (($skuIds | ForEach-Object { $_.Guid }) -join ', '))
    }

    process {
        $skuIds = $script:__GLA_TargetSkuIds

        # Build HashSet for fast membership checks
        $skuSet = [System.Collections.Generic.HashSet[guid]]::new()
        foreach ($s in $skuIds) { [void]$skuSet.Add([guid]$s) }

        # ---- FAST PATH (optimisation) ----
        # Graph can reject OR queries over assignedLicenses. Even two SKUs can fail.
        # So we run one fast query per SKU (only for small SKU sets) and union results by user Id.
        $users = $null

        if ($skuIds.Count -le 2) {
            $userById = @{}

            foreach ($sid in $skuIds) {
                try {
                    $tmp = Get-MgUser `
                        -Filter "assignedLicenses/any(l:l/skuId eq $sid)" `
                        -All `
                        -Property DisplayName,UserPrincipalName,Id,LicenseAssignmentStates,AccountEnabled `
                        -ConsistencyLevel eventual

                    foreach ($u in $tmp) {
                        if ($u.Id -and -not $userById.ContainsKey($u.Id)) {
                            $userById[$u.Id] = $u
                        }
                    }
                }
                catch {
                    Write-Verbose ("Fast path failed for SkuId {0}: {1}" -f $sid, $_.Exception.Message)
                    $userById = @{}
                    break
                }
            }

            if ($userById.Count -gt 0) {
                $users = $userById.Values
            }
        }
        else {
            Write-Verbose ("Skipping fast path: {0} SKUs resolved (Graph limitation / low ROI)" -f $skuIds.Count)
        }

        # ---- FALLBACK (source of truth) ----
        if (-not $users -or $users.Count -eq 0) {
            Write-Verbose "Fast path returned no users — using fallback enumeration via LicenseAssignmentStates"

            $allUsers =
                if ($NoCache) {
                    Get-MgUser `
                        -All `
                        -Property DisplayName,UserPrincipalName,Id,LicenseAssignmentStates,AccountEnabled `
                        -ConsistencyLevel eventual
                }
                else {
                    if (-not $script:__GLA_AllUsersCache) {
                        $script:__GLA_AllUsersCache = Get-MgUser `
                            -All `
                            -Property DisplayName,UserPrincipalName,Id,LicenseAssignmentStates,AccountEnabled `
                            -ConsistencyLevel eventual
                    }
                    $script:__GLA_AllUsersCache
                }

            $users = $allUsers | Where-Object {
                $_.LicenseAssignmentStates -and (
                    $_.LicenseAssignmentStates | Where-Object { $skuSet.Contains([guid]$_.SkuId) }
                )
            }
        }

        if (-not $users -or $users.Count -eq 0) {
            Write-Warning ("No users found with the license '{0}' (SkuIds: {1})" -f $Name, (($skuIds -join ', ')))
            return
        }

        # Cache group name lookups per invocation
        $groupCache = @{}

        foreach ($user in $users) {

            $states = @($user.LicenseAssignmentStates | Where-Object { $skuSet.Contains([guid]$_.SkuId) })

            if (-not $states -or $states.Count -eq 0) {
                [pscustomobject]@{
                    License              = $Name
                    MatchedSkuId         = $null
                    MatchedSkuPartNumber = $null
                    DisplayName          = $user.DisplayName
                    UserPrincipalName    = $user.UserPrincipalName
                    AccountEnabled       = $user.AccountEnabled
                    AssignmentMethod     = 'Unknown'
                    GroupName            = 'N/A'
                }
                continue
            }

            foreach ($state in $states) {

                $matchedSkuId = [guid]$state.SkuId
                $matchedPart  = $script:__GLA_SkuPartByIdCache[$matchedSkuId]

                if ($state.AssignedByGroup) {
                    $groupId = $state.AssignedByGroup

                    if (-not $groupCache.ContainsKey($groupId)) {
                        try {
                            $groupCache[$groupId] =
                                (Get-MgGroup -GroupId $groupId -Property DisplayName -ErrorAction Stop).DisplayName
                        }
                        catch {
                            $groupCache[$groupId] = "Unknown Group ($groupId)"
                        }
                    }

                    [pscustomobject]@{
                        License              = $Name
                        MatchedSkuId         = $matchedSkuId
                        MatchedSkuPartNumber = $matchedPart
                        DisplayName          = $user.DisplayName
                        UserPrincipalName    = $user.UserPrincipalName
                        AccountEnabled       = $user.AccountEnabled
                        AssignmentMethod     = 'Group'
                        GroupName            = $groupCache[$groupId]
                    }
                }
                else {
                    [pscustomobject]@{
                        License              = $Name
                        MatchedSkuId         = $matchedSkuId
                        MatchedSkuPartNumber = $matchedPart
                        DisplayName          = $user.DisplayName
                        UserPrincipalName    = $user.UserPrincipalName
                        AccountEnabled       = $user.AccountEnabled
                        AssignmentMethod     = 'Direct'
                        GroupName            = 'N/A'
                    }
                }
            }
        }
    }
}
