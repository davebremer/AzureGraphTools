<#
.SYNOPSIS
    Returns a tenant-wide inventory of subscribed Microsoft 365 / Entra SKUs with friendly names and seat availability.

.DESCRIPTION
    Queries Microsoft Graph (Get-MgSubscribedSku) to retrieve all subscribed license SKUs in the tenant and returns a
    normalised inventory view including friendly product name, enabled seats, consumed seats, and calculated availability.

    Friendly product names are resolved using a lookup hashtable keyed by SKU GUID. By default, this lookup is generated
    by Get-FriendlyLicenseNames, which:
        - Downloads Microsoft’s official SKU → product name licensing reference
        - Falls back to tenant SkuPartNumber values when entries are missing
        - Ensures every subscribed tenant SKU resolves to a name

    This function deliberately reports *tenant-level SKU inventory only*.
    It does not enumerate per-user assignments and does not determine assignment source
    (Direct vs Group-based licensing). User-level assignment analysis is handled separately
    by Get-LicenseAssignments.

.PARAMETER FriendlyNames
    Hashtable mapping SKU GUIDs to friendly product names.

    Expected format:
        Key   : Canonical SKU GUID string (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
        Value : Friendly product name (string)

    If omitted, the mapping is generated automatically by Get-FriendlyLicenseNames.

.INPUTS
    None. You cannot pipe input objects to this function.

.OUTPUTS
    PSCustomObject with the following properties:
        Name          Friendly product name
        SkuPartNumber Microsoft SKU part number
        SkuId         SKU GUID
        Consumed      ConsumedUnits reported by Graph
        Enabled       Enabled (prepaid) units reported by Graph
        Available     Enabled - Consumed
        AppliesTo     Graph AppliesTo value (e.g. User, Company)

.EXAMPLE
    Get-TenantLicenses

    Retrieves all tenant SKUs with friendly names resolved automatically.

.EXAMPLE
    $fn = Get-FriendlyLicenseNames
    Get-TenantLicenses -FriendlyNames $fn

    Uses a pre-generated friendly-name lookup, avoiding repeated downloads
    of Microsoft’s licensing reference.

.EXAMPLE
    Get-TenantLicenses |
        Where-Object Available -lt 5 |
        Select-Object Name, Enabled, Consumed, Available |
        Sort-Object Available

    Lists SKUs that are low on available seats.

.EXAMPLE
    Get-TenantLicenses |
        Where-Object Name -match '\b(?:F1|F3|E3|E5)\b' |
        Select-Object Name, Enabled, Consumed, Available

    Filters common Microsoft 365 suite licenses by friendly name.

.NOTES
    Requires:
        PowerShell 7+
        Microsoft.Graph.Users
        Microsoft.Graph.Groups
        Microsoft.Graph.Identity.DirectoryManagement

    Required Microsoft Graph scopes:
        User.Read.All
        Directory.Read.All
        Group.Read.All
        (Delegated or application)

    Behaviour notes:
        - If required Graph scopes are missing, Connect-ToGraphRead is invoked.
        - Available is calculated as Enabled - Consumed and should be treated as an
          operational indicator, not a guarantee of assignable capacity.
        - Values do not account for pending purchases, reservations, service-plan
          constraints, or assignment logic.

    Related commands:
        - Get-FriendlyLicenseNames  (SKU GUID → friendly name resolution)
        - Get-LicenseAssignments    (User-level assignments and assignment source)

    Author:
        Originally based on work by Ian Bartram.
        Updated and maintained by Dave Bremer.
#>

function Get-TenantLicenses {

    [CmdletBinding()]
    param(
        [hashtable]$FriendlyNames
    )

    # Populate default only if caller didn't supply one
    if (-not $FriendlyNames -or $FriendlyNames.Count -eq 0) {
        $FriendlyNames = Get-FriendlyLicenseNames
    }

    # Ensure Graph permissions
    $required = @('User.Read.All', 'Directory.Read.All', 'Group.Read.All')
    $ctx = Get-MgContext
    $granted = if ($ctx -and $ctx.Scopes) { @($ctx.Scopes) } else { @() }
    $missing = $required | Where-Object { $_ -notin $granted }

    if ($missing) {
        Write-Verbose (
            "Missing the following: {0}`nso connecting with: {1}" -f
            ($missing -join ', '),
            ($required -join ', ')
        )
        Connect-ToGraphRead
    }

    Write-Verbose 'Retrieving tenant licenses...'
    try {
        $skus = Get-MgSubscribedSku -All | Sort-Object SkuPartNumber
    }
    catch {
        throw "Failed to retrieve subscribed SKUs from Graph. $($_.Exception.Message)"
    }

    Write-Verbose 'Processing license SKUs'
    foreach ($sku in $skus) {

        # Normalise GUID key to match Get-FriendlyLicenseNames output
        $skuKey = ([guid]$sku.SkuId).ToString('D').ToLowerInvariant()

        $friendly = $FriendlyNames[$skuKey]
        if (-not $friendly) {
            $friendly = $sku.SkuPartNumber
        }

        Write-Debug $friendly

        # Safely extract numeric values (defensive against nulls)
        $enabled = if ($sku.PrepaidUnits -and $null -ne $sku.PrepaidUnits.Enabled) {
            [int]$sku.PrepaidUnits.Enabled
        }
        else {
            0
        }

        $consumed = if ($null -ne $sku.ConsumedUnits) {
            [int]$sku.ConsumedUnits
        }
        else {
            0
        }

        # Stream object to pipeline
        [PSCustomObject]@{
            Name          = $friendly
            SkuPartNumber = $sku.SkuPartNumber
            SkuId         = $sku.SkuId
            Consumed      = $consumed
            Enabled       = $enabled
            Available     = $enabled - $consumed
            AppliesTo     = $sku.AppliesTo
        }
    }
}


# $fn = Get-FriendlyLicenseNames -Verbose
# Get-TenantLicenses $fn -verbose -debug
# get-TenantLicenses -verbose