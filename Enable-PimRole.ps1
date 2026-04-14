<#
    .SYNOPSIS
    Activates (self-activates) Microsoft Entra PIM eligible directory roles for the signed-in user.

    .DESCRIPTION
    Submits a PIM role activation request (Action=selfActivate) using Microsoft Graph PowerShell.
    Accepts role names via parameter or pipeline. Uses the current Graph connection if it exists and
    includes the required delegated scopes; otherwise, connects interactively (supports MFA).

    Success is reported only via Write-Verbose. Failures terminate with clear messaging.

    .PARAMETER RoleName
    The display name of the Entra directory role to activate (e.g. "Global Reader").
    Accepts pipeline input as strings or objects with RoleName/Name/Role properties.

    .PARAMETER Reason
    Justification / reason for activation (required).

    .PARAMETER Duration
    ISO 8601 duration for how long to activate the role, e.g. PT1H, PT4H, PT9H.
    Default is PT9H.
    
    NOTE: Case is important in ISO8601 - PT4h will not work

    .PARAMETER TicketNumber
    Optional ticket/reference number to include with the activation request.

    .PARAMETER TicketSystem
    Optional ticket system name to include with the activation request. Eg "ServiceNow", or "ADO"

    .PARAMETER UseDeviceCode
    Use device code authentication for Connect-MgGraph (handy for non-GUI sessions).

    .EXAMPLE
    Enable-PimRole -RoleName "Global Reader" -Reason "Investigating access issue" -Verbose

    .EXAMPLE
    "Global Reader","SharePoint Administrator" | Enable-PimRole -Reason "Daily admin tasks" -Verbose

    .EXAMPLE
    $roleList = @(
        "Global Reader"
        "SharePoint Administrator"
    )

    $roleList | Enable-PimRole -Reason "Change window" -Duration PT4H -Verbose

    Demonstrates activating multiple eligible PIM roles by first defining a list
    of role display names and then piping them into Enable-PimRole. The activation
    uses a reduced duration to ensure compliance with role-specific PIM policies.

    
    .EXAMPLE
    Enable-PimRole "User Administrator" -reason "Changing groups"

    The command fails with:
    RoleAssignmentRequestPolicyValidationFailed
    ["ExpirationRule"]

    This error is due to default being 9 hours but "User Administrator" has a maximum of 4 hours or PT4H
    
    Note: Case is important for the duration - this should work
    > Enable-PimRole "User Administrator" "Changing groups" -Duration PT4

    .NOTES
    Requires delegated Graph permissions. PIM activation for "self" requires MFA in a session where MFA was challenged.

    Author: Copilot driven by Dave Bremer
    #>
