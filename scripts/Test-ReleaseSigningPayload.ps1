[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Snapshot', 'Verify')]
    [string] $Mode,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Bootstrap', 'Msi')]
    [string] $Kind,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $RootDirectory,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z')]
    [string] $Version,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $InventoryPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $SigningCatalogPath,

    [Parameter()]
    [string] $ExpectedSignerSubject,

    [Parameter()]
    [string] $ExpectedTimestampSubject
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$maximumEntries = 4096
$maximumFileBytes = 512MB
$maximumAggregateBytes = 2GB
$maximumInventoryBytes = 8MB

function Assert-OrdinaryItem {
    param(
        [Parameter(Mandatory = $true)]
        [IO.FileSystemInfo] $Item
    )

    $linkTypeProperty = $Item.PSObject.Properties['LinkType']
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($null -ne $linkTypeProperty -and
            -not [string]::IsNullOrEmpty([string]$linkTypeProperty.Value))) {
        throw "Release signing input '$($Item.FullName)' must not be a link or reparse point."
    }
}

function Get-RelativeReleasePath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $rootPrefix = $Root.TrimEnd('\') + '\'
    if (-not $Path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Release signing input '$Path' escapes root '$Root'."
    }
    $relative = $Path.Substring($rootPrefix.Length).Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($relative) -or
        $relative.Length -gt 1024 -or
        $relative.IndexOfAny([char[]]"`r`n|") -ge 0 -or
        $relative -match '(^|/)\.\.?(/|$)') {
        throw "Release signing input has unsafe relative path '$relative'."
    }
    return $relative
}

function Get-ReleaseInventory {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root
    )

    $rootItem = Get-Item -LiteralPath $Root -Force
    if (-not $rootItem.PSIsContainer) {
        throw "Release signing root '$Root' is not a directory."
    }
    Assert-OrdinaryItem -Item $rootItem

    $entries = [Collections.Generic.List[object]]::new()
    $pending = [Collections.Generic.Queue[IO.DirectoryInfo]]::new()
    $pending.Enqueue([IO.DirectoryInfo]$rootItem)
    $seenPaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    [Int64]$aggregateBytes = 0

    while ($pending.Count -gt 0) {
        $directory = $pending.Dequeue()
        $children = @(Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction Stop)
        foreach ($child in $children) {
            Assert-OrdinaryItem -Item $child
            $relativePath = Get-RelativeReleasePath -Root $Root -Path $child.FullName
            if (-not $seenPaths.Add($relativePath)) {
                throw "Release signing input contains case-insensitive path collision '$relativePath'."
            }
            if ($seenPaths.Count -gt $maximumEntries) {
                throw "Release signing input exceeds the $maximumEntries-entry limit."
            }

            if ($child.PSIsContainer) {
                $entries.Add([pscustomobject]@{
                        Path = $relativePath
                        Type = 'Directory'
                        Length = [Int64]0
                        Sha256 = $null
                    })
                $pending.Enqueue([IO.DirectoryInfo]$child)
                continue
            }

            if ([Int64]$child.Length -lt 0 -or
                [Int64]$child.Length -gt $maximumFileBytes) {
                throw "Release signing file '$relativePath' exceeds the $maximumFileBytes-byte per-file limit."
            }
            if ([Int64]$child.Length -gt ($maximumAggregateBytes - $aggregateBytes)) {
                throw "Release signing input exceeds the $maximumAggregateBytes-byte aggregate limit."
            }
            $aggregateBytes += [Int64]$child.Length
            if ($aggregateBytes -gt $maximumAggregateBytes) {
                throw "Release signing input exceeds the $maximumAggregateBytes-byte aggregate limit."
            }
            $entries.Add([pscustomobject]@{
                    Path = $relativePath
                    Type = 'File'
                    Length = [Int64]$child.Length
                    Sha256 = (
                        Get-FileHash -Algorithm SHA256 -LiteralPath $child.FullName
                    ).Hash.ToLowerInvariant()
                })
        }
    }

    return @($entries | Sort-Object -Property Path)
}

function Get-ExpectedTargetPaths {
    param(
        [Parameter(Mandatory = $true)]
        [string] $PayloadKind,

        [Parameter(Mandatory = $true)]
        [string] $ReleaseVersion
    )

    $targets = [Collections.Generic.List[string]]::new()
    foreach ($architecture in @('x86', 'x64', 'ARM64')) {
        foreach ($flavor in @('no-uwp', 'uwp')) {
            if ($PayloadKind -ceq 'Bootstrap') {
                $targets.Add(
                    "unsigned-WireSockUI-v$ReleaseVersion-$architecture-$flavor/WireSockUI.exe")
            }
            else {
                $msiArchitecture = $architecture.ToLowerInvariant()
                $targets.Add(
                    "WireSockUI-$ReleaseVersion-win-$msiArchitecture-$flavor.msi")
            }
        }
    }
    return @($targets | Sort-Object)
}

