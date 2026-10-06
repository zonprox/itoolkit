function Set-ExcelComAddinState {
<#
.SYNOPSIS
    Modifies the LoadBehavior of a registered Excel COM Add-in.
.DESCRIPTION
    Updates LoadBehavior in HKCU:\Software\Microsoft\Office\Excel\Addins\<ProgId>.
    Common LoadBehavior values:
    - 3: Loaded at startup (Enabled)
    - 2: Disconnected (Disabled)
    - 0: Inactive
.PARAMETER ProgId
    The programmatic identifier of the target COM add-in (e.g. 'PowerPivot').
.PARAMETER LoadBehavior
    Target LoadBehavior integer (0, 1, 2, 3, 16).
.OUTPUTS
    [PSCustomObject] containing ProgId, PreviousBehavior, and NewBehavior.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$ProgId,

        [Parameter(Mandatory = $true, Position = 1)]
        [int]$LoadBehavior
    )

    process {
        $keyPath = "HKCU:\Software\Microsoft\Office\Excel\Addins\$ProgId"
        $valueName = 'LoadBehavior'

        if (-not $PSCmdlet.ShouldProcess($ProgId, "Set LoadBehavior to $LoadBehavior")) {
            return [PSCustomObject]@{
                ProgId           = $ProgId
                PreviousBehavior = $null
                NewBehavior      = $LoadBehavior
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Updating COM add-in '$ProgId' LoadBehavior to $LoadBehavior" -Level 'INFO' -Component 'Set-ExcelComAddinState'
        }

        $regResult = Set-ToolkitRegistryValue -KeyPath $keyPath -ValueName $valueName -Value $LoadBehavior -PropertyType 'DWord'

        $previousVal = $null
        $newVal = $LoadBehavior

        if ($null -ne $regResult) {
            if ($regResult.PSObject.Properties['PreviousValue']) {
                $previousVal = $regResult.PreviousValue
            }
            if ($regResult.PSObject.Properties['NewValue']) {
                $newVal = $regResult.NewValue
            }
        }

        return [PSCustomObject]@{
            ProgId           = $ProgId
            PreviousBehavior = $previousVal
            NewBehavior      = $newVal
        }
    }
}
