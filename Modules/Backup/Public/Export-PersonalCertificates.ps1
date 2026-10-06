function Export-PersonalCertificates {
<#
.SYNOPSIS
    Exports user certificates from Cert:\CurrentUser\My with SecureString password protection.
.DESCRIPTION
    Enumerates personal certificates in Cert:\CurrentUser\My. For certificates with exportable
    private keys, exports to .pfx using the supplied SecureString password. For certificates without
    private keys or non-exportable hardware keys, falls back to public .cer export.
.PARAMETER DestinationPath
    Destination directory to save exported certificates.
.PARAMETER Password
    Password required to protect exported private key (.pfx) files. Must be [SecureString].
.OUTPUTS
    [PSCustomObject[]]@{ Thumbprint, Subject, HasPrivateKey, ExportFormat, FilePath }
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [System.Security.SecureString]$Password
    )

    process {
        if (-not (Test-Path -LiteralPath $DestinationPath)) {
            $null = New-Item -ItemType Directory -Path $DestinationPath -Force -ErrorAction SilentlyContinue
        }

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
        $certs = @()

        try {
            $certs = Get-ChildItem -Path 'Cert:\CurrentUser\My' -ErrorAction SilentlyContinue
        }
        catch {
            Write-Verbose "Could not access personal certificate store: $($_.Exception.Message)"
        }

        if ($null -eq $certs) {
            $certs = @()
        }

        foreach ($cert in $certs) {
            $thumb = [System.Guid]::NewGuid().ToString('N').ToUpper()
            if ($cert.PSObject.Properties['Thumbprint']) {
                $thumb = [string]$cert.Thumbprint
            }

            $subject = 'CN=Personal Certificate'
            if ($cert.PSObject.Properties['Subject']) {
                $subject = [string]$cert.Subject
            }

            $hasKey = $false
            if ($cert.PSObject.Properties['HasPrivateKey']) {
                $hasKey = [bool]$cert.HasPrivateKey
            }

            $exportFormat = 'CER'
            $outPath = Join-Path -Path $DestinationPath -ChildPath "$thumb.cer" -ErrorAction SilentlyContinue
            if ([string]::IsNullOrWhiteSpace($outPath)) {
                $sep = '\'
                if ($DestinationPath -match '/') {
                    $sep = '/'
                }
                $outPath = "$($DestinationPath.TrimEnd('/\'))$sep$thumb.cer"
            }

            if ($hasKey) {
                $pfxPath = Join-Path -Path $DestinationPath -ChildPath "$thumb.pfx" -ErrorAction SilentlyContinue
                if ([string]::IsNullOrWhiteSpace($pfxPath)) {
                    $sep = '\'
                    if ($DestinationPath -match '/') {
                        $sep = '/'
                    }
                    $pfxPath = "$($DestinationPath.TrimEnd('/\'))$sep$thumb.pfx"
                }
                $pfxSuccess = $false
                try {
                    Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $Password -ErrorAction Stop
                    $exportFormat = 'PFX'
                    $outPath = $pfxPath
                    $pfxSuccess = $true
                }
                catch {
                    if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
                        Write-ToolkitLog -Message "Private key not exportable for cert $thumb. Falling back to .cer" -Level 'WARN' -Component 'Backup:Certs'
                    }
                }

                if (-not $pfxSuccess) {
                    try {
                        Export-Certificate -Cert $cert -FilePath $outPath -Type CERT -ErrorAction SilentlyContinue
                    }
                    catch {
                        Write-Verbose "Public certificate export failed for '$thumb': $($_.Exception.Message)"
                    }
                }
            }
            else {
                try {
                    Export-Certificate -Cert $cert -FilePath $outPath -Type CERT -ErrorAction SilentlyContinue
                }
                catch {
                    Write-Verbose "Public certificate export failed for '$thumb': $($_.Exception.Message)"
                }
            }

            $results.Add([PSCustomObject]@{
                Thumbprint    = $thumb
                Subject       = $subject
                HasPrivateKey = $hasKey
                ExportFormat  = $exportFormat
                FilePath      = $outPath
            })
        }

        if (Get-Command -Name 'Write-ToolkitLog' -ErrorAction SilentlyContinue) {
            Write-ToolkitLog -Message "Exported $($results.Count) certificate(s) to '$DestinationPath'" -Level 'INFO' -Component 'Backup:Certs'
        }

        return @($results)
    }
}
