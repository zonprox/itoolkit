function Get-OutlookPstThreshold {
<#
.SYNOPSIS
    Queries active Outlook PST and OST file size threshold policies.
.DESCRIPTION
    Inspects Group Policy (HKCU/HKLM Software\Policies\Microsoft\Office\<ver>\Outlook\PST)
    and user preference keys (HKCU/HKLM Software\Microsoft\Office\<ver>\Outlook\PST)
    for MaxLargeFileSize and WarnLargeFileSize registry values across Office 16.0 and 15.0.
    Returns structured metadata indicating whether policies are active, expanded (>50GB),
    or at default limits.
.PARAMETER OfficeVersion
    Optional Office version string ('16.0' or '15.0'). If omitted, checks 16.0 followed by 15.0.
.OUTPUTS
    [PSCustomObject]@{ MaxLargeFileSizeMB, WarnLargeFileSizeMB, IsCustomPolicy, PolicySource, IsExpanded, Description }
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet('16.0', '15.0')]
        [string]$OfficeVersion
    )

    process {
        # Default Outlook thresholds (50 GB / 47.5 GB)
        $defaultMax = 51200
        $defaultWarn = 48640

        $versionsToCheck = if (-not [string]::IsNullOrWhiteSpace($OfficeVersion)) {
            @($OfficeVersion)
        }
        else {
            @('16.0', '15.0')
        }

        $candidateKeys = [System.Collections.Generic.List[string]]::new()
        foreach ($ver in $versionsToCheck) {
            # 1. Group Policy (HKCU then HKLM)
            $candidateKeys.Add("HKCU:\Software\Policies\Microsoft\Office\$ver\Outlook\PST")
            $candidateKeys.Add("HKLM:\Software\Policies\Microsoft\Office\$ver\Outlook\PST")
            # 2. Preferences (HKCU then HKLM)
            $candidateKeys.Add("HKCU:\Software\Microsoft\Office\$ver\Outlook\PST")
            $candidateKeys.Add("HKLM:\Software\Microsoft\Office\$ver\Outlook\PST")
        }

        $foundMax = $null
        $foundWarn = $null
        $matchedKey = $null

        foreach ($key in $candidateKeys) {
            try {
                if (Test-Path -LiteralPath $key) {
                    $prop = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
                    if ($null -ne $prop) {
                        $maxVal = $null
                        $warnVal = $null

                        if ($null -ne $prop.PSObject.Properties['MaxLargeFileSize'] -and $null -ne $prop.MaxLargeFileSize) {
                            $maxVal = [int]$prop.MaxLargeFileSize
                        }
                        if ($null -ne $prop.PSObject.Properties['WarnLargeFileSize'] -and $null -ne $prop.WarnLargeFileSize) {
                            $warnVal = [int]$prop.WarnLargeFileSize
                        }

                        if ($null -ne $maxVal -or $null -ne $warnVal) {
                            $foundMax = if ($null -ne $maxVal) { $maxVal } else { $defaultMax }
                            $foundWarn = if ($null -ne $warnVal) { $warnVal } else { [int]($foundMax * 0.95) }
                            $matchedKey = $key
                            break
                        }
                    }
                }
            }
            catch {
                Write-Verbose "Threshold query notice on '$key': $($_.Exception.Message)"
            }
        }

        $isCustom = ($null -ne $matchedKey)
        $maxMB = if ($isCustom) { $foundMax } else { $defaultMax }
        $warnMB = if ($isCustom) { $foundWarn } else { $defaultWarn }
        $policySource = if ($isCustom) { $matchedKey } else { 'Default' }
        $isExpanded = ($maxMB -gt $defaultMax)

        $description = if ($isExpanded) {
            "Expanded PST limit ($([Math]::Round($maxMB / 1024, 1)) GB max, $([Math]::Round($warnMB / 1024, 1)) GB warn) via $policySource"
        }
        elseif ($isCustom) {
            "Custom PST limit ($([Math]::Round($maxMB / 1024, 1)) GB max, $([Math]::Round($warnMB / 1024, 1)) GB warn) via $policySource"
        }
        else {
            "Default limit (~50 GB threshold)"
        }

        return [PSCustomObject]@{
            MaxLargeFileSizeMB  = $maxMB
            WarnLargeFileSizeMB = $warnMB
            IsCustomPolicy      = $isCustom
            PolicySource        = $policySource
            IsExpanded          = $isExpanded
            Description         = $description
        }
    }
}
