Set-StrictMode -Version Latest

# GENERIC_READ and GENERIC_EXECUTE have no FileSystemRights enum names.
[Int64]$safeFileSystemRightsMask =
    [Int64][Security.AccessControl.FileSystemRights]::ReadAndExecute -bor
    [Int64][Security.AccessControl.FileSystemRights]::Synchronize -bor
    0x80000000L -bor
    0x20000000L

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

Export-ModuleMember -Function Test-MsiWriteCapableFileSystemRights
