Set-StrictMode -Version Latest

# GENERIC_READ and GENERIC_EXECUTE have no FileSystemRights enum names.
[Int64]$safeFileSystemRightsMask =
    [Int64][Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
    [Int64][Security.AccessControl.FileSystemRights]::Synchronize -bor
    0x80000000L -bor
    0x20000000L
[Int64]$safeNonReplacingFileSystemRightsMask =
    $safeFileSystemRightsMask -bor
    [Int64][Security.AccessControl.FileSystemRights]::Delete -bor
    [Int64][Security.AccessControl.FileSystemRights]::
        DeleteSubdirectoriesAndFiles

function Test-MsiWriteCapableFileSystemRights {
    param(
        [Parameter(Mandatory = $true)]
        [Security.AccessControl.FileSystemRights]$Rights
    )

    # FileSystemRights omits names for the raw GENERIC_* access-mask bits and
    # represents GENERIC_READ as a negative enum value. Normalize to the native
    # 32-bit mask and fail closed on everything except read/execute/synchronize.
    [Int64]$normalizedRights = [Int64]$Rights -band 0xffffffffL
    return (
        ($normalizedRights -band $safeFileSystemRightsMask) -ne
        $normalizedRights)
}

function Test-MsiReplacementCapableFileSystemRights {
    param(
        [Parameter(Mandatory = $true)]
        [Security.AccessControl.FileSystemRights]$Rights
    )

    # A delete-only ACE can make an entry unavailable, but cannot replace it
    # when its parent is protected against untrusted entry creation. Keep that
    # distinction separate from the stricter write-capable classifier.
    [Int64]$normalizedRights = [Int64]$Rights -band 0xffffffffL
    return (
        ($normalizedRights -band $safeNonReplacingFileSystemRightsMask) -ne
        $normalizedRights)
}

function Test-MsiSecurityDescriptorHasNonNullDacl {
    param(
        [Parameter(Mandatory = $true)]
        [Security.AccessControl.FileSystemSecurity]$Security
    )

    try {
        $binaryDescriptor = $Security.GetSecurityDescriptorBinaryForm()
        $rawDescriptor =
            [Security.AccessControl.RawSecurityDescriptor]::new(
                $binaryDescriptor,
                0)
        return (
            ($rawDescriptor.ControlFlags -band
                [Security.AccessControl.ControlFlags]::
                    DiscretionaryAclPresent) -ne 0 -and
            $null -ne $rawDescriptor.DiscretionaryAcl)
    }
    catch {
        return $false
    }
}

Export-ModuleMember -Function @(
    'Test-MsiReplacementCapableFileSystemRights',
    'Test-MsiSecurityDescriptorHasNonNullDacl',
    'Test-MsiWriteCapableFileSystemRights'
)
