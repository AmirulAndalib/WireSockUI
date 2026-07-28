$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module `
    (Join-Path $PSScriptRoot 'MsiTest.AccessControl.psm1') `
    -Force

foreach ($rights in @(
        [Security.AccessControl.FileSystemRights]::Read,
        [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        [Security.AccessControl.FileSystemRights]::ExecuteFile,
        [Security.AccessControl.FileSystemRights]::Synchronize)) {
    if (Test-MsiWriteCapableFileSystemRights -Rights $rights) {
        throw "Read-only filesystem rights '$rights' were classified as writable."
    }
}

foreach ($rights in @(
        [Security.AccessControl.FileSystemRights]::Write,
        [Security.AccessControl.FileSystemRights]::WriteData,
        [Security.AccessControl.FileSystemRights]::AppendData,
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes,
        [Security.AccessControl.FileSystemRights]::WriteAttributes,
        [Security.AccessControl.FileSystemRights]::Modify,
        [Security.AccessControl.FileSystemRights]::Delete,
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles,
        [Security.AccessControl.FileSystemRights]::ChangePermissions,
        [Security.AccessControl.FileSystemRights]::TakeOwnership,
        [Security.AccessControl.FileSystemRights]::FullControl)) {
    if (-not (Test-MsiWriteCapableFileSystemRights -Rights $rights)) {
        throw "Mutation-capable filesystem rights '$rights' were classified as read-only."
    }
}

Write-Output 'Validated MSI filesystem-rights classification.'
