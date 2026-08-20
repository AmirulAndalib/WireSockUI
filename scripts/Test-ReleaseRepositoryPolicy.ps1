[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z')]
    [string] $Repository,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $GitHubApiUrl,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('\Arelease-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z')]
    [string] $ReleaseTag,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]] $RequiredEnvironment
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
    throw 'GH_TOKEN is required to inspect protected repository release policy.'
}
if ($Repository -cne 'wiresock/WireSockUI') {
    throw "Release policy validation is restricted to the canonical 'wiresock/WireSockUI' repository."
}

$apiUri = $null
if (-not [Uri]::TryCreate($GitHubApiUrl, [UriKind]::Absolute, [ref]$apiUri) -or
    $apiUri.Scheme -cne 'https' -or
    $apiUri.Host -cne 'api.github.com' -or
    -not $apiUri.IsDefaultPort -or
    -not [string]::IsNullOrEmpty($apiUri.UserInfo) -or
    $apiUri.AbsolutePath -cnotin @('', '/') -or
    -not [string]::IsNullOrEmpty($apiUri.Query) -or
    -not [string]::IsNullOrEmpty($apiUri.Fragment)) {
    throw "GitHubApiUrl must be exactly the public GitHub HTTPS API origin 'https://api.github.com'."
}
$apiRoot = $GitHubApiUrl.TrimEnd('/')
$headers = @{
    Accept = 'application/vnd.github+json'
    Authorization = "Bearer $env:GH_TOKEN"
    'X-GitHub-Api-Version' = '2026-03-10'
}

function Invoke-GitHubPolicyRequest {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $RelativePath
    )

    $uri = "$apiRoot/repos/$Repository"
    if (-not [string]::IsNullOrEmpty($RelativePath)) {
        $uri += "/$RelativePath"
    }
    try {
        return Invoke-RestMethod `
            -Method Get `
            -Headers $headers `
            -TimeoutSec 30 `
            -Uri $uri
    }
    catch {
        throw "Unable to verify protected release policy at '$RelativePath': $($_.Exception.Message)"
    }
}

function Get-EffectiveRules {
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('\Arules/(branches|tags)/[A-Za-z0-9._~%-]+\z')]
        [string] $RelativePath
    )

    $rules = [Collections.Generic.List[object]]::new()
    foreach ($page in 1..10) {
        $pageRules = @(
            Invoke-GitHubPolicyRequest `
                -RelativePath "$RelativePath`?per_page=100&page=$page"
        )
        foreach ($pageRule in $pageRules) {
            $rules.Add($pageRule)
        }
        if ($pageRules.Count -lt 100) {
            return @($rules)
        }
    }
    throw "Effective rules at '$RelativePath' exceed the bounded 1,000-rule scan."
}

$repositoryMetadata = Invoke-GitHubPolicyRequest -RelativePath ''
if ([string]$repositoryMetadata.full_name -cne $Repository -or
    [string]$repositoryMetadata.owner.type -cne 'Organization' -or
    [string]$repositoryMetadata.default_branch -cne 'main') {
    throw (
        "Release publication requires '$Repository' to be organization-owned " +
        "and to use the protected literal default branch 'main'.")
}

$immutableReleasePolicy =
    Invoke-GitHubPolicyRequest -RelativePath 'immutable-releases'
if ($immutableReleasePolicy.enabled -ne $true) {
    throw "Immutable releases must be enabled for '$Repository' before a release can be published."
}

$actionsPolicy = Invoke-GitHubPolicyRequest -RelativePath 'actions/permissions'
if ($actionsPolicy.enabled -ne $true -or
    [string]$actionsPolicy.allowed_actions -cne 'selected' -or
    $actionsPolicy.sha_pinning_required -ne $true) {
    throw 'Repository Actions must be enabled only for selected actions and require full commit-SHA pinning.'
}
$selectedActions =
    Invoke-GitHubPolicyRequest -RelativePath 'actions/permissions/selected-actions'
