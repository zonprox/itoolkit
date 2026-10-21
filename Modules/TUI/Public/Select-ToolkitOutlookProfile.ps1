<#
.SYNOPSIS
    Selects an Outlook profile interactively using numeric selection, or returns
    the default profile in headless/non-interactive mode.
.DESCRIPTION
    Provides a robust, reusable console selector for choosing an Outlook profile from
    an array of profiles or discovered profiles via Get-OutlookSystemContext. Supports
    single numeric selection [1..N], custom profile entry [N+1], instant fallback in
    -NonInteractive mode without user interaction, and direct string matching for
    backwards compatibility and automated test mocks.
.PARAMETER DefaultProfile
    Optional default profile name. If omitted, falls back to discovered DefaultProfile or 'Outlook'.
.PARAMETER Profiles
    Optional list of available Outlook profiles. If omitted, discovers profiles via Get-OutlookSystemContext.
.PARAMETER NonInteractive
    Headless automation mode: returns the effective default profile immediately without prompting.
.PARAMETER Prompt
    Custom prompt prefix to display to the user. Defaults to '  Select Target Outlook Profile'.
.OUTPUTS
    [string] Selected Outlook profile name.
#>
function Select-ToolkitOutlookProfile {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$DefaultProfile,

        [Parameter(Mandatory = $false)]
        [string[]]$Profiles,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,

        [Parameter(Mandatory = $false)]
        [string]$Prompt = "  Select Target Outlook Profile"
    )

    process {
        # 1. Telemetry & Profile Resolution
        $discoveredProfiles = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $Profiles -and $Profiles.Count -gt 0) {
            foreach ($p in $Profiles) {
                if (-not [string]::IsNullOrWhiteSpace($p) -and -not $discoveredProfiles.Contains($p.Trim())) {
                    $discoveredProfiles.Add($p.Trim())
                }
            }
        }

        $effectiveDefault = $DefaultProfile
        if (Get-Command -Name 'Get-OutlookSystemContext' -ErrorAction SilentlyContinue) {
            try {
                $sysCtx = Get-OutlookSystemContext
                if ($null -ne $sysCtx) {
                    if ($discoveredProfiles.Count -eq 0 -and $null -ne $sysCtx.Profiles) {
                        foreach ($p in $sysCtx.Profiles) {
                            if (-not [string]::IsNullOrWhiteSpace($p) -and -not $discoveredProfiles.Contains($p.Trim())) {
                                $discoveredProfiles.Add($p.Trim())
                            }
                        }
                    }
                    if ([string]::IsNullOrWhiteSpace($effectiveDefault) -and -not [string]::IsNullOrWhiteSpace($sysCtx.DefaultProfile) -and $sysCtx.DefaultProfile -ne 'None') {
                        $effectiveDefault = $sysCtx.DefaultProfile.Trim()
                    }
                }
            }
            catch {
                $null = $_
            }
        }

        if ([string]::IsNullOrWhiteSpace($effectiveDefault)) {
            if ($discoveredProfiles.Count -gt 0) {
                $effectiveDefault = $discoveredProfiles[0]
            }
            else {
                $effectiveDefault = 'Outlook'
            }
        }

        if ($discoveredProfiles.Count -eq 0) {
            $discoveredProfiles.Add($effectiveDefault)
        }

        # 2. Instant Non-Interactive & Headless Safeguard
        if ($NonInteractive -or $env:ITOOLKIT_NONINTERACTIVE -eq '1') {
            return $effectiveDefault
        }

        # 3. Interactive Numeric Presentation
        $customOpt = $discoveredProfiles.Count + 1
        Write-Host ""
        Write-Host "  Available Outlook Profiles:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $discoveredProfiles.Count; $i++) {
            $idx = $i + 1
            $profName = $discoveredProfiles[$i]
            $tag = ""
            if ($profName -eq $effectiveDefault) {
                $tag = " [DEFAULT]"
            }
            Write-Host "    [$idx] $profName$tag" -ForegroundColor Gray
        }
        Write-Host "    [$customOpt] Specify custom profile name..." -ForegroundColor Gray
        Write-Host ""

        # 4. Input Evaluation & Selection Dispatch
        $promptText = "$Prompt [1-$($discoveredProfiles.Count), $customOpt for custom, or Enter for '$effectiveDefault']"
        $rawChoice = Read-Host -Prompt $promptText

        if ($null -eq $rawChoice) {
            return $effectiveDefault
        }

        $trimmed = $rawChoice.Trim()
        if ([string]::IsNullOrEmpty($trimmed)) {
            return $effectiveDefault
        }

        # Check numeric selection [1..N] or [N+1]
        $choiceNum = 0
        if ([int]::TryParse($trimmed, [ref]$choiceNum)) {
            if ($choiceNum -ge 1 -and $choiceNum -le $discoveredProfiles.Count) {
                return $discoveredProfiles[$choiceNum - 1]
            }
            elseif ($choiceNum -eq $customOpt) {
                $customPrompt = "  Enter custom Outlook profile name (Default: $effectiveDefault)"
                $customInput = Read-Host -Prompt $customPrompt
                if (-not [string]::IsNullOrWhiteSpace($customInput)) {
                    return $customInput.Trim()
                }
                return $effectiveDefault
            }
            else {
                # Out-of-bounds numeric choice fallback
                foreach ($p in $discoveredProfiles) {
                    if ($p -ieq $trimmed) {
                        return $p
                    }
                }
                return $effectiveDefault
            }
        }

        # 5. String Input Fallback for Direct Profile Name & Mock Compatibility
        foreach ($p in $discoveredProfiles) {
            if ($p -ieq $trimmed) {
                return $p
            }
        }

        # If direct string input provided does not match list, return trimmed custom input
        return $trimmed
    }
}
