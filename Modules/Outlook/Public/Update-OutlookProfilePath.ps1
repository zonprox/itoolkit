function Update-OutlookProfilePath {
<#
.SYNOPSIS
    Re-maps Outlook profile registry pointer to a new data file path.
.DESCRIPTION
    Updates Unicode (001f6700, 001f6620) and ANSI (001e6700, 001e6620) binary property
    tags across Office 16.0, 15.0, and legacy Windows Messaging Subsystem profile subkeys
    to point to the relocated data file, backing up registry before edit.
    Returns $false without modifying registry if OldPath is not matched.
.PARAMETER ProfileName
    Outlook profile name (e.g. 'Outlook').
.PARAMETER OldPath
    Original data file path.
.PARAMETER NewPath
    New relocated data file path.
.OUTPUTS
    [bool] $true if profile registry was updated successfully; otherwise $false.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$ProfileName,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$OldPath,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string]$NewPath
    )

    process {
        if (-not $PSCmdlet.ShouldProcess($ProfileName, "Update MAPI data file path from '$OldPath' to '$NewPath'")) {
            return $true
        }

        # Ensure private helper is loaded if running outside imported module
        if (-not (Get-Command -Name 'ConvertFrom-MapiBinaryProperty' -ErrorAction SilentlyContinue)) {
            $privHelper = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Private/ConvertFrom-MapiBinaryProperty.ps1'
            if (Test-Path -LiteralPath $privHelper) {
                . $privHelper
            }
        }

        $candidateProfileKeys = @(
            "HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles\$ProfileName",
            "HKCU:\Software\Microsoft\Office\15.0\Outlook\Profiles\$ProfileName",
            "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows Messaging Subsystem\Profiles\$ProfileName"
        )

        $targetTags = @('001f6700', '001f6620', '001e6700', '001e6620')
        $updated = $false

        foreach ($profileKey in $candidateProfileKeys) {
            if (Test-Path -LiteralPath $profileKey) {
                try {
                    $subkeys = @(Get-ChildItem -LiteralPath $profileKey -ErrorAction SilentlyContinue)
                    foreach ($subkey in $subkeys) {
                        $itemProp = Get-ItemProperty -LiteralPath $subkey.PSPath -ErrorAction SilentlyContinue
                        if ($null -ne $itemProp) {
                            foreach ($tag in $targetTags) {
                                if ($null -ne $itemProp.PSObject.Properties[$tag] -and $null -ne $itemProp.$tag) {
                                    $val = $itemProp.$tag
                                    $currentStr = $null

                                    if (Get-Command -Name 'ConvertFrom-MapiBinaryProperty' -ErrorAction SilentlyContinue) {
                                        $currentStr = ConvertFrom-MapiBinaryProperty -Bytes $val -PropertyName $tag
                                    }
                                    elseif ($val -is [byte[]]) {
                                        try {
                                            $currentStr = [System.Text.Encoding]::Unicode.GetString($val).TrimEnd([char]0)
                                        }
                                        catch {
                                            Write-Verbose "Could not decode binary property '$tag': $($_.Exception.Message)"
                                        }
                                    }
                                    elseif ($val -is [string]) {
                                        $currentStr = $val.Trim()
                                    }

                                    if (-not [string]::IsNullOrWhiteSpace($currentStr) -and $currentStr -ieq $OldPath) {
                                        $newBytes = if ($tag -like '001e*') {
                                            [System.Text.Encoding]::Default.GetBytes($NewPath + [char]0)
                                        }
                                        else {
                                            [System.Text.Encoding]::Unicode.GetBytes($NewPath + [char]0)
                                        }

                                        $res = Set-ToolkitRegistryValue -KeyPath $subkey.PSPath -ValueName $tag -Value $newBytes -PropertyType 'Binary'
                                        if ($null -ne $res) {
                                            $updated = $true
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                catch {
                    Write-Verbose "Error enumerating profile subkeys: $($_.Exception.Message)"
                }
            }
        }

        if (-not $updated) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "No matching MAPI profile entry found for '$OldPath' in profile '$ProfileName'" -Level 'WARN' -Component 'Outlook:Profile'
            }
        }
        else {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Successfully re-mapped profile '$ProfileName' data path to '$NewPath'" -Level 'SUCCESS' -Component 'Outlook:Profile'
            }
        }

        return $updated
    }
}
