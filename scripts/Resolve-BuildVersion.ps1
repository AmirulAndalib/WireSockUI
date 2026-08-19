#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryPath = [IO.Path]::GetFullPath($RepositoryRoot)
$configurationPath = Join-Path $repositoryPath 'version.json'
$configurationFile = Get-Item -LiteralPath $configurationPath -Force
if ($configurationFile.PSIsContainer -or
    ($configurationFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Build version configuration '$configurationPath' must be an ordinary file."
}
if ($configurationFile.Length -le 0 -or $configurationFile.Length -gt 4KB) {
    throw "Build version configuration '$configurationPath' is empty or too large."
}

$configuration = Get-Content `
    -LiteralPath $configurationFile.FullName `
    -Raw `
    -Encoding UTF8 |
    ConvertFrom-Json
$expectedProperties = @(
    'buildNumberStart',
    'major',
    'minor',
    'schema'
)
$actualProperties = @(
    $configuration.PSObject.Properties.Name | Sort-Object
)
if ([string]::Join("`n", $actualProperties) -cne
    [string]::Join("`n", $expectedProperties)) {
    throw 'Build version configuration has an unexpected schema.'
}

foreach ($propertyName in $expectedProperties) {
    $propertyValue = $configuration.$propertyName
    if ($propertyValue -isnot [long] -and $propertyValue -isnot [int]) {
        throw "Build version property '$propertyName' must be an integer."
    }
}
if ([long]$configuration.schema -ne 1) {
    throw "Unsupported build version schema '$($configuration.schema)'."
}
if ([long]$configuration.major -lt 0 -or
    [long]$configuration.major -gt 255 -or
    [long]$configuration.minor -lt 0 -or
    [long]$configuration.minor -gt 255 -or
    [long]$configuration.buildNumberStart -lt 0 -or
    [long]$configuration.buildNumberStart -gt 65535) {
    throw 'Build version configuration exceeds Windows Installer version limits.'
}

$gitDirectory = Join-Path $repositoryPath '.git'
if (-not (Test-Path -LiteralPath $gitDirectory)) {
    throw "Repository root '$repositoryPath' has no Git metadata."
}
$epochOutput = @(& git `
        -C $repositoryPath `
        rev-list `
        --first-parent `
        --reverse `
        HEAD `
        -- `
        version.json 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to inspect first-parent version history: $($epochOutput -join ' ')"
}
$epochCommits = @(
    $epochOutput |
        ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrEmpty($_) }
)
if ($epochCommits.Count -lt 1 -or
    $epochCommits[0] -cnotmatch '\A[0-9a-f]{40,64}\z') {
    throw 'Git did not identify the first-parent build version epoch.'
}

$historyOutput = @(& git `
        -C $repositoryPath `
        rev-list `
        --count `
        --first-parent `
        "$($epochCommits[0])..HEAD" 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to count builds after the version epoch: $($historyOutput -join ' ')"
}
$historyText = [string]::Join('', $historyOutput).Trim()
[long] $buildsAfterEpoch = 0
if ($historyText -cnotmatch '\A[0-9]+\z' -or
    -not [long]::TryParse($historyText, [ref]$buildsAfterEpoch)) {
    throw "Git returned an invalid post-epoch history count '$historyText'."
}
$buildNumber =
    [long]$configuration.buildNumberStart + $buildsAfterEpoch
if ($buildNumber -gt 65535) {
    throw "Build number $buildNumber exceeds the Windows Installer patch limit."
}

Write-Output (
    "{0}.{1}.{2}" -f
    [long]$configuration.major,
    [long]$configuration.minor,
    $buildNumber)