function Enable-PimRole {

    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(
            Mandatory,
            Position = 0,
            ValueFromPipeline,
            ValueFromPipelineByPropertyName
        )]
        [Alias('Name','Role')]
        [ValidateNotNullOrEmpty()]
        [string[]]$RoleName,

        [Parameter(
            Mandatory,
            Position = 1
        )]
        [ValidateNotNullOrEmpty()]
        [string]$Reason,

        [Parameter()]
        [ValidatePattern('^P(T(\d+H)?(\d+M)?(\d+S)?)$')]
        [string]$Duration = 'PT9H',

        [Parameter()]
        [string]$TicketNumber,

        [Parameter()]
        [string]$TicketSystem,

        [Parameter()]
        [switch]$UseDeviceCode
    )

    BEGIN {

        function Throw-Terminating {
            param(
                [string]$Message,
                [string]$ErrorId = 'EnablePimRoleError',
                [System.Exception]$Exception = $null
            )

            if (-not $Exception) {
                $Exception = [System.Exception]::new($Message)
            }

            $err = New-Object System.Management.Automation.ErrorRecord `
                $Exception,
                $ErrorId,
                ([System.Management.Automation.ErrorCategory]::InvalidOperation),
                $null

            $PSCmdlet.ThrowTerminatingError($err)
        }

        function Ensure-GraphConnection {
            param(
                [string[]]$RequiredScopes
            )

            Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
            Import-Module Microsoft.Graph.Identity.Governance -ErrorAction Stop

            $context = $null
            try {
                $context = Get-MgContext -ErrorAction Stop
            } catch {
                $context = $null
            }

            $needsConnect = $true

            if ($context -and $context.AuthType -eq 'Delegated') {
                $haveScopes = $context.Scopes | ForEach-Object { $_.ToLowerInvariant() }
                $needScopes = $RequiredScopes | ForEach-Object { $_.ToLowerInvariant() }

                if (@($needScopes | Where-Object { $_ -notin $haveScopes }).Count -eq 0) {
                    $needsConnect = $false
                }
            }

            if ($needsConnect) {
                Write-Verbose "Connecting to Microsoft Graph (delegated, MFA capable)"

                try {
                    if ($UseDeviceCode) {
                        Connect-MgGraph -Scopes $RequiredScopes -UseDeviceCode -ErrorAction Stop | Out-Null
                    }
                    else {
                        Connect-MgGraph -Scopes $RequiredScopes -ErrorAction Stop | Out-Null
                    }
                }
                catch {
                    Throw-Terminating `
                        -Message "Failed to connect to Microsoft Graph. $($_.Exception.Message)" `
                        -ErrorId 'GraphConnectionFailed' `
                        -Exception $_.Exception
                }
            }

            $context = Get-MgContext -ErrorAction Stop
            if ($context.AuthType -ne 'Delegated') {
                Throw-Terminating `
                    -Message 'Microsoft Graph context is not delegated. PIM self‑activation requires interactive delegated sign‑in.' `
                    -ErrorId 'GraphNotDelegated'
            }

            return $context
        }

        $requiredScopes = @(
            'User.Read',
            'RoleManagement.ReadWrite.Directory'
        )

        Ensure-GraphConnection -RequiredScopes $requiredScopes | Out-Null

        try {
            $context = Get-MgContext
            if (-not $context.Account) {
                Throw-Terminating -Message 'Graph context does not contain an authenticated account.' -ErrorId 'NoGraphAccount'
            }

            $me = Get-MgUser -UserId $context.Account -Property Id,UserPrincipalName -ErrorAction Stop
            $script:PrincipalId  = $me.Id
            $script:PrincipalUpn = $me.UserPrincipalName
        }
        catch {
            Throw-Terminating `
                -Message "Unable to resolve signed-in user from Graph context. $($_.Exception.Message)" `
                -ErrorId 'UserLookupFailed' `
                -Exception $_.Exception
        }


        try {
            $script:EligibleRoles = Get-MgRoleManagementDirectoryRoleEligibilitySchedule `
                -All `
                -ExpandProperty RoleDefinition `
                -Filter ("principalId eq '{0}'" -f $script:PrincipalId) `
                -ErrorAction Stop
        }
        catch {
            Throw-Terminating `
                -Message "Failed to retrieve eligible PIM roles. $($_.Exception.Message)" `
                -ErrorId 'EligibilityLookupFailed' `
                -Exception $_.Exception
        }

        if (-not $script:EligibleRoles) {
            Throw-Terminating `
                -Message "No eligible PIM roles found for $script:PrincipalUpn." `
                -ErrorId 'NoEligibleRoles'
        }
    }

    PROCESS {

        foreach ($role in $RoleName) {

            $roleTrimmed = $role.Trim()
            if (-not $roleTrimmed) { continue }

            $matches = @(
                $script:EligibleRoles |
                    Where-Object { $_.RoleDefinition.DisplayName -eq $roleTrimmed }
            )

            if ($matches.Count -eq 0) {
                Throw-Terminating `
                    -Message "Role '$roleTrimmed' is not an eligible PIM role for $script:PrincipalUpn." `
                    -ErrorId 'RoleNotEligible'
            }

            if ($matches.Count -gt 1) {
                $scopes = ($matches | Select-Object -ExpandProperty DirectoryScopeId -Unique) -join ', '
                Throw-Terminating `
                    -Message "Role '$roleTrimmed' matched multiple eligible schedules (Scopes: $scopes)." `
                    -ErrorId 'RoleAmbiguous'
            }

            $match = $matches[0]

            $body = @{
                Action           = 'selfActivate'
                PrincipalId      = $match.PrincipalId
                RoleDefinitionId = $match.RoleDefinitionId
                DirectoryScopeId = $match.DirectoryScopeId
                Justification    = $Reason
                ScheduleInfo     = @{
                    StartDateTime = Get-Date
                    Expiration    = @{
                        Type     = 'AfterDuration'
                        Duration = $Duration
                    }
                }
            }

            if ($TicketNumber -or $TicketSystem) {
                $body.TicketInfo = @{}
                if ($TicketNumber) { $body.TicketInfo.TicketNumber = $TicketNumber }
                if ($TicketSystem) { $body.TicketInfo.TicketSystem = $TicketSystem }
            }

            if ($PSCmdlet.ShouldProcess(
                $script:PrincipalUpn,
                "Activate PIM role '$roleTrimmed' for $Duration"
            )) {
                try {
                    $response = New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest `
                        -BodyParameter $body `
                        -ErrorAction Stop

                    Write-Verbose (
                        "PIM activation requested successfully: Role='{0}', User='{1}', Duration='{2}', RequestId='{3}', Status='{4}'" -f
                        $roleTrimmed,
                        $script:PrincipalUpn,
                        $Duration,
                        $response.Id,
                        $response.Status
                    )
                }
                catch {
                    Throw-Terminating `
                        -Message "Failed to activate role '$roleTrimmed'. $($_.Exception.Message)" `
                        -ErrorId 'ActivationFailed' `
                        -Exception $_.Exception
                }
            }
        }
    }

    END {
        # No output by design – success is reported via Write-Verbose only
    }
}
