<#
    .SYNOPSIS
        Returns Intune-held hardware specifications for an Autopilot device using Microsoft Graph PowerShell SDK.

    .DESCRIPTION
        This function queries Microsoft Graph to collect hardware detail for a given Autopilot device.
        It combines:
            - Windows Autopilot device identity (deviceManagement/windowsAutopilotDeviceIdentities)
            - Intune managed device inventory (deviceManagement/managedDevices) including hardwareInformation (Graph /beta)

        Because hardwareInformation is documented in Microsoft Graph beta for Intune, this function uses Microsoft.Graph.Beta
        cmdlets where required. [4](https://learn.microsoft.com/en-us/graph/api/resources/intune-devices-hardwareinformation?view=graph-rest-beta)

        Required Graph permissions (delegated or application) typically include:
            - DeviceManagementServiceConfig.Read.All (Autopilot device identity) [2](https://learn.microsoft.com/en-us/graph/api/intune-enrollment-windowsautopilotdeviceidentity-list?view=graph-rest-1.0)[3](https://learn.microsoft.com/en-us/powershell/module/microsoft.graph.devicemanagement.enrollment/get-mgdevicemanagementwindowsautopilotdeviceidentity?view=graph-powershell-1.0)
            - DeviceManagementManagedDevices.Read.All (Managed device inventory) [6](https://learn.microsoft.com/en-us/graph/api/intune-devices-manageddevice-get?view=graph-rest-beta)[7](https://learn.microsoft.com/en-us/powershell/module/microsoft.graph.devicemanagement/get-mgdevicemanagementmanageddevice?view=graph-powershell-1.0)

    .PARAMETER DeviceName
        The device hostname / machine name as recorded in Intune (managedDevice.deviceName).
        This is the default parameter and accepts pipeline input.

    .PARAMETER SerialNumber
        The device serial number. Accepts pipeline input.

    .PARAMETER AutopilotDeviceIdentityId
        The Windows Autopilot device identity Id (Graph object Id for windowsAutopilotDeviceIdentity).

    .PARAMETER ManagedDeviceId
        The Intune managedDevice Id.

    .PARAMETER IncludeNonHardwareProperties
        When set, includes a small selection of non-hardware Intune properties (for context) such as OperatingSystem, OsVersion,
        EnrollmentType and LastSyncDateTime. Hardware-focused output remains the default.

    .PARAMETER PassThruRaw
        When set, includes the raw Autopilot and ManagedDevice Graph objects in the output for troubleshooting or exploration.

    .EXAMPLE
        Get-IntuneDeviceDetails -SerialNumber "PF3K1ABC"    Returns Intune-held Autopilot + hardware details for the device with serial PF3K1ABC.

    .EXAMPLE
        "PF3K1ABC","C02Z12345XYZ" | Get-IntuneDeviceDetails    Looks up each serial number from the pipeline and returns Intune-held hardware details for each device.

    .EXAMPLE
        Get-IntuneDeviceDetails -AutopilotDeviceIdentityId "fac6f0b1-f0b1-fac6-b1f0-c6fab1f0c6fa"    Returns device details using a known Autopilot identity Id.

    .EXAMPLE
        Get-IntuneDeviceDetails -ManagedDeviceId "2b6a6b9c-2d2f-4b74-a5c4-111111111111" -IncludeNonHardwareProperties    Returns hardware details plus a small set of additional Intune inventory fields for context.

    .OUTPUTS
        System.Management.Automation.PSCustomObject

    .NOTES
        Author: Dave Bremer heavily using copilot - created 20 April 2026
#>
function Get-IntuneDeviceDetails {
    [CmdletBinding(DefaultParameterSetName = 'ByDeviceName')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(
            Mandatory = $true,
            ParameterSetName = 'ByDeviceName',
            ValueFromPipeline = $true,
            ValueFromPipelineByPropertyName = $true,
            Position = 0
        )]
        [ValidateNotNullOrEmpty()]
        [Alias('Hostname', 'ComputerName', 'MachineName')]
        [string]$DeviceName,

        [Parameter(
            Mandatory = $true,
            ParameterSetName = 'BySerial',
            ValueFromPipeline = $true,
            ValueFromPipelineByPropertyName = $true
        )]
        [ValidateNotNullOrEmpty()]
        [Alias('Serial', 'DeviceSerialNumber')]
        [string]$SerialNumber,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByAutopilotId', ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('WindowsAutopilotDeviceIdentityId', 'AutopilotId')]
        [string]$AutopilotDeviceIdentityId,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByManagedDeviceId', ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('IntuneDeviceId', 'DeviceId')]
        [string]$ManagedDeviceId,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeNonHardwareProperties,

        [Parameter(Mandatory = $false)]
        [switch]$PassThruRaw
    )

    BEGIN {
        Write-Verbose 'Starting Get-IntuneDeviceDetails.'

        # ---- ensure Graph permissions ----
        $required = @(
            'DeviceManagementManagedDevices.Read.All'
        )

        $ctx = Get-MgContext
        $granted = @()

        if ($ctx) {
            $granted = @($ctx.Scopes)
        }

        $missing = $required | Where-Object { $_ -notin $granted }

        if (-not $ctx -or $missing) {
            if (-not $ctx) {
                Write-Verbose 'No Graph context detected — connecting via Connect-ToGraphRead.'
            }
            else {
                Write-Verbose ("Missing scopes: {0} — reconnecting" -f ($missing -join ', '))
            }

            Connect-ToGraphRead

            $ctx = Get-MgContext
            if (-not $ctx) {
                throw 'Connect-ToGraphRead did not establish a Graph context.'
            }
        }

        # Helper: return the first non-null / non-empty value from a list of candidates.
        function Get-FirstNonEmptyValue {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $false)]
                [object[]]$Values
            )

            if ($null -eq $Values -or $Values.Count -eq 0) {
                return $null
            }

            foreach ($value in $Values) {
                if ($null -ne $value) {
                    $stringValue = $value.ToString().Trim()
                    if ($stringValue.Length -gt 0) {
                        return $value
                    }
                }
            }

            return $null
        }

        # Helper: convert bytes to GB with rounding (2 dp).
        function Convert-BytesToGB {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $false)]
                [Nullable[Int64]]$Bytes
            )

            if ($null -eq $Bytes) {
                return $null
            }

            return [Math]::Round(($Bytes / 1GB), 2)
        }

        # Helper: escape a string for safe use inside OData single-quoted literals.
        function ConvertTo-ODataSingleQuotedString {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [string]$Value
            )

            return $Value.Replace("'", "''")
        }

        # Helper: Autopilot cmdlets are not always present in centrally managed installs.
        # We keep Autopilot enrichment optional and do not fail the function if the cmdlet is missing.
        function Get-AutopilotIdentityIfAvailable {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $false)]
                [string]$Filter,

                [Parameter(Mandatory = $false)]
                [string]$Id
            )

            $cmd = Get-Command -Name 'Get-MgDeviceManagementWindowsAutopilotDeviceIdentity' -ErrorAction SilentlyContinue
            if (-not $cmd) {
                Write-Verbose 'Autopilot cmdlet Get-MgDeviceManagementWindowsAutopilotDeviceIdentity is not available in this session. Skipping Autopilot enrichment.'
                return @()
            }

            try {
                if (-not [string]::IsNullOrWhiteSpace($Id)) {
                    return @(Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -WindowsAutopilotDeviceIdentityId $Id -ErrorAction Stop)
                }

                if (-not [string]::IsNullOrWhiteSpace($Filter)) {
                    return @(Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -Filter $Filter -All -ErrorAction Stop)
                }
            }
            catch {
                Write-Debug ("Autopilot lookup failed. Error: {0}" -f $_.Exception.Message)
                return @()
            }

            return @()
        }

        # Helper: normalise MAC addresses into HH:HH:HH:HH:HH:HH (upper-case hex, colon separated).
        function ConvertTo-ColonMacAddress {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $false)]
                [string]$MacAddress
            )

            if ([string]::IsNullOrWhiteSpace($MacAddress)) {
                return $null
            }

            $clean = $MacAddress.Trim()

            # Remove common separators and whitespace: :, -, ., and spaces.
            $clean = $clean.Replace(':', '')
            $clean = $clean.Replace('-', '')
            $clean = $clean.Replace('.', '')
            $clean = $clean.Replace(' ', '')

            # Must be exactly 12 hex chars after cleaning.
            if ($clean.Length -ne 12) {
                Write-Debug ("MAC address not 12 hex chars after cleaning: '{0}' (original: '{1}')" -f $clean, $MacAddress)
                return $null
            }

            # Validate hex characters only.
            if ($clean -notmatch '^[0-9A-Fa-f]{12}$') {
                Write-Debug ("MAC address contains non-hex characters: '{0}' (original: '{1}')" -f $clean, $MacAddress)
                return $null
            }

            $clean
    }

    PROCESS {
        $managedDeviceResults = @()
        $autopilotResults = @()

        if ($PSCmdlet.ParameterSetName -eq 'ByDeviceName') {
            Write-Verbose ("Querying managed device by DeviceName: {0}" -f $DeviceName)
            $escapedName = ConvertTo-ODataSingleQuotedString -Value $DeviceName

            try {
                $managedDeviceResults = @(Get-MgDeviceManagementManagedDevice -Filter ("deviceName eq '{0}'" -f $escapedName) -All -ErrorAction Stop)
            }
            catch {
                Write-Debug ("ManagedDevice lookup by deviceName filter failed. Error: {0}" -f $_.Exception.Message)
                throw
            }
        }

        if ($PSCmdlet.ParameterSetName -eq 'BySerial') {
            Write-Verbose ("Querying managed device by SerialNumber: {0}" -f $SerialNumber)
            $escapedSerial = ConvertTo-ODataSingleQuotedString -Value $SerialNumber

            try {
                $managedDeviceResults = @(Get-MgDeviceManagementManagedDevice -Filter ("serialNumber eq '{0}'" -f $escapedSerial) -All -ErrorAction Stop)
            }
            catch {
                Write-Debug ("ManagedDevice lookup by serialNumber filter failed. Error: {0}" -f $_.Exception.Message)
                $managedDeviceResults = @()
            }
        }

        if ($PSCmdlet.ParameterSetName -eq 'ByManagedDeviceId') {
            Write-Verbose ("Retrieving managed device by Id: {0}" -f $ManagedDeviceId)
            try {
                $managedDeviceResults = @(Get-MgDeviceManagementManagedDevice -ManagedDeviceId $ManagedDeviceId -ErrorAction Stop)
            }
            catch {
                Write-Debug ("ManagedDevice lookup by Id failed. Error: {0}" -f $_.Exception.Message)
                throw
            }
        }

        if ($PSCmdlet.ParameterSetName -eq 'ByAutopilotId') {
            Write-Verbose ("Retrieving Autopilot identity by Id: {0}" -f $AutopilotDeviceIdentityId)
            $autopilotResults = @(Get-AutopilotIdentityIfAvailable -Id $AutopilotDeviceIdentityId)

            foreach ($autopilot in $autopilotResults) {
                if ($null -eq $autopilot) {
                    continue
                }

                if (-not [string]::IsNullOrWhiteSpace($autopilot.ManagedDeviceId)) {
                    Write-Verbose ("Retrieving managed device using Autopilot.ManagedDeviceId: {0}" -f $autopilot.ManagedDeviceId)
                    try {
                        $managedDeviceResults = @(Get-MgDeviceManagementManagedDevice -ManagedDeviceId $autopilot.ManagedDeviceId -ErrorAction Stop)
                        break
                    }
                    catch {
                        Write-Debug ("ManagedDevice lookup using Autopilot.ManagedDeviceId failed. Error: {0}" -f $_.Exception.Message)
                    }
                }
            }
        }

        if ($managedDeviceResults.Count -eq 0 -and $autopilotResults.Count -eq 0) {
            Write-Verbose 'No managed device (and no Autopilot identity) found for the supplied input.'
            return
        }

        if ($managedDeviceResults.Count -eq 0) {
            $managedDeviceResults = @($null)
        }

        foreach ($managedDevice in $managedDeviceResults) {
            if ($null -eq $managedDevice) {
                continue
            }

            if ($autopilotResults.Count -eq 0) {
                if (-not [string]::IsNullOrWhiteSpace($managedDevice.SerialNumber)) {
                    $escapedSerialForAp = ConvertTo-ODataSingleQuotedString -Value $managedDevice.SerialNumber
                    Write-Verbose ("Attempting Autopilot enrichment by serialNumber: {0}" -f $managedDevice.SerialNumber)
                    $autopilotResults = @(Get-AutopilotIdentityIfAvailable -Filter ("serialNumber eq '{0}'" -f $escapedSerialForAp))
                }
            }

            $bestAutopilot = $null
            foreach ($apCandidate in $autopilotResults) {
                if ($null -eq $apCandidate) {
                    continue
                }

                if (-not [string]::IsNullOrWhiteSpace($apCandidate.ManagedDeviceId) -and $apCandidate.ManagedDeviceId -eq $managedDevice.Id) {
                    $bestAutopilot = $apCandidate
                    break
                }

                if (-not [string]::IsNullOrWhiteSpace($apCandidate.SerialNumber) -and $apCandidate.SerialNumber -eq $managedDevice.SerialNumber) {
                    $bestAutopilot = $apCandidate
                }
            }

            $resolvedDeviceName = Get-FirstNonEmptyValue -Values @(
                $managedDevice.DeviceName,
                $DeviceName
            )

            $resolvedSerialNumber = Get-FirstNonEmptyValue -Values @(
                $managedDevice.SerialNumber,
                $SerialNumber,
                $bestAutopilot.SerialNumber
            )

            $output = [ordered]@{
                Identity              = $resolvedDeviceName
                DeviceName            = $resolvedDeviceName
                SerialNumber          = $resolvedSerialNumber

                Manufacturer          = $managedDevice.Manufacturer
                Model                 = $managedDevice.Model

                OperatingSystem       = $managedDevice.OperatingSystem
                OsVersion             = $managedDevice.OsVersion

                ProcessorArchitecture = $managedDevice.ProcessorArchitecture
                PhysicalMemoryInBytes = $managedDevice.PhysicalMemoryInBytes
                PhysicalMemoryGB      = Convert-BytesToGB -Bytes $managedDevice.PhysicalMemoryInBytes

                TotalStorageBytes     = $managedDevice.TotalStorageSpaceInBytes
                TotalStorageGB        = Convert-BytesToGB -Bytes $managedDevice.TotalStorageSpaceInBytes
                FreeStorageBytes      = $managedDevice.FreeStorageSpaceInBytes
                FreeStorageGB         = Convert-BytesToGB -Bytes $managedDevice.FreeStorageSpaceInBytes

                EthernetMacAddress    = ConvertTo-ColonMacAddress -MacAddress $managedDevice.EthernetMacAddress
                WifiMacAddress        = ConvertTo-ColonMacAddress -MacAddress $managedDevice.WifiMacAddress

                Imei                 = $managedDevice.Imei
                Meid                 = $managedDevice.Meid
                Udid                 = $managedDevice.Udid

                ManagedDeviceId       = $managedDevice.Id

                AutopilotDeviceIdentityId = $bestAutopilot.Id
                AutopilotGroupTag         = $bestAutopilot.GroupTag
                AutopilotPurchaseOrderId  = $bestAutopilot.PurchaseOrderIdentifier
                AutopilotSystemFamily     = $bestAutopilot.SystemFamily
                AutopilotSkuNumber        = $bestAutopilot.SkuNumber
                AutopilotLastContacted    = $bestAutopilot.LastContactedDateTime
            }

            if (-not $IncludeNonHardwareProperties) {
                $output.Remove('OperatingSystem')
                $output.Remove('OsVersion')
            }

            if ($IncludeNonHardwareProperties) {
                $output['EnrollmentType']   = $managedDevice.EnrollmentType
                $output['ManagementAgent']  = $managedDevice.ManagementAgent
                $output['LastSyncDateTime'] = $managedDevice.LastSyncDateTime
                $output['ComplianceState']  = $managedDevice.ComplianceState
                $output['DeviceState']      = $managedDevice.DeviceState
            }

            if ($PassThruRaw) {
                $output['RawManagedDeviceObject'] = $managedDevice
                $output['RawAutopilotObject']     = $bestAutopilot
            }

            [pscustomobject]$output
        }
    }

    END {
        Write-Verbose 'Completed Get-IntuneDeviceDetails.'
    }
}
