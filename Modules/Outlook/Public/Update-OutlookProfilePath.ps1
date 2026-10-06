function Update-OutlookProfilePath {
<#
.SYNOPSIS
    Re-maps Outlook profile registry pointer to a new data file path.
.DESCRIPTION
    Updates Unicode binary property tag 001f6700 in Outlook profile MAPI subkeys
    to point to the relocated PST file, backing up registry before edit.
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

        $newBytes = [System.Text.Encoding]::Unicode.GetBytes($NewPath + [char]0)
        $profileKey = "HKCU:\Software\Microsoft\Office\16.0\Outlook\Profiles\$ProfileName"

        $updated = $false

        # Enumerate subkeys if profile registry key exists
        if (Test-Path -LiteralPath $profileKey) {
            try {
                $subkeys = @(Get-ChildItem -LiteralPath $profileKey -ErrorAction SilentlyContinue)
                foreach ($subkey in $subkeys) {
                    $val = (Get-ItemProperty -LiteralPath $subkey.PSPath -Name '001f6700' -ErrorAction SilentlyContinue).'001f6700'
                    if ($null -ne $val -and $val -is [byte[]]) {
                        $currentStr = [System.Text.Encoding]::Unicode.GetString($val).TrimEnd([char]0)
                        if ($currentStr -ieq $OldPath) {
                            $res = Set-ToolkitRegistryValue -KeyPath $subkey.PSPath -ValueName '001f6700' -Value $newBytes -PropertyType 'Binary'
                            if ($null -ne $res) {
                                $updated = $true
                            }
                        }
                    }
                }
            }
            catch {
                Write-Verbose "Error enumerating profile subkeys: $($_.Exception.Message)"
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
