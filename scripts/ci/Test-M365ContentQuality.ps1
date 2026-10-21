[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scripts = Split-Path -Parent $PSScriptRoot
. (Join-Path $scripts 'M365DashboardContent.ps1')
$owned = Join-Path (Get-Location) ".m365-content-test-$([guid]::NewGuid().ToString('N'))"
$checks = 0
function Assert-Quality {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:checks++
}
function Assert-Rejected {
    param([scriptblock]$Action, [string]$Name)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-Quality $rejected $Name
}
function Write-Fixture {
    param($Value, [string]$Path)
    ConvertTo-Json -InputObject $Value -Depth 12 | Set-Content -LiteralPath $Path -Encoding utf8
}
try {
    New-Item -ItemType Directory -Path $owned | Out-Null
    $messages = @(foreach ($i in 1..6) {
        [pscustomobject]@{
            id = "MC$i"; title = "Change $i"; category = 'planForChange'
            bodyText = ('Source body text. ' * 90); services = @('Teams', 'Exchange')
            actionRequiredByDateTime = '2026-11-01T09:00:00+09:00'
            lastModifiedDateTime = "2026-10-0${i}T00:00:00Z"
            japaneseTitle = '変更のお知らせ'; japaneseSummary = 'サービスの変更について確認します。'
            details = @([pscustomobject]@{ name = 'url'; value = "https://admin.microsoft.com/#/MessageCenter/:/messages/MC$i" })
        }
    })
    $document = [pscustomobject]@{
        meta = @{ source = 'fixture'; publicFieldPolicy = 'Lab-public content. Approved fixture.' }
        messages = $messages
    }
    $source = Join-Path $owned 'messages.json'
    $facts = Join-Path $owned 'facts.json'
    $previousPath = Join-Path $owned 'previous.json'
    $output = Join-Path $owned 'public'
    $context = Join-Path $owned 'context.json'
    Write-Fixture $document $source
    Write-Fixture @{ summary = @{ total = 6 } } $facts
    $params = @{ MessagesJson = $source; OutputDirectory = $output; AgentContextPath = $context; Mode = 'Translations'; PreviousInsightsPath = $previousPath }
    $hash = Get-M365MessageSourceHash $messages[0]
    Assert-Quality ($hash -cmatch '^[a-f0-9]{64}$') 'SHA256 lowercase format'
    $equivalent = $messages[0] | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $equivalent.services = @('exchange', ' Teams ')
    $equivalent.actionRequiredByDateTime = '2026-11-01T00:00:00Z'
    Assert-Quality ((Get-M365MessageSourceHash $equivalent) -ceq $hash) 'Canonical services and UTC timestamp'
    $equivalent.bodyText = "First`r`nSecond"
    $crlfHash = Get-M365MessageSourceHash $equivalent
    $equivalent.bodyText = "First`nSecond"
    Assert-Quality ((Get-M365MessageSourceHash $equivalent) -ceq $crlfHash) 'Canonical body newlines'
    $equivalent.bodyText = $messages[0].bodyText
    Assert-Quality (-not (Test-M365TranslationSource @{ id = 'MC1' } $messages[0])) 'Unbound legacy translation is stale'
    Assert-Quality (Test-M365TranslationSource @{ sourceHash = $hash } $messages[0]) 'Bound translation is fresh'
    $equivalent.bodyText += ' Changed.'
    Assert-Quality (-not (Test-M365TranslationSource @{ sourceHash = $hash } $equivalent)) 'Changed same-ID source invalidates translation'
    Assert-Quality ((ConvertTo-M365ContentText 'one\nsecond\r\nthird') -ceq "one`nsecond`nthird") 'Literal newline normalization'
    $summary = [ordered]@{
        headline = '変更の概要'; executiveSummary = 'サービスの変更を確認します。'
        thisWeek = 'MC1 の変更内容を確認します。'; thisMonth = '公開された情報を確認します。'
        watch = '今後の更新内容を継続確認します。'; customerQuestions = '利用状況を確認してください。'
        referencedIds = @('MC1'); messageTranslations = @()
    }
    Assert-Quality (Get-M365SummaryValidation $summary $messages).valid 'Legitimate summary accepted'
    $summary.watch = 'MC1727: なし\nMC1727: なし'
    $validation = Get-M365SummaryValidation $summary $messages
    Assert-Quality (-not $validation.valid -and 'MC1727' -in $validation.unknownIds) 'Unknown inline ID rejected with valid declared IDs'
    $summary.watch = 'MC1: なし'
    Assert-Quality (-not (Get-M365SummaryValidation $summary $messages).valid) 'Known placeholder rejected'
    $summary.watch = '同じ具体的な確認事項を繰り返します。\n同じ具体的な確認事項を繰り返します。'
    Assert-Quality (-not (Get-M365SummaryValidation $summary $messages).valid) 'Duplicate substantive escaped lines rejected'
    $summary.watch = 'MC2 の変更を継続確認します。'
    Assert-Quality (-not (Get-M365SummaryValidation $summary $messages).valid) 'Undeclared inline citation rejected'
    $summary.watch = '今後の更新内容を継続確認します。'
    Write-Fixture $summary $previousPath
    & (Join-Path $scripts 'New-M365AgentContext.ps1') @params
    $batchPath = Join-Path $output 'translation-batch.json'
    $batch = Get-Content -LiteralPath $batchPath -Raw | ConvertFrom-Json
    Assert-Quality (@($batch.messages).Count -eq 4 -and $batch.messages[0].id -eq 'MC6') 'Automatic queue bounded and newest first'
    Assert-Quality ((Get-FileHash -LiteralPath $source).Hash -eq (Get-FileHash -LiteralPath (Join-Path $output 'messages.json')).Hash) 'Messages bytes preserved'
    Assert-Quality ((Get-FileHash -LiteralPath $facts).Hash -eq (Get-FileHash -LiteralPath (Join-Path $output 'facts.json')).Hash) 'Facts bytes preserved'
    Assert-Quality ((Get-M365SnapshotSourceHash -Document @{ messages = @($messages[5..0]) }) -ceq (Get-M365SnapshotSourceHash -Document $document)) 'Snapshot hash independent of exported order'
    $contextDocument = Get-Content -LiteralPath $context -Raw | ConvertFrom-Json
    Assert-Quality ($contextDocument.translationBatch[0].bodyText.Length -eq 1000 -and $batch.messages[0].sourceCharacterCount -eq 1000 -and $batch.messages[0].sourceTruncated) 'Bounded source counters'
    $agent = [ordered]@{ items = @([ordered]@{
        type = 'publish_m365_dashboard'; headline = $summary.headline; executive_summary = $summary.executiveSummary
        this_week = 'MC1 の変更内容を確認します。\n確認内容を整理してください。'
        this_month = $summary.thisMonth; watch = $summary.watch; customer_questions = $summary.customerQuestions
        referenced_ids = 'MC1'
        translation_updates = @(foreach ($b in $batch.messages) {
            @{ id = $b.id; japanese_detailed_summary = ('今回の変更内容と影響を、提示された本文の範囲で確認してください。' * 4)
                japanese_body_translation = '提示された本文の日本語訳です。'; source_character_count = $b.sourceCharacterCount; source_truncated = $b.sourceTruncated }
        })
    }) }
    $agentPath = Join-Path $owned 'agent.json'
    $publishedPath = Join-Path $owned 'insights.json'
    Write-Fixture $agent $agentPath
    $publish = @{ AgentOutputPath = $agentPath; MessagesJson = $source; TranslationBatchJson = $batchPath; PreviousInsightsPath = $previousPath; UseDeterministicMessageUpdates = $true; OutputPath = $publishedPath }
    & (Join-Path $scripts 'Publish-M365AgentInsights.ps1') @publish
    $published = Get-Content -LiteralPath $publishedPath -Raw | ConvertFrom-Json
    Assert-Quality ($published.thisWeek.Contains("`n") -and -not $published.thisWeek.Contains('\n')) 'Publisher normalizes literal newlines'
    Assert-Quality ($published.summarySourceHash -ceq (Get-M365SnapshotSourceHash -Document $document)) 'Summary bound to snapshot'
    $recoveryPublish = @{} + $publish
    $recoveryPublish.OutputPath = Join-Path $owned 'recovered-insights.json'
    & (Join-Path $scripts 'Publish-M365AgentInsights.ps1') @recoveryPublish `
        -SourceGeneratedAt '2026-10-14T00:00:00Z' -SourceAgentRunId '123'
    $recovered = Get-Content -LiteralPath $recoveryPublish.OutputPath -Raw | ConvertFrom-Json
    Assert-Quality (([DateTimeOffset]$recovered.summaryGeneratedAt) -eq [DateTimeOffset]'2026-10-14T00:00:00Z') 'Recovery preserves original model completion time'
    Assert-Quality ($recovered.sourceAgentRunId -eq '123') 'Recovery records the original source run'
    foreach ($translation in $published.messageTranslations) {
        $m = @($messages | Where-Object id -eq $translation.id)[0]
        Assert-Quality ((Test-M365TranslationSource $translation $m) -and $translation.validatedAt -and $translation.sourceCharacterCount -eq 1000 -and $translation.sourceTruncated) 'Publisher derives translation hash and counters'
    }
    $agent.items[0].watch = 'MC1727 の変更を確認します。'
    Write-Fixture $agent $agentPath
    Assert-Rejected { & (Join-Path $scripts 'Publish-M365AgentInsights.ps1') @publish } 'Publisher refuses inline fabricated ID'
    $agent.items[0].watch = $summary.watch
    Write-Fixture $agent $agentPath
    $batch.messages[0].sourceHash = '0' * 64
    Write-Fixture $batch $batchPath
    Assert-Rejected { & (Join-Path $scripts 'Publish-M365AgentInsights.ps1') @publish } 'Publisher verifies supplied batch hash'
    $batch.messages[0].PSObject.Properties.Remove('sourceHash')
    Write-Fixture $batch $batchPath
    & (Join-Path $scripts 'Publish-M365AgentInsights.ps1') @publish
    $compat = Get-Content -LiteralPath $publishedPath -Raw | ConvertFrom-Json
    Assert-Quality (Test-M365TranslationSource $compat.messageTranslations[0] (@($messages | Where-Object id -eq $compat.messageTranslations[0].id)[0])) 'Legacy batch without hash receives actual publisher hash'
    $batch.messages[0].sourceCharacterCount = $messages[0].bodyText.Length + 1
    Write-Fixture $batch $batchPath
    Assert-Rejected { & (Join-Path $scripts 'Publish-M365AgentInsights.ps1') @publish } 'Impossible source counters rejected'
    & (Join-Path $scripts 'New-M365AgentContext.ps1') @params
    $batch = Get-Content -LiteralPath $batchPath -Raw | ConvertFrom-Json
    $typed = [ordered]@{ type = 'publish_m365_translations' }
    for ($slot = 1; $slot -le 4; $slot++) {
        $b = $batch.messages[$slot - 1]
        $typed["translation_${slot}_id"] = $b.id
        $typed["translation_${slot}_japanese_title"] = 'Teams の会議設定を更新します'
        $typed["translation_${slot}_japanese_facts"] = "変更：会議設定の既定値が変更されます。`n影響：原文に記載なし`n時期：段階的に展開されます。`n対応：管理者は設定を確認してください。"
        $typed["translation_${slot}_japanese_detailed_summary"] = '変更内容と影響を提示された本文の範囲で確認してください。' * 4
        $typed["translation_${slot}_japanese_body_translation"] = '提示された本文の日本語訳です。'
        $typed["translation_${slot}_source_character_count"] = $b.sourceCharacterCount
        $typed["translation_${slot}_source_truncated"] = $b.sourceTruncated
    }
    Write-Fixture @{ items = @($typed) } $agentPath
    $summary.summaryGeneratedAt = '2026-10-01T00:00:00Z'
    $summary.summarySourceHash = $published.summarySourceHash
    $summary.messageTranslations = @(@{ id = 'MC1'; japaneseDetailedSummary = '以前の要約です。' })
    Write-Fixture $summary $previousPath
    $bridgeParams = @{ AgentOutputPath = $agentPath; MessagesJson = $source; TranslationBatchJson = $batchPath; PreviousInsightsPath = $previousPath; OutputPath = $publishedPath }
    & (Join-Path $scripts 'Publish-M365AgentTranslations.ps1') @bridgeParams
    $merged = Get-Content -LiteralPath $publishedPath -Raw | ConvertFrom-Json
    Assert-Quality ([DateTimeOffset]$merged.summaryGeneratedAt -eq [DateTimeOffset]$summary.summaryGeneratedAt -and $merged.summarySourceHash -ceq $summary.summarySourceHash) 'Translation bridge preserves core provenance'
    $legacy = @($merged.messageTranslations | Where-Object id -eq 'MC1')[0]
    Assert-Quality ($legacy.PSObject.Properties.Name -notcontains 'sourceHash') 'Historical translation not relabeled current'
    $titled = @($merged.messageTranslations | Where-Object id -eq $batch.messages[0].id)[0]
    Assert-Quality ($titled.japaneseTitle -ceq 'Teams の会議設定を更新します') 'Publisher stores validated Japanese title'
    Assert-Quality ($titled.japaneseFacts.change -ceq '会議設定の既定値が変更されます。' -and $titled.japaneseFacts.impact -ceq '原文に記載なし') 'Publisher stores validated Japanese facts'
    $typed['translation_1_japanese_facts'] = "変更：会議設定の既定値が変更されます。`n影響：原文に記載なし`n時期：2031年に開始します。`n対応：管理者は設定を確認してください。"
    Write-Fixture @{ items = @($typed) } $agentPath
    Assert-Rejected { & (Join-Path $scripts 'Publish-M365AgentTranslations.ps1') @bridgeParams } 'Year absent from the notification rejected'
    $typed['translation_1_japanese_facts'] = "変更：English only fact`n影響：原文に記載なし`n時期：段階的に展開されます。`n対応：管理者は設定を確認してください。"
    Write-Fixture @{ items = @($typed) } $agentPath
    Assert-Rejected { & (Join-Path $scripts 'Publish-M365AgentTranslations.ps1') @bridgeParams } 'Non-Japanese fact rejected'
    $typed['translation_1_japanese_facts'] = "変更：会議設定の既定値が変更されます。`n影響：原文に記載なし`n時期：段階的に展開されます。`n対応：" + ('管理者は設定を確認してください。' * 40)
    Write-Fixture @{ items = @($typed) } $agentPath
    & (Join-Path $scripts 'Publish-M365AgentTranslations.ps1') @bridgeParams
    $trimmed = @((Get-Content -LiteralPath $publishedPath -Raw | ConvertFrom-Json).messageTranslations | Where-Object id -eq $batch.messages[0].id)[0]
    Assert-Quality ($trimmed.japaneseFacts.action.Length -le 400 -and $trimmed.japaneseFacts.action.EndsWith('。')) 'Over-long Japanese fact is shortened at a sentence boundary instead of failing the batch'
    $typed['translation_1_japanese_facts'] = "変更：会議設定の既定値が変更されます。`n影響：原文に記載なし`n時期：段階的に展開されます。`n対応：管理者は設定を確認してください。"
    Write-Fixture @{ items = @($typed) } $agentPath
    $typed['translation_1_japanese_title'] = 'English only title'
    Write-Fixture @{ items = @($typed) } $agentPath
    Assert-Rejected { & (Join-Path $scripts 'Publish-M365AgentTranslations.ps1') @bridgeParams } 'Non-Japanese title rejected'
    $typed['translation_1_japanese_title'] = 'Teams の会議設定を更新します'
    Write-Fixture @{ items = @($typed) } $agentPath
    $summary.watch = 'MC1727: なし'
    Write-Fixture $summary $previousPath
    Assert-Rejected { & (Join-Path $scripts 'Publish-M365AgentTranslations.ps1') @bridgeParams } 'Bridge refuses invalid inherited weekly summary'
    $summary.watch = '今後の更新内容を継続確認します。'
    $summary.messageTranslations = @(foreach ($m in $messages) { @{ id = $m.id; sourceHash = Get-M365MessageSourceHash $m; japaneseTitle = '更新内容を確認する通知です'; japaneseFacts = @{ change = '変更内容を確認します。' } } })
    Write-Fixture $summary $previousPath
    & (Join-Path $scripts 'New-M365AgentContext.ps1') @params
    Assert-Quality (@((Get-Content -LiteralPath $batchPath -Raw | ConvertFrom-Json).messages).Count -eq 0) 'Fresh queue empty'
    $summary.messageTranslations = @(foreach ($m in $messages) { @{ id = $m.id; sourceHash = Get-M365MessageSourceHash $m; japaneseTitle = '更新内容を確認する通知です' } })
    Write-Fixture $summary $previousPath
    & (Join-Path $scripts 'New-M365AgentContext.ps1') @params
    Assert-Quality (@((Get-Content -LiteralPath $batchPath -Raw | ConvertFrom-Json).messages).Count -gt 0) 'Verified translations lacking Japanese facts are queued'
    $summary.messageTranslations = @(foreach ($m in $messages) { @{ id = $m.id; sourceHash = Get-M365MessageSourceHash $m; japaneseTitle = '更新内容を確認する通知です'; japaneseFacts = @{ change = '変更内容を確認します。' } } })
    Write-Fixture $summary $previousPath
    & (Join-Path $scripts 'New-M365AgentContext.ps1') @params
    & (Join-Path $scripts 'New-M365AgentContext.ps1') @params
    Assert-Quality (@((Get-Content -LiteralPath $batchPath -Raw | ConvertFrom-Json).messages).Count -eq 0) 'Empty queue idempotent'
    $messages[0].bodyText += ' Source changed.'
    Write-Fixture $document $source
    & (Join-Path $scripts 'New-M365AgentContext.ps1') @params
    Assert-Quality (@((Get-Content -LiteralPath $batchPath -Raw | ConvertFrom-Json).messages).Count -eq 1) 'Changed source queued without manual IDs'
    Assert-Rejected { & (Join-Path $scripts 'New-M365AgentContext.ps1') @params -AgentTranslationIds 'MC1,MC1' } 'Duplicate requested IDs rejected'
    Assert-Rejected { & (Join-Path $scripts 'New-M365AgentContext.ps1') @params -AgentTranslationIds 'MC999' } 'Unapproved requested IDs rejected'
    $coreParams = $params.Clone()
    $coreParams.Mode = 'Core'
    & (Join-Path $scripts 'New-M365AgentContext.ps1') @coreParams
    Assert-Quality (@((Get-Content -LiteralPath $context -Raw | ConvertFrom-Json).translationBatch).Count -eq 0) 'Core never requests translations'
    Write-Fixture @{ value = $messages } $source
    Assert-Rejected { & (Join-Path $scripts 'New-M365AgentContext.ps1') @params } 'Raw Graph rejected'
    $document.meta.source = 'unapproved'
    Write-Fixture $document $source
    Assert-Rejected { & (Join-Path $scripts 'New-M365AgentContext.ps1') @params } 'Unapproved snapshot rejected'
    Write-Host "PASS: $checks content quality checks."
} finally {
    if (Test-Path -LiteralPath $owned) { Remove-Item -LiteralPath $owned -Recurse -Force }
}
