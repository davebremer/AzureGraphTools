<#
    .SYNOPSIS
        Builds a lookup hashtable of Microsoft 365 license SKU GUIDs to friendly product names.
    .DESCRIPTION
        
        Downloads Microsoft's official “Product names and service plan identifiers for licensing” CSV and converts it into a hashtable
        mapping SKU GUID -> Product_Display_Name.

        If the download fails for any reason, the function continues and will fall back to using the tenant's SkuPartNumber values
        (via Get-MgSubscribedSku) as the friendly names.

        The function also augments the lookup with any SKU IDs that exist in the tenant but are not present in Microsoft’s curated CSV,
        ensuring every subscribed SKU in the tenant has a corresponding entry.

        By default the output is:
            [hashtable] GUID (string) -> FriendlyName (string)

        If -Reverse is specified, the mapping is inverted:
            [hashtable] FriendlyName (string) -> GUID (string)

    .PARAMETER Reverse
        Inverts the output mapping so that FriendlyName becomes the key and GUID becomes the value.

        
    .OUTPUTS
        System.Collections.Hashtable
        A hashtable containing either:
            GUID -> FriendlyName
        or (with -Reverse):
            FriendlyName -> GUID

    .EXAMPLE
        $FNames = Get-FriendlyLicenseNames

        $sku     = Get-MgSubscribedSku | Select-Object -First 1
        $skuId   = $sku.SkuId.Guid     # normalise GUID object to string

        $FNames[$skuId]
        $FNames["6fd2c87f-b296-42f0-b197-1e91e994b900"]
        Returns the friendly product name for the specified tenant SKU.
   
    .EXAMPLE
        $Rev = Get-FriendlyLicenseNames -Reverse

        # Example friendly name as it appears in Microsoft's CSV
        # or as a tenant SkuPartNumber fallback
        $friendlyName = "Microsoft 365 F3"

        # Look up the SKU GUID using the friendly name
        $skuId = $Rev[$friendlyName]

        $skuId

        Demonstrates how to retrieve a license SKU GUID (returned as a string)
        when you already know the friendly product name. If the friendly name
        is not present in the lookup, the result will be $null.

    .LINK
        Microsoft licensing reference (Product names, String IDs, and SKU GUIDs):
        https://learn.microsoft.com/en-us/entra/identity/users/licensing-service-plan-reference

    .LINK
        Direct download of the official Microsoft SKU-to-friendly-name CSV:
        https://download.microsoft.com/download/e/3/e/e3e9faf2-f28b-490a-9ada-c6089a1fc5b0/Product%20names%20and%20service%20plan%20identifiers%20for%20licensing.csv

    
    .NOTES
        Requirements:
        - Microsoft.Graph module with permission to read subscribed SKUs (Get-MgSubscribedSku).

        
        Authoritative identifiers:
            License SKU GUIDs are the authoritative and stable identifiers for Microsoft 365
            licenses when working with Microsoft Graph and modern PowerShell modules.
            Friendly product names and SkuPartNumber values are provided for human readability
            only and may change over time due to rebranding, legacy offers, or product reshaping.

            For automation, reporting, and license assignment logic, SKU GUIDs should always
            be treated as the source of truth. This function therefore defaults to returning
            a GUID -> FriendlyName mapping, with -Reverse provided as a convenience only.


        Behaviour notes:       
        - Duplicate friendly names:
                The Microsoft licensing CSV can, on rare occasions, contain the same
                Product_Display_Name associated with more than one SKU GUID
                (for example during transitions, legacy offers, or region-specific SKUs).

                When using -Reverse, friendly names are used as hashtable keys and
                must therefore be unique. If duplicate friendly names are encountered,
                only the first mapping added to the hashtable is retained and subsequent
                duplicates are ignored.

                For scenarios where uniqueness is required or ambiguous names must be
                resolved, consider using the default GUID -> FriendlyName mapping instead.


        - The CSV occasionally includes BOM/odd header characters; the function attempts to locate the GUID/Product_Display_Name
        properties defensively if the expected headers are not parsed cleanly.
        - When -Reverse is used, duplicate friendly names in the CSV (rare, but possible) will result in later entries being ignored
        once a key already exists (because hashtable keys must be unique).

        Author:
        Original concept credited to Ian Bartram
        Adapted/maintained by Dave Bremer (module note: 2026-03-03)

#>
function Get-FriendlyLicenseNames {

    [cmdletBinding()]
    param(
        [switch]$reverse
    )

    $uri = 'https://download.microsoft.com/download/e/3/e/e3e9faf2-f28b-490a-9ada-c6089a1fc5b0/Product%20names%20and%20service%20plan%20identifiers%20for%20licensing.csv'
    $lookup = @{}

    # Normalise any GUID-ish input (string or [Guid]) to canonical "D" string format
    $NormalizeSkuGuid = {
        param($Value)
        if ($null -eq $Value -or $Value -eq '') { return $null }

        try {
            # Cast handles both [Guid] and string GUIDs
            return ([guid]$Value).ToString('D').ToLowerInvariant()
        } catch {
            return $null
        }
    }


    try {
        Write-Verbose 'Downloading license name mappings from Microsoft...'
        $csvContent = Invoke-RestMethod -Method Get -Uri $uri
        $table = $csvContent | ConvertFrom-Csv

        foreach ($row in $table) {
            $guid = & $NormalizeSkuGuid $row.GUID
            $name = $row.Product_Display_Name
            # The CSV sometimes has leading BOM characters in the header
            if (-not $guid) {
                $guidProp = $row.PSObject.Properties | Where-Object { $_.Name -match 'GUID' } | Select-Object -First 1
                $nameProp = $row.PSObject.Properties | Where-Object { $_.Name -match 'Product_Display_Name' } | Select-Object -First 1
                if ($guidProp -and $nameProp) {
                    $guid = & $NormalizeSkuGuid $guidProp.Value
                    $name = $nameProp.Value
                }
            }
            
            if ($guid -and $name) {
                if ($reverse) {
                    if (-not $lookup.ContainsKey($name)) {
                        $lookup[$name] = $guid
                    } else {        
                        Write-Debug ("Duplicate friendly name in CSV ignored: {0}" -f $name)
                    }
                } else {
                    if (-not $lookup.ContainsKey($guid)) {
                        $lookup[$guid] = $name
                    }
                }
            }

        }
        
    }
    catch {
        Write-Verbose 'Warning: Could not download friendly names. Will use SKU part numbers instead.' 
    }

    # get inbuilt name in case any aren't in #friendlyname
    Write-Verbose "Now getting tenant part numbers to fill gaps"
    $tenantSkus = Get-MgSubscribedSku -All | Select-Object SkuId, SkuPartNumber
   
    foreach ($tsku in $tenantSkus){
        # Normalise GUID to string form to match CSV keys
        $tenantKey = & $NormalizeSkuGuid $tsku.SkuId

        if ($tenantKey -and -not $lookup.ContainsKey($tenantKey)) {
            $guid = $tenantKey
            $name = $tsku.SkuPartNumber
            Write-Debug ("Adding from tenant as not found in lookup: {0}" -f $name)

            if ($reverse){
                if (-not $lookup.ContainsKey($name)){
                    $lookup[$name] = $guid
                }
            } else {
                $lookup[$guid] = $name
            }
        }
    }   
    Write-Verbose "Loaded $($lookup.Count) friendly name mappings." 
    #output to pipeline
   $lookup
    }
 # $friendly = Get-FriendlyLicenseNames -verbose -Debug