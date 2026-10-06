function Assert-SupportedOfficeVersion {
<#
.SYNOPSIS
    Validates that the target Office version is supported (Office 16.0).
.DESCRIPTION
    Enforces the project requirement that only Office 16.0 (2016, 2019, 2021, 2024, C2R)
    is supported, and throws an exception for legacy Office 2010 (14.0) or Office 2013 (15.0).
.PARAMETER OfficeVersion
    The Office version string to test (e.g. '16.0', '15.0', '14.0'). Default is '16.0'.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$OfficeVersion = '16.0'
    )

    if ($OfficeVersion -match '14\.0' -or $OfficeVersion -match '15\.0') {
        $msg = "Unsupported legacy Office version: $OfficeVersion. Only Office 16.0 (2016/2021/2024/C2R) is supported."
        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message $msg -Level 'ERROR' -Component 'Office:VersionCheck'
        }
        throw $msg
    }

    return $true
}
