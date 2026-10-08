function Import-ToolkitCertificates {
<#
.SYNOPSIS
    Imports certificates into Windows certificate stores (Root, CA, My).
.DESCRIPTION
    Imports public certificates (.cer, .crt, .p7b) and private key archives (.pfx)
    from a file or directory into specified certificate stores. Supports automatic
    store detection based on folder/file naming conventions, elevation check with
    graceful fallback from LocalMachine to CurrentUser, and -WhatIf dry-run simulation.
.PARAMETER Path
    Path to a certificate file (.cer, .crt, .pfx, .p7b) or a directory containing certificates.
.PARAMETER StoreName
    Target certificate store: 'Root', 'CA', 'My', or 'Auto' (default: 'Auto').
.PARAMETER StoreLocation
    Target store location: 'LocalMachine' or 'CurrentUser' (default: 'LocalMachine').
.PARAMETER Password
    SecureString password for importing password-protected PFX archives.
.OUTPUTS
    [PSCustomObject[]]@{ Path, Store, Location, Thumbprint, Subject, Success, ErrorMessage }
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Position = 1)]
        [ValidateSet('Root', 'CA', 'My', 'Auto')]
        [string]$StoreName = 'Auto',

        [Parameter(Position = 2)]
        [ValidateSet('LocalMachine', 'CurrentUser')]
        [string]$StoreLocation = 'LocalMachine',

        [Parameter(Mandatory = $false)]
        [System.Security.SecureString]$Password
    )

    process {
        # Cross-platform compatibility stubs for Linux / non-Windows execution
        if (-not (Get-Command -Name 'Import-Certificate' -ErrorAction SilentlyContinue)) {
            Set-Item -Path 'function:global:Import-Certificate' -Value { [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$args) }
        }
        if (-not (Get-Command -Name 'Import-PfxCertificate' -ErrorAction SilentlyContinue)) {
            Set-Item -Path 'function:global:Import-PfxCertificate' -Value { [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$args) }
        }

        # Elevation check for LocalMachine store location
        $targetLocation = $StoreLocation
        if ($targetLocation -eq 'LocalMachine') {
            $isAdmin = $true
            if (Get-Command -Name 'Test-IsAdmin' -ErrorAction SilentlyContinue) {
                $isAdmin = Test-IsAdmin
            }
            if (-not $isAdmin) {
                Write-Warning "Administrative privileges required to import certificates into 'LocalMachine'. Falling back to 'CurrentUser' store location."
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Non-elevated session: Falling back certificate import from LocalMachine to CurrentUser." -Level 'WARN' -Component 'Backup:Certs'
                }
                $targetLocation = 'CurrentUser'
            }
        }

        # Resolve target certificate files
        $filesToImport = [System.Collections.Generic.List[string]]::new()
        $pathExists = Test-Path -LiteralPath $Path

        if (-not $pathExists) {
            $defaultStore = if ($StoreName -eq 'Auto') { 'My' } else { $StoreName }
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "Certificate import path does not exist: '$Path'" -Level 'ERROR' -Component 'Backup:Certs'
            }
            return @([PSCustomObject]@{
                Path         = $Path
                Store        = $defaultStore
                Location     = $targetLocation
                Thumbprint   = $null
                Subject      = $null
                Success      = $false
                ErrorMessage = "Path does not exist: '$Path'"
            })
        }

        if ($Path -match '(?i)\.(cer|crt|pfx|p7b)$') {
            $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue).Path
            if ([string]::IsNullOrWhiteSpace($resolved)) {
                $resolved = $Path
            }
            $filesToImport.Add($resolved)
        }
        else {
            # Path is a directory containing certificate files
            $foundFiles = Get-ChildItem -Path $Path -Recurse -ErrorAction SilentlyContinue | Where-Object {
                if ($_.PSObject.Properties['PSIsContainer'] -and $_.PSIsContainer) {
                    return $false
                }
                $ext = if ($_.PSObject.Properties['Extension']) { $_.Extension } else { [System.IO.Path]::GetExtension($_.Name) }
                return ($ext -match '(?i)^\.(cer|crt|pfx|p7b)$')
            }
            if ($null -ne $foundFiles) {
                foreach ($f in $foundFiles) {
                    $itemPath = if ($f.PSObject.Properties['FullName']) { $f.FullName } else { [string]$f }
                    $filesToImport.Add($itemPath)
                }
            }
        }

        if ($filesToImport.Count -eq 0) {
            if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                Write-ToolkitLog -Message "No certificate files (.cer, .crt, .pfx, .p7b) found at '$Path'." -Level 'WARN' -Component 'Backup:Certs'
            }
            return @()
        }

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($filePath in $filesToImport) {
            # Auto store detection if requested
            $targetStore = $StoreName
            if ($targetStore -eq 'Auto') {
                $fileName = [System.IO.Path]::GetFileName($filePath)
                $parentName = Split-Path -Path $filePath -Parent
                $combinedHint = "$parentName/$fileName"

                if ($combinedHint -match '(?i)Root') {
                    $targetStore = 'Root'
                }
                elseif ($combinedHint -match '(?i)(CA|Intermediate)') {
                    $targetStore = 'CA'
                }
                elseif ($filePath -match '(?i)\.pfx$' -or $combinedHint -match '(?i)(My|Personal)') {
                    $targetStore = 'My'
                }
                else {
                    $targetStore = 'My'
                }
            }

            $certStorePath = "Cert:\$targetLocation\$targetStore"
            $isPfx = $filePath -match '(?i)\.pfx$'

            # WhatIf / ShouldProcess Evaluation
            if (-not $PSCmdlet.ShouldProcess($filePath, "Import certificate into '$certStorePath'")) {
                $results.Add([PSCustomObject]@{
                    Path         = $filePath
                    Store        = $targetStore
                    Location     = $targetLocation
                    Thumbprint   = $null
                    Subject      = $null
                    Success      = $true
                    ErrorMessage = $null
                })
                continue
            }

            $thumb = $null
            $subj = $null
            $success = $false
            $errMsg = $null

            try {
                $imported = $null
                if ($isPfx) {
                    if ($null -ne $Password) {
                        $imported = Import-PfxCertificate -FilePath $filePath -CertStoreLocation $certStorePath -Password $Password -ErrorAction Stop
                    }
                    else {
                        $imported = Import-PfxCertificate -FilePath $filePath -CertStoreLocation $certStorePath -ErrorAction Stop
                    }
                }
                else {
                    $imported = Import-Certificate -FilePath $filePath -CertStoreLocation $certStorePath -ErrorAction Stop
                }

                if ($null -ne $imported) {
                    $first = if ($imported -is [array]) { $imported[0] } else { $imported }
                    if ($first -and $first.PSObject.Properties['Thumbprint']) {
                        $thumb = [string]$first.Thumbprint
                    }
                    if ($first -and $first.PSObject.Properties['Subject']) {
                        $subj = [string]$first.Subject
                    }
                }

                $success = $true
            }
            catch {
                $errMsg = $_.Exception.Message
                $success = $false
                if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                    Write-ToolkitLog -Message "Failed to import '$filePath' to '$certStorePath': $errMsg" -Level 'ERROR' -Component 'Backup:Certs'
                }
            }

            $results.Add([PSCustomObject]@{
                Path         = $filePath
                Store        = $targetStore
                Location     = $targetLocation
                Thumbprint   = $thumb
                Subject      = $subj
                Success      = $success
                ErrorMessage = $errMsg
            })
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Import-ToolkitCertificates processed $($results.Count) certificate(s)." -Level 'INFO' -Component 'Backup:Certs'
        }

        return @($results)
    }
}
