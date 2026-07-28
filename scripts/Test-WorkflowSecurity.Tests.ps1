[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$validator = Join-Path $PSScriptRoot 'Test-WorkflowSecurity.ps1'
$temporaryRoot = Join-Path (
    [IO.Path]::GetTempPath()
) ("WireSockUI-WorkflowSecurity-" + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temporaryRoot)

$validWorkflow = @'
name: fixture
permissions:
  contents: read
on:
  push:
    tags:
      - 'release-v*.*.*'
jobs:
  test:
    runs-on: windows-latest
    timeout-minutes: 5
    steps:
      - name: Checkout
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0
        with:
          persist-credentials: false
      - name: Safely consume context
        env:
          SAFE_REF: ${{ github.ref_name }}
        run: Write-Host $env:SAFE_REF
'@
$validShorthandWorkflow = $validWorkflow -replace (
    '(?m)^      - name: Checkout\r?\n        uses:'),
    '      - uses:'
$releaseSigningWorkflow = Get-Content `
    -LiteralPath (
        Join-Path (
            Split-Path -Parent $PSScriptRoot
        ) '.github\workflows\release-signing.yml') `
    -Raw `
    -Encoding UTF8
$sdkIntegrationWorkflow = Get-Content `
    -LiteralPath (
        Join-Path (
            Split-Path -Parent $PSScriptRoot
        ) '.github\workflows\sdk-integration.yml') `
    -Raw `
    -Encoding UTF8
$productionMainWorkflow = Get-Content `
    -LiteralPath (
        Join-Path (
            Split-Path -Parent $PSScriptRoot
        ) '.github\workflows\main.yml') `
    -Raw `
    -Encoding UTF8
$privilegedCallerPattern =
    '(?m)(uses:\s+wiresock/WireSockUI/\.github/workflows/' +
    '(?:sdk-integration|release-signing)\.yml)@[0-9a-f]{40}'
$mutableProductionMainWorkflow = [Text.RegularExpressions.Regex]::new(
    $privilegedCallerPattern
).Replace(
    $productionMainWorkflow,
    '$1@main',
    1)
if ($mutableProductionMainWorkflow -ceq $productionMainWorkflow) {
    throw 'The production workflow fixture has no pinned privileged caller to mutate.'
}

function Invoke-Fixture {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $Workflow,

        [Parameter(Mandatory = $true)]
        [bool] $ShouldPass,

        [Parameter()]
        [string] $ReleaseSigningWorkflow,

        [Parameter()]
        [string] $SdkIntegrationWorkflow
    )

    $fixture = Join-Path $temporaryRoot $Name
    [void](New-Item -ItemType Directory -Path $fixture)
    Set-Content `
        -LiteralPath (Join-Path $fixture 'main.yml') `
        -Value $Workflow `
        -Encoding utf8

    if (-not [string]::IsNullOrEmpty($ReleaseSigningWorkflow)) {
        Set-Content `
            -LiteralPath (Join-Path $fixture 'release-signing.yml') `
            -Value $ReleaseSigningWorkflow `
            -Encoding utf8
    }
    if (-not [string]::IsNullOrEmpty($SdkIntegrationWorkflow)) {
        Set-Content `
            -LiteralPath (Join-Path $fixture 'sdk-integration.yml') `
            -Value $SdkIntegrationWorkflow `
            -Encoding utf8
    }

    $failed = $false
    try {
        & $validator -WorkflowDirectory $fixture | Out-Null
    }
    catch {
        $failed = $true
    }
    if ($failed -eq $ShouldPass) {
        throw "Workflow security fixture '$Name' produced the wrong result."
    }
}

