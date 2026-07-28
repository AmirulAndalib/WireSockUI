Set-StrictMode -Version Latest

[Int64]$writeCapableFileSystemRightsMask =
    [Int64][Security.AccessControl.FileSystemRights]::Write -bor
    [Int64][Security.AccessControl.FileSystemRights]::Delete -bor
    [Int64][Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
    [Int64][Security.AccessControl.FileSystemRights]::ChangePermissions -bor
    [Int64][Security.AccessControl.FileSystemRights]::TakeOwnership

function Test-MsiWriteCapableFileSystemRights {
    param(
        [Parameter(Mandatory = $true)]
        [Security.AccessControl.FileSystemRights]$Rights
    )

    # FileSystemRights.Modify is deliberately not part of the mask: it is a
    # composite that includes ReadAndExecute. Its unsafe Write and Delete
    # components are already represented by the explicit mutation masks above.
    return (
        ([Int64]$Rights -band $writeCapableFileSystemRightsMask) -ne 0)
}

Export-ModuleMember -Function Test-MsiWriteCapableFileSystemRights
