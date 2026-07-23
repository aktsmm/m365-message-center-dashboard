<#
.SYNOPSIS
    Serially backfills validated Message Center translations using an authorized gh CLI identity.
#>
[CmdletBinding()]
param(
    [string]$Repository = 'aktsmm/m365-message-center-dashboard',
    [ValidateRange(1, 10)][int]$BatchSize = 4,
    [ValidateRange(1, 5)][int]$BatchAttempts = 2,
    [ValidateRange(0, 100)][int]$MaximumBatches = 0
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

function Get-MainMessages {
    $content = (Invoke-Gh -Arguments @(
        'api', "repos/$Repository/contents/reports/m365/latest/messages.json?ref=main", '--jq', '.content'
    )) -join ''
    return ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($content)) | ConvertFrom-Json)
}

function Get-CurrentTranslationState {
    $insights = Get-MainInsights
    $messages = Get-MainMessages
    $currentIds = @{}
    foreach ($message in @($messages.messages)) {
        $currentIds[([string]$message.id).Trim().ToUpperInvariant()] = $true
    }
    $translatedIds = @{}
    foreach ($translation in @($insights.messageTranslations)) {
        $id = ([string]$translation.id).Trim().ToUpperInvariant()
        if ($currentIds.ContainsKey($id) -and
            -not [string]::IsNullOrWhiteSpace([string]$translation.japaneseDetailedSummary)) {
            $translatedIds[$id] = $true
        }
    }
    return [pscustomobject]@{
        Insights      = $insights
        CurrentIds       = $currentIds
        TranslatedIds    = $translatedIds
        PendingIds       = @($currentIds.Keys | Where-Object { -not $translatedIds.ContainsKey($_) } | Sort-Object)
        TranslationCount = $translatedIds.Count
    }
}

function Get-RecentTranslationRuns {
    $runsJson = (Invoke-Gh -Arguments @(
        'api', "repos/$Repository/actions/workflows/m365-weekly-translations.lock.yml/runs?event=workflow_dispatch&per_page=30",
        '--jq', '.workflow_runs'
    )) -join [Environment]::NewLine
    return @($runsJson | ConvertFrom-Json)
}

function Wait-ForDispatchedRun {
    param(
        [Parameter(Mandatory)][hashtable]$ExistingRunIds,
        [Parameter(Mandatory)][string]$RequestId
    )

    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $runs = Get-RecentTranslationRuns
        $run = @(
            $runs |
                Where-Object {
                    -not $ExistingRunIds.ContainsKey([string]$_.id) -and
                    [string]$_.display_title -like "*$RequestId*"
                } |
                Sort-Object id -Descending
        ) | Select-Object -First 1
        if ($run) { return $run }
        Start-Sleep -Seconds 4
    }
    throw 'The dispatched translation workflow run was not discovered for the authenticated operator.'
}

function Invoke-VerifiedTranslationBatch {
    param([Parameter(Mandatory)][string[]]$Ids)

    $beforeState = Get-CurrentTranslationState
    $existingRunIds = @{}
    foreach ($existingRun in Get-RecentTranslationRuns) {
        $existingRunIds[[string]$existingRun.id] = $true
    }
    $requestId = [guid]::NewGuid().ToString('N')
    Invoke-Gh -Arguments @(
        'workflow', 'run', 'Microsoft 365 Message Center bounded translations',
        '--repo', $Repository, '--ref', 'main',
        '-f', "translation_ids=$($Ids -join ',')",
        '-f', "translation_request_id=$requestId"
    ) | Out-Null
    $run = Wait-ForDispatchedRun -ExistingRunIds $existingRunIds -RequestId $requestId
    & gh run watch $run.id --repo $Repository --exit-status | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Translation run $($run.id) failed."
    }

    $runDetailsJson = (Invoke-Gh -Arguments @(
        'run', 'view', $run.id, '--repo', $Repository, '--json', 'conclusion,jobs'
    )) -join [Environment]::NewLine
    $runDetails = $runDetailsJson | ConvertFrom-Json
    $publisher = @($runDetails.jobs | Where-Object name -eq 'publish_m365_translations') | Select-Object -First 1
    $publisherConclusion = if ($publisher) { [string]$publisher.conclusion } else { 'missing' }
    if ($runDetails.conclusion -ne 'success' -or $publisherConclusion -ne 'success') {
        throw "Translation run $($run.id) did not reach a successful publisher job. Workflow conclusion: $($runDetails.conclusion); publisher conclusion: $publisherConclusion."
    }

    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $state = Get-CurrentTranslationState
        $currentRequestedIds = @(
            $Ids | ForEach-Object { $_.Trim().ToUpperInvariant() } |
                Where-Object { $state.CurrentIds.ContainsKey($_) }
        )
        $unpersisted = @(
            $currentRequestedIds | Where-Object { -not $state.TranslatedIds.ContainsKey($_) }
        )
        if (-not $unpersisted.Count -and $currentRequestedIds.Count) {
            if ($state.TranslationCount -le $beforeState.TranslationCount) {
                throw "Translation run $($run.id) persisted the requested IDs but did not increase the main translation count from $($beforeState.TranslationCount)."
            }
            return [pscustomobject]@{
                RunId            = $run.id
                CurrentIds       = $state.CurrentIds
                TranslatedIds    = $state.TranslatedIds
                TranslationCount = $state.TranslationCount
            }
        }
        Start-Sleep -Seconds 5
    }
    throw "Translation run $($run.id) reported a successful publisher job but did not persist translations for: $($Ids -join ', ')."
}

$failedIds = @{}
$failureReasons = @{}
$completedBatches = 0
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
    if ($batchSucceeded) {
        $completedBatches++
        if ($MaximumBatches -and $completedBatches -ge $MaximumBatches) {
            $limitedState = Get-CurrentTranslationState
            Write-Host "Stopped after $completedBatches verified batch(es): $($limitedState.TranslatedIds.Count)/$($limitedState.CurrentIds.Count) current cards are translated."
            return
        }
        continue
    }

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
