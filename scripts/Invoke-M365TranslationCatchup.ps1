<#
.SYNOPSIS
    Serially backfills validated Message Center translations using an authorized gh CLI identity.
#>
[CmdletBinding()]
param(
    [string]$Repository = 'aktsmm/m365-message-center-dashboard',
    [ValidateRange(1, 10)][int]$BatchSize = 4,
    [ValidateRange(1, 5)][int]$BatchAttempts = 2
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Gh {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & gh @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "gh $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return @($output)
}

function Get-MainInsights {
    $content = (Invoke-Gh -Arguments @(
        'api', "repos/$Repository/contents/reports/m365/latest/insights.json?ref=main", '--jq', '.content'
    )) -join ''
    return ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($content)) | ConvertFrom-Json)
}

function Get-CurrentTranslationState {
    $insights = Get-MainInsights
    $currentIds = @{}
    foreach ($update in @($insights.messageUpdates)) {
        $currentIds[([string]$update.id).Trim().ToUpperInvariant()] = $true
    }
    $translatedIds = @{}
    foreach ($translation in @($insights.messageTranslations)) {
        $id = ([string]$translation.id).Trim().ToUpperInvariant()
        if (-not [string]::IsNullOrWhiteSpace([string]$translation.japaneseDetailedSummary)) {
            $translatedIds[$id] = $true
        }
    }
    return [pscustomobject]@{
        Insights      = $insights
        CurrentIds    = $currentIds
        TranslatedIds = $translatedIds
        PendingIds    = @($currentIds.Keys | Where-Object { -not $translatedIds.ContainsKey($_) } | Sort-Object)
    }
}

function Wait-ForDispatchedRun {
    param(
        [Parameter(Mandatory)][DateTimeOffset]$StartedAt,
        [Parameter(Mandatory)][string]$ActorLogin
    )

    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $runs = (Invoke-Gh -Arguments @(
            'run', 'list', '--repo', $Repository,
            '--workflow', 'Microsoft 365 Message Center bounded translations',
            '--event', 'workflow_dispatch', '--limit', '30',
            '--json', 'databaseId,createdAt,actor'
        ) -join [Environment]::NewLine | ConvertFrom-Json)
        $run = @(
            $runs |
                Where-Object {
                    $_.actor.login -eq $ActorLogin -and
                    [DateTimeOffset]::Parse([string]$_.createdAt) -ge $StartedAt.AddSeconds(-5)
                } |
                Sort-Object databaseId -Descending
        ) | Select-Object -First 1
        if ($run) { return $run }
        Start-Sleep -Seconds 4
    }
    throw 'The dispatched translation workflow run was not discovered for the authenticated operator.'
}

function Invoke-VerifiedTranslationBatch {
    param([Parameter(Mandatory)][string[]]$Ids)

    $actorLogin = ((Invoke-Gh -Arguments @('api', 'user', '--jq', '.login')) -join '').Trim()
    $startedAt = [DateTimeOffset]::UtcNow
    Invoke-Gh -Arguments @(
        'workflow', 'run', 'Microsoft 365 Message Center bounded translations',
        '--repo', $Repository, '--ref', 'main', '-f', "translation_ids=$($Ids -join ',')"
    ) | Out-Null
    $run = Wait-ForDispatchedRun -StartedAt $startedAt -ActorLogin $actorLogin
    & gh run watch $run.databaseId --repo $Repository --exit-status
    if ($LASTEXITCODE -ne 0) {
        throw "Translation run $($run.databaseId) failed."
    }

    $runDetails = (Invoke-Gh -Arguments @(
        'run', 'view', $run.databaseId, '--repo', $Repository, '--json', 'conclusion,jobs'
    ) -join [Environment]::NewLine | ConvertFrom-Json)
    $publisher = @($runDetails.jobs | Where-Object name -eq 'publish_m365_translations') | Select-Object -First 1
    $publisherConclusion = if ($publisher) { [string]$publisher.conclusion } else { 'missing' }
    if ($runDetails.conclusion -ne 'success' -or $publisherConclusion -ne 'success') {
        throw "Translation run $($run.databaseId) did not reach a successful publisher job. Workflow conclusion: $($runDetails.conclusion); publisher conclusion: $publisherConclusion."
    }

    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $state = Get-CurrentTranslationState
        $unpersisted = @(
            $Ids | Where-Object {
                $id = $_.Trim().ToUpperInvariant()
                $state.CurrentIds.ContainsKey($id) -and -not $state.TranslatedIds.ContainsKey($id)
            }
        )
        if (-not $unpersisted.Count) {
            return [pscustomobject]@{
                RunId       = $run.databaseId
                CurrentIds   = $state.CurrentIds
                TranslatedIds = $state.TranslatedIds
            }
        }
        Start-Sleep -Seconds 5
    }
    throw "Translation run $($run.databaseId) reported a successful publisher job but did not persist translations for: $($Ids -join ', ')."
}

$failedIds = @{}
$failureReasons = @{}
while ($true) {
    $state = Get-CurrentTranslationState
    $pending = @($state.PendingIds | Where-Object { -not $failedIds.ContainsKey($_) })
    if (-not $pending.Count) { break }

    $batch = @($pending | Select-Object -First $BatchSize)
    $batchSucceeded = $false
    $batchReason = $null
    for ($attempt = 1; $attempt -le $BatchAttempts; $attempt++) {
        try {
            $result = Invoke-VerifiedTranslationBatch -Ids $batch
            Write-Host "Persisted translation batch in run $($result.RunId): $($batch -join ', ')"
            $batchSucceeded = $true
            break
        } catch {
            $batchReason = $_.Exception.Message
            Write-Warning "Batch attempt $attempt/$BatchAttempts failed for $($batch -join ', '): $batchReason"
        }
    }
    if ($batchSucceeded) { continue }

    foreach ($id in $batch) {
        $itemSucceeded = $false
        $itemReason = $batchReason
        for ($attempt = 1; $attempt -le $BatchAttempts; $attempt++) {
            try {
                $result = Invoke-VerifiedTranslationBatch -Ids @($id)
                Write-Host "Persisted isolated translation in run $($result.RunId): $id"
                $itemSucceeded = $true
                break
            } catch {
                $itemReason = $_.Exception.Message
                Write-Warning "Isolated attempt $attempt/$BatchAttempts failed for ${id}: $itemReason"
            }
        }
        if (-not $itemSucceeded) {
            $failedIds[$id] = $true
            $failureReasons[$id] = $itemReason
        }
    }
}

$finalState = Get-CurrentTranslationState
if ($failedIds.Count) {
    $details = @(
        $failedIds.Keys | Sort-Object | ForEach-Object { "${_}: $($failureReasons[$_])" }
    ) -join [Environment]::NewLine
    throw "Translation catch-up could not validate or persist the following MC IDs:$([Environment]::NewLine)$details"
}
if ($finalState.PendingIds.Count) {
    throw "Translation catch-up ended with untranslated current MC IDs: $($finalState.PendingIds -join ', ')"
}
Write-Host "Translation catch-up completed: $($finalState.TranslatedIds.Count)/$($finalState.CurrentIds.Count) current cards have validated detailed Japanese translations."
