Set-StrictMode -Version Latest

function Get-MsiCommonProgramsFolderId {
    # FOLDERID_CommonPrograms is the machine-wide Start Menu Programs folder.
    return [Guid]'0139D44E-6AFE-49F2-8690-3DAFCAE6FFB8'
}

Export-ModuleMember -Function Get-MsiCommonProgramsFolderId
