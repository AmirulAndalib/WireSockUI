$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module `
    (Join-Path $PSScriptRoot 'MsiTest.KnownFolders.psm1') `
    -Force

$commonProgramsFolderId = Get-MsiCommonProgramsFolderId
if ($commonProgramsFolderId -ne
    [Guid]'0139D44E-6AFE-49F2-8690-3DAFCAE6FFB8') {
    throw 'The MSI common Programs known-folder identifier has drifted.'
}
if ($commonProgramsFolderId -eq
    [Guid]'A77F5D77-2E2B-44C3-A6A2-ABA601054A51') {
    throw 'The MSI common Programs identifier resolves the per-user folder.'
}

$commonPrograms = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::CommonPrograms)
$currentUserPrograms = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::Programs)
$currentUserProfile = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::UserProfile)
if ([string]::IsNullOrWhiteSpace($commonPrograms) -or
    [string]::IsNullOrWhiteSpace($currentUserPrograms) -or
    [string]::IsNullOrWhiteSpace($currentUserProfile)) {
    throw 'Windows did not resolve the Programs known-folder contract.'
}

$resolvedCommonPrograms = [IO.Path]::GetFullPath($commonPrograms)
$resolvedCurrentUserPrograms = [IO.Path]::GetFullPath($currentUserPrograms)
$normalizedUserProfile = [IO.Path]::GetFullPath(
    $currentUserProfile).TrimEnd('\', '/') + '\'
if ([string]::Equals(
        $resolvedCommonPrograms,
        $resolvedCurrentUserPrograms,
        [StringComparison]::OrdinalIgnoreCase) -or
    $resolvedCommonPrograms.StartsWith(
        $normalizedUserProfile,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw "The common Programs path '$resolvedCommonPrograms' is user-scoped."
}

Write-Output 'Validated the machine-wide MSI Programs known-folder contract.'
