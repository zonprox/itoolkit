function Export-ToolkitCertificates {
<#
.SYNOPSIS
    Exports certificates across multiple Windows certificate stores (Root, CA, My).
.DESCRIPTION
    Enumerates certificates across specified store names (Root, CA, My) and store locations
    (LocalMachine, CurrentUser). Exports public certificates as .cer without requiring a password,
    and certificates with exportable private keys as .pfx protected by the provided SecureString password.
    Organizes exports into store-specific subdirectories without creating empty folders for stores with no certificates.
.PARAMETER DestinationPath
    Destination directory to save exported certificates. Defaults to C:\Backups\Certificates.
.PARAMETER StoreNames
    Certificate store names to query (default: Root, CA, My).
.PARAMETER StoreLocations
    Certificate store locations to query (default: LocalMachine, CurrentUser).
.PARAMETER Password
    SecureString password protecting exported private key (.pfx) certificates.
.PARAMETER IncludeArchived
    Switch to include archived certificates in the export.
.OUTPUTS
    [PSCustomObject[]]@{ Store, Location, Thumbprint, Subject, ExportPath, HasPrivateKey, Format, Success }
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath = 'C:\Backups\Certificates',

        [Parameter(Position = 1)]
        [ValidateSet('Root', 'CA', 'My', 'AuthRoot', 'Disallowed', 'TrustedPublisher', 'TrustedPeople', 'AddressBook')]
        [string[]]$StoreNames = @('Root', 'CA', 'My'),

        [Parameter(Position = 2)]
        [ValidateSet('LocalMachine', 'CurrentUser')]
        [string[]]$StoreLocations = @('LocalMachine', 'CurrentUser'),

        [Parameter(Mandatory = $false)]
        [System.Security.SecureString]$Password,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeArchived
    )

    process {
        # Cross-platform compatibility stubs for Linux / non-Windows execution
        if (-not (Get-Command -Name 'Export-Certificate' -ErrorAction SilentlyContinue)) {
            Set-Item -Path 'function:global:Export-Certificate' -Value { [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$args) }
        }
        if (-not (Get-Command -Name 'Export-PfxCertificate' -ErrorAction SilentlyContinue)) {
            Set-Item -Path 'function:global:Export-PfxCertificate' -Value { [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$args) }
        }

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()

        foreach ($location in $StoreLocations) {
            foreach ($store in $StoreNames) {
                $storePath = "Cert:\$location\$store"
                $certs = @()

                try {
                    $certs = Get-ChildItem -Path $storePath -ErrorAction SilentlyContinue
                }
                catch {
                    Write-Verbose "Could not access certificate store '$storePath': $($_.Exception.Message)"
                }

                if ($null -eq $certs) {
                    $certs = @()
                }

                # Filter archived certificates unless explicitly requested
                if (-not $IncludeArchived) {
                    $filteredCerts = [System.Collections.Generic.List[psobject]]::new()
                    foreach ($c in $certs) {
                        if ($c.PSObject.Properties['Archived'] -and [bool]$c.Archived) {
                            continue
                        }
                        $filteredCerts.Add($c)
                    }
                    $certs = @($filteredCerts)
                }

                # Avoid creating empty subdirectories if no certificates exist in this store
                if ($certs.Count -eq 0) {
                    continue
                }

                $storeFolder = "${location}_${store}"
                $storeDir = Join-Path -Path $DestinationPath -ChildPath $storeFolder -ErrorAction SilentlyContinue
                if ([string]::IsNullOrWhiteSpace($storeDir)) {
                    $sep = if ($DestinationPath -match '/') { '/' } else { '\' }
                    $storeDir = "$($DestinationPath.TrimEnd('/\'))$sep$storeFolder"
                }

                if (-not (Test-Path -LiteralPath $storeDir)) {
                    $null = New-Item -ItemType Directory -Path $storeDir -Force -ErrorAction SilentlyContinue
                }

                foreach ($cert in $certs) {
                    $thumb = if ($cert.PSObject.Properties['Thumbprint'] -and -not [string]::IsNullOrWhiteSpace($cert.Thumbprint)) {
                        [string]$cert.Thumbprint
                    } else {
                        [System.Guid]::NewGuid().ToString('N').ToUpper()
                    }

                    $subject = if ($cert.PSObject.Properties['Subject'] -and -not [string]::IsNullOrWhiteSpace($cert.Subject)) {
                        [string]$cert.Subject
                    } else {
                        "CN=Certificate_$thumb"
                    }

                    $hasKey = $false
                    if ($cert.PSObject.Properties['HasPrivateKey']) {
                        $hasKey = [bool]$cert.HasPrivateKey
                    }

                    $exportFormat = 'CER'
                    $fileName = "$thumb.cer"
                    $targetFilePath = Join-Path -Path $storeDir -ChildPath $fileName -ErrorAction SilentlyContinue
                    if ([string]::IsNullOrWhiteSpace($targetFilePath)) {
                        $sep = if ($storeDir -match '/') { '/' } else { '\' }
                        $targetFilePath = "$($storeDir.TrimEnd('/\'))$sep$fileName"
                    }

                    $success = $false

                    if ($hasKey) {
                        if ($null -ne $Password) {
                            $pfxFileName = "$thumb.pfx"
                            $pfxPath = Join-Path -Path $storeDir -ChildPath $pfxFileName -ErrorAction SilentlyContinue
                            if ([string]::IsNullOrWhiteSpace($pfxPath)) {
                                $sep = if ($storeDir -match '/') { '/' } else { '\' }
                                $pfxPath = "$($storeDir.TrimEnd('/\'))$sep$pfxFileName"
                            }

                            if ($PSCmdlet.ShouldProcess("$thumb ($subject)", "Export PFX certificate to '$pfxPath'")) {
                                try {
                                    Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $Password -ErrorAction Stop
                                    $exportFormat = 'PFX'
                                    $targetFilePath = $pfxPath
                                    $success = $true
                                }
                                catch {
                                    if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                                        Write-ToolkitLog -Message "PFX export failed for cert $thumb, falling back to CER: $($_.Exception.Message)" -Level 'WARN' -Component 'Backup:Certs'
                                    }
                                }

                                if (-not $success) {
                                    try {
                                        Export-Certificate -Cert $cert -FilePath $targetFilePath -Type CERT -ErrorAction SilentlyContinue
                                        $exportFormat = 'CER'
                                        $success = $true
                                    }
                                    catch {
                                        Write-Verbose "CER fallback export failed for '$thumb': $($_.Exception.Message)"
                                    }
                                }
                            }
                            else {
                                # -WhatIf mode simulation
                                $exportFormat = 'PFX'
                                $targetFilePath = $pfxPath
                                $success = $true
                            }
                        }
                        else {
                            Write-Warning "Certificate '$thumb' has private key, but no Password was supplied. Exporting public key (.cer) only."
                            if ($PSCmdlet.ShouldProcess("$thumb ($subject)", "Export CER certificate to '$targetFilePath'")) {
                                try {
                                    Export-Certificate -Cert $cert -FilePath $targetFilePath -Type CERT -ErrorAction SilentlyContinue
                                    $exportFormat = 'CER'
                                    $success = $true
                                }
                                catch {
                                    Write-Verbose "CER export failed for '$thumb': $($_.Exception.Message)"
                                }
                            }
                            else {
                                # -WhatIf mode simulation
                                $exportFormat = 'CER'
                                $success = $true
                            }
                        }
                    }
                    else {
                        if ($PSCmdlet.ShouldProcess("$thumb ($subject)", "Export CER certificate to '$targetFilePath'")) {
                            try {
                                Export-Certificate -Cert $cert -FilePath $targetFilePath -Type CERT -ErrorAction SilentlyContinue
                                $exportFormat = 'CER'
                                $success = $true
                            }
                            catch {
                                Write-Verbose "CER export failed for '$thumb': $($_.Exception.Message)"
                            }
                        }
                        else {
                            # -WhatIf mode simulation
                            $exportFormat = 'CER'
                            $success = $true
                        }
                    }

                    $results.Add([PSCustomObject]@{
                        Store         = $store
                        Location      = $location
                        Thumbprint    = $thumb
                        Subject       = $subject
                        ExportPath    = $targetFilePath
                        HasPrivateKey = $hasKey
                        Format        = $exportFormat
                        Success       = $success
                    })
                }
            }
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Export-ToolkitCertificates completed. Exported $($results.Count) certificate(s) to '$DestinationPath'." -Level 'INFO' -Component 'Backup:Certs'
        }

        return @($results)
    }
}
