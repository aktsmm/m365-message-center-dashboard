<#
.SYNOPSIS
    gh-aw の検証済み safe output を公開用 insights.json に変換する。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AgentOutputPath,
    [Parameter(Mandatory)][string]$MessagesJson,
    [string]$TranslationBatchJson,
    [string]$PreviousInsightsPath,
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $AgentOutputPath)) { throw "Agent output not found: $AgentOutputPath" }
if (-not (Test-Path -LiteralPath $MessagesJson)) { throw "Messages JSON not found: $MessagesJson" }

$agentOutput = Get-Content -LiteralPath $AgentOutputPath -Raw -Encoding UTF8 | ConvertFrom-Json
$items = @($agentOutput.items | Where-Object type -eq 'publish_m365_dashboard')
if ($items.Count -ne 1) { throw "Expected exactly one publish_m365_dashboard item, got $($items.Count)." }
$item = $items[0]

function Get-SafeText {
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateRange(1, 200000)][int]$MaxLength
    )
    if (-not ($item.PSObject.Properties.Name -contains $Name)) { throw "Missing insight field: $Name" }
    $value = [string]$item.$Name
    $value = ($value -replace '[\u0000-\u0008\u000B\u000C\u000E-\u001F]', '').Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Insight field is empty: $Name" }
    if ($value.Length -gt $MaxLength) { throw "Insight field exceeds $MaxLength characters: $Name" }
    if ($value -match '<\s*(script|iframe|object|embed|style|svg)\b' -or $value -match '(?i)javascript:|data:text/html') {
        throw "Unsafe content detected in insight field: $Name"
    }
    if ($value -match '(?i)\b(bearer\s+)[A-Za-z0-9._~+/=-]{12,}' -or
        $value -match '(?i)\b(authorization\s*:\s*(?:basic|bearer)\s+)\S+' -or
        $value -match '(?i)\b(access[_ -]?token|refresh[_ -]?token|client[_ -]?secret|api[_ -]?key|password)\s*(?:[:=]|\bis\b)\s*\S+') {
        throw "Credential-like content detected in insight field: $Name"
    }
    return $value
}

function Test-ContainsJapanese {
    param([Parameter(Mandatory)][string]$Value)

    return $Value -match '[ぁ-んァ-ヶ一-龠々ー]'
}

function Get-RequiredUpdateText {
    param(
        [Parameter(Mandatory)][object]$Update,
        [Parameter(Mandatory)][string]$Name,
        [ValidateRange(1, 5000)][int]$MaxLength,
        [string]$JapaneseFallback
    )

    if (-not ($Update.PSObject.Properties.Name -contains $Name)) {
        throw "Message update is missing field: $Name"
    }
    $value = ([string]$Update.$Name).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Message update field is empty: $Name" }
    if ($value.Length -gt $MaxLength) { throw "Message update field exceeds $MaxLength characters: $Name" }
    if ($value -match '<\s*(script|iframe|object|embed|style|svg)\b' -or $value -match '(?i)javascript:|data:text/html') {
        throw "Unsafe content detected in message update field: $Name"
    }
    if ($value -match '(?i)\b(bearer\s+)[A-Za-z0-9._~+/=-]{12,}' -or
        $value -match '(?i)\b(authorization\s*:\s*(?:basic|bearer)\s+)\S+' -or
        $value -match '(?i)\b(access[_ -]?token|refresh[_ -]?token|client[_ -]?secret|api[_ -]?key|password)\s*(?:[:=]|\bis\b)\s*\S+') {
        throw "Credential-like content detected in message update field: $Name"
    }
    if (-not (Test-ContainsJapanese $value)) {
        $fallback = $JapaneseFallback.Trim()
        if ([string]::IsNullOrWhiteSpace($fallback)) {
            throw "Message update field must contain Japanese text: $Name"
        }
        if ($fallback.Length -gt $MaxLength -or -not (Test-ContainsJapanese $fallback)) {
            throw "Deterministic Japanese fallback is invalid for message update field: $Name"
        }
        if ($fallback -match '<\s*(script|iframe|object|embed|style|svg)\b' -or $fallback -match '(?i)javascript:|data:text/html') {
            throw "Unsafe content detected in deterministic Japanese fallback: $Name"
        }
        if ($fallback -match '(?i)\b(bearer\s+)[A-Za-z0-9._~+/=-]{12,}' -or
            $fallback -match '(?i)\b(authorization\s*:\s*(?:basic|bearer)\s+)\S+' -or
            $fallback -match '(?i)\b(access[_ -]?token|refresh[_ -]?token|client[_ -]?secret|api[_ -]?key|password)\s*(?:[:=]|\bis\b)\s*\S+') {
            throw "Credential-like content detected in deterministic Japanese fallback: $Name"
        }
        return $fallback
    }
    return $value
}

