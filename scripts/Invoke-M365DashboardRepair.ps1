<#
.SYNOPSIS
    Inspects approved on-disk content and requests at most one bounded repair.
#>
[CmdletBinding()]
param(
    [string]$SnapshotRoot = (Join-Path $PSScriptRoot '..\reports\m365'),
    [string]$Repository = $env:GITHUB_REPOSITORY,
    [string]$StatePath,
    [DateTimeOffset]$ReferenceTime = [DateTimeOffset]::UtcNow,
    [switch]$TrustedAutomationApproved,
    [long]$RetrySkippedRunId = 0,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'M365DashboardContent.ps1')
if (-not $StatePath) { $StatePath = Join-Path $SnapshotRoot 'repair-state.json' }
if ($Apply -and $Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw 'A scoped owner/repository is required for repair dispatch.'
}
$messagesPath = Join-Path $SnapshotRoot 'latest\messages.json'
if (-not (Test-Path -LiteralPath $messagesPath)) { throw 'Approved current snapshot is missing.' }
$document = Get-Content -LiteralPath $messagesPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($document.meta.source -notin @('Microsoft Graph', 'fixture') -or
    $document.meta.PSObject.Properties.Name -notcontains 'publicFieldPolicy' -or
    $document.meta.publicFieldPolicy -notmatch '^Lab-public content\.') {
    throw 'Repair requires an exported approved lab-public snapshot.'
}
$insightsPath = Join-Path $SnapshotRoot 'latest\insights.json'
$insights = if (Test-Path -LiteralPath $insightsPath) {
    Get-Content -LiteralPath $insightsPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else { $null }
$validation = if ($insights) { Get-M365SummaryValidation -Insights $insights -Messages @($document.messages) } else {
    @{ valid = $false; reason = 'missing_summary' }
}
$summaryStatus = if (-not $validation.valid) { 'invalid' } elseif (
    $insights.PSObject.Properties.Name -notcontains 'summarySourceHash') { 'unverified' } elseif (
    $insights.summarySourceHash -ne (Get-M365SnapshotSourceHash -Document $document)) { 'stale' } else { 'current' }
$translations = @{}
if ($insights -and $insights.PSObject.Properties.Name -contains 'messageTranslations') {
    foreach ($translation in @($insights.messageTranslations)) { $translations[$translation.id] = $translation }
}
$currentCount = @($document.messages | Where-Object {
    $translations.ContainsKey($_.id) -and (Test-M365TranslationSource -Translation $translations[$_.id] -Message $_)
}).Count
$previous = if (Test-Path -LiteralPath $StatePath) {
    Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
} else { @{ schemaVersion = 1; attempts = @{} } }
if ($previous.schemaVersion -ne 1 -or -not $previous.ContainsKey('attempts')) {
    throw 'Unsupported repair checkpoint schema.'
}
$plan = [ordered]@{
    schemaVersion = 1
    observedAt = $ReferenceTime.ToUniversalTime().ToString('o')
    snapshotGeneratedAt = $document.meta.generatedAt
    summary = @{ status = $summaryStatus; reason = $validation.reason }
    translations = @{ total = @($document.messages).Count; current = $currentCount; pending = @($document.messages).Count - $currentCount }
    attempts = $previous.attempts
    action = @{ status = 'not_needed'; lane = $null; workflow = $null }
}
$lane = if ($summaryStatus -ne 'current') { 'core' } elseif ($plan.translations.pending -gt 0) { 'translations' } else { $null }
if ($lane) {
    $workflow = if ($lane -eq 'core') { 'm365-weekly-insights.lock.yml' } else { 'm365-weekly-translations.lock.yml' }
    $plan.action = @{ status = 'planned'; lane = $lane; workflow = $workflow }
    $attempt = $plan.attempts[$lane]
    if ($attempt -and ($ReferenceTime - [DateTimeOffset]$attempt.requestedAt).TotalHours -lt 24) {
        $plan.action.status = 'cooldown'
        $plan.action.nextAttemptAt = ([DateTimeOffset]$attempt.requestedAt).AddHours(24).ToString('o')
    }
}
if ($Apply -and $lane -and $env:GITHUB_ACTIONS -eq 'true' -and -not $TrustedAutomationApproved) {
    $plan.action.status = 'authorization_required'
    $plan.action.reason = 'Trusted automation approval has not been recorded. No dispatch is attempted until the scoped bot allowlist is approved.'
}
if ($Apply -and $lane -and $plan.action.status -eq 'cooldown' -and $RetrySkippedRunId -gt 0) {
    $runJson = gh api "repos/$Repository/actions/runs/$RetrySkippedRunId"
    if ($LASTEXITCODE -ne 0) { throw 'Could not verify the previously skipped run.' }
    $run = $runJson | ConvertFrom-Json
    if ($run.status -ne 'completed' -or $run.head_branch -ne 'main' -or
        $run.event -ne 'workflow_dispatch' -or $run.actor.login -ne 'github-actions[bot]' -or
        $run.path -ne ".github/workflows/$($plan.action.workflow)") {
        throw 'Retry requires the completed, scoped bot workflow on main.'
    }
    $requestedAt = [DateTimeOffset]$plan.attempts[$lane].requestedAt
    $createdAt = [DateTimeOffset]$run.created_at
    if ($createdAt -lt $requestedAt.AddSeconds(-5) -or $createdAt -gt $requestedAt.AddMinutes(5)) {
        throw 'The skipped run does not match the recorded most recent repair attempt.'
    }
    $jobsJson = gh run view $RetrySkippedRunId --repo $Repository --json jobs
    if ($LASTEXITCODE -ne 0) { throw 'Could not verify whether the agent actually started.' }
    $jobs = @(($jobsJson | ConvertFrom-Json).jobs)
    $agents = @($jobs | Where-Object name -eq 'agent')
    $publishers = @($jobs | Where-Object { $_.name -in @('publish_m365_dashboard', 'publish_m365_translations') })
    if ($agents.Count -ne 1 -or $agents[0].conclusion -ne 'skipped' -or
        @($publishers | Where-Object conclusion -ne 'skipped').Count) {
        throw 'The previous agent started or publishing ran; its cooldown cannot be reset.'
    }
    $plan.action.status = 'planned'
    $plan.action.retrySkippedRunId = $RetrySkippedRunId
    $plan.action.Remove('nextAttemptAt')
}

function Save-RepairCheckpoint {
    $parent = Split-Path -Parent $StatePath
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = "$StatePath.tmp"
    $plan | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $StatePath -Force
}

if ($Apply -and $plan.action.status -eq 'planned') {
    $runsJson = gh run list --repo $Repository --workflow $plan.action.workflow --branch main --limit 5 --json 'databaseId,status'
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the scoped workflow before repair.' }
    $active = @($runsJson | ConvertFrom-Json | Where-Object status -in @('queued', 'in_progress', 'waiting', 'pending', 'requested'))
    if ($active.Count) {
        $plan.action.status = 'already_running'
    } else {
        $stamp = @{ requestedAt = $plan.observedAt; status = 'requested'; workflow = $plan.action.workflow }
        if ($plan.action.ContainsKey('retrySkippedRunId')) { $stamp.previousSkippedRunId = $plan.action.retrySkippedRunId }
        $plan.attempts[$lane] = $stamp
        # A successful core run already triggers one bounded translation run.
        if ($lane -eq 'core') {
            $plan.attempts.translations = @{ requestedAt = $plan.observedAt; status = 'following_core'; workflow = 'm365-weekly-translations.lock.yml' }
        }
        Save-RepairCheckpoint
        gh workflow run $plan.action.workflow --repo $Repository --ref main
        if ($LASTEXITCODE -ne 0) {
            $plan.attempts[$lane].status = 'dispatch_failed'
            $plan.action.status = 'dispatch_failed'
            Save-RepairCheckpoint
            throw 'Repair dispatch failed. The checkpoint records the failure; inspect the scoped workflow permissions.'
        }
        $plan.attempts[$lane].status = 'dispatched'
        $plan.action.status = 'dispatched'
    }
}
if ($Apply) { Save-RepairCheckpoint }
$plan | ConvertTo-Json -Depth 10
