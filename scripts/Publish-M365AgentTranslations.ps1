<#
.SYNOPSIS
    Merges a bounded Agentic translation batch into previously validated insights.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AgentOutputPath,
    [Parameter(Mandatory)][string]$MessagesJson,
    [Parameter(Mandatory)][string]$TranslationBatchJson,
    [Parameter(Mandatory)][string]$PreviousInsightsPath,
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($path in @($AgentOutputPath, $MessagesJson, $TranslationBatchJson, $PreviousInsightsPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required input not found: $path" }
}

$agentOutput = Get-Content -LiteralPath $AgentOutputPath -Raw -Encoding UTF8 | ConvertFrom-Json
$translationItem = @($agentOutput.items | Where-Object type -eq 'publish_m365_translations')
if ($translationItem.Count -ne 1) { throw "Expected exactly one publish_m365_translations item, got $($translationItem.Count)." }
if (-not ($translationItem[0].PSObject.Properties.Name -contains 'translation_updates')) {
    throw 'Missing translation_updates safe output.'
}

$previous = Get-Content -LiteralPath $PreviousInsightsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$updates = @($previous.messageUpdates)
if (-not $updates.Count) { throw 'Previous insights do not contain validated message updates.' }
$legacyUpdates = @($updates | ForEach-Object {
    [ordered]@{
        id = $_.id; japanese_title = $_.japaneseTitle; japanese_summary = $_.japaneseSummary
        message_url = $_.messageUrl; learn_urls = @($_.learnUrls)
    }
})
$bridge = [ordered]@{
    items = @([ordered]@{
        type = 'publish_m365_dashboard'
        headline = $previous.headline; executive_summary = $previous.executiveSummary
        this_week = $previous.thisWeek; this_month = $previous.thisMonth; watch = $previous.watch
        customer_questions = $previous.customerQuestions
        referenced_ids = (@($previous.referencedIds) -join ',')
        message_updates = ($legacyUpdates | ConvertTo-Json -Depth 8 -Compress)
        translation_updates = $translationItem[0].translation_updates
    })
}
$temp = Join-Path ([System.IO.Path]::GetTempPath()) "m365-agent-bridge-$([guid]::NewGuid().ToString('N')).json"
try {
    $bridge | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temp -Encoding UTF8
    & (Join-Path $PSScriptRoot 'Publish-M365AgentInsights.ps1') `
        -AgentOutputPath $temp -MessagesJson $MessagesJson -TranslationBatchJson $TranslationBatchJson `
        -PreviousInsightsPath $PreviousInsightsPath -OutputPath $OutputPath
} finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}
