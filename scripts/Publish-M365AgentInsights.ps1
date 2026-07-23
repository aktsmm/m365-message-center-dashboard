<#
.SYNOPSIS
    gh-aw の検証済み safe output を公開用 insights.json に変換する。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AgentOutputPath,
    [Parameter(Mandatory)][string]$MessagesJson,
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
        [ValidateRange(1, 1000)][int]$MaxLength
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
    if (-not (Test-ContainsJapanese $value)) { throw "Message update field must contain Japanese text: $Name" }
    return $value
}

function ConvertFrom-MessageUpdatesInput {
    param([Parameter(Mandatory)][object]$InputValue)

    if ($InputValue -isnot [string]) { return @($InputValue) }

    $serialized = Get-SafeText -Name 'message_updates' -MaxLength 200000
    if ($serialized.StartsWith('gzip-base64:', [StringComparison]::Ordinal)) {
        try {
            $compressedBytes = [Convert]::FromBase64String($serialized.Substring('gzip-base64:'.Length))
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
            throw "message_updates gzip-base64 payload could not be decoded: $($_.Exception.Message)"
        }
    }

    try {
        return @($serialized | ConvertFrom-Json)
    } catch {
        throw "message_updates must be a valid JSON array: $($_.Exception.Message)"
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
$messageUpdates = @(ConvertFrom-MessageUpdatesInput -InputValue $messageUpdatesInput)
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

    $japaneseTitle = Get-RequiredUpdateText -Update $update -Name 'japanese_title' -MaxLength 200
    $japaneseSummary = Get-RequiredUpdateText -Update $update -Name 'japanese_summary' -MaxLength 100
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
}

$parent = Split-Path -Parent $OutputPath
if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
$insights | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Host "Published validated Agentic insights to $OutputPath"