function Assert-ExpectedPayload {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Entries,

        [Parameter(Mandatory = $true)]
        [string[]] $ExpectedTargets,

        [Parameter(Mandatory = $true)]
        [string] $PayloadKind,

        [Parameter(Mandatory = $true)]
        [string] $ResolvedRoot
    )

    $files = @($Entries | Where-Object { $_.Type -ceq 'File' })
    $directories = @($Entries | Where-Object { $_.Type -ceq 'Directory' })
    $actualTargets = if ($PayloadKind -ceq 'Bootstrap') {
        @($files | Where-Object { $_.Path.EndsWith('/WireSockUI.exe', [StringComparison]::Ordinal) })
    }
    else {
        @($files | Where-Object { $_.Path.EndsWith('.msi', [StringComparison]::Ordinal) })
    }

    $targetDifferences = @(
        Compare-Object `
            -ReferenceObject $ExpectedTargets `
            -DifferenceObject @($actualTargets.Path | Sort-Object) `
            -CaseSensitive
    )
    if ($targetDifferences.Count -ne 0) {
        throw "Release signing '$PayloadKind' target inventory is not the exact six-item architecture/flavor set."
    }

    if ($PayloadKind -ceq 'Bootstrap') {
        $expectedDirectories = @(
            $ExpectedTargets |
                ForEach-Object { Split-Path -Parent $_ } |
                Sort-Object
        )
        $rootDirectories = @(
            $directories |
                Where-Object { $_.Path.IndexOf('/') -lt 0 } |
                ForEach-Object { $_.Path } |
                Sort-Object
        )
        $directoryDifferences = @(
            Compare-Object `
                -ReferenceObject $expectedDirectories `
                -DifferenceObject $rootDirectories `
                -CaseSensitive
        )
        if ($directoryDifferences.Count -ne 0) {
            throw 'Unsigned payload artifact directories are not the exact six-item architecture/flavor set.'
        }

        foreach ($target in $ExpectedTargets) {
            $payloadDirectory = Split-Path -Parent $target
            $managedPath = "$payloadDirectory/WireSockUI.Managed.dll"
            if (@($files | Where-Object { $_.Path -ceq $managedPath }).Count -ne 1) {
                throw "Unsigned payload '$payloadDirectory' is missing its root WireSockUI.Managed.dll."
            }
        }
    }
    else {
        $expectedFiles = @(
            $ExpectedTargets
            $ExpectedTargets | ForEach-Object { "$_.validation.json" }
        ) | Sort-Object
        $fileDifferences = @(
            Compare-Object `
                -ReferenceObject $expectedFiles `
                -DifferenceObject @($files.Path | Sort-Object) `
                -CaseSensitive
        )
        if ($fileDifferences.Count -ne 0 -or $directories.Count -ne 0) {
            throw 'MSI signing input must contain exactly six MSIs and their six validation documents.'
        }
    }

    foreach ($target in $ExpectedTargets) {
        $absoluteTarget = Join-Path $ResolvedRoot $target.Replace('/', '\')
        $signature = Get-AuthenticodeSignature -FilePath $absoluteTarget
        if ($Mode -ceq 'Snapshot') {
            if ($signature.Status -ne [Management.Automation.SignatureStatus]::NotSigned) {
                throw "Release signing target '$target' must be unsigned before signing."
            }
        }
    }
}

$resolvedRoot = (Resolve-Path -LiteralPath $RootDirectory).Path.TrimEnd('\')
$resolvedInventoryPath = [IO.Path]::GetFullPath($InventoryPath)
$resolvedCatalogPath = [IO.Path]::GetFullPath($SigningCatalogPath)
if ($resolvedInventoryPath.StartsWith(
        "$resolvedRoot\",
        [StringComparison]::OrdinalIgnoreCase) -or
    $resolvedCatalogPath.StartsWith(
        "$resolvedRoot\",
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Signing inventory and catalog files must be stored outside the payload root.'
}

$entries = @(Get-ReleaseInventory -Root $resolvedRoot)
$expectedTargets = @(
    Get-ExpectedTargetPaths -PayloadKind $Kind -ReleaseVersion $Version
)
Assert-ExpectedPayload `
    -Entries $entries `
    -ExpectedTargets $expectedTargets `
    -PayloadKind $Kind `
    -ResolvedRoot $resolvedRoot

if ($Mode -ceq 'Snapshot') {
    foreach ($outputPath in @($resolvedInventoryPath, $resolvedCatalogPath)) {
        $parentPath = Split-Path -Parent $outputPath
        if (-not (Test-Path -LiteralPath $parentPath -PathType Container)) {
            throw "Signing output parent '$parentPath' does not exist."
        }
        if (Test-Path -LiteralPath $outputPath) {
            throw "Signing output '$outputPath' unexpectedly already exists."
        }
    }

    $inventory = [ordered]@{
        SchemaVersion = 1
        Kind = $Kind
        Version = $Version
        Entries = $entries
        SigningTargets = $expectedTargets
    }
    $inventory |
        ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $resolvedInventoryPath -Encoding utf8

    $catalogDirectory = Split-Path -Parent $resolvedCatalogPath
    $catalogDirectoryPrefix = $catalogDirectory.TrimEnd('\') + '\'
    $catalogEntries = foreach ($target in $expectedTargets) {
        $absoluteTarget = [IO.Path]::GetFullPath(
            (Join-Path $resolvedRoot $target.Replace('/', '\')))
        if (-not $absoluteTarget.StartsWith(
                $catalogDirectoryPrefix,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "Signing target '$absoluteTarget' is not below catalog directory '$catalogDirectory'."
        }
        ".\" + $absoluteTarget.Substring($catalogDirectoryPrefix.Length)
    }
    $catalogEntries |
        Set-Content -LiteralPath $resolvedCatalogPath -Encoding ascii

    Write-Output "Snapshotted exact $Kind signing input with $($entries.Count) entries."
    return
}

foreach ($requiredValue in @(
        @{ Name = 'ExpectedSignerSubject'; Value = $ExpectedSignerSubject },
        @{ Name = 'ExpectedTimestampSubject'; Value = $ExpectedTimestampSubject })) {
    if ([string]::IsNullOrWhiteSpace($requiredValue.Value) -or
        $requiredValue.Value.Length -gt 1024 -or
        $requiredValue.Value.Trim() -cne $requiredValue.Value -or
        $requiredValue.Value.IndexOfAny([char[]]"`r`n") -ge 0) {
        throw "$($requiredValue.Name) must be a trimmed, single-line value no longer than 1,024 characters."
    }
}

$inventoryItem = Get-Item -LiteralPath $resolvedInventoryPath -Force
Assert-OrdinaryItem -Item $inventoryItem
if ($inventoryItem.PSIsContainer -or
    [Int64]$inventoryItem.Length -le 0 -or
    [Int64]$inventoryItem.Length -gt $maximumInventoryBytes) {
    throw "Signing inventory '$resolvedInventoryPath' is empty or exceeds the $maximumInventoryBytes-byte limit."
}
$snapshot = Get-Content -LiteralPath $resolvedInventoryPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
if ([int]$snapshot.SchemaVersion -ne 1 -or
    [string]$snapshot.Kind -cne $Kind -or
    [string]$snapshot.Version -cne $Version) {
    throw 'Signing inventory identity does not match the requested verification.'
}

$snapshotEntries = @($snapshot.Entries)
$snapshotTargets = @($snapshot.SigningTargets)
$targetDifferences = @(
    Compare-Object `
        -ReferenceObject $expectedTargets `
        -DifferenceObject @($snapshotTargets | Sort-Object) `
        -CaseSensitive
)
if ($targetDifferences.Count -ne 0 -or
    $snapshotEntries.Count -ne $entries.Count) {
    throw 'Signing input entry or target inventory changed during signing.'
}

$currentByPath = @{}
foreach ($entry in $entries) {
    $currentByPath.Add([string]$entry.Path, $entry)
}
$targetSet = [Collections.Generic.HashSet[string]]::new(
    $expectedTargets,
    [StringComparer]::Ordinal)
foreach ($before in $snapshotEntries) {
    $path = [string]$before.Path
    $after = $null
    if (-not $currentByPath.TryGetValue($path, [ref]$after) -or
        [string]$after.Type -cne [string]$before.Type) {
        throw "Signing input '$path' was added, removed, or changed type."
    }
    if ([string]$before.Type -ceq 'Directory') {
        continue
    }
    if ($targetSet.Contains($path)) {
        if ([string]$after.Sha256 -ceq [string]$before.Sha256) {
            throw "Signing target '$path' was not modified by the signing operation."
        }
    }
    elseif ([Int64]$after.Length -ne [Int64]$before.Length -or
        [string]$after.Sha256 -cne [string]$before.Sha256) {
        throw "Non-signing payload '$path' was unexpectedly modified by the signing operation."
    }
}

$absoluteTargets = @(
    $expectedTargets |
        ForEach-Object {
            Join-Path $resolvedRoot $_.Replace('/', '\')
        }
)
& (Join-Path $PSScriptRoot 'Test-ReleaseSignature.ps1') `
    -FilePath $absoluteTargets `
    -ExpectedSignerSubject $ExpectedSignerSubject `
    -ExpectedTimestampSubject $ExpectedTimestampSubject

Write-Output "Verified exact $Kind signing output with no out-of-scope payload changes."
