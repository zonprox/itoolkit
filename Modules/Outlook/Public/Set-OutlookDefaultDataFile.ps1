function Set-OutlookDefaultDataFile {
<#
.SYNOPSIS
    Assigns an Outlook data file as the default data file for a profile.
.DESCRIPTION
    Configures the specified PST or OST file as the default delivery data file for
    the target Outlook profile using guided profile management (/manageprofiles or mlcfg32.cpl).
    Validates file extension (.pst or .ost), checks running Outlook process state,
    and supports -WhatIf / ShouldProcess.
.PARAMETER Path
    Path to the PST or OST data file.
.PARAMETER ProfileName
    Outlook profile name. Defaults to the active or default profile.
.OUTPUTS
    [PSCustomObject]@{ Path, Profile, Success, Method, FallbackTriggered, OutlookRunning, ErrorMessage }
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$ProfileName
    )

    process {
        # 1. Extension Validation
        if ($Path -notmatch '(?i)\.(pst|ost)$') {
            throw "The data file path must have a .pst or .ost extension: '$Path'"
        }

        # 2. Path Normalization
        $resolvedPath = [System.Environment]::ExpandEnvironmentVariables($Path.Trim())
        if (-not ($resolvedPath -match '^[a-zA-Z]:[/\\]' -and [System.IO.Path]::DirectorySeparatorChar -ne [char]92)) {
            try {
                $resolvedPath = [System.IO.Path]::GetFullPath($resolvedPath)
            } catch { $null = $_ }
        }

        # 3. Resolve Target Profile
        $targetProfile = $ProfileName
        if ([string]::IsNullOrWhiteSpace($targetProfile)) {
            if (Get-Command -Name 'Get-OutlookSystemContext' -ErrorAction SilentlyContinue) {
                try {
                    $ctx = Get-OutlookSystemContext
                    if ($null -ne $ctx -and -not [string]::IsNullOrWhiteSpace($ctx.DefaultProfile) -and $ctx.DefaultProfile -ne 'None') {
                        $targetProfile = $ctx.DefaultProfile
                    }
                } catch { $null = $_ }
            }
        }
        if ([string]::IsNullOrWhiteSpace($targetProfile)) {
            $targetProfile = 'Outlook'
        }

        # 4. SupportsShouldProcess Check
        if (-not $PSCmdlet.ShouldProcess($resolvedPath, "Set as default data file for Outlook profile '$targetProfile'")) {
            return [PSCustomObject]@{
                Path              = $resolvedPath
                Profile           = $targetProfile
                Success           = $true
                Method            = 'WhatIf'
                FallbackTriggered = $false
                OutlookRunning    = $false
                ErrorMessage      = $null
            }
        }

        # 5. Check Running Outlook Processes
        $outlookProcs = @(Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
        $isOutlookRunning = ($outlookProcs.Count -gt 0)

        # 6. Locate Outlook Executable
        $outlookExe = 'outlook.exe'
        if (Get-Command -Name 'Get-OutlookSystemContext' -ErrorAction SilentlyContinue) {
            try {
                $sys = Get-OutlookSystemContext
                if ($null -ne $sys -and -not [string]::IsNullOrWhiteSpace($sys.OutlookPath)) {
                    $outlookExe = $sys.OutlookPath
                }
            } catch { $null = $_ }
        }

        # 7. Launch Guided Profile Manager
        $launched = $false
        try {
            $p = Start-Process -FilePath $outlookExe -ArgumentList '/manageprofiles' -PassThru -ErrorAction SilentlyContinue
            if ($null -ne $p) { $launched = $true }
        } catch { $null = $_ }

        if (-not $launched) {
            try {
                $p = Start-Process -FilePath 'control.exe' -ArgumentList 'mlcfg32.cpl' -PassThru -ErrorAction SilentlyContinue
                if ($null -ne $p) { $launched = $true }
            } catch { $null = $_ }
        }

        $leafName = Split-Path -Path $resolvedPath -Leaf
        if ([string]::IsNullOrWhiteSpace($leafName) -or $leafName -match '[\\/]') {
            $leafName = ($resolvedPath -split '[\\/]')[-1]
        }
        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "To set '$leafName' as default: 1. Click 'Data Files...' -> 2. Select '$leafName' -> 3. Click 'Set as Default' -> 4. Click 'Close'." -Level 'INFO' -Component 'Outlook:SetDefault'
            if ($isOutlookRunning) {
                Write-ToolkitLog -Message "Notice: Outlook is currently running. Restart Outlook for default store changes to take effect." -Level 'WARN' -Component 'Outlook:SetDefault'
            }
        }

        $errorMessage = if (-not $launched) { "Could not launch Outlook profile management dialog." } else { $null }

        return [PSCustomObject]@{
            Path              = $resolvedPath
            Profile           = $targetProfile
            Success           = $launched
            Method            = 'GuidedFallback'
            FallbackTriggered = $true
            OutlookRunning    = $isOutlookRunning
            ErrorMessage      = $errorMessage
        }
    }
}
