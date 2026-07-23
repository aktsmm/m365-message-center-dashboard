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
    if ($messagesRaw -notmatch 'THIS_BODY_IS_LAB_PUBLIC|"details"|MessageCenterUrl|japaneseSummary') {
        throw 'Lab-public body, details, or deterministic Japanese summary is missing from public JSON.'
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
    if ((Get-Content -LiteralPath $agentContext -Raw -Encoding UTF8) -notmatch 'THIS_BODY_IS_LAB_PUBLIC') {
        throw 'Transient agent context did not include the message body for summarization.'
    }
    if ($html -notmatch '共同作業と管理者設定の変更') { throw 'Agentic summary is missing from dashboard HTML.' }
    if ($html -notmatch 'Microsoft 365 Change Radar') { throw 'Dashboard title is missing.' }
    if ($html -notmatch 'scoutTheme' -or $html -notmatch '--cp-accent') { throw 'Mandatory artifact theme is missing.' }
    $repositoryLinks = [regex]::Matches($html, 'https://github\.com/aktsmm/m365-message-center-dashboard').Count
    if ($repositoryLinks -lt 2 -or $html -notmatch 'hero-repo-link|GitHub リポジトリを開く') {
        throw 'Dashboard is missing the accessible hero repository link or footer repository link.'
    }
    if ($html -notmatch 'href="about/"') { throw 'Dashboard footer is missing the visible automation explanation link.' }
    if (-not (Test-Path -LiteralPath $aboutPage) -or
        (Get-Content -LiteralPath $aboutPage -Raw -Encoding UTF8) -notmatch '毎週の自動更新|GitHub Agentic Workflow') {
        throw 'Automation explanation page was not generated.'
    }
    $renderer = Get-Content -LiteralPath (Join-Path $root 'scripts\New-M365MessageCenterDashboard.ps1') -Raw -Encoding UTF8
    if (-not $renderer.Contains('Array.isArray(message.details)')) {
        throw 'Renderer does not defensively handle legacy single-object details.'
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
        -not $preAgentSection.Contains('-AgentContextLimit 1000')) {
        throw 'Agentic pre-agent steps do not export and transfer the public metadata snapshot.'
    }
    if (-not $safeOutputSection.Contains('uses: actions/download-artifact@v8') -or
        -not $safeOutputSection.Contains('name: m365-agent-public-metadata') -or
    -not $safeOutputSection.Contains('-MessagesJson $messagesJson') -or
    -not $safeOutputSection.Contains('message_updates')) {
        throw 'Agentic safe output does not validate against the transferred public metadata snapshot.'
    }
    if ($safeOutputSection -match 'Export-M365MessageCenter\.ps1|azure/login@') {
        throw 'Agentic safe output must not perform a second Graph pull before validation.'
    }
    $publicWorkflow = Get-Content -LiteralPath (Join-Path $root '.github\workflows\m365-dashboard-public.yml') -Raw -Encoding UTF8
    if (-not $publicWorkflow.Contains('Export lab-public Message Center content') -or
        -not $publicWorkflow.Contains('-IncludeContent') -or
        -not $publicWorkflow.Contains('New-M365DashboardAboutPage.ps1')) {
        throw 'The dedicated public dashboard pipeline does not enable lab-public Message Center content.'
    }
    if (-not $safeOutputSection.Contains('New-M365DashboardAboutPage.ps1')) {
        throw 'The Agentic pipeline does not publish the automation explanation page.'
    }

    Write-Host 'M365 dashboard fixture validation passed.'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