$expectedActionPatterns = @(
    'actions/attest@*',
    'actions/checkout@*',
    'actions/create-github-app-token@*',
    'actions/download-artifact@*',
    'actions/setup-dotnet@*',
    'actions/upload-artifact@*'
)
$actualActionPatterns = @($selectedActions.patterns_allowed | Sort-Object -Unique)
$actionPatternDifferences = @(
    Compare-Object `
        -ReferenceObject $expectedActionPatterns `
        -DifferenceObject $actualActionPatterns `
        -CaseSensitive
)
if ($selectedActions.github_owned_allowed -ne $false -or
    $selectedActions.verified_allowed -ne $false -or
    $actionPatternDifferences.Count -ne 0) {
    throw 'Repository selected-action policy differs from the exact audited action allowlist.'
}

$oidcSubjectPolicy =
    Invoke-GitHubPolicyRequest -RelativePath 'actions/oidc/customization/sub'
$expectedOidcClaims = @('repo', 'context', 'job_workflow_ref')
$actualOidcClaims = @($oidcSubjectPolicy.include_claim_keys)
if ($oidcSubjectPolicy.use_default -ne $false -or
    $actualOidcClaims.Count -ne $expectedOidcClaims.Count) {
    throw 'Repository OIDC tokens must use the exact hardened subject-claim template.'
}
for ($claimIndex = 0; $claimIndex -lt $expectedOidcClaims.Count; $claimIndex++) {
    if ([string]$actualOidcClaims[$claimIndex] -cne $expectedOidcClaims[$claimIndex]) {
        throw 'Repository OIDC tokens must use [repo, context, job_workflow_ref] in that exact order.'
    }
}

$branchProtection = Invoke-GitHubPolicyRequest -RelativePath 'branches/main/protection'
if ($branchProtection.enforce_admins.enabled -ne $true -or
    $branchProtection.required_pull_request_reviews.dismiss_stale_reviews -ne $true -or
    $branchProtection.required_pull_request_reviews.require_last_push_approval -ne $true -or
    [int]$branchProtection.required_pull_request_reviews.required_approving_review_count -lt 1 -or
    $branchProtection.required_conversation_resolution.enabled -ne $true -or
    $branchProtection.required_signatures.enabled -ne $true) {
    throw 'Classic main protection must enforce administrators, signed commits, reviews, latest-push approval, stale-review dismissal, and conversation resolution.'
}
$bypassProperty =
    $branchProtection.required_pull_request_reviews.PSObject.Properties[
        'bypass_pull_request_allowances'
    ]
if ($null -ne $bypassProperty -and
    $null -ne $bypassProperty.Value) {
    $bypassAllowances = $bypassProperty.Value
    if (@($bypassAllowances.users).Count -gt 0 -or
        @($bypassAllowances.teams).Count -gt 0 -or
        @($bypassAllowances.apps).Count -gt 0) {
        throw 'Classic main protection must not grant pull-request bypass allowances.'
    }
}

# GitHub deliberately withholds ruleset bypass actors from an
# Administration(read) token. Independently administered controls must keep
# main and tag-mutation rulesets free of bypass actors. Active tag creation
# must be isolated in its own ruleset with only a narrowly scoped, audited
# release-tagger bypass. Requiring Administration(write) here would turn a
# read-only release gate into a repository-takeover credential.
$effectiveMainRules = @(
    Get-EffectiveRules -RelativePath 'rules/branches/main'
)
$mainRulesByType = @{}
foreach ($rule in $effectiveMainRules) {
    $ruleType = [string]$rule.type
    if ($ruleType -cnotmatch '^[a-z][a-z0-9_]*$') {
        throw "Effective main rules contain an invalid '$ruleType' rule type."
    }
    if (-not $mainRulesByType.ContainsKey($ruleType)) {
        $mainRulesByType[$ruleType] =
            [Collections.Generic.List[object]]::new()
    }
    [void]$mainRulesByType[$ruleType].Add($rule)
}
foreach ($requiredRuleType in @(
        'deletion',
        'non_fast_forward',
        'required_signatures',
        'pull_request',
        'required_status_checks')) {
    if (-not $mainRulesByType.ContainsKey($requiredRuleType)) {
        throw "Protected main is missing effective '$requiredRuleType' rule enforcement."
    }
}

$dismissStaleReviews = $false
$requireLastPushApproval = $false
$requireReviewThreadResolution = $false
$requiredApprovingReviewCount = 0
foreach ($pullRequestRule in @($mainRulesByType['pull_request'])) {
    $parametersProperty =
        $pullRequestRule.PSObject.Properties['parameters']
    if ($null -eq $parametersProperty -or
        $null -eq $parametersProperty.Value) {
        throw 'Effective main contains a pull-request rule without parameters.'
    }

    $parameters = $parametersProperty.Value
    $dismissStaleReviews =
        $dismissStaleReviews -or
        $parameters.dismiss_stale_reviews_on_push -eq $true
    $requireLastPushApproval =
        $requireLastPushApproval -or
        $parameters.require_last_push_approval -eq $true
    $requireReviewThreadResolution =
        $requireReviewThreadResolution -or
        $parameters.required_review_thread_resolution -eq $true

    $approvalCountProperty =
        $parameters.PSObject.Properties['required_approving_review_count']
    if ($null -eq $approvalCountProperty) {
        throw 'Effective main contains a pull-request rule without an approval count.'
    }
    $approvalCount = [int]$approvalCountProperty.Value
    if ($approvalCount -lt 0 -or $approvalCount -gt 100) {
        throw 'Effective main contains an invalid required approval count.'
    }
    $requiredApprovingReviewCount =
        [Math]::Max($requiredApprovingReviewCount, $approvalCount)
}
if (-not $dismissStaleReviews -or
    -not $requireLastPushApproval -or
    -not $requireReviewThreadResolution -or
    $requiredApprovingReviewCount -lt 1) {
    throw 'Effective main pull-request rules do not enforce the required review invariants.'
}

$requiredGitHubActionsChecks = @(
    'dependency-audit',
    'msi-architecture-isolation',
    'msi-install-smoke (ARM64)',
    'msi-install-smoke (x64)',
    'msi-install-smoke (x86)',
    'msi-transition-smoke',
    'native-host-smoke (ARM64)',
    'native-host-smoke (x64)',
    'native-host-smoke (x86)',
    'publish (Release UWP, ARM64)',
    'publish (Release UWP, x64)',
    'publish (Release UWP, x86)',
    'publish (Release, ARM64)',
    'publish (Release, x64)',
    'publish (Release, x86)',
    'sdk-contract',
    'test (Release UWP, ARM64)',
    'test (Release UWP, x64)',
    'test (Release UWP, x86)',
    'test (Release, ARM64)',
    'test (Release, x64)',
    'test (Release, x86)'
)

$strictStatusChecks = $false
$configuredCheckCount = 0
$checksByContext =
    [Collections.Generic.Dictionary[string, string]]::new(
        [StringComparer]::Ordinal)
foreach ($statusCheckRule in @($mainRulesByType['required_status_checks'])) {
    $parametersProperty =
        $statusCheckRule.PSObject.Properties['parameters']
    if ($null -eq $parametersProperty -or
        $null -eq $parametersProperty.Value) {
        throw 'Effective main contains a required-status-check rule without parameters.'
    }

    $parameters = $parametersProperty.Value
    $strictStatusChecks =
        $strictStatusChecks -or
        $parameters.strict_required_status_checks_policy -eq $true
    foreach ($configuredCheck in @($parameters.required_status_checks)) {
        $configuredCheckCount++
        if ($configuredCheckCount -gt 64) {
            throw 'Protected main has an unexpectedly large required-status-check policy.'
        }

        $context = [string]$configuredCheck.context
        if ([string]::IsNullOrWhiteSpace($context) -or
            $context.Length -gt 255 -or
            $context -match '[\p{Cc}\p{Cf}]') {
            throw "Protected main has an invalid required status check '$context'."
        }

        $integrationProperty =
            $configuredCheck.PSObject.Properties['integration_id']
        if ($null -eq $integrationProperty -or
            $null -eq $integrationProperty.Value) {
            $integrationKey = 'any'
        }
        else {
            $integrationId = [Int64]$integrationProperty.Value
            if ($integrationId -le 0) {
                throw "Protected main check '$context' has an invalid integration ID."
            }
            $integrationKey = "id:$integrationId"
        }

        if ($checksByContext.ContainsKey($context)) {
            if ($checksByContext[$context] -cne $integrationKey) {
                throw (
                    "Protected main check '$context' has conflicting " +
                    'integration IDs across effective rules.')
            }
            continue
        }
        $checksByContext.Add($context, $integrationKey)
    }
}
if (-not $strictStatusChecks -or $checksByContext.Count -lt 1) {
    throw 'Effective main rules must require at least one strict status check.'
}
foreach ($requiredCheck in $requiredGitHubActionsChecks) {
    if (-not $checksByContext.ContainsKey($requiredCheck) -or
        $checksByContext[$requiredCheck] -cne 'id:15368') {
        throw "Protected main must require GitHub Actions check '$requiredCheck' from App ID 15368."
    }
}

$legacyReleaseTag = $ReleaseTag.Substring('release-'.Length)
$tagProbes = [Collections.Generic.List[string]]::new()
$seenTagProbes = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal)
foreach ($candidateTagProbe in @(
        $ReleaseTag,
        $legacyReleaseTag,
        'v0.0.0')) {
    if ($seenTagProbes.Add($candidateTagProbe)) {
        $tagProbes.Add($candidateTagProbe)
    }
}

foreach ($tagProbe in $tagProbes) {
    $encodedTagProbe = [Uri]::EscapeDataString($tagProbe)
    $effectiveTagRules = @(
        Get-EffectiveRules -RelativePath "rules/tags/$encodedTagProbe"
    )
    $requiredTagRulesByType = @{}
    foreach ($requiredTagRule in @('creation', 'update', 'deletion')) {
        $matchingTagRules = @(
            $effectiveTagRules |
                Where-Object { [string]$_.type -ceq $requiredTagRule }
        )
        if ($matchingTagRules.Count -lt 1) {
            throw "Tag policy for '$tagProbe' does not enforce '$requiredTagRule'."
        }
        $requiredTagRulesByType[$requiredTagRule] = $matchingTagRules

        foreach ($matchingTagRule in $matchingTagRules) {
            $rulesetIdProperty =
                $matchingTagRule.PSObject.Properties['ruleset_id']
            if ($null -eq $rulesetIdProperty -or
                [Int64]$rulesetIdProperty.Value -le 0) {
                throw (
                    "Tag policy for '$tagProbe' has a '$requiredTagRule' " +
                    'rule without a valid source ruleset ID.')
            }
        }
    }

    if ($tagProbe -ceq $ReleaseTag) {
        $creationRulesetIds =
            [Collections.Generic.HashSet[Int64]]::new()
        $mutationRulesetIds =
            [Collections.Generic.HashSet[Int64]]::new()
        foreach ($creationRule in $requiredTagRulesByType['creation']) {
            [void]$creationRulesetIds.Add([Int64]$creationRule.ruleset_id)
        }
        foreach ($mutationRule in @(
                $requiredTagRulesByType['update']
                $requiredTagRulesByType['deletion'])) {
            [void]$mutationRulesetIds.Add([Int64]$mutationRule.ruleset_id)
        }
        foreach ($creationRulesetId in $creationRulesetIds) {
            if ($mutationRulesetIds.Contains($creationRulesetId)) {
                throw (
                    "Active tag '$ReleaseTag' must isolate creation rules " +
                    'from zero-bypass update/deletion rulesets.')
            }
        }
    }
}

$distinctEnvironments =
    [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($environmentName in $RequiredEnvironment) {
    if ($environmentName -cnotmatch '^[A-Za-z0-9_.-]{1,255}$' -or
        -not $distinctEnvironments.Add($environmentName)) {
        throw "Required environment '$environmentName' is invalid or duplicated."
    }

    $encodedName = [Uri]::EscapeDataString($environmentName)
    $environment =
        Invoke-GitHubPolicyRequest -RelativePath "environments/$encodedName"
    if ([string]$environment.name -cne $environmentName) {
        throw "GitHub returned the wrong environment for '$environmentName'."
    }
    if ($environment.can_admins_bypass -ne $false) {
        throw "Environment '$environmentName' must disable administrator protection-rule bypass."
    }

    $reviewRules = @(
        @($environment.protection_rules) |
            Where-Object { [string]$_.type -ceq 'required_reviewers' }
    )
    if ($reviewRules.Count -ne 1 -or
        @($reviewRules[0].reviewers).Count -lt 1 -or
        $reviewRules[0].prevent_self_review -ne $true) {
        throw "Environment '$environmentName' must require at least one independent reviewer and prevent self-review."
    }
    foreach ($reviewer in @($reviewRules[0].reviewers)) {
        if ([string]$reviewer.type -cnotmatch '^(User|Team)$' -or
            ([string]::IsNullOrWhiteSpace([string]$reviewer.reviewer.login) -and
             [string]::IsNullOrWhiteSpace([string]$reviewer.reviewer.slug))) {
            throw "Environment '$environmentName' has an invalid required reviewer."
        }
    }

    if ($environment.deployment_branch_policy.protected_branches -ne $false -or
        $environment.deployment_branch_policy.custom_branch_policies -ne $true) {
        throw "Environment '$environmentName' must use an explicit custom release-tag policy."
    }
    $branchPolicies = Invoke-GitHubPolicyRequest `
        -RelativePath "environments/$encodedName/deployment-branch-policies?per_page=100"
    $policies = @($branchPolicies.branch_policies)
    if ([int]$branchPolicies.total_count -ne 1 -or
        $policies.Count -ne 1 -or
        [string]$policies[0].type -cne 'tag' -or
        [string]$policies[0].name -cne 'release-v*.*.*') {
        throw "Environment '$environmentName' must allow exactly the custom tag pattern 'release-v*.*.*' and no branch patterns."
    }
}

if ($distinctEnvironments.Count -lt 1 -or $distinctEnvironments.Count -gt 8) {
    throw 'Between one and eight distinct protected release environments must be checked.'
}

Write-Output (
    "Validated organization ownership, immutable releases, Actions allowlisting, " +
    "OIDC subject binding, main/tag protection, and protected environment policy for '$Repository'.")
