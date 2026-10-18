[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$temporary = Join-Path ([IO.Path]::GetTempPath()) "m365-repair-$([guid]::NewGuid().ToString('N'))"
$latest = Join-Path $temporary 'latest'
New-Item -ItemType Directory -Path $latest -Force | Out-Null
$calls = [Collections.Generic.List[string]]::new()
$retryAgent = 'skipped'
function gh {
    $command = $args -join ' '
    $calls.Add($command)
    $global:LASTEXITCODE = 0
    if ($command -like 'run list*') { return '[]' }
    if ($command -like 'api*') {
        return '{"status":"completed","head_branch":"main","event":"workflow_dispatch","actor":{"login":"github-actions[bot]"},"path":".github/workflows/m365-weekly-insights.lock.yml","created_at":"2026-10-16T01:00:01Z"}'
    }
    if ($command -like 'run view*') {
        return (@{ jobs = @(@{ name = 'agent'; conclusion = $retryAgent }, @{ name = 'publish_m365_dashboard'; conclusion = 'skipped' }) } | ConvertTo-Json -Depth 5)
    }
}
try {
    foreach ($name in @('m365-weekly-insights.md', 'm365-weekly-translations.md')) {
        $workflow = Get-Content -LiteralPath (Join-Path $root ".github\workflows\$name") -Raw -Encoding UTF8
        if ($workflow -notmatch '(?m)^  bots:\s*\r?\n    - "github-actions\[bot\]"' -or
            -not $workflow.Contains("if: github.ref == 'refs/heads/main' &&") -or
            $workflow -match '(?m)^  roles:') {
            throw 'Trusted automation must use only the exact bot allowlist on main and preserve default human roles.'
        }
    }
    $message = [ordered]@{
        id = 'MC900001'; title = 'Microsoft Teams meeting control'; category = 'PlanForChange'
        bodyText = 'Synthetic approved source.'; services = @('Microsoft Teams')
        actionRequiredByDateTime = $null
    }
    $document = @{ meta = @{ source = 'fixture'; generatedAt = '2026-10-16T00:00:00Z'; publicFieldPolicy = 'Lab-public content. Synthetic fixture.' }; messages = @($message) }
    $messagesPath = Join-Path $latest 'messages.json'
    $document | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $messagesPath -Encoding UTF8
    $insights = [ordered]@{
        headline = '会議コントロールの変更'; executiveSummary = '会議設定への影響を確認します。'
        thisWeek = 'MC900001: 会議設定を確認'; thisMonth = 'MC900001: 展開に備える'
        watch = 'MC1727: なし'; customerQuestions = '利用部門と対象を確認します。'
        referencedIds = @('MC900001'); messageTranslations = @()
    }
    $insightsPath = Join-Path $latest 'insights.json'
    $insights | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $insightsPath -Encoding UTF8
    $parameters = @{
        SnapshotRoot = $temporary; Repository = 'example/dashboard'
        ReferenceTime = [DateTimeOffset]'2026-10-16T01:00:00Z'
    }
    $repair = Join-Path $root 'scripts\Invoke-M365DashboardRepair.ps1'
    $dry = & $repair @parameters | ConvertFrom-Json
    if ($dry.action.lane -ne 'core' -or $dry.action.status -ne 'planned' -or $calls.Count) {
        throw 'Dry run must plan summary repair without GitHub calls.'
    }
    $statePath = Join-Path $temporary 'repair-state.json'
    if (Test-Path -LiteralPath $statePath) { throw 'Dry run must not persist a repair checkpoint.' }
    $previousActions = $env:GITHUB_ACTIONS
    try {
        $env:GITHUB_ACTIONS = 'true'
        $blocked = & $repair @parameters -Apply | ConvertFrom-Json
        if ($blocked.action.status -ne 'authorization_required' -or $calls.Count) {
            throw 'Unapproved automation must stop before any dispatch or role bypass.'
        }
    } finally { $env:GITHUB_ACTIONS = $previousActions }
    $applied = & $repair @parameters -Apply -TrustedAutomationApproved | ConvertFrom-Json
    if ($applied.action.status -ne 'dispatched' -or @($calls | Where-Object { $_ -like 'workflow run*' }).Count -ne 1) {
        throw 'Apply must request exactly one scoped repair.'
    }
    if (($calls -join "`n") -match 'Export|Graph|azure/login') { throw 'Repair must not acquire Graph data.' }
    $again = & $repair @parameters -Apply -TrustedAutomationApproved | ConvertFrom-Json
    if ($again.action.status -ne 'cooldown' -or @($calls | Where-Object { $_ -like 'workflow run*' }).Count -ne 1) {
        throw 'Cooldown must prevent duplicate dispatches.'
    }
    $retryAgent = 'success'
    $rejected = $false
    try { & $repair @parameters -Apply -TrustedAutomationApproved -RetrySkippedRunId 123 | Out-Null } catch { $rejected = $true }
    if (-not $rejected -or @($calls | Where-Object { $_ -like 'workflow run*' }).Count -ne 1) {
        throw 'An actually started agent must keep its cooldown.'
    }
    $retryAgent = 'skipped'
    $retried = & $repair @parameters -Apply -TrustedAutomationApproved -RetrySkippedRunId 123 | ConvertFrom-Json
    if ($retried.action.status -ne 'dispatched' -or $retried.action.retrySkippedRunId -ne 123 -or
        @($calls | Where-Object { $_ -like 'workflow run*' }).Count -ne 2) {
        throw 'Only a verified not-started attempt may be retried once.'
    }
    . (Join-Path $root 'scripts\M365DashboardContent.ps1')
    $insights.watch = 'MC900001: 展開状況を確認'
    $insights.summarySourceHash = Get-M365SnapshotSourceHash -Document $document
    $insights | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $insightsPath -Encoding UTF8
    $later = @{ SnapshotRoot = $temporary; Repository = 'example/dashboard'; ReferenceTime = [DateTimeOffset]'2026-10-17T02:00:00Z' }
    $translation = & $repair @later | ConvertFrom-Json
    if ($translation.action.lane -ne 'translations' -or $translation.translations.pending -ne 1) {
        throw 'A repaired summary must allow the bounded translation lane.'
    }
    $insights.messageTranslations = @(@{ id = 'MC900001'; sourceHash = Get-M365MessageSourceHash -Message $message; japaneseTitle = '更新内容を確認する通知です'; japaneseFacts = @{ change = '変更内容を確認します。' } })
    $insights | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $insightsPath -Encoding UTF8
    $healthy = & $repair @later | ConvertFrom-Json
    if ($healthy.action.status -ne 'not_needed' -or $healthy.translations.pending) {
        throw 'Healthy content must not dispatch more agent work.'
    }
    $accepted = Join-Path $temporary 'accepted.json'
    Copy-Item -LiteralPath $messagesPath -Destination $accepted
    Assert-M365SnapshotCurrent -AcceptedJson $accepted -CurrentJson $messagesPath
    $document.messages[0].bodyText = 'Newer source must not be overwritten.'
    $document | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $messagesPath -Encoding UTF8
    $rejected = $false
    try { Assert-M365SnapshotCurrent -AcceptedJson $accepted -CurrentJson $messagesPath } catch { $rejected = $true }
    if (-not $rejected) { throw 'A stale agent source must never overwrite the newer snapshot.' }
    Write-Host 'Repair planning, scoped dispatch, cooldown, no-op and source-race checks passed.'
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
