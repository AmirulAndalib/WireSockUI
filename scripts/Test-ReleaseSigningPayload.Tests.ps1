[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptUnderTest = Join-Path $PSScriptRoot 'Test-ReleaseSigningPayload.ps1'
$testRoot = Join-Path (
    [IO.Path]::GetTempPath()
) ("WireSockUI-ReleaseSigning-{0}" -f [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot)

# Fixture files are intentionally tiny non-PE placeholders. The inventory tests
# exercise scope and mutation handling; release signature semantics are covered by
# Test-ReleaseSignature.ps1 against real PE/MSI files.
function global:Get-AuthenticodeSignature {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath
    )

    [pscustomobject]@{
        Path = $FilePath
        Status = [Management.Automation.SignatureStatus]::NotSigned
    }
}

function Write-TestFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    $parent = Split-Path -Parent $Path
    [void](New-Item -ItemType Directory -Path $parent -Force)
    Set-Content -LiteralPath $Path -Value $Value -Encoding ascii
}

function New-BootstrapFixture {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root
    )

    foreach ($architecture in @('x86', 'x64', 'ARM64')) {
        foreach ($flavor in @('no-uwp', 'uwp')) {
            $payload = Join-Path $Root "unsigned-WireSockUI-v1.2.3-$architecture-$flavor"
            Write-TestFile -Path (Join-Path $payload 'WireSockUI.exe') -Value "$architecture-$flavor-launcher"
            Write-TestFile -Path (Join-Path $payload 'WireSockUI.Managed.dll') -Value "$architecture-$flavor-managed"
            Write-TestFile -Path (Join-Path $payload 'WireSockUI.exe.config') -Value '<configuration />'
        }
    }
}

function New-MsiFixture {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root
    )

    [void](New-Item -ItemType Directory -Path $Root)
    foreach ($architecture in @('x86', 'x64', 'arm64')) {
        foreach ($flavor in @('no-uwp', 'uwp')) {
            $msi = Join-Path $Root "WireSockUI-1.2.3-win-$architecture-$flavor.msi"
            Write-TestFile -Path $msi -Value "$architecture-$flavor-msi"
            Write-TestFile -Path "$msi.validation.json" -Value '{}'
        }
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock] $Action,

        [Parameter(Mandatory = $true)]
        [string] $ExpectedMessage
    )

    try {
        & $Action
        throw "Expected failure containing '$ExpectedMessage', but the command succeeded."
    }
    catch {
        if ($_.Exception.Message -notlike "*$ExpectedMessage*") {
            throw "Expected failure containing '$ExpectedMessage', got '$($_.Exception.Message)'."
        }
    }
}

try {
    $bootstrapRoot = Join-Path $testRoot 'bootstrap'
    [void](New-Item -ItemType Directory -Path $bootstrapRoot)
    New-BootstrapFixture -Root $bootstrapRoot
    $bootstrapInventory = Join-Path $testRoot 'bootstrap-inventory.json'
    $bootstrapCatalog = Join-Path $testRoot 'bootstrap-catalog.txt'
    $null = & $scriptUnderTest `
        -Mode Snapshot `
        -Kind Bootstrap `
        -RootDirectory $bootstrapRoot `
        -Version 1.2.3 `
        -InventoryPath $bootstrapInventory `
        -SigningCatalogPath $bootstrapCatalog

    $inventory = Get-Content -LiteralPath $bootstrapInventory -Raw |
        ConvertFrom-Json
    if (@($inventory.SigningTargets).Count -ne 6 -or
        @($inventory.Entries).Count -ne 24) {
        throw 'Bootstrap snapshot did not contain the expected exact target and entry counts.'
    }
    $catalog = @(Get-Content -LiteralPath $bootstrapCatalog)
    if ($catalog.Count -ne 6 -or
        @($catalog | Where-Object {
                [IO.Path]::IsPathRooted($_) -or $_ -match '(^|[\\/])\.\.([\\/]|$)'
            }).Count -ne 0) {
        throw 'Bootstrap signing catalog was not a safe six-item relative-path catalog.'
    }

    Write-TestFile `
        -Path (Join-Path $bootstrapRoot 'unsigned-WireSockUI-v1.2.3-x64-uwp/nested/WireSockUI.exe') `
        -Value 'unexpected'
    Assert-Throws `
        -Action {
            & $scriptUnderTest `
                -Mode Snapshot `
                -Kind Bootstrap `
                -RootDirectory $bootstrapRoot `
                -Version 1.2.3 `
                -InventoryPath (Join-Path $testRoot 'unexpected-inventory.json') `
                -SigningCatalogPath (Join-Path $testRoot 'unexpected-catalog.txt')
        } `
        -ExpectedMessage 'exact six-item'

    $msiRoot = Join-Path $testRoot 'msis'
    New-MsiFixture -Root $msiRoot
    $msiInventory = Join-Path $testRoot 'msi-inventory.json'
    $msiCatalog = Join-Path $testRoot 'msi-catalog.txt'
    $null = & $scriptUnderTest `
        -Mode Snapshot `
        -Kind Msi `
        -RootDirectory $msiRoot `
        -Version 1.2.3 `
        -InventoryPath $msiInventory `
        -SigningCatalogPath $msiCatalog
    if (@(Get-Content -LiteralPath $msiCatalog).Count -ne 6) {
        throw 'MSI signing catalog did not contain exactly six targets.'
    }

    Write-TestFile `
        -Path (Join-Path $msiRoot 'unexpected.txt') `
        -Value 'unexpected'
    Assert-Throws `
        -Action {
            & $scriptUnderTest `
                -Mode Verify `
                -Kind Msi `
                -RootDirectory $msiRoot `
                -Version 1.2.3 `
                -InventoryPath $msiInventory `
                -SigningCatalogPath $msiCatalog `
                -ExpectedSignerSubject 'CN=Fixture' `
                -ExpectedTimestampSubject 'CN=Fixture Timestamp'
        } `
        -ExpectedMessage 'exactly six MSIs'

    Write-Output 'Release signing payload tests passed.'
}
finally {
    Remove-Item -LiteralPath Function:\Get-AuthenticodeSignature -Force
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedTestRoot.StartsWith(
            $resolvedTempRoot,
            [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTestRoot) -match '^WireSockUI-ReleaseSigning-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