function ConvertFrom-MessageUpdatesInput {
    param(
        [Parameter(Mandatory)][object]$InputValue,
        [Parameter(Mandatory)][string]$Name
    )

    if ($InputValue -isnot [string]) { return @($InputValue) }

    $serialized = Get-SafeText -Name $Name -MaxLength 200000
    if ($serialized.StartsWith('gzip-base64:', [StringComparison]::Ordinal) -or
        ($Name -eq 'translation_updates' -and $serialized -match '^H4sI[A-Za-z0-9+/=]+$')) {
        try {
            $base64 = if ($serialized.StartsWith('gzip-base64:', [StringComparison]::Ordinal)) {
                $serialized.Substring('gzip-base64:'.Length)
            } else {
                $serialized
            }
            $compressedBytes = [Convert]::FromBase64String($base64)
            $compressedStream = [System.IO.MemoryStream]::new($compressedBytes)
            try {
                $gzipStream = [System.IO.Compression.GzipStream]::new(
                    $compressedStream,
                    [System.IO.Compression.CompressionMode]::Decompress
                )
                try {
                    $reader = [System.IO.StreamReader]::new($gzipStream, [System.Text.Encoding]::UTF8)
                    try {
                        $serialized = $reader.ReadToEnd()
                    } finally {
                        $reader.Dispose()
                    }
                } finally {
                    $gzipStream.Dispose()
                }
            } finally {
                $compressedStream.Dispose()
            }
        } catch {
            throw "${Name} gzip-base64 payload could not be decoded: $($_.Exception.Message)"
        }
    }

    try {
        return @($serialized | ConvertFrom-Json)
    } catch {
        throw "${Name} must be a valid JSON array: $($_.Exception.Message)"
    }
}

$messages = Get-Content -LiteralPath $MessagesJson -Raw -Encoding UTF8 | ConvertFrom-Json
$allowedIds = @(
    $messages.messages |
        ForEach-Object { ([string]$_.id).Trim().ToUpperInvariant() } |
        Sort-Object -Unique
)
$allowedIdSet = @{}
foreach ($id in $allowedIds) { $allowedIdSet[$id] = $true }
$messagesById = @{}
foreach ($message in @($messages.messages)) {
    $messagesById[([string]$message.id).Trim().ToUpperInvariant()] = $message
}
$referencedIds = @(
    ([string]$item.referenced_ids -split '[,\s]+') |
        Where-Object { $_ } |
        ForEach-Object { $_.Trim().ToUpperInvariant() } |
        Sort-Object -Unique
)
$invalidIds = @($referencedIds | Where-Object { $_ -notin $allowedIds })
if ($invalidIds.Count) { throw "Agent referenced unknown MC IDs: $($invalidIds -join ', ')" }

