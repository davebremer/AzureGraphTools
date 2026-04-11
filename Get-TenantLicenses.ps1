<#
.SYNOPSIS
    Retrieves all subscribed SKUs and enriches them with friendly names and number available.

.DESCRIPTION
    Retrieves all subscribed SKUs and enriches them with friendly names and number available.
    You can pass in a hashtable of friendlynames if you have one, otherwise it grabs the list from Microsoft

.EXAMPLE
    Get-TenantLicenses

    Grabs a copy of Microsoft's friendly name list and returns as objects the details of the licenses in the tenancy such as:
        Name          : Visio Plan 2
        SkuPartNumber : VISIOCLIENT
        SkuId         : c5928f49-12ba-48f7-ada3-0d743a3601d5
        Consumed      : 234
        Enabled       : 1234
        Available     : 1000
        AppliesTo     : User

.EXAMPLE
    Get-TenantLicenses $FriendlyNamesHash

    Uses an already obtained hashtable in the form of GUID as key and FriendlyName as value. This saves on the overhead of dragging down a fresh copy. Minimal mind you

.EXAMPLE
    Get-TenantLicenses | where available -LT 5 | select Name,Enabled,Consumed,Available | sort available
    
    Returns those items with less than 5 spare licenses sorted by number of available licenses

.EXAMPLE
    Get-TenantLicenses | where name -like "*[F|E][1|3|5]*" | select Name,Enabled,Consumed,Available 

    Returns the number of licenses for F1, F3 or E5 (and other combinations but they don't exist)

.NOTES
    Requires:   PowerShell 7+, Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement
    Permissions: User.Read.All, Directory.Read.All, Group.Read.All (delegated or application)

    AUTHOR:
        Nicked from Ian Bartram
        Dave Bremer updated for module
#>
function Get-TenantLicenses {
    
    [cmdletBinding()]
    param(
        [hashtable]$FriendlyNames =(Get-FriendlyLicenseNames)
    )

    # get a connection if we don't have the rights
    $required = @('User.Read.All', 'Directory.Read.All', 'Group.Read.All')
    $granted  = Get-MgContext | Select-Object -ExpandProperty Scopes
    $missing  = $required | Where-Object { $_ -notin $granted }
    if ($missing) {
        Write-Verbose ("Missing the following: {0}`nso connecting with: {1}" -f ($missing -join ', '),($required -join ', '))
        Connect-ToGraphRead
    }

    Write-verbose 'Retrieving tenant licenses...'
    $skus = Get-MgSubscribedSku -All | Sort-Object SkuPartNumber

    Write-verbose "Processing licence skus"
    $licenseList = foreach ($sku in $skus) {
        $friendly = $FriendlyNames[$sku.SkuId]
        if (-not $friendly) { $friendly = $sku.SkuPartNumber }

        write-debug ("{0}" -f $friendly)
        [PSCustomObject]@{
            Name  = $friendly
            SkuPartNumber = $sku.SkuPartNumber
            SkuId         = $sku.SkuId
            Consumed      = $sku.ConsumedUnits
            Enabled       = $sku.PrepaidUnits.Enabled
            Available     = $sku.PrepaidUnits.Enabled - $sku.ConsumedUnits
            AppliesTo     = $sku.AppliesTo
        }
    } #foreach sku

    # output to pipeline
    $licenseList

}

# $fn = Get-FriendlyLicenseNames -Verbose
# Get-TenantLicenses $fn -verbose -debug
# get-TenantLicenses -verbose