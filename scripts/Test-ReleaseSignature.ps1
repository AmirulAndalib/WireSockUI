[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]] $FilePath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $ExpectedSignerSubject,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $ExpectedTimestampSubject
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$codeSigningEku = '1.3.6.1.5.5.7.3.3'
$timestampSigningEku = '1.3.6.1.5.5.7.3.8'
$maximumSignedFileBytes = 1GB

function Assert-SafeExpectedSubject {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    if ($Value.Length -gt 4096 -or
        $Value.Trim() -cne $Value -or
        $Value.IndexOfAny([char[]]"`r`n") -ge 0) {
        throw "$Name must be a trimmed, single-line certificate subject."
    }
}

function Test-CertificateEku {
    param(
        [Parameter(Mandatory = $true)]
        [Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,

        [Parameter(Mandatory = $true)]
        [string] $RequiredOid
    )

    $ekuExtensions = @(
        $Certificate.Extensions |
            Where-Object {
                $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]
            }
    )
    if ($ekuExtensions.Count -ne 1) {
        return $false
    }

    return @(
        $ekuExtensions[0].EnhancedKeyUsages |
            Where-Object { $_.Value -ceq $RequiredOid }
    ).Count -eq 1
}

function Find-SignTool {
    $programFilesX86 = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::ProgramFilesX86)
    $windowsKitsBin = Join-Path $programFilesX86 'Windows Kits\10\bin'
    if (-not (Test-Path -LiteralPath $windowsKitsBin -PathType Container)) {
        throw 'signtool.exe is unavailable and the Windows 10 SDK bin directory was not found.'
    }

    $candidates = @(
        Get-ChildItem -LiteralPath $windowsKitsBin -Directory |
            ForEach-Object {
                $version = $null
                if (-not [Version]::TryParse($_.Name, [ref]$version)) {
                    return
                }
                $candidate = Join-Path $_.FullName 'x64\signtool.exe'
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    [pscustomobject]@{
                        Path = $candidate
                        Version = $version
                    }
                }
            } |
            Sort-Object Version -Descending
    )
    if ($candidates.Count -lt 1) {
        throw 'signtool.exe was not found in any installed Windows 10 SDK.'
    }

    $signToolFile = Get-Item -LiteralPath $candidates[0].Path -Force
    if (($signToolFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Windows SDK SignTool '$($signToolFile.FullName)' must not be a reparse point."
    }
    $signToolSignature = Get-AuthenticodeSignature -LiteralPath $signToolFile.FullName
    if ($signToolSignature.Status -ne
            [System.Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signToolSignature.SignerCertificate -or
        $signToolSignature.SignerCertificate.Subject -cnotmatch
            '(^|,\s*)O=Microsoft Corporation(,|$)') {
        throw "Windows SDK SignTool '$($signToolFile.FullName)' is not validly signed by Microsoft."
    }
    return $signToolFile.FullName
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Release signature validation requires Windows.'
}
Assert-SafeExpectedSubject -Name 'ExpectedSignerSubject' -Value $ExpectedSignerSubject
Assert-SafeExpectedSubject -Name 'ExpectedTimestampSubject' -Value $ExpectedTimestampSubject

$resolvedFiles =
    [Collections.Generic.Dictionary[string, IO.FileInfo]]::new(
        [StringComparer]::OrdinalIgnoreCase)
foreach ($path in $FilePath) {
    $resolvedPath = [IO.Path]::GetFullPath($path)
    $file = Get-Item -LiteralPath $resolvedPath -Force
    if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Signed release file '$resolvedPath' must not be a reparse point."
    }
    if ($file.Length -lt 1 -or $file.Length -gt $maximumSignedFileBytes) {
        throw "Signed release file '$resolvedPath' is empty or exceeds the $maximumSignedFileBytes-byte limit."
    }
    if ($resolvedFiles.ContainsKey($resolvedPath)) {
        throw "Signed release file '$resolvedPath' was supplied more than once."
    }
    $resolvedFiles.Add($resolvedPath, $file)
}
if ($resolvedFiles.Count -lt 1 -or $resolvedFiles.Count -gt 64) {
    throw 'Between one and 64 distinct signed release files must be supplied.'
}

$signTool = Find-SignTool
foreach ($file in $resolvedFiles.Values) {
    $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "Authenticode validation failed for '$($file.FullName)': $($signature.StatusMessage)"
    }
    if ([string]$signature.SignatureType -cne 'Authenticode') {
        throw "Release file '$($file.FullName)' must carry its own Authenticode signature, not a catalog-only signature."
    }
    if ($null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -cne $ExpectedSignerSubject) {
        $actualSubject = if ($null -eq $signature.SignerCertificate) {
            '<missing>'
        }
        else {
            $signature.SignerCertificate.Subject
        }
        throw "The signer for '$($file.FullName)' is '$actualSubject', not the protected expected identity."
    }
    if (-not (Test-CertificateEku `
            -Certificate $signature.SignerCertificate `
            -RequiredOid $codeSigningEku)) {
        throw "The signer for '$($file.FullName)' does not have the Code Signing EKU."
    }
    if ($null -eq $signature.TimeStamperCertificate -or
        $signature.TimeStamperCertificate.Subject -cne $ExpectedTimestampSubject) {
        $actualTimestampSubject = if ($null -eq $signature.TimeStamperCertificate) {
            '<missing>'
        }
        else {
            $signature.TimeStamperCertificate.Subject
        }
        throw "The RFC 3161 timestamp signer for '$($file.FullName)' is '$actualTimestampSubject', not the protected expected identity."
    }
    if (-not (Test-CertificateEku `
            -Certificate $signature.TimeStamperCertificate `
            -RequiredOid $timestampSigningEku)) {
        throw "The timestamp signer for '$($file.FullName)' does not have the Time Stamping EKU."
    }

    $verificationOutput = & $signTool verify /pa /all /v /tw $file.FullName 2>&1 |
        Out-String
    if ($LASTEXITCODE -ne 0 -or
        $verificationOutput -notmatch '(?im)^\s*Successfully verified:\s') {
        throw "SignTool verification failed for '$($file.FullName)':`n$verificationOutput"
    }
    if ($verificationOutput -match '(?im)^\s*(?:SignTool\s+)?Warning(?:s)?\b') {
        throw "SignTool reported a warning for '$($file.FullName)':`n$verificationOutput"
    }
    if ($verificationOutput -notmatch
            '(?im)^\s*Number of signatures successfully Verified:\s*1\s*$' -or
        $verificationOutput -notmatch '(?im)^\s*Number of warnings:\s*0\s*$' -or
        $verificationOutput -notmatch '(?im)^\s*Number of errors:\s*0\s*$') {
        throw "Release file '$($file.FullName)' must have exactly one warning-free Authenticode signature."
    }

    $digestMatches = @(
        [Text.RegularExpressions.Regex]::Matches(
            $verificationOutput,
            '(?im)^\s*Digest Algorithm:\s*(?<algorithm>[A-Za-z0-9-]+)\s*$')
    ) + @(
        [Text.RegularExpressions.Regex]::Matches(
            $verificationOutput,
            '(?im)^\s*Hash of file \((?<algorithm>[A-Za-z0-9-]+)\):\s*[0-9a-f]+\s*$')
    )
    if ($digestMatches.Count -lt 1 -or
        @(
            $digestMatches |
                Where-Object {
                    $_.Groups['algorithm'].Value -cne 'sha256'
                }
        ).Count -ne 0) {
        throw "Every Authenticode file digest for '$($file.FullName)' must use SHA-256."
    }

    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).
        Hash.ToLowerInvariant()
    Write-Output (
        "Validated release signature '$($file.Name)' " +
        "(signer '$ExpectedSignerSubject', timestamp '$ExpectedTimestampSubject', sha256 $hash).")
}