$messageUrlsById = @{}
$learnUrlsById = @{}
foreach ($message in @($messages.messages)) {
    $id = ([string]$message.id).Trim().ToUpperInvariant()
    $messageUrls = [System.Collections.Generic.List[string]]::new()
    $learnUrls = [System.Collections.Generic.List[string]]::new()
    $details = if ($message.PSObject.Properties.Name -contains 'details') { @($message.details) } else { @() }
    foreach ($detail in $details) {
        if ($null -eq $detail) { continue }
        $uri = $null
        $value = [string]$detail.value
        if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
            continue
        }
        $hostName = $uri.Host.ToLowerInvariant()
        if ($hostName -in @('admin.microsoft.com', 'm365.cloud.microsoft') -and
            $uri.AbsoluteUri -match '(?i)message.?center|/messages/') {
            $messageUrls.Add($uri.AbsoluteUri)
        }
        if ($hostName -eq 'learn.microsoft.com') {
            $learnUrls.Add($uri.AbsoluteUri)
        }
    }
    $messageUrlsById[$id] = @($messageUrls | Sort-Object -Unique)
    $learnUrlsById[$id] = @($learnUrls | Sort-Object -Unique)
}

if (-not ($item.PSObject.Properties.Name -contains 'message_updates')) {
    throw 'Missing insight field: message_updates'
}
$messageUpdatesInput = $item.message_updates
$messageUpdates = @(ConvertFrom-MessageUpdatesInput -InputValue $messageUpdatesInput -Name 'message_updates')
if ($messageUpdates.Count -ne $allowedIds.Count) {
    throw "Expected one message update for each MC ID ($($allowedIds.Count)), got $($messageUpdates.Count)."
}
$seenUpdateIds = @{}
$validatedUpdates = @()
foreach ($update in $messageUpdates) {
    if (-not ($update.PSObject.Properties.Name -contains 'id')) { throw 'Message update is missing field: id' }
    $id = ([string]$update.id).Trim().ToUpperInvariant()
    if (-not $allowedIdSet.ContainsKey($id)) { throw "Message update referenced unknown MC ID: $id" }
    if ($seenUpdateIds.ContainsKey($id)) { throw "Message update is duplicated for MC ID: $id" }
    $seenUpdateIds[$id] = $true

    $snapshotMessage = $messagesById[$id]
    $japaneseTitle = Get-RequiredUpdateText -Update $update -Name 'japanese_title' -MaxLength 200 `
        -JapaneseFallback ([string]$snapshotMessage.japaneseTitle)
    $japaneseSummary = Get-RequiredUpdateText -Update $update -Name 'japanese_summary' -MaxLength 100 `
        -JapaneseFallback ([string]$snapshotMessage.japaneseSummary)
    $messageUrl = $null
    if ($update.PSObject.Properties.Name -contains 'message_url' -and -not [string]::IsNullOrWhiteSpace([string]$update.message_url)) {
        $messageUrl = ([string]$update.message_url).Trim()
        if ($messageUrl -notin $messageUrlsById[$id]) {
            throw "Message update URL is not an allowed snapshot URL for ${id}: $messageUrl"
        }
    }
    $learnUrls = @()
    if ($update.PSObject.Properties.Name -contains 'learn_urls' -and $null -ne $update.learn_urls) {
        $learnUrls = @(
            $update.learn_urls |
                ForEach-Object { ([string]$_).Trim() } |
                Where-Object { $_ } |
                Sort-Object -Unique
        )
        foreach ($learnUrl in $learnUrls) {
            if ($learnUrl -notin $learnUrlsById[$id]) {
                throw "Learn URL is not an allowed snapshot URL for ${id}: $learnUrl"
            }
        }
    }
    $validatedUpdates += [ordered]@{
        id              = $id
        japaneseTitle   = $japaneseTitle
        japaneseSummary = $japaneseSummary
        messageUrl      = $messageUrl
        learnUrls       = $learnUrls
    }
}
foreach ($id in $allowedIds) {
    if (-not $seenUpdateIds.ContainsKey($id)) { throw "Message update is missing for MC ID: $id" }
}

