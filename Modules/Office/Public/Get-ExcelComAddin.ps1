function Get-ExcelComAddin {
<#
.SYNOPSIS
    Enumerates registered Excel COM Add-ins across HKCU and HKLM hives.
.DESCRIPTION
    Scans Excel COM Add-in registration paths in the Windows Registry:
    - HKCU:\Software\Microsoft\Office\Excel\Addins
    - HKLM:\Software\Microsoft\Office\Excel\Addins
    - HKLM:\Software\WOW6432Node\Microsoft\Office\Excel\Addins
    Deduplicates add-in entries by ProgId, returning their LoadBehavior, status, and location.
.OUTPUTS
    [PSCustomObject[]] containing Name, ProgId, LoadBehavior, Status, and Location.
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param()

    process {
        $searchHives = @(
            'HKCU:\Software\Microsoft\Office\Excel\Addins',
            'HKLM:\Software\Microsoft\Office\Excel\Addins',
            'HKLM:\Software\WOW6432Node\Microsoft\Office\Excel\Addins'
        )

        $discovered = [System.Collections.Generic.List[PSCustomObject]]::new()
        $seenProgIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($hive in $searchHives) {
            try {
                $subKeys = @(Get-ChildItem -Path $hive -ErrorAction SilentlyContinue)
                if ($null -ne $subKeys -and $subKeys.Count -gt 0) {
                    foreach ($key in $subKeys) {
                        $progId = $key.PSChildName
                        if ([string]::IsNullOrWhiteSpace($progId)) {
                            continue
                        }

                        if ($seenProgIds.Contains($progId)) {
                            continue
                        }
                        $null = $seenProgIds.Add($progId)

                        # Resolve properties via GetValue or direct property lookup
                        $loadBehavior = 3
                        $friendlyName = $progId

                        if ($key.PSObject.Methods.Match('GetValue').Count -gt 0) {
                            $lbVal = $key.GetValue('LoadBehavior')
                            if ($null -ne $lbVal) {
                                $loadBehavior = [int]$lbVal
                            }
                            $fnVal = $key.GetValue('FriendlyName')
                            if ($null -ne $fnVal -and -not [string]::IsNullOrWhiteSpace($fnVal)) {
                                $friendlyName = [string]$fnVal
                            }
                            else {
                                $descVal = $key.GetValue('Description')
                                if ($null -ne $descVal -and -not [string]::IsNullOrWhiteSpace($descVal)) {
                                    $friendlyName = [string]$descVal
                                }
                            }
                        }
                        elseif ($key.PSObject.Properties['GetValue'] -and $key.GetValue -is [scriptblock]) {
                            $lbVal = & $key.GetValue 'LoadBehavior'
                            if ($null -ne $lbVal) {
                                $loadBehavior = [int]$lbVal
                            }
                            $fnVal = & $key.GetValue 'FriendlyName'
                            if ($null -ne $fnVal -and -not [string]::IsNullOrWhiteSpace($fnVal)) {
                                $friendlyName = [string]$fnVal
                            }
                        }

                        $status = 'Custom'
                        switch ($loadBehavior) {
                            3       { $status = 'Enabled' }
                            2       { $status = 'Disabled' }
                            0       { $status = 'Inactive' }
                            1       { $status = 'DemandLoad' }
                            16      { $status = 'FirstTimeDemand' }
                            default { $status = 'Custom' }
                        }

                        $hiveLocation = 'HKLM'
                        if ($hive -match '^HKCU') {
                            $hiveLocation = 'HKCU'
                        }

                        $discovered.Add([PSCustomObject]@{
                            Name         = $friendlyName
                            ProgId       = $progId
                            LoadBehavior = $loadBehavior
                            Status       = $status
                            Location     = $hiveLocation
                        })
                    }
                }
            }
            catch {
                Write-Verbose "Scanning registry hive '$hive' encountered error: $($_.Exception.Message)"
            }
        }

        return @($discovered)
    }
}
