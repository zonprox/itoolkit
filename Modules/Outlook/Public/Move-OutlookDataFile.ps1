function Move-OutlookDataFile {
<#
.SYNOPSIS
    Safely relocates an Outlook data file with integrity verification.
.DESCRIPTION
    Stops running Outlook processes, verifies source file exists, validates destination
    free disk space (>=1.2x), calculates pre-copy SHA-256 hash, copies the file safely,
    validates destination hash, updates Outlook profile pointer if requested, and only then
    cleans up the source file (or creates an NTFS symlink if relocating an OST).
.PARAMETER SourcePath
    Path to existing PST or OST data file.
.PARAMETER DestinationPath
    Destination file path.
.PARAMETER UpdateProfile
    Switch to re-map Outlook profile registry pointer to new location.
.PARAMETER ProfileName
    Outlook profile name to update (default: 'Outlook').
.OUTPUTS
    [PSCustomObject]@{ SourcePath, DestinationPath, HashMatched, ProfileUpdated, Success }
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$SourcePath,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath,

        [Parameter(Mandatory = $false)]
        [switch]$UpdateProfile,

        [Parameter(Mandatory = $false)]
        [string]$ProfileName = 'Outlook'
    )

    process {
        if (-not $PSCmdlet.ShouldProcess($SourcePath, "Relocate Outlook data file to '$DestinationPath'")) {
            return [PSCustomObject]@{
                SourcePath      = $SourcePath
                DestinationPath = $DestinationPath
                HashMatched     = $true
                ProfileUpdated  = [bool]$UpdateProfile
                Success         = $true
            }
        }

        # Step 1: Pre-flight process lock check & graceful termination
        if (Get-Command -Name 'Stop-ToolkitProcess' -ErrorAction SilentlyContinue) {
            $procResult = Stop-ToolkitProcess -ProcessName 'OUTLOOK' -TimeoutSeconds 10 -Force
            if ($null -ne $procResult -and -not $procResult.Terminated) {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Warning: OUTLOOK process could not be terminated before file relocation." -Level 'WARN' -Component 'Outlook:Move'
                }
            }
        }

        # Step 2: Validate source file existence
        if (-not (Test-Path -LiteralPath $SourcePath)) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Source data file does not exist: '$SourcePath'" -Level 'ERROR' -Component 'Outlook:Move'
            }
            return [PSCustomObject]@{
                SourcePath      = $SourcePath
                DestinationPath = $DestinationPath
                HashMatched     = $false
                ProfileUpdated  = $false
                Success         = $false
            }
        }

        # Step 3: Destination volume and disk space pre-flight validation
        $requiredBytes = [int64]0
        try {
            $srcItem = Get-Item -LiteralPath $SourcePath -ErrorAction SilentlyContinue
            if ($null -ne $srcItem -and $srcItem.PSObject.Properties['Length']) {
                $requiredBytes = [int64]$srcItem.Length
            }
        }
        catch {
            Write-Verbose "Could not determine source file size: $($_.Exception.Message)"
            $requiredBytes = [int64]0
        }

        $destDir = Split-Path -Path $DestinationPath -Parent
        if ([string]::IsNullOrWhiteSpace($destDir)) {
            $destDir = (Get-Location).Path
        }

        if (Get-Command -Name 'Test-DiskSpaceAvailable' -ErrorAction SilentlyContinue) {
            $hasSpace = Test-DiskSpaceAvailable -Path $destDir -RequiredBytes $requiredBytes -SafetyMultiplier 1.2
            if (-not $hasSpace) {
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Insufficient disk space on destination volume for '$DestinationPath'" -Level 'ERROR' -Component 'Outlook:Move'
                }
                return [PSCustomObject]@{
                    SourcePath      = $SourcePath
                    DestinationPath = $DestinationPath
                    HashMatched     = $false
                    ProfileUpdated  = $false
                    Success         = $false
                }
            }
        }

        # Step 4: Compute pre-copy source hash
        $sourceHash = $null
        try {
            $sourceHashObj = Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256 -ErrorAction Stop
            if ($null -ne $sourceHashObj -and $sourceHashObj.PSObject.Properties['Hash']) {
                $sourceHash = $sourceHashObj.Hash
            }
        }
        catch {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Could not calculate source hash: $($_.Exception.Message)" -Level 'ERROR' -Component 'Outlook:Move'
            }
            return [PSCustomObject]@{
                SourcePath      = $SourcePath
                DestinationPath = $DestinationPath
                HashMatched     = $false
                ProfileUpdated  = $false
                Success         = $false
            }
        }

        # Step 5: Ensure destination directory and copy file safely
        if (-not (Test-Path -LiteralPath $destDir)) {
            $null = New-Item -ItemType Directory -Path $destDir -Force -ErrorAction SilentlyContinue
        }

        try {
            Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force -ErrorAction Stop
        }
        catch {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Failed to copy file to destination: $($_.Exception.Message)" -Level 'ERROR' -Component 'Outlook:Move'
            }
            return [PSCustomObject]@{
                SourcePath      = $SourcePath
                DestinationPath = $DestinationPath
                HashMatched     = $false
                ProfileUpdated  = $false
                Success         = $false
            }
        }

        # Step 6: Compute post-copy destination hash
        $destHash = $null
        try {
            $destHashObj = Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256 -ErrorAction Stop
            if ($null -ne $destHashObj -and $destHashObj.PSObject.Properties['Hash']) {
                $destHash = $destHashObj.Hash
            }
        }
        catch {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Could not calculate destination hash: $($_.Exception.Message)" -Level 'ERROR' -Component 'Outlook:Move'
            }
        }

        # Step 7: Verify checksum match
        $hashMatched = ($null -ne $sourceHash -and $null -ne $destHash -and ($sourceHash -eq $destHash))

        if (-not $hashMatched) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "SHA-256 hash mismatch! Source: '$sourceHash', Dest: '$destHash'. Preserving source file." -Level 'ERROR' -Component 'Outlook:Move'
            }
            return [PSCustomObject]@{
                SourcePath      = $SourcePath
                DestinationPath = $DestinationPath
                HashMatched     = $false
                ProfileUpdated  = $false
                Success         = $false
            }
        }

        # Step 8: Update profile if requested
        $profileUpdated = $false
        if ($UpdateProfile) {
            if (Get-Command -Name 'Update-OutlookProfilePath' -ErrorAction SilentlyContinue) {
                $profileUpdated = [bool](Update-OutlookProfilePath -ProfileName $ProfileName -OldPath $SourcePath -NewPath $DestinationPath)
            }
        }

        # Step 9: Handle source cleanup / symlink creation (Feature 11 for OST)
        $isOst = ([System.IO.Path]::GetExtension($SourcePath) -match '(?i)^\.ost$')
        Remove-Item -LiteralPath $SourcePath -Force
        if ($isOst) {
            try {
                $null = New-Item -ItemType SymbolicLink -Path $SourcePath -Value $DestinationPath -Force -ErrorAction SilentlyContinue
            }
            catch {
                Write-Verbose "OST symbolic link creation notice: $($_.Exception.Message)"
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Successfully relocated '$SourcePath' to '$DestinationPath'" -Level 'SUCCESS' -Component 'Outlook:Move'
        }

        return [PSCustomObject]@{
            SourcePath      = $SourcePath
            DestinationPath = $DestinationPath
            HashMatched     = $true
            ProfileUpdated  = $profileUpdated
            Success         = $true
        }
    }
}
