<#
    .SYNOPSIS
        Downloads the official Microsoft SKU-to-friendly-name mapping CSV. Falls back to SkuPartNumber if the download fails.
    .DESCRIPTION
        Downloads the official Microsoft SKU-to-friendly-name mapping CSV. Falls back to SkuPartNumber if the download fails.
        Also augments the hashtable with skuPartNumbers for any sku's that are in the tenant but missing from Microsoft's curated list.

        This is rendered as a hashtable of GUID|FriendlyName unless the -reverse switch is used in which case the FriendlyName becomes the key

    .EXAMPLE
        $FNames = Get-FriendlyLicenseNames
        $Fnames will be a hashtable with the license GUID as a key and the friendly name of the license as a value

        $FName[$SkuId] will return the friendly name of the GUID stored in $SkuID

    .EXAMPLE
        $RevFName = GetFriendlyLicenseNames -reverse
        $RevFName will be a hashtable with the friendly name of the license as a key and the GUID as the value

        This can be handy if you have the friendly name and want to retrieve its GUID or SKU-ID for some reason

    .NOTES
        Author:
            Nicked from Ian Bartram
            Module Dave Bremer 3/3/26    

#>
function Get-FriendlyLicenseNames {

    [cmdletBinding()]
    param(
        [switch]$reverse
    )

    $uri = 'https://download.microsoft.com/download/e/3/e/e3e9faf2-f28b-490a-9ada-c6089a1fc5b0/Product%20names%20and%20service%20plan%20identifiers%20for%20licensing.csv'
    $lookup = @{}

    try {
        Write-Verbose 'Downloading license name mappings from Microsoft...'
        $csvContent = Invoke-RestMethod -Method Get -Uri $uri
        $table = $csvContent | ConvertFrom-Csv

        foreach ($row in $table) {
            $guid = $row.GUID
            $name = $row.Product_Display_Name
            # The CSV sometimes has leading BOM characters in the header
            if (-not $guid) {
                $guidProp = $row.PSObject.Properties | Where-Object { $_.Name -match 'GUID' } | Select-Object -First 1
                $nameProp = $row.PSObject.Properties | Where-Object { $_.Name -match 'Product_Display_Name' } | Select-Object -First 1
                if ($guidProp -and $nameProp) {
                    $guid = $guidProp.Value
                    $name = $nameProp.Value
                }
            }
            if ($guid -and $name -and -not $lookup.ContainsKey($guid)) {
                if ($reverse){
                    $lookup[$name] = $guid
                } else {
                    $lookup[$guid] = $name
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
       # write-debug ("{0} - `"{1}`"" -f $tsku.SkuPartNumber,$lookup[$tsku.skuid])
        if ($null -eq $lookup[$tsku.skuid]){
            $guid = $tsku.SkuId
            $name = $tsku.SkuPartNumber
            Write-debug ("Adding from tenant as not found in lookup: {0}" -f $name)
            if ($reverse){
                $lookup[$name] = $guid
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