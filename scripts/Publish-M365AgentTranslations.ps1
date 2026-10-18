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
. (Join-Path $PSScriptRoot 'M365DashboardContent.ps1')

foreach ($path in @($AgentOutputPath, $MessagesJson, $TranslationBatchJson, $PreviousInsightsPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required input not found: $path" }
}

function Get-RequiredTranslationSlotValue {
    param(
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][string]$Name,
        [ValidateRange(1, 4)][int]$Slot
    )

    if ($Item.PSObject.Properties.Name -notcontains $Name -or $null -eq $Item.$Name) {
        throw "Translation slot $Slot is missing required field: $Name"
    }
    return $Item.$Name
}

function Get-StructuredTranslationUpdates {
    param(
        [Parameter(Mandatory)][object]$Item,
        [ValidateRange(0, 4)][int]$ExpectedCount
    )

    if ($Item.PSObject.Properties.Name -contains 'translation_updates') {
        throw 'Opaque translation_updates safe output is not supported. Use the typed translation slot fields.'
    }

    $updates = [System.Collections.Generic.List[object]]::new()
    $propertyNames = @($Item.PSObject.Properties.Name)
    for ($slot = 1; $slot -le 4; $slot++) {
        $fieldNames = @(
            "translation_${slot}_id",
            "translation_${slot}_japanese_detailed_summary",
            "translation_${slot}_japanese_body_translation",
            "translation_${slot}_source_character_count",
            "translation_${slot}_source_truncated"
        )
        $optionalFieldNames = @("translation_${slot}_japanese_title", "translation_${slot}_japanese_facts")
        $providedFields = [System.Collections.Generic.List[string]]::new()
        foreach ($fieldName in $fieldNames) {
            if ($propertyNames -contains $fieldName -and $null -ne $Item.$fieldName) {
                $providedFields.Add($fieldName)
            }
        }

        if ($slot -gt $ExpectedCount) {
            if ($providedFields.Count -or @($optionalFieldNames | Where-Object { $propertyNames -contains $_ -and $null -ne $Item.$_ }).Count) {
                throw "Translation slot $slot is outside the current batch and must not be populated."
            }
            continue
        }

        $missingFields = @($fieldNames | Where-Object { $providedFields -notcontains $_ })
        if ($missingFields.Count) {
            throw "Translation slot $slot is missing required field(s): $($missingFields -join ', ')"
        }

        $id = Get-RequiredTranslationSlotValue -Item $Item -Name "translation_${slot}_id" -Slot $slot
        $detailSummary = Get-RequiredTranslationSlotValue -Item $Item -Name "translation_${slot}_japanese_detailed_summary" -Slot $slot
        $bodyTranslation = Get-RequiredTranslationSlotValue -Item $Item -Name "translation_${slot}_japanese_body_translation" -Slot $slot
        $sourceCharacterCount = Get-RequiredTranslationSlotValue -Item $Item -Name "translation_${slot}_source_character_count" -Slot $slot
        $sourceTruncated = Get-RequiredTranslationSlotValue -Item $Item -Name "translation_${slot}_source_truncated" -Slot $slot

        foreach ($textField in @(
            @{ Name = 'id'; Value = $id },
            @{ Name = 'japanese_detailed_summary'; Value = $detailSummary },
            @{ Name = 'japanese_body_translation'; Value = $bodyTranslation }
        )) {
            if ($textField.Value -isnot [string]) {
                throw "Translation slot $slot $($textField.Name) must be a string."
            }
        }

        $numericTypeNames = @(
            'System.Byte', 'System.SByte', 'System.Int16', 'System.UInt16', 'System.Int32',
            'System.UInt32', 'System.Int64', 'System.UInt64', 'System.Single', 'System.Double', 'System.Decimal'
        )
        if ($sourceCharacterCount.GetType().FullName -notin $numericTypeNames) {
            throw "Translation slot $slot source_character_count must be a JSON number."
        }
        try {
            $sourceCharacterCount = [decimal]$sourceCharacterCount
        } catch {
            throw "Translation slot $slot source_character_count must be a JSON number."
        }
        if ($sourceCharacterCount -lt 0 -or
            $sourceCharacterCount -gt 3000 -or
            $sourceCharacterCount -ne [Math]::Truncate($sourceCharacterCount)) {
            throw "Translation slot $slot source_character_count must be a whole number between 0 and 3000."
        }
        if ($sourceTruncated -isnot [bool]) {
            throw "Translation slot $slot source_truncated must be a JSON boolean."
        }

        $japaneseTitle = $null
        if ($propertyNames -contains "translation_${slot}_japanese_title" -and $null -ne $Item."translation_${slot}_japanese_title") {
            $japaneseTitle = $Item."translation_${slot}_japanese_title"
            if ($japaneseTitle -isnot [string]) { throw "Translation slot $slot japanese_title must be a string." }
        }
        $facts = [ordered]@{}
        $factsKey = "translation_${slot}_japanese_facts"
        if ($propertyNames -contains $factsKey -and $null -ne $Item.$factsKey) {
            if ($Item.$factsKey -isnot [string]) { throw "Translation slot $slot japanese_facts must be a string." }
            $labels = [ordered]@{ '変更' = 'change'; '影響' = 'impact'; '時期' = 'timing'; '対応' = 'action' }
            foreach ($line in ($Item.$factsKey -split "`r?`n")) {
                if ($line -match '^\s*(変更|影響|時期|対応)\s*[：:]\s*(.+?)\s*$') { $facts[$labels[$Matches[1]]] = $Matches[2] }
            }
            if ($facts.Count -ne 4) { throw "Translation slot $slot japanese_facts must contain 変更/影響/時期/対応 lines." }
        }
        $updates.Add([ordered]@{
            id                       = $id
            japanese_title            = $japaneseTitle
            japanese_facts            = $facts
            japanese_detailed_summary = $detailSummary
            japanese_body_translation = $bodyTranslation
            source_character_count    = [int]$sourceCharacterCount
            source_truncated          = $sourceTruncated
        })
    }
    return @($updates)
}

$agentOutput = Get-Content -LiteralPath $AgentOutputPath -Raw -Encoding UTF8 | ConvertFrom-Json
$translationItem = @($agentOutput.items | Where-Object type -eq 'publish_m365_translations')
if ($translationItem.Count -ne 1) { throw "Expected exactly one publish_m365_translations item, got $($translationItem.Count)." }
$translationBatch = Get-Content -LiteralPath $TranslationBatchJson -Raw -Encoding UTF8 | ConvertFrom-Json
$translationBatchMessages = @($translationBatch.messages)
if ($translationBatchMessages.Count -gt 4) { throw 'Translation batch exceeds the four-message safe output limit.' }
$structuredTranslationUpdates = @(Get-StructuredTranslationUpdates -Item $translationItem[0] -ExpectedCount $translationBatchMessages.Count)
$translationUpdatesJson = if ($structuredTranslationUpdates.Count) {
    $structuredTranslationUpdates | ConvertTo-Json -Depth 8 -Compress
} else {
    '[]'
}

$previous = Get-Content -LiteralPath $PreviousInsightsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$snapshot = Get-Content -LiteralPath $MessagesJson -Raw -Encoding UTF8 | ConvertFrom-Json
$validation = Get-M365SummaryValidation -Insights $previous -Messages @($snapshot.messages)
if (-not $validation.valid) {
    throw "Invalid inherited weekly summary; run core summary repair first: $($validation.reason)"
}
$bridge = [ordered]@{
    items = @([ordered]@{
        type = 'publish_m365_dashboard'
        headline = $previous.headline; executive_summary = $previous.executiveSummary
        this_week = $previous.thisWeek; this_month = $previous.thisMonth; watch = $previous.watch
        customer_questions = $previous.customerQuestions
        referenced_ids = (@($previous.referencedIds) -join ',')
        translation_updates = $translationUpdatesJson
    })
}
$temp = Join-Path (Get-Location) ".m365-agent-bridge-$([guid]::NewGuid().ToString('N')).json"
try {
    $bridge | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temp -Encoding UTF8
    & (Join-Path $PSScriptRoot 'Publish-M365AgentInsights.ps1') `
        -AgentOutputPath $temp -MessagesJson $MessagesJson -TranslationBatchJson $TranslationBatchJson `
        -PreviousInsightsPath $PreviousInsightsPath -UseDeterministicMessageUpdates -PreserveSummaryMetadata -OutputPath $OutputPath
} finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}