try {
    Invoke-Fixture -Name valid -Workflow $validWorkflow -ShouldPass $true
    Invoke-Fixture `
        -Name valid-shorthand `
        -Workflow $validShorthandWorkflow `
        -ShouldPass $true
    Invoke-Fixture `
        -Name valid-trusted-release-signing-boundary `
        -Workflow $validWorkflow `
        -ReleaseSigningWorkflow $releaseSigningWorkflow `
        -SdkIntegrationWorkflow $sdkIntegrationWorkflow `
        -ShouldPass $true
    Invoke-Fixture `
        -Name valid-production-release-workflow `
        -Workflow $productionMainWorkflow `
        -ReleaseSigningWorkflow $releaseSigningWorkflow `
        -SdkIntegrationWorkflow $sdkIntegrationWorkflow `
        -ShouldPass $true
    Invoke-Fixture `
        -Name mutable-production-privileged-caller `
        -Workflow $mutableProductionMainWorkflow `
        -ReleaseSigningWorkflow $releaseSigningWorkflow `
        -SdkIntegrationWorkflow $sdkIntegrationWorkflow `
        -ShouldPass $false
    Invoke-Fixture `
        -Name candidate-release-validator `
        -Workflow $validWorkflow `
        -ReleaseSigningWorkflow $releaseSigningWorkflow.Replace(
            './.trusted-release-tooling/scripts/Test-ReleaseTag.ps1',
            './scripts/Test-ReleaseTag.ps1') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name caller-sha-used-as-release-tooling-source `
        -Workflow $validWorkflow `
        -ReleaseSigningWorkflow $releaseSigningWorkflow.Replace(
            '${{ job.workflow_sha }}',
            '${{ github.workflow_sha }}') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name caller-sha-used-as-sdk-tooling-source `
        -Workflow $validWorkflow `
        -SdkIntegrationWorkflow $sdkIntegrationWorkflow.Replace(
            '${{ job.workflow_sha }}',
            '${{ github.workflow_sha }}') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name candidate-script-before-independent-authorization `
        -Workflow $validWorkflow `
        -ReleaseSigningWorkflow $releaseSigningWorkflow.Replace(
            '      - name: Validate reusable-workflow release identity',
            '      - name: Execute unauthorized candidate script
        shell: pwsh
        run: ./scripts/Build-Msi.ps1

      - name: Validate reusable-workflow release identity') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name incomplete-independent-release-authorization `
        -Workflow $validWorkflow `
        -ReleaseSigningWorkflow $releaseSigningWorkflow.Replace(
            '$currentMainSha -cne $env:TRUSTED_SHA',
            '$currentMainSha -cne $currentMainSha') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name string-spoofed-independent-release-authorization `
        -Workflow $validWorkflow `
        -ReleaseSigningWorkflow (
            $releaseSigningWorkflow.Replace(
                '$currentMainSha -cne $env:TRUSTED_SHA) {',
                '$false) {').Replace(
                '          $apiUri = $null',
                '          $spoof = "ignored
          $currentMainSha -cne $env:TRUSTED_SHA) {
          ignored"
          $apiUri = $null')) `
        -ShouldPass $false
    Invoke-Fixture `
        -Name skipped-independent-release-authorization `
        -Workflow $validWorkflow `
        -ReleaseSigningWorkflow $releaseSigningWorkflow.Replace(
            '      - name: Validate reusable-workflow release identity
        shell: pwsh',
            '      - name: Validate reusable-workflow release identity
        if: ${{ false }}
        shell: pwsh') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name suppressed-independent-release-authorization-failure `
        -Workflow $validWorkflow `
        -ReleaseSigningWorkflow $releaseSigningWorkflow.Replace(
            '      - name: Validate reusable-workflow release identity
        shell: pwsh',
            '      - name: Validate reusable-workflow release identity
        continue-on-error: true
        shell: pwsh') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name skipped-sdk-authorization `
        -Workflow $validWorkflow `
        -SdkIntegrationWorkflow $sdkIntegrationWorkflow.Replace(
            '      - name: Authorize trusted candidate revision
        id: authorize',
            '      - name: Authorize trusted candidate revision
        if: ${{ false }}
        id: authorize') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name suppressed-sdk-runner-policy-failure `
        -Workflow $validWorkflow `
        -SdkIntegrationWorkflow $sdkIntegrationWorkflow.Replace(
            '      - name: Verify exact SDK runner-group policy
        shell: pwsh',
            '      - name: Verify exact SDK runner-group policy
        continue-on-error: true
        shell: pwsh') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name mutable `
        -Workflow $validWorkflow.Replace(
            'actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0',
            'actions/checkout@main') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name credentials `
        -Workflow $validWorkflow.Replace(
            'persist-credentials: false',
            'persist-credentials: true') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name duplicate-quoted-credentials `
        -Workflow $validWorkflow.Replace(
            '          persist-credentials: false',
            "          persist-credentials: false`n          persist-credentials: `"true`"") `
        -ShouldPass $false
    Invoke-Fixture `
        -Name dangerous-trigger `
        -Workflow ($validWorkflow -replace
            '(?m)^  push:$',
            '  pull_request_target:') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name wrong-tags `
        -Workflow $validWorkflow.Replace(
            "'release-v*.*.*'",
            "'v*'") `
        -ShouldPass $false
    Invoke-Fixture `
        -Name shorthand-mutable `
        -Workflow $validWorkflow.Replace(
            '    steps:',
            "    steps:`n      - uses: actions/checkout@main") `
        -ShouldPass $false
    Invoke-Fixture `
        -Name quoted-uses-key `
        -Workflow $validWorkflow.Replace(
            '    steps:',
            "    steps:`n      - `"uses`": actions/checkout@main") `
        -ShouldPass $false
    Invoke-Fixture `
        -Name escaped-uses-key `
        -Workflow $validWorkflow.Replace(
            '    steps:',
            '    steps:
      - "u\u0073es": actions/checkout@main') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name escaped-flow-uses-key `
        -Workflow $validWorkflow.Replace(
            '    steps:',
            '    steps:
      - { "u\u0073es": actions/checkout@main }') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name flow-uses-key `
        -Workflow $validWorkflow.Replace(
            '    steps:',
            "    steps:`n      - { uses: actions/checkout@main }") `
        -ShouldPass $false
    Invoke-Fixture `
        -Name explicit-uses-key `
        -Workflow $validWorkflow.Replace(
            '    steps:',
            "    steps:`n      - ? uses`n        : actions/checkout@main") `
        -ShouldPass $false
    Invoke-Fixture `
        -Name compact-explicit-escaped-uses-key `
        -Workflow $validWorkflow.Replace(
            '    steps:',
            '    steps:
      - { ?"u\u0073es": actions/checkout@main }') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name inline-trigger-map `
        -Workflow $validWorkflow.Replace(
            'on:',
            'on: { pull_request_target: {} }') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name inline-trigger-list `
        -Workflow $validWorkflow.Replace(
            'on:',
            'on: [push, pull_request_target]') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name quoted-write-all `
        -Workflow $validWorkflow.Replace(
            "  test:`n    runs-on:",
            "  test:`n    permissions: `"write-all`"`n    runs-on:") `
        -ShouldPass $false
    Invoke-Fixture `
        -Name escaped-write-all-key `
        -Workflow $validWorkflow.Replace(
            "  test:`n    runs-on:",
            '  test:
    "permiss\u0069ons": write-all
    runs-on:') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name escaped-persist-credentials-key `
        -Workflow $validWorkflow.Replace(
            '          persist-credentials: false',
            '          persist-credentials: false
          "persist-cr\u0065dentials": true') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name direct-run-expression `
        -Workflow $validWorkflow.Replace(
            '        run: Write-Host $env:SAFE_REF',
            '        run: Write-Host ''${{ github.ref_name }}''') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name escaped-run-expression `
        -Workflow $validWorkflow.Replace(
            '        run: Write-Host $env:SAFE_REF',
            '        run: "\u0024{{ github.ref_name }}"') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name next-line-run-block-expression `
        -Workflow $validWorkflow.Replace(
            '        run: Write-Host $env:SAFE_REF',
            '        run:
          |
            Write-Host ''${{ github.ref_name }}''') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name plain-run-continuation-expression `
        -Workflow $validWorkflow.Replace(
            '        run: Write-Host $env:SAFE_REF',
            '        run: Write-Host
          ''${{ github.ref_name }}''') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name indentation-indicator-run-expression `
        -Workflow $validWorkflow.Replace(
            '        run: Write-Host $env:SAFE_REF',
            '        run: |2
          Write-Host ''${{ github.ref_name }}''') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name chomping-indicator-run-expression `
        -Workflow $validWorkflow.Replace(
            '        run: Write-Host $env:SAFE_REF',
            '        run: >-
          Write-Host ''${{ github.ref_name }}''') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name bare-tagged-run-expression `
        -Workflow $validWorkflow.Replace(
            '        run: Write-Host $env:SAFE_REF',
            '        run: ! |
          Write-Host ''${{ github.ref_name }}''') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name block-scalar-permissions `
        -Workflow $validWorkflow.Replace(
            'permissions:
  contents: read',
            'permissions:
  |-
    write-all') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name deferred-plain-permissions `
        -Workflow $validWorkflow.Replace(
            'permissions:
  contents: read',
            'permissions:
  write-all') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name escaped-forbidden-secret `
        -Workflow $validWorkflow.Replace(
            '          SAFE_REF: ${{ github.ref_name }}',
            '          SAFE_REF: ${{ github.ref_name }}
          TOKEN: "${{ secrets.MY_GITHUB_\u0050AT }}"') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name deferred-escaped-forbidden-secret `
        -Workflow $validWorkflow.Replace(
            '          SAFE_REF: ${{ github.ref_name }}',
            '          SAFE_REF: ${{ github.ref_name }}
          TOKEN:
            "${{ secrets.MY_GITHUB_\u0050AT }}"') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name computed-forbidden-secret `
        -Workflow $validWorkflow.Replace(
            '          SAFE_REF: ${{ github.ref_name }}',
            '          SAFE_REF: ${{ github.ref_name }}
          TOKEN: ${{ secrets[format(''MY_GITHUB_{0}'', ''PAT'')] }}') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name computed-forbidden-secret-in-attestation-block `
        -Workflow $validWorkflow.Replace(
            '    steps:',
            '    steps:
      - name: Unsafe attestation input
        uses: actions/attest@f7c74d28b9d84cb8768d0b8ca14a4bac6ef463e6
        with:
          subject-path: |
            ${{ secrets[format(''MY_GITHUB_{0}'', ''PAT'')] }}') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name child-powershell-command-injection `
        -Workflow $validWorkflow.Replace(
            '          SAFE_REF: ${{ github.ref_name }}
        run: Write-Host $env:SAFE_REF',
            '          SAFE_REF: ${{ github.ref_name }}
          UNTRUSTED: ${{ github.event.pull_request.title }}
        run: pwsh -NoProfile -Command $env:UNTRUSTED') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name dynamic-shell `
        -Workflow $validWorkflow.Replace(
            '        run: Write-Host $env:SAFE_REF',
            '        shell: ${{ github.event.pull_request.title }}
        run: Write-Host $env:SAFE_REF') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name dynamic-working-directory `
        -Workflow $validWorkflow.Replace(
            '        run: Write-Host $env:SAFE_REF',
            '        working-directory: ${{ github.event.pull_request.title }}
        run: Write-Host $env:SAFE_REF') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name dynamic-runner `
        -Workflow $validWorkflow.Replace(
            '    runs-on: windows-latest',
            '    runs-on: ${{ github.event.pull_request.title }}') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name self-hosted-runner `
        -Workflow $validWorkflow.Replace(
            '    runs-on: windows-latest',
            '    runs-on: self-hosted') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name job-container `
        -Workflow $validWorkflow.Replace(
            '    runs-on: windows-latest',
            '    runs-on: windows-latest
    container: attacker.invalid/image:latest') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name aliased-permissions `
        -Workflow $validWorkflow.Replace(
            'permissions:
  contents: read',
            'permission-value: &write_all write-all
permissions: *write_all') `
        -ShouldPass $false
    Invoke-Fixture `
        -Name tagged-permissions `
        -Workflow $validWorkflow.Replace(
            'permissions:
  contents: read',
            'permissions: !!str write-all') `
        -ShouldPass $false
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

Write-Output 'Workflow security fixtures passed.'
