function Get-M365ContentProperty {
    param($Object, [string]$Name, $Default = '')
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    } elseif ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $Default
}

function ConvertTo-M365ContentText {
    param([AllowEmptyString()][string]$Text)
    $parts = [regex]::Split($Text, '((?:[A-Za-z]:\\|\\\\)[^\s]+)')
    for ($index = 0; $index -lt $parts.Count; $index += 2) {
        $parts[$index] = $parts[$index] -replace '\\r\\n|\\n|\\r', "`n"
    }
    return ($parts -join '') -replace "`r`n?", "`n"
}

function Get-M365ContentHash {
    param([AllowEmptyString()][string]$Text)
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
        [System.Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function Get-M365MessageSourceHash {
    param([Parameter(Mandatory)]$Message)
    $services = [string[]]@(Get-M365ContentProperty $Message 'services' @() |
        ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
    [Array]::Sort($services, [StringComparer]::Ordinal)
    $actionValue = Get-M365ContentProperty $Message 'actionRequiredByDateTime'
    $action = [string]$actionValue
    if ($action) {
        $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
        $date = if ($actionValue -is [DateTimeOffset]) { $actionValue } elseif ($actionValue -is [DateTime]) {
            if ($actionValue.Kind -eq [DateTimeKind]::Unspecified) {
                [DateTimeOffset]::new([DateTime]::SpecifyKind($actionValue, [DateTimeKind]::Utc))
            } else { [DateTimeOffset]::new($actionValue) }
        } else { [DateTimeOffset]::Parse($action, [Globalization.CultureInfo]::InvariantCulture, $styles) }
        $action = $date.UtcDateTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    $parts = @(
        ([string](Get-M365ContentProperty $Message 'id')).Trim().ToUpperInvariant()
        [string](Get-M365ContentProperty $Message 'title')
        [string](Get-M365ContentProperty $Message 'category')
        (([string](Get-M365ContentProperty $Message 'bodyText')) -replace "`r`n?", "`n")
        ($services -join ',')
        $action
    )
    return Get-M365ContentHash ($parts -join [char]0x1f)
}

function Test-M365TranslationSource {
    param($Translation, [Parameter(Mandatory)]$Message)
    $hash = [string](Get-M365ContentProperty $Translation 'sourceHash')
    return ($hash -cmatch '^[a-f0-9]{64}$' -and $hash -ceq (Get-M365MessageSourceHash -Message $Message))
}

function Test-M365TranslationComplete {
    param($Translation, [Parameter(Mandatory)]$Message)
    $title = [string](Get-M365ContentProperty $Translation 'japaneseTitle')
    return ((Test-M365TranslationSource -Translation $Translation -Message $Message) -and $title.Trim().Length -ge 4)
}

function Get-M365SnapshotSourceHash {
    param([Parameter(Mandatory)]$Document)
    $entries = [string[]]@(foreach ($message in @(Get-M365ContentProperty $Document 'messages' @())) {
        ([string]$message.id).Trim().ToUpperInvariant() + [char]0x1f + (Get-M365MessageSourceHash -Message $message)
    })
    [Array]::Sort($entries, [StringComparer]::Ordinal)
    return Get-M365ContentHash ($entries -join [char]0x1f)
}

function Assert-M365SnapshotCurrent {
    param([Parameter(Mandatory)][string]$AcceptedJson, [Parameter(Mandatory)][string]$CurrentJson)
    foreach ($path in @($AcceptedJson, $CurrentJson)) {
        if (-not (Test-Path -LiteralPath $path)) { throw 'Accepted or current public snapshot is missing.' }
    }
    $accepted = Get-Content -LiteralPath $AcceptedJson -Raw -Encoding UTF8 | ConvertFrom-Json
    $current = Get-Content -LiteralPath $CurrentJson -Raw -Encoding UTF8 | ConvertFrom-Json
    if ((Get-M365SnapshotSourceHash -Document $accepted) -cne (Get-M365SnapshotSourceHash -Document $current)) {
        throw 'The public snapshot changed while the agent was running. Keep the newer snapshot and retry from current data.'
    }
}

function Get-M365SummaryValidation {
    param([Parameter(Mandatory)]$Insights, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Messages)
    $allowed = @{}
    foreach ($message in $Messages) { $allowed[([string]$message.id).ToUpperInvariant()] = $true }
    $unknown = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $reasons = [System.Collections.Generic.List[string]]::new()
    $declared = @(Get-M365ContentProperty $Insights 'referencedIds' @() | ForEach-Object { ([string]$_).ToUpperInvariant() })
    foreach ($id in $declared) { if (-not $allowed.ContainsKey($id)) { [void]$unknown.Add($id) } }
    foreach ($field in @('headline', 'executiveSummary', 'thisWeek', 'thisMonth', 'watch', 'customerQuestions')) {
        $text = ConvertTo-M365ContentText ([string](Get-M365ContentProperty $Insights $field))
        if ([string]::IsNullOrWhiteSpace($text)) { $reasons.Add("Empty summary field: $field") }
        foreach ($match in [regex]::Matches($text, '(?i)\bMC\d+\b')) {
            $id = $match.Value.ToUpperInvariant()
            if (-not $allowed.ContainsKey($id)) { [void]$unknown.Add($id) }
            if ($id -notin $declared) { $reasons.Add("Inline citation absent from referencedIds: $id") }
        }
        if ($text -match '(?im)\bMC(?:\d+|\.{3}|…)\s*[:：]\s*(?:なし|N/?A|none)(?:\s|[。.;；]|$)') {
            $reasons.Add("Placeholder citation in $field")
        }
        $seen = @{}
        foreach ($line in ($text -split "`n")) {
            $line = ($line.Trim() -replace '^(?:[-*•]|\d+[.)])\s*', '') -replace '\s+', ' '
            if ($line.Length -lt 12) { continue }
            if ($seen.ContainsKey($line)) { $reasons.Add("Duplicate substantive line in $field") }
            $seen[$line] = $true
        }
    }
    if ($unknown.Count) { $reasons.Add('Unknown inline or declared MC IDs') }
    return [pscustomobject]@{ valid = $reasons.Count -eq 0; reason = $reasons -join '; '; unknownIds = @($unknown | Sort-Object) }
}
