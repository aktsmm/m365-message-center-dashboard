[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$temp = Join-Path ([System.IO.Path]::GetTempPath()) "m365-dashboard-$([guid]::NewGuid().ToString('N'))"
$agentContext = Join-Path $temp 'agent-context.json'
$publishedInsights = Join-Path $temp 'insights.json'
$aboutPage = Join-Path $temp 'about\index.html'

try {
    & (Join-Path $root 'scripts\Export-M365MessageCenter.ps1') `
        -InputJsonPath (Join-Path $root 'tests\fixtures\m365-messages.json') `
        -OutputDirectory $temp `
        -LookbackDays 365 `
        -RunId 'fixture-run' `
        -ReferenceTime '2026-07-23T00:00:00Z' `
        -AgentContextPath $agentContext `
        -IncludeContent
    & (Join-Path $root 'scripts\Publish-M365AgentInsights.ps1') `
        -AgentOutputPath (Join-Path $root 'tests\fixtures\gh-aw-agent-output.json') `
        -MessagesJson (Join-Path $temp 'messages.json') `
        -OutputPath $publishedInsights
    & (Join-Path $root 'scripts\New-M365DashboardAboutPage.ps1') `
        -OutputPath $aboutPage
    $stringStructuredOutput = Join-Path $temp 'agent-output-string-updates.json'
    $stringStructuredInsights = Join-Path $temp 'insights-string-updates.json'
    $agentOutputWithStringUpdates = Get-Content -LiteralPath (Join-Path $root 'tests\fixtures\gh-aw-agent-output.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $agentOutputWithStringUpdates.items[0].message_updates = $agentOutputWithStringUpdates.items[0].message_updates | ConvertTo-Json -Depth 8 -Compress
    $agentOutputWithStringUpdates | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $stringStructuredOutput -Encoding UTF8
    & (Join-Path $root 'scripts\Publish-M365AgentInsights.ps1') `
        -AgentOutputPath $stringStructuredOutput `
        -MessagesJson (Join-Path $temp 'messages.json') `
        -OutputPath $stringStructuredInsights
    if ((Get-Content -LiteralPath $stringStructuredInsights -Raw -Encoding UTF8) -notmatch 'messageUpdates') {
        throw 'String-form message_updates did not publish structured per-message updates.'
    }
    $gzipStructuredOutput = Join-Path $temp 'agent-output-gzip-updates.json'
    $gzipStructuredInsights = Join-Path $temp 'insights-gzip-updates.json'
    $agentOutputWithGzipUpdates = Get-Content -LiteralPath (Join-Path $root 'tests\fixtures\gh-aw-agent-output.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $updateBytes = [System.Text.Encoding]::UTF8.GetBytes(($agentOutputWithGzipUpdates.items[0].message_updates | ConvertTo-Json -Depth 8 -Compress))
    $updateStream = [System.IO.MemoryStream]::new()
    $gzipStream = [System.IO.Compression.GzipStream]::new($updateStream, [System.IO.Compression.CompressionLevel]::Optimal, $true)
    $gzipStream.Write($updateBytes, 0, $updateBytes.Length)
    $gzipStream.Dispose()
    $agentOutputWithGzipUpdates.items[0].message_updates = 'gzip-base64:' + [Convert]::ToBase64String($updateStream.ToArray())
    $updateStream.Dispose()
    $agentOutputWithGzipUpdates | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $gzipStructuredOutput -Encoding UTF8
    & (Join-Path $root 'scripts\Publish-M365AgentInsights.ps1') `
        -AgentOutputPath $gzipStructuredOutput `
        -MessagesJson (Join-Path $temp 'messages.json') `
        -OutputPath $gzipStructuredInsights
    if ((Get-Content -LiteralPath $gzipStructuredInsights -Raw -Encoding UTF8) -notmatch 'messageUpdates') {
        throw 'gzip-base64 message_updates did not publish structured per-message updates.'
    }
    $englishUpdatesOutput = Join-Path $temp 'agent-output-english-updates.json'
    $englishUpdatesInsights = Join-Path $temp 'insights-english-updates.json'
    $agentOutputWithEnglishUpdates = Get-Content -LiteralPath (Join-Path $root 'tests\fixtures\gh-aw-agent-output.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $agentOutputWithEnglishUpdates.items[0].message_updates[0].japanese_title = 'English title'
    $agentOutputWithEnglishUpdates.items[0].message_updates[0].japanese_summary = 'English summary'
    $agentOutputWithEnglishUpdates | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $englishUpdatesOutput -Encoding UTF8
    & (Join-Path $root 'scripts\Publish-M365AgentInsights.ps1') `
        -AgentOutputPath $englishUpdatesOutput `
        -MessagesJson (Join-Path $temp 'messages.json') `
        -OutputPath $englishUpdatesInsights
    $englishFallbackUpdate = @((Get-Content -LiteralPath $englishUpdatesInsights -Raw -Encoding UTF8 | ConvertFrom-Json).messageUpdates | Where-Object id -eq 'MC900001')[0]
    $snapshotFallbackMessage = @((Get-Content -LiteralPath (Join-Path $temp 'messages.json') -Raw -Encoding UTF8 | ConvertFrom-Json).messages | Where-Object id -eq 'MC900001')[0]
    if ($englishFallbackUpdate.japaneseTitle -ne $snapshotFallbackMessage.japaneseTitle -or
        $englishFallbackUpdate.japaneseSummary -ne $snapshotFallbackMessage.japaneseSummary) {
        throw 'Non-Japanese Agentic card fields did not fall back to same-snapshot deterministic Japanese text.'
    }
    $legacyInsightsPath = Join-Path $temp 'legacy-insights.json'
    $legacyCompatibleInsights = Join-Path $temp 'insights-legacy-compatible.json'
    [ordered]@{
        messageUpdates = @()
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $legacyInsightsPath -Encoding UTF8
    & (Join-Path $root 'scripts\Publish-M365AgentInsights.ps1') `
        -AgentOutputPath (Join-Path $root 'tests\fixtures\gh-aw-agent-output.json') `
        -MessagesJson (Join-Path $temp 'messages.json') `
        -PreviousInsightsPath $legacyInsightsPath `
        -OutputPath $legacyCompatibleInsights
    if ((Get-Content -LiteralPath $legacyCompatibleInsights -Raw -Encoding UTF8) -notmatch '"messageTranslations":\s*\[\s*\]') {
        throw 'Legacy insights without messageTranslations did not remain compatible with the core publisher.'
    }
    $deterministicOutput = Join-Path $temp 'agent-output-deterministic-updates.json'
    $deterministicInsights = Join-Path $temp 'insights-deterministic-updates.json'
    $agentOutputWithoutUpdates = Get-Content -LiteralPath (Join-Path $root 'tests\fixtures\gh-aw-agent-output.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $agentOutputWithoutUpdates.items[0].PSObject.Properties.Remove('message_updates')
    $agentOutputWithoutUpdates | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $deterministicOutput -Encoding UTF8
    & (Join-Path $root 'scripts\Publish-M365AgentInsights.ps1') `
        -AgentOutputPath $deterministicOutput `
        -MessagesJson (Join-Path $temp 'messages.json') `
        -UseDeterministicMessageUpdates `
        -OutputPath $deterministicInsights
    $deterministicUpdates = @((Get-Content -LiteralPath $deterministicInsights -Raw -Encoding UTF8 | ConvertFrom-Json).messageUpdates)
    $deterministicMessageCount = @((Get-Content -LiteralPath (Join-Path $temp 'messages.json') -Raw -Encoding UTF8 | ConvertFrom-Json).messages).Count
    if ($deterministicUpdates.Count -ne $deterministicMessageCount -or
        @($deterministicUpdates | Where-Object { $_.japaneseTitle -notmatch '[ぁ-んァ-ヶ一-龠々ー]' -or $_.japaneseSummary.Length -gt 100 }).Count) {
        throw 'Core deterministic message updates do not cover every snapshot message with safe Japanese card text.'
    }
    $translationBatchPath = Join-Path $temp 'translation-batch.json'
    $translationOutputPath = Join-Path $temp 'agent-output-translations.json'
    $translationInsightsPath = Join-Path $temp 'insights-translations.json'
    $translationSource = @((Get-Content -LiteralPath (Join-Path $temp 'messages.json') -Raw -Encoding UTF8 | ConvertFrom-Json).messages)[0]
    $translationSourceLength = [Math]::Min(([string]$translationSource.bodyText).Length, 1000)
    [ordered]@{
        messages = @([ordered]@{
            id = $translationSource.id
            sourceCharacterCount = $translationSourceLength
            sourceTruncated = ([string]$translationSource.bodyText).Length -gt $translationSourceLength
        })
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $translationBatchPath -Encoding UTF8
    $agentOutputWithTranslations = Get-Content -LiteralPath (Join-Path $root 'tests\fixtures\gh-aw-agent-output.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $translationUpdates = @([ordered]@{
        id = $translationSource.id
        japanese_detailed_summary = '共同作業コントロールの変更内容、対象となる Teams と SharePoint の設定、展開前に確認すべき影響範囲を整理した詳細要約です。検証担当者、対象テナント、既存ポリシーとの整合性を確認してください。'
        japanese_body_translation = '共同作業コントロールに関する更新です。対象設定を確認し、展開前に影響範囲を検証してください。'
        source_character_count = $translationSourceLength
        source_truncated = ([string]$translationSource.bodyText).Length -gt $translationSourceLength
    })
    $translationBytes = [System.Text.Encoding]::UTF8.GetBytes(($translationUpdates | ConvertTo-Json -Depth 8 -Compress))
    $translationStream = [System.IO.MemoryStream]::new()
    $translationGzip = [System.IO.Compression.GzipStream]::new($translationStream, [System.IO.Compression.CompressionLevel]::Optimal, $true)
    $translationGzip.Write($translationBytes, 0, $translationBytes.Length)
    $translationGzip.Dispose()
    $agentOutputWithTranslations.items[0] | Add-Member -NotePropertyName translation_updates -NotePropertyValue ('gzip-base64:' + [Convert]::ToBase64String($translationStream.ToArray()))
    $translationStream.Dispose()
    $agentOutputWithTranslations | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $translationOutputPath -Encoding UTF8
    & (Join-Path $root 'scripts\Publish-M365AgentInsights.ps1') `
        -AgentOutputPath $translationOutputPath `
        -MessagesJson (Join-Path $temp 'messages.json') `
        -TranslationBatchJson $translationBatchPath `
        -OutputPath $translationInsightsPath
    if ((Get-Content -LiteralPath $translationInsightsPath -Raw -Encoding UTF8) -notmatch 'messageTranslations|日本語訳') {
        throw 'Validated translation batch did not publish Japanese detailed translation data.'
    }
    $base64TranslationOutput = Join-Path $temp 'agent-output-base64-translations.json'
    $base64TranslationInsights = Join-Path $temp 'insights-base64-translations.json'
    $agentOutputWithBase64Translations = Get-Content -LiteralPath (Join-Path $root 'tests\fixtures\gh-aw-agent-output.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $agentOutputWithBase64Translations.items[0] | Add-Member -NotePropertyName translation_updates -NotePropertyValue ('base64-json:' + [Convert]::ToBase64String($translationBytes))
    $agentOutputWithBase64Translations | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $base64TranslationOutput -Encoding UTF8
    & (Join-Path $root 'scripts\Publish-M365AgentInsights.ps1') `
        -AgentOutputPath $base64TranslationOutput `
        -MessagesJson (Join-Path $temp 'messages.json') `
        -TranslationBatchJson $translationBatchPath `
        -OutputPath $base64TranslationInsights
    if ((Get-Content -LiteralPath $base64TranslationInsights -Raw -Encoding UTF8) -notmatch 'messageTranslations|日本語訳') {
        throw 'base64-json translation updates did not publish validated Japanese detailed translation data.'
    }
    $mismatchedTranslationOutput = Join-Path $temp 'agent-output-mismatched-translation.json'
    $agentOutputWithMismatchedTranslation = Get-Content -LiteralPath $translationOutputPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $decodedTranslationPayload = [Convert]::FromBase64String(
        $agentOutputWithMismatchedTranslation.items[0].translation_updates.Substring('gzip-base64:'.Length)
    )
    $decodedTranslationStream = [System.IO.MemoryStream]::new($decodedTranslationPayload)
    $decodedTranslationGzip = [System.IO.Compression.GzipStream]::new(
        $decodedTranslationStream,
        [System.IO.Compression.CompressionMode]::Decompress
    )
    $decodedTranslationReader = [System.IO.StreamReader]::new($decodedTranslationGzip, [System.Text.Encoding]::UTF8)
    $mismatchedTranslations = @($decodedTranslationReader.ReadToEnd() | ConvertFrom-Json)
    $decodedTranslationReader.Dispose()
    $decodedTranslationGzip.Dispose()
    $decodedTranslationStream.Dispose()
    $mismatchedTranslations[0].source_character_count++
    $mismatchedBytes = [System.Text.Encoding]::UTF8.GetBytes(($mismatchedTranslations | ConvertTo-Json -Depth 8 -Compress))
    $mismatchedStream = [System.IO.MemoryStream]::new()
    $mismatchedGzip = [System.IO.Compression.GzipStream]::new($mismatchedStream, [System.IO.Compression.CompressionLevel]::Optimal, $true)
    $mismatchedGzip.Write($mismatchedBytes, 0, $mismatchedBytes.Length)
    $mismatchedGzip.Dispose()
    $agentOutputWithMismatchedTranslation.items[0].translation_updates = 'gzip-base64:' + [Convert]::ToBase64String($mismatchedStream.ToArray())
    $mismatchedStream.Dispose()
    $agentOutputWithMismatchedTranslation | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $mismatchedTranslationOutput -Encoding UTF8
    $translationMismatchFailed = $false
    try {
        & (Join-Path $root 'scripts\Publish-M365AgentInsights.ps1') `
            -AgentOutputPath $mismatchedTranslationOutput `
            -MessagesJson (Join-Path $temp 'messages.json') `
            -TranslationBatchJson $translationBatchPath `
            -OutputPath (Join-Path $temp 'insights-mismatched-translation.json')
    } catch {
        if ($_.Exception.Message -notmatch 'Translation source character count does not match') { throw }
        $translationMismatchFailed = $true
    }
    if (-not $translationMismatchFailed) {
        throw 'Translation with mismatched source character count unexpectedly passed validation.'
    }
    $translationDashboard = Join-Path $temp 'dashboard-translations.html'
    & (Join-Path $root 'scripts\New-M365MessageCenterDashboard.ps1') `
        -MessagesJson (Join-Path $temp 'messages.json') `
        -InsightsJson $translationInsightsPath `
        -OutputPath $translationDashboard
    if ((Get-Content -LiteralPath $translationDashboard -Raw -Encoding UTF8) -notmatch '日本語訳と詳細要約|共同作業コントロールの変更内容|本文の日本語訳（抜粋）|全文は「Message Center の全文と詳細」で確認してください') {
        throw 'Dashboard does not render validated Japanese translations and detailed summaries.'
    }
    $translationOnlyOutput = Join-Path $temp 'agent-output-translation-only.json'
    $stalePreviousInsights = Join-Path $temp 'insights-with-stale-update.json'
    $translationBridgeInsights = Join-Path $temp 'insights-translation-bridge.json'
    [ordered]@{
        items = @([ordered]@{
            type = 'publish_m365_translations'
            translation_updates = $agentOutputWithTranslations.items[0].translation_updates
        })
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $translationOnlyOutput -Encoding UTF8
    $previousWithStaleUpdate = Get-Content -LiteralPath $publishedInsights -Raw -Encoding UTF8 | ConvertFrom-Json
    $previousWithStaleUpdate.messageUpdates += [pscustomobject]@{
        id = 'MC999999'; japaneseTitle = '古い更新'; japaneseSummary = '現在の snapshot にはない古い更新です。'
        messageUrl = $null; learnUrls = @()
    }
    $previousWithStaleUpdate | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $stalePreviousInsights -Encoding UTF8
    & (Join-Path $root 'scripts\Publish-M365AgentTranslations.ps1') `
        -AgentOutputPath $translationOnlyOutput `
        -MessagesJson (Join-Path $temp 'messages.json') `
        -TranslationBatchJson $translationBatchPath `
        -PreviousInsightsPath $stalePreviousInsights `
        -OutputPath $translationBridgeInsights
    if ((Get-Content -LiteralPath $translationBridgeInsights -Raw -Encoding UTF8) -match 'MC999999') {
        throw 'Translation bridge retained a message update that is absent from the current snapshot.'
    }
    & (Join-Path $root 'scripts\New-M365MessageCenterDashboard.ps1') `
        -MessagesJson (Join-Path $temp 'messages.json') `
        -InsightsJson $publishedInsights `
        -OutputPath (Join-Path $temp 'index.html')

    $messagesRaw = Get-Content -LiteralPath (Join-Path $temp 'messages.json') -Raw -Encoding UTF8
    $messages = $messagesRaw | ConvertFrom-Json
    $html = Get-Content -LiteralPath (Join-Path $temp 'index.html') -Raw -Encoding UTF8

    if ($messages.messages.Count -ne 3) { throw "Expected 3 messages, got $($messages.messages.Count)." }
    $oneDetailMessage = @($messages.messages | Where-Object id -eq 'MC900002')[0]
    if ($oneDetailMessage.details -isnot [System.Array] -or $oneDetailMessage.details.Count -ne 1) {
        throw 'A single Message Center detail was not serialized as a JSON array.'
    }
    if ($messagesRaw -notmatch 'THIS_BODY_IS_LAB_PUBLIC|"details"|MessageCenterUrl|japaneseTitle|japaneseSummary') {
        throw 'Lab-public body, details, or deterministic Japanese title and summary are missing from public JSON.'
    }
    if ($messagesRaw -match 'abcdefghijklmnopqrstuvwxyz|lab-secret-value|LAB_SCRIPT_MUST_NOT_RENDER|<p>') {
        throw 'Credential-like values or unsafe source HTML leaked into public JSON.'
    }
    if ($messagesRaw -notmatch '\[REDACTED\]') { throw 'Credential-like values were not redacted from public JSON.' }
    if ($messagesRaw -match '"expiryDateTime"') { throw 'Unsupported Graph expiryDateTime leaked into public JSON.' }
    if ($html -notmatch 'THIS_BODY_IS_LAB_PUBLIC|Message Center を開く|共同作業コントロールの更新|変更予定') {
        throw 'Lab-public full content or deterministic Japanese summary is missing from dashboard HTML.'
    }
    if ($html -notmatch 'https://admin\.microsoft\.com/AdminPortal/home#|https://learn\.microsoft\.com/microsoft-365/admin/manage/message-center') {
        throw 'Validated Message Center or Microsoft Learn links are missing from dashboard HTML.'
    }
    if ($html -match 'abcdefghijklmnopqrstuvwxyz|lab-secret-value|LAB_SCRIPT_MUST_NOT_RENDER|example\.com|<script[^>]+src=|<link[^>]+href=') {
        throw 'Credentials or external resources leaked into dashboard HTML.'
    }
    $published = Get-Content -LiteralPath $publishedInsights -Raw -Encoding UTF8 | ConvertFrom-Json
    $publishedUpdates = @($published.messageUpdates)
    if ($publishedUpdates.Count -ne $messages.messages.Count) {
        throw 'Agentic per-message updates do not cover every Message Center record.'
    }
    foreach ($update in $publishedUpdates) {
        if ([string]$update.japaneseTitle -notmatch '[ぁ-んァ-ヶ一-龠々ー]' -or
            [string]$update.japaneseSummary -notmatch '[ぁ-んァ-ヶ一-龠々ー]' -or
            ([string]$update.japaneseSummary).Length -gt 100) {
            throw 'Agentic per-message title or summary is not valid Japanese output within 100 characters.'
        }
    }
    $firstUpdate = @($publishedUpdates | Where-Object id -eq 'MC900001')[0]
    if ($firstUpdate.messageUrl -ne 'https://admin.microsoft.com/AdminPortal/home#/MessageCenter/:/messages/MC900001' -or
        @($firstUpdate.learnUrls) -notcontains 'https://learn.microsoft.com/microsoft-365/admin/manage/message-center') {
        throw 'Allowed Message Center or Microsoft Learn URLs were not preserved.'
    }
    if (@($publishedUpdates | Where-Object { $_.id -ne 'MC900001' -and $_.messageUrl }).Count) {
        throw 'A message update fabricated a direct Message Center URL.'
    }
    $compactAgentContext = Get-Content -LiteralPath $agentContext -Raw -Encoding UTF8 | ConvertFrom-Json
    if (@($compactAgentContext.messages).Count -ne $messages.messages.Count) {
        throw 'Compact agent context does not include every current Message Center ID.'
    }
    foreach ($contextMessage in @($compactAgentContext.messages)) {
        if ($contextMessage.PSObject.Properties.Name -contains 'bodyText' -or
            $contextMessage.PSObject.Properties.Name -contains 'details' -or
            -not ($contextMessage.PSObject.Properties.Name -contains 'bodyExcerpt') -or
            ([string]$contextMessage.bodyExcerpt).Length -gt 1000) {
            throw 'Agent context exposes full content/details or exceeds the bounded body excerpt.'
        }
        if (@($compactAgentContext.translationBatch).Count -lt 1 -or
            @($compactAgentContext.translationBatch).Count -gt 4 -or
            @($compactAgentContext.translationBatch | Where-Object { $_.bodyText.Length -gt 1000 }).Count) {
            throw 'Agent translation batch is not bounded to the configured size and body length.'
        }
    }
    if ((Get-Content -LiteralPath $agentContext -Raw -Encoding UTF8) -notmatch 'THIS_BODY_IS_LAB_PUBLIC') {
        throw 'Compact agent context did not include the bounded message excerpt for summarization.'
    }
    $backfillSnapshot = Join-Path $temp 'backfill-snapshot'
    $backfillContext = Join-Path $temp 'backfill-context.json'
    & (Join-Path $root 'scripts\Export-M365MessageCenter.ps1') `
        -InputJsonPath (Join-Path $root 'tests\fixtures\m365-messages.json') `
        -OutputDirectory $backfillSnapshot `
        -LookbackDays 365 `
        -RunId 'backfill-fixture-run' `
        -ReferenceTime '2026-07-23T00:00:00Z' `
        -AgentContextPath $backfillContext `
        -AgentTranslationIds 'MC900002,MC900003' `
        -IncludeContent
    $backfillBatch = @((Get-Content -LiteralPath $backfillContext -Raw -Encoding UTF8 | ConvertFrom-Json).translationBatch)
    if ($backfillBatch.Count -ne 2 -or @($backfillBatch.id | Sort-Object -Unique).Count -ne 2) {
        throw 'Explicit translation backfill batch is not a bounded unique requested-message batch.'
    }
    if ($html -notmatch '共同作業と管理者設定の変更') { throw 'Agentic summary is missing from dashboard HTML.' }
    if ($html -notmatch 'Microsoft 365 Change Radar') { throw 'Dashboard title is missing.' }
    if ($html -notmatch 'scoutTheme' -or
        $html -notmatch 'localStorage\.getItem\("scoutTheme"\)' -or
        $html -notmatch 'localStorage\.setItem\("scoutTheme", nextTheme\)' -or
        $html -notmatch 'theme-toggle' -or
        $html -notmatch 'aria-label="表示テーマをダークに切り替えます"' -or
        $html -notmatch 'aria-pressed="false"' -or
        $html -notmatch 'const theme = forcedTheme \|\| \(\["light", "dark"\]\.includes\(storedTheme\) \? storedTheme : "light"\)' -or
        $html -notmatch 'color-scheme: light;' -or
        $html -match 'prefers-color-scheme') {
        throw 'Light-first persistent accessible theme control is missing or still follows the OS theme.'
    }
    $themeCss = [regex]::Match($html, '<style>(?<css>[\s\S]*?)</style>').Groups['css'].Value
    $hardCodedComponentColors = [regex]::Matches(
        $themeCss,
        '(?m)^\s*(?!\-\-cp-)(?:background|color|border(?:-color)?|outline(?:-color)?|box-shadow)\s*:\s*[^;]*(?:#[0-9a-fA-F]{3,8}|rgba?\(|hsla?\()'
    )
    if ($hardCodedComponentColors.Count -or
        $themeCss -match '#0078d4|#4da6ff') {
        throw 'Dashboard components must use warm Clawpilot theme variables instead of hard-coded or generic blue colors.'
    }
    $repositoryLinks = [regex]::Matches($html, 'https://github\.com/aktsmm/m365-message-center-dashboard').Count
    if ($repositoryLinks -lt 2 -or $html -notmatch 'hero-repo-link|GitHub リポジトリを開く') {
        throw 'Dashboard is missing the accessible hero repository link or footer repository link.'
    }
    if ($html -notmatch 'href="about/"') { throw 'Dashboard footer is missing the visible automation explanation link.' }
    if (-not (Test-Path -LiteralPath $aboutPage) -or
        (Get-Content -LiteralPath $aboutPage -Raw -Encoding UTF8) -notmatch '毎週の自動更新|GitHub Agentic Workflow') {
        throw 'Automation explanation page was not generated.'
    }
    $aboutHtml = Get-Content -LiteralPath $aboutPage -Raw -Encoding UTF8
    if ($aboutHtml -notmatch 'scoutTheme' -or
        $aboutHtml -notmatch 'localStorage\.getItem\("scoutTheme"\)' -or
        $aboutHtml -notmatch 'theme-toggle' -or
        $aboutHtml -notmatch 'storedTheme.*"light"' -or
        $aboutHtml -match 'prefers-color-scheme') {
        throw 'About page does not share the light-first persistent accessible theme contract.'
    }
    $renderer = Get-Content -LiteralPath (Join-Path $root 'scripts\New-M365MessageCenterDashboard.ps1') -Raw -Encoding UTF8
    if (-not $renderer.Contains('Array.isArray(message.details)')) {
        throw 'Renderer does not defensively handle legacy single-object details.'
    }
    if (-not $renderer.Contains('update?.japaneseTitle || message.japaneseTitle')) {
        throw 'Renderer does not use the deterministic Japanese title when Agentic updates are unavailable.'
    }

    $fallbackOutput = Join-Path $temp 'fallback'
    $fallbackCalls = [System.Collections.Generic.List[string]]::new()
    $fixtureResponse = Get-Content -LiteralPath (Join-Path $root 'tests\fixtures\m365-messages.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    function Invoke-RestMethod {
        param([string]$Method, [string]$Uri, [hashtable]$Headers)

        $fallbackCalls.Add($Uri)
        if ($fallbackCalls.Count -eq 1) { throw 'Selected metadata request failed.' }
        return $fixtureResponse
    }

    & (Join-Path $root 'scripts\Export-M365MessageCenter.ps1') `
        -AccessToken 'fixture-token' `
        -OutputDirectory $fallbackOutput `
        -LookbackDays 365 `
        -ReferenceTime '2026-07-23T00:00:00Z' `
        -IncludeContent

    if ($fallbackCalls.Count -ne 2) { throw "Expected one fallback request, got $($fallbackCalls.Count) requests." }
    if ($fallbackCalls[0] -notmatch '\$select=.*body,details') { throw 'Initial Graph request did not select lab-public body and details.' }
    if ($fallbackCalls[1] -ne 'https://graph.microsoft.com/v1.0/admin/serviceAnnouncement/messages') {
        throw 'Graph fallback request did not use the unselected Message Center endpoint.'
    }
    $fallbackMessages = Get-Content -LiteralPath (Join-Path $fallbackOutput 'messages.json') -Raw -Encoding UTF8
    if ($fallbackMessages -notmatch 'THIS_BODY_IS_LAB_PUBLIC|"details"|MessageCenterUrl') {
        throw 'Graph fallback did not preserve lab-public body and details.'
    }
    if ($fallbackMessages -match 'abcdefghijklmnopqrstuvwxyz|lab-secret-value') {
        throw 'Graph fallback did not redact credential-like values.'
    }

    $currentSnapshot = Join-Path $temp 'current-graph-pull'
    & (Join-Path $root 'scripts\Export-M365MessageCenter.ps1') `
        -InputJsonPath (Join-Path $root 'tests\fixtures\m365-current-messages.json') `
        -OutputDirectory $currentSnapshot `
        -LookbackDays 365 `
        -RunId 'current-fixture-run' `
        -ReferenceTime '2026-07-23T00:00:00Z' `
        -IncludeContent
    $currentSnapshotRaw = Get-Content -LiteralPath (Join-Path $currentSnapshot 'messages.json') -Raw -Encoding UTF8
    if ($currentSnapshotRaw -notmatch 'CURRENT_BODY_IS_LAB_PUBLIC|"details"|ChangeOwner') {
        throw 'Current lab-public snapshot is missing body or details.'
    }
    $staleValidationFailed = $false
    try {
        & (Join-Path $root 'scripts\Publish-M365AgentInsights.ps1') `
            -AgentOutputPath (Join-Path $root 'tests\fixtures\gh-aw-agent-output-current-id.json') `
            -MessagesJson (Join-Path $temp 'messages.json') `
            -OutputPath (Join-Path $temp 'stale-insights.json')
    } catch {
        if ($_.Exception.Message -notmatch 'Agent referenced unknown MC IDs: MC1436831') { throw }
        $staleValidationFailed = $true
    }
    if (-not $staleValidationFailed) {
        throw 'A stale metadata snapshot unexpectedly accepted a current agent reference.'
    }
    $currentInsights = Join-Path $temp 'current-insights.json'
    & (Join-Path $root 'scripts\Publish-M365AgentInsights.ps1') `
        -AgentOutputPath (Join-Path $root 'tests\fixtures\gh-aw-agent-output-current-id.json') `
        -MessagesJson (Join-Path $currentSnapshot 'messages.json') `
        -OutputPath $currentInsights
    if ((Get-Content -LiteralPath $currentInsights -Raw -Encoding UTF8) -notmatch 'MC1436831') {
        throw 'A current public metadata snapshot did not validate the matching agent reference.'
    }
    $credentialValidationFailed = $false
    try {
        & (Join-Path $root 'scripts\Publish-M365AgentInsights.ps1') `
            -AgentOutputPath (Join-Path $root 'tests\fixtures\gh-aw-agent-output-credential.json') `
            -MessagesJson (Join-Path $temp 'messages.json') `
            -OutputPath (Join-Path $temp 'credential-insights.json')
    } catch {
        if ($_.Exception.Message -notmatch 'Credential-like content detected in insight field: headline') { throw }
        $credentialValidationFailed = $true
    }
    if (-not $credentialValidationFailed) {
        throw 'Credential-like Agentic safe output unexpectedly passed validation.'
    }
    $invalidLinkValidationFailed = $false
    try {
        & (Join-Path $root 'scripts\Publish-M365AgentInsights.ps1') `
            -AgentOutputPath (Join-Path $root 'tests\fixtures\gh-aw-agent-output-invalid-link.json') `
            -MessagesJson (Join-Path $temp 'messages.json') `
            -OutputPath (Join-Path $temp 'invalid-link-insights.json')
    } catch {
        if ($_.Exception.Message -notmatch 'Message update URL is not an allowed snapshot URL for MC900001') { throw }
        $invalidLinkValidationFailed = $true
    }
    if (-not $invalidLinkValidationFailed) {
        throw 'A fabricated Message Center URL unexpectedly passed validation.'
    }

    $agentWorkflow = Get-Content -LiteralPath (Join-Path $root '.github\workflows\m365-weekly-insights.md') -Raw -Encoding UTF8
    $preAgentSection = ($agentWorkflow -split 'safe-outputs:', 2)[0]
    $safeOutputSection = ($agentWorkflow -split 'safe-outputs:', 2)[1]
    if (-not $preAgentSection.Contains('uses: actions/upload-artifact@v7') -or
        -not $preAgentSection.Contains('name: m365-agent-public-metadata') -or
        -not $preAgentSection.Contains('$env:RUNNER_TEMP/m365-agent-public') -or
        -not $preAgentSection.Contains('-IncludeContent') -or
        -not $preAgentSection.Contains('-AgentContextLimit 1000') -or
        -not $preAgentSection.Contains('-AgentContextBodyMaxChars 1000')) {
        throw 'Agentic pre-agent steps do not export and transfer the public metadata snapshot.'
    }
    if (-not $safeOutputSection.Contains('uses: actions/download-artifact@v8') -or
        -not $safeOutputSection.Contains('name: m365-agent-public-metadata') -or
    -not $safeOutputSection.Contains('-MessagesJson $messagesJson') -or
    -not $safeOutputSection.Contains('-UseDeterministicMessageUpdates')) {
        throw 'Agentic safe output does not validate against the transferred public metadata snapshot.'
    }
    if ($safeOutputSection -match 'Export-M365MessageCenter\.ps1|azure/login@') {
        throw 'Agentic safe output must not perform a second Graph pull before validation.'
    }
    if ($safeOutputSection.Contains('translation_updates:') -or
        $safeOutputSection.Contains('-TranslationBatchJson') -or
        $safeOutputSection.Contains('message_updates:')) {
        throw 'Core weekly workflow must not publish Agentic card or translation-only safe output.'
    }
    $publicWorkflow = Get-Content -LiteralPath (Join-Path $root '.github\workflows\m365-dashboard-public.yml') -Raw -Encoding UTF8
    if (-not $publicWorkflow.Contains('Export lab-public Message Center content') -or
        -not $publicWorkflow.Contains('-IncludeContent') -or
        -not $publicWorkflow.Contains('New-M365DashboardAboutPage.ps1')) {
        throw 'The dedicated public dashboard pipeline does not enable lab-public Message Center content.'
    }
    if (-not $publicWorkflow.Contains("cron: '17 22 * * 0,3'") -or
        -not $publicWorkflow.Contains('Monday and Thursday 07:17 JST')) {
        throw 'The public dashboard pipeline is not scheduled for Monday and Thursday at 07:17 JST.'
    }
    if (-not $safeOutputSection.Contains('New-M365DashboardAboutPage.ps1')) {
        throw 'The Agentic pipeline does not publish the automation explanation page.'
    }
    $translationWorkflow = Get-Content -LiteralPath (Join-Path $root '.github\workflows\m365-weekly-translations.md') -Raw -Encoding UTF8
    $translationPreAgentSection = ($translationWorkflow -split 'safe-outputs:', 2)[0]
    $translationSafeOutputSection = ($translationWorkflow -split 'safe-outputs:', 2)[1]
    if (-not $translationPreAgentSection.Contains('workflows:') -or
        -not $translationPreAgentSection.Contains('"Microsoft 365 Message Center weekly dashboard"') -or
        -not $translationPreAgentSection.Contains("github.event.workflow_run.conclusion == 'success'") -or
        -not $translationPreAgentSection.Contains('translation_batch_index') -or
        -not $translationPreAgentSection.Contains('translation_ids') -or
        -not $translationPreAgentSection.Contains('translation_request_id') -or
        -not $translationPreAgentSection.Contains('AgentTranslationIds') -or
        -not $translationPreAgentSection.Contains('AgentTranslationBatchIndex') -or
        $translationPreAgentSection.Contains('M365 Message Center Dashboard - Public Metadata')) {
        throw 'Translations workflow does not wait for the successful core weekly dashboard workflow.'
    }
    if ($translationSafeOutputSection.Contains('message_updates:') -or
        $translationSafeOutputSection.Contains('publish-m365-dashboard') -or
        -not $translationSafeOutputSection.Contains('translation_updates:') -or
        -not $translationSafeOutputSection.Contains('base64-json:')) {
        throw 'Translations workflow must publish only translation_updates.'
    }
    if (@($compactAgentContext.translationBatch).Count -ne [Math]::Min(4, @($messages.messages).Count) -or
        @($compactAgentContext.translationBatch.id | Sort-Object -Unique).Count -ne @($compactAgentContext.translationBatch).Count) {
        throw 'Translation batch does not contain the configured number of unique rotating Message Center records.'
    }
    $catchupController = Get-Content -LiteralPath (Join-Path $root 'scripts\Invoke-M365TranslationCatchup.ps1') -Raw -Encoding UTF8
    if (-not $catchupController.Contains('publish_m365_translations') -or
        -not $catchupController.Contains('Translation run $($run.id) reported a successful publisher job but did not persist') -or
        -not $catchupController.Contains('Persisted isolated translation') -or
        -not $catchupController.Contains('translation_ids') -or
        -not $catchupController.Contains('translation_request_id') -or
        -not $catchupController.Contains('did not increase the main translation count')) {
        throw 'Translation catch-up controller does not verify persisted publishes or isolate individual IDs.'
    }
    $readme = Get-Content -LiteralPath (Join-Path $root 'README.md') -Raw -Encoding UTF8
    $aboutGenerator = Get-Content -LiteralPath (Join-Path $root 'scripts\New-M365DashboardAboutPage.ps1') -Raw -Encoding UTF8
    if ($readme -notmatch '月曜日・木曜日 07:17 JST' -or
        $readme -notmatch '最大8カード/週' -or
        $aboutGenerator -notmatch '月曜日・木曜日 07:17 JST' -or
        $aboutGenerator -notmatch '最大8カード/週') {
        throw 'Operator documentation does not describe the twice-weekly translation cadence.'
    }

    Write-Host 'M365 dashboard fixture validation passed.'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