$validatedTranslations = @()
if ($TranslationBatchJson) {
    if (-not (Test-Path -LiteralPath $TranslationBatchJson)) { throw "Translation batch JSON not found: $TranslationBatchJson" }
    if (-not ($item.PSObject.Properties.Name -contains 'translation_updates')) {
        throw 'Missing insight field: translation_updates'
    }
    $translationBatch = Get-Content -LiteralPath $TranslationBatchJson -Raw -Encoding UTF8 | ConvertFrom-Json
    $batchById = @{}
    foreach ($batchMessage in @($translationBatch.messages)) {
        $id = ([string]$batchMessage.id).Trim().ToUpperInvariant()
        if (-not $allowedIdSet.ContainsKey($id)) { throw "Translation batch contains unknown MC ID: $id" }
        if ($batchById.ContainsKey($id)) { throw "Translation batch contains duplicate MC ID: $id" }
        $batchById[$id] = $batchMessage
    }
    $translationUpdates = @(ConvertFrom-MessageUpdatesInput -InputValue $item.translation_updates -Name 'translation_updates')
    if ($translationUpdates.Count -ne $batchById.Count) {
        throw "Expected one translation update for each batch MC ID ($($batchById.Count)), got $($translationUpdates.Count)."
    }
    $seenTranslationIds = @{}
    foreach ($translation in $translationUpdates) {
        if (-not ($translation.PSObject.Properties.Name -contains 'id')) { throw 'Translation update is missing field: id' }
        $id = ([string]$translation.id).Trim().ToUpperInvariant()
        if (-not $batchById.ContainsKey($id)) { throw "Translation update referenced an ID outside the current batch: $id" }
        if ($seenTranslationIds.ContainsKey($id)) { throw "Translation update is duplicated for MC ID: $id" }
        $seenTranslationIds[$id] = $true
        $detailSummary = Get-RequiredUpdateText -Update $translation -Name 'japanese_detailed_summary' -MaxLength 1200
        if ($detailSummary.Length -lt 80) { throw "Translation detailed summary is too short for MC ID: $id" }
        $bodyTranslation = Get-RequiredUpdateText -Update $translation -Name 'japanese_body_translation' -MaxLength 5000
        $batchMessage = $batchById[$id]
        if ([int]$translation.source_character_count -ne [int]$batchMessage.sourceCharacterCount) {
            throw "Translation source character count does not match the current batch for MC ID: $id"
        }
        if ([bool]$translation.source_truncated -ne [bool]$batchMessage.sourceTruncated) {
            throw "Translation truncation flag does not match the current batch for MC ID: $id"
        }
        $validatedTranslations += [ordered]@{
            id                     = $id
            japaneseDetailedSummary = $detailSummary
            japaneseBodyTranslation = $bodyTranslation
            sourceCharacterCount    = [int]$batchMessage.sourceCharacterCount
            sourceTruncated         = [bool]$batchMessage.sourceTruncated
        }
    }
}

$translationsById = @{}
if ($PreviousInsightsPath -and (Test-Path -LiteralPath $PreviousInsightsPath)) {
    $previousInsights = Get-Content -LiteralPath $PreviousInsightsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($previousInsights.PSObject.Properties.Name -contains 'messageTranslations') {
        foreach ($translation in @($previousInsights.messageTranslations)) {
            $id = ([string]$translation.id).Trim().ToUpperInvariant()
            if ($allowedIdSet.ContainsKey($id)) { $translationsById[$id] = $translation }
        }
    }
}
foreach ($translation in $validatedTranslations) { $translationsById[$translation.id] = $translation }

$insights = [ordered]@{
    generatedAt       = [DateTimeOffset]::UtcNow.ToString('o')
    source            = 'GitHub Agentic Workflows / Copilot'
    headline          = Get-SafeText -Name 'headline' -MaxLength 160
    executiveSummary  = Get-SafeText -Name 'executive_summary' -MaxLength 2000
    thisWeek          = Get-SafeText -Name 'this_week' -MaxLength 3000
    thisMonth         = Get-SafeText -Name 'this_month' -MaxLength 3000
    watch             = Get-SafeText -Name 'watch' -MaxLength 3000
    customerQuestions = Get-SafeText -Name 'customer_questions' -MaxLength 3000
    referencedIds     = $referencedIds
    messageUpdates    = $validatedUpdates
    messageTranslations = @($translationsById.Values | Sort-Object id)
}

$parent = Split-Path -Parent $OutputPath
if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
$insights | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Host "Published validated Agentic insights to $OutputPath"
