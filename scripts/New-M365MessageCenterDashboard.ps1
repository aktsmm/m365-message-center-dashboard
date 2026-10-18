<#
.SYNOPSIS
    公開許可済み Message Center メタデータから単一 HTML ダッシュボードを生成する。
#>
[CmdletBinding()]
param(
    [string]$MessagesJson = (Join-Path $PSScriptRoot '..\output\m365\messages.json'),
    [string]$InsightsJson,
    [string]$RelatedDocumentsJson = (Join-Path $PSScriptRoot '..\reports\m365\related-documents.json'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\output\m365\index.html')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'M365DashboardContent.ps1')
$viewHelpers = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'dashboard-view.js') -Raw -Encoding UTF8

function Compress-PublicJson {
    param([string]$Json)
    $document = [Text.Json.JsonDocument]::Parse($Json)
    try {
        $options = [Text.Json.JsonSerializerOptions]::new()
        $options.Encoder = [Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
        return [Text.Json.JsonSerializer]::Serialize($document.RootElement, $options)
    } finally {
        $document.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $MessagesJson)) { throw "Messages JSON not found: $MessagesJson" }
$safeJson = Get-Content -LiteralPath $MessagesJson -Raw -Encoding UTF8
$data = $safeJson | ConvertFrom-Json
$safeJson = Compress-PublicJson $safeJson
$safeJson = $safeJson.Replace('&', '\u0026').Replace('<', '\u003c').Replace('>', '\u003e')
$safeInsightsJson = 'null'
$relatedDocuments = [ordered]@{}
if ($PSBoundParameters.ContainsKey('RelatedDocumentsJson') -and $RelatedDocumentsJson -and
    -not (Test-Path -LiteralPath $RelatedDocumentsJson)) {
    throw "Related documents JSON not found: $RelatedDocumentsJson"
}
if ($RelatedDocumentsJson -and (Test-Path -LiteralPath $RelatedDocumentsJson)) {
    $catalog = Get-Content -LiteralPath $RelatedDocumentsJson -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    if ($catalog.schemaVersion -ne 1) { throw 'Unsupported related-document schema.' }
    foreach ($message in $data.messages) {
        $entry = $catalog.messages[$message.id]
        if (-not $entry) { continue }
        $values = @([string]$message.id, [string]$message.title,
            $(if ($message.PSObject.Properties.Name -contains 'bodyText') { [string]$message.bodyText } else { '' }),
            (@($message.services) -join "`n"), (@($message.tags) -join "`n"),
            $(if ($message.PSObject.Properties.Name -contains 'officialDocumentUrls') { @($message.officialDocumentUrls) -join "`n" } else { '' }))
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes(($values -join [char]31)))).ToLowerInvariant()
        if ($entry.ContainsKey('variants') -and $entry.variants.ContainsKey($hash)) {
            $entry = $entry.variants[$hash]
        }
        if ($hash -notin $entry.sourceHashes) {
            Write-Warning "Related documents require re-verification for changed message $($message.id)."
            continue
        }
        if ($entry.status -notin @('verified', 'not_researched', 'no_verified_document', 'fetch_failed')) {
            throw "Invalid document state for $($message.id)"
        }
        if (@($entry.documents).Count -gt 3) { throw 'Related documents exceed three articles.' }
        foreach ($document in $entry.documents) {
            foreach ($value in @($document.title, $document.rationale, $document.url)) {
                if ($value -match '(?i)\b(bearer\s+)[A-Za-z0-9._~+/=-]{12,}' -or
                    $value -match '(?i)\b(access[_ -]?token|refresh[_ -]?token|client[_ -]?secret|api[_ -]?key|password)\s*[:=]\s*\S+' -or
                    $value -match '<\s*(script|iframe|object|embed|style|svg)\b|(?i)javascript:|data:text/html') {
                    throw "Unsafe related document for $($message.id)"
                }
            }
            $uri = $null
            if (-not [Uri]::TryCreate($document.url, [UriKind]::Absolute, [ref]$uri) -or
                $uri.Scheme -ne 'https' -or $uri.Host -ne 'learn.microsoft.com' -or $uri.UserInfo -or
                $uri.AbsolutePath -notmatch '^/(ja-jp|en-us)/[^/]+/.+' -or
                [string]::IsNullOrWhiteSpace($document.title) -or
                [string]::IsNullOrWhiteSpace($document.rationale) -or
                $document.bodySha256 -notmatch '^[a-f0-9]{64}$' -or
                $document.locale -notin @('ja-jp', 'en-us') -or
                $uri.AbsolutePath -notmatch "^/$($document.locale)/") {
                throw "Invalid verified document for $($message.id)"
            }
            $null = [DateTimeOffset]::Parse($document.checkedAt)
        }
        if ($entry.status -eq 'verified' -and -not @($entry.documents).Count) {
            throw "Verified document state is empty for $($message.id)"
        }
        $relatedDocuments[$message.id] = [ordered]@{
            status = $entry.status
            documents = $entry.documents
            checkedAt = $entry.checkedAt
            nextAttemptAt = $(if ($entry.ContainsKey('nextAttemptAt')) { $entry.nextAttemptAt } else { $null })
        }
    }
}
$safeDocumentsJson = ConvertTo-Json -InputObject $relatedDocuments -Depth 12 -Compress
$safeDocumentsJson = $safeDocumentsJson.Replace('&', '\u0026').Replace('<', '\u003c').Replace('>', '\u003e')
if ($InsightsJson -and (Test-Path -LiteralPath $InsightsJson)) {
    $safeInsightsJson = Get-Content -LiteralPath $InsightsJson -Raw -Encoding UTF8
    $safeInsightsJson = Compress-PublicJson $safeInsightsJson
    $safeInsightsJson = $safeInsightsJson.Replace('&', '\u0026').Replace('<', '\u003c').Replace('>', '\u003e')
}
$contentState = [ordered]@{ messages = [ordered]@{}; summary = [ordered]@{ status = 'missing'; reason = '週次要約は未生成です。' } }
$insightsObject = if ($safeInsightsJson -ne 'null') { $safeInsightsJson | ConvertFrom-Json } else { $null }
$translations = @{}
if ($insightsObject -and $insightsObject.PSObject.Properties.Name -contains 'messageTranslations') {
    foreach ($translation in @($insightsObject.messageTranslations)) { $translations[$translation.id] = $translation }
}
foreach ($message in $data.messages) {
    $translation = $translations[$message.id]
    $status = if (-not $translation) { 'missing' } elseif ($translation.PSObject.Properties.Name -notcontains 'sourceHash') {
        'unverified'
    } elseif (Test-M365TranslationSource -Translation $translation -Message $message) { 'current' } else { 'stale' }
    $contentState.messages[$message.id] = [ordered]@{ sourceHash = Get-M365MessageSourceHash -Message $message; translation = $status }
}
if ($insightsObject) {
    $validation = Get-M365SummaryValidation -Insights $insightsObject -Messages @($data.messages)
    $status = if (-not $validation.valid) { 'invalid' } elseif (
        $insightsObject.PSObject.Properties.Name -notcontains 'summarySourceHash') { 'unverified' } elseif (
        $insightsObject.summarySourceHash -eq (Get-M365SnapshotSourceHash -Document $data)) { 'current' } else { 'stale' }
    $contentState.summary = [ordered]@{ status = $status; reason = $validation.reason }
}
$safeContentState = ($contentState | ConvertTo-Json -Depth 8 -Compress).Replace('&', '\u0026').Replace('<', '\u003c').Replace('>', '\u003e')

$html = @'
<!doctype html>
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <script>
    (() => {
      const param = new URLSearchParams(window.location.search).get("scoutTheme");
      const forcedTheme = ["light", "dark"].includes(param) ? param : null;
      const storedTheme = localStorage.getItem("scoutTheme");
      const theme = forcedTheme || (["light", "dark"].includes(storedTheme) ? storedTheme : "light");
      document.documentElement.setAttribute("data-theme", theme);
      document.documentElement.setAttribute("data-theme-source", forcedTheme ? "url" : storedTheme === theme ? "storage" : "default");
    })();
  </script>
  <title>Microsoft 365 Change Radar</title>
  <style>
    :root {
      color-scheme: light;
      --cp-bg: #f8f4ed;
      --cp-bg-elevated: #fdfaf5;
      --cp-surface: #ffffff;
      --cp-surface-soft: #f4ede4;
      --cp-border: #e4d9cc;
      --cp-border-strong: #a28c77;
      --cp-text: #2d2822;
      --cp-text-muted: #665d54;
      --cp-text-soft: #7c7064;
      --cp-accent: #a33e2c;
      --cp-accent-hover: #873424;
      --cp-accent-soft: rgba(163, 62, 44, 0.1);
      --cp-accent-fg: #ffffff;
      --cp-success: #2f7b55;
      --cp-danger: #b63f36;
      --cp-warning: #a45a10;
      --cp-link: #94412f;
      --cp-shadow: 0 18px 48px rgba(45, 40, 34, 0.12);
      --cp-overlay: rgba(255, 255, 255, 0.82);
      --cp-panel: rgba(255, 255, 255, 0.9);
      --cp-panel-strong: rgba(255, 255, 255, 0.98);
      --cp-sheen: rgba(255, 255, 255, 0.6);
      --cp-highlight: rgba(163, 62, 44, 0.12);
    }
    html[data-theme="dark"] {
      color-scheme: dark;
      --cp-bg: #292521;
      --cp-bg-elevated: #322d28;
      --cp-surface: #39332d;
      --cp-surface-soft: #433a32;
      --cp-border: #5d5044;
      --cp-border-strong: #86705c;
      --cp-text: #f4eae0;
      --cp-text-muted: #d2c1b2;
      --cp-text-soft: #e2d2c4;
      --cp-accent: #ffb09c;
      --cp-accent-hover: #ffc5b5;
      --cp-accent-soft: rgba(255, 176, 156, 0.16);
      --cp-accent-fg: #332018;
      --cp-success: #8bd3a7;
      --cp-danger: #ff9d91;
      --cp-warning: #f6be73;
      --cp-link: #ffc0a8;
      --cp-shadow: 0 18px 48px rgba(0, 0, 0, 0.4);
      --cp-overlay: rgba(41, 37, 33, 0.9);
      --cp-panel: rgba(57, 51, 45, 0.84);
      --cp-panel-strong: rgba(57, 51, 45, 0.98);
      --cp-sheen: rgba(255, 255, 255, 0.06);
      --cp-highlight: rgba(255, 176, 156, 0.14);
    }
    * { box-sizing: border-box; }
    html { scroll-behavior: smooth; }
    body {
      margin: 0;
      background: var(--cp-bg);
      color: var(--cp-text);
      font-family: "Segoe UI", Aptos, Calibri, -apple-system, BlinkMacSystemFont, sans-serif;
      line-height: 1.5;
      min-height: 100vh;
    }
    .aurora {
      position: fixed; inset: 0; z-index: -1; pointer-events: none;
      background:
        radial-gradient(circle at 10% 5%, color-mix(in srgb, var(--cp-link) 24%, var(--cp-bg)) 0, var(--cp-bg) 32%),
        radial-gradient(circle at 92% 12%, color-mix(in srgb, var(--cp-accent) 20%, var(--cp-bg)) 0, var(--cp-bg) 30%),
        radial-gradient(circle at 78% 82%, color-mix(in srgb, var(--cp-warning) 18%, var(--cp-bg)) 0, var(--cp-bg) 34%),
        radial-gradient(circle at 12% 88%, color-mix(in srgb, var(--cp-success) 16%, var(--cp-bg)) 0, var(--cp-bg) 30%);
    }
    button, input { font: inherit; }
    .shell { width: min(1180px, calc(100% - 32px)); margin: 0 auto; padding: 28px 0 64px; }
    .nav {
      position: sticky; top: 12px; z-index: 10; display: flex; align-items: center;
      flex-wrap: wrap; gap: 12px 16px; padding: 12px 16px;
      background: var(--cp-panel); border: 1px solid var(--cp-border); border-radius: 16px;
      backdrop-filter: blur(20px); box-shadow: var(--cp-shadow);
    }
    .brand { display: flex; align-items: center; gap: 10px; font-weight: 700; letter-spacing: -0.02em; }
    .brand-mark {
      width: 32px; height: 32px; display: grid; place-items: center; border-radius: 0.625rem;
      color: var(--cp-accent-fg);
      background: linear-gradient(135deg, var(--cp-link), var(--cp-accent), var(--cp-warning));
    }
    .demo-links { display: flex; flex: 1 1 420px; flex-wrap: wrap; align-items: center; gap: 6px; }
    .demo-link {
      padding: 6px 9px; color: var(--cp-link); border: 1px solid transparent; border-radius: 999px;
      font-size: 0.78rem; font-weight: 700; text-decoration: none;
    }
    .demo-link:hover { color: var(--cp-accent); border-color: var(--cp-border-strong); background: var(--cp-surface); }
    .demo-link:focus-visible { outline: 3px solid var(--cp-accent); outline-offset: 3px; }
    .demo-link[aria-current="page"] {
      color: var(--cp-accent-fg); background: linear-gradient(110deg, var(--cp-link), var(--cp-accent));
      border-color: var(--cp-border-strong);
    }
    .nav-actions { display: flex; align-items: center; gap: 10px; margin-left: auto; }
    .theme-toggle {
      padding: 8px 12px; color: var(--cp-text); background: var(--cp-surface);
      border: 1px solid var(--cp-border-strong); border-radius: 999px; cursor: pointer; font-weight: 700;
    }
    .theme-toggle:hover { color: var(--cp-accent); border-color: var(--cp-accent); }
    .theme-toggle:focus-visible { outline: 3px solid var(--cp-accent); outline-offset: 3px; }
    .theme-toggle:disabled { cursor: not-allowed; opacity: 0.72; }
    .nav-meta { color: var(--cp-text-muted); font-size: 0.84rem; text-align: right; }
    .source-status { font-weight: 700; color: var(--cp-text); }
    .hero { padding: 56px 8px 28px; max-width: 840px; }
    .eyebrow { color: var(--cp-text-muted); font-size: 0.82rem; font-weight: 800; letter-spacing: 0.14em; text-transform: uppercase; }
    h1 {
      margin: 10px 0 14px; font-size: clamp(1.9rem, 4.2vw, 2.9rem); line-height: 1.3; letter-spacing: -0.02em;
      color: var(--cp-text); font-weight: 800;
    }
    .lede { max-width: 720px; margin: 0; color: var(--cp-text-muted); font-size: clamp(0.98rem, 1.6vw, 1.12rem); }
    .hero-repo-link {
      display: inline-flex; align-items: center; margin-top: 20px; padding: 10px 14px; border: 1px solid var(--cp-border-strong);
      border-radius: 999px; color: var(--cp-link); background: var(--cp-surface); font-weight: 700; text-decoration: none;
    }
    .hero-repo-link:hover { color: var(--cp-accent); border-color: var(--cp-accent); }
    .hero-repo-link:focus-visible { outline: 3px solid var(--cp-accent); outline-offset: 3px; }
    .hero-stats { display: flex; flex-wrap: wrap; gap: 10px; margin: 18px 0 8px; padding: 0; }
    .hero-stats span { padding: 10px 16px; border-radius: 0.9rem; background: var(--cp-surface-soft); font-size: 0.86rem; font-weight: 650; color: var(--cp-text-muted); }
    .hero-stats strong { display: block; font-size: 1.7rem; line-height: 1.2; color: var(--cp-text); }
    .hero-stats small { font-size: 0.85rem; font-weight: 600; }
    .hero-access-note { margin: 10px 0 0; color: var(--cp-text-muted); font-size: 0.88rem; }
    .context-panel, .filter-panel, .priority-section {
      margin-bottom: 18px; padding: clamp(20px, 4vw, 32px); background: var(--cp-panel-strong);
      border: 1px solid var(--cp-border); border-radius: 16px; box-shadow: var(--cp-shadow);
    }
    .context-panel { display: grid; grid-template-columns: minmax(0, 1.2fr) minmax(280px, 1fr); gap: 24px; }
    .context-panel h2, .filter-panel h2, .priority-section h2 { font-size: clamp(1.35rem, 3vw, 2rem); }
    .context-panel p { margin: 10px 0 0; color: var(--cp-text-muted); }
    .context-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 10px; margin: 0; }
    .context-grid div { padding: 14px; background: var(--cp-surface-soft); border: 1px solid var(--cp-border); border-radius: 0.625rem; }
    .context-grid dt { color: var(--cp-text-muted); font-size: 0.78rem; font-weight: 700; }
    .context-grid dd { margin: 5px 0 0; font-size: 1rem; font-weight: 750; }
    .insights {
      padding: clamp(24px, 5vw, 48px); margin-bottom: 18px; overflow: hidden;
      background: var(--cp-panel-strong); border: 1px solid var(--cp-border); border-radius: 16px;
      box-shadow: var(--cp-shadow); backdrop-filter: blur(24px);
    }
    .insight-headline { max-width: 900px; margin: 8px 0 14px; font-size: clamp(1.8rem, 4vw, 3.5rem); line-height: 1.08; letter-spacing: -0.055em; }
    .insight-summary { max-width: 900px; margin: 0; color: var(--cp-text-muted); font-size: 1.05rem; }
    .insight-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; margin-top: 28px; }
    .insight-column { padding: 18px; background: var(--cp-surface-soft); border: 1px solid var(--cp-border); border-radius: 0.625rem; }
    .insight-column h3 { margin: 0 0 10px; font-size: 0.78rem; letter-spacing: 0.1em; text-transform: uppercase; }
    .insight-column ul { margin: 0; padding-left: 18px; color: var(--cp-text-muted); }
    .insight-column li + li { margin-top: 8px; }
    .insight-pending { color: var(--cp-text-muted); }
    .metrics { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; margin-bottom: 40px; }
    .metric, .panel, .message {
      background: var(--cp-surface); border: 1px solid var(--cp-border); border-radius: 16px;
      box-shadow: var(--cp-shadow);
    }
    .metric { padding: 22px; min-height: 150px; display: flex; flex-direction: column; justify-content: space-between; }
    .metric-value { font-size: 2.7rem; font-weight: 750; letter-spacing: -0.055em; }
    .metric-label { color: var(--cp-text-muted); font-size: 0.88rem; }
    .metric-alert .metric-value { color: var(--cp-link); }
    .section-head { display: flex; align-items: end; justify-content: space-between; gap: 20px; margin: 40px 0 16px; }
    h2 { margin: 0; font-size: clamp(1.8rem, 4vw, 3rem); letter-spacing: -0.045em; }
    .section-note { color: var(--cp-text-muted); font-size: 0.9rem; }
    .services { display: grid; grid-template-columns: repeat(4, 1fr); gap: 10px; }
    .service {
      min-height: 112px; padding: 16px; color: var(--cp-text); background: var(--cp-bg-elevated);
      border: 1px solid var(--cp-border); border-radius: 0.625rem; cursor: pointer; text-align: left;
    }
    .service:hover, .service[aria-pressed="true"] { border-color: var(--cp-accent); background: var(--cp-accent-soft); }
    .service[aria-pressed="true"] strong::after { content: " ✓"; color: var(--cp-accent); }
    .service strong { display: block; font-size: 1.35rem; }
    .service span { color: var(--cp-text-muted); font-size: 0.82rem; }
    .service:focus-visible, .filter:focus-visible, .clear-filters:focus-visible, .service-filter input:focus-visible + span {
      outline: 3px solid var(--cp-accent); outline-offset: 3px;
    }
    .filter-panel-head, .priority-head { display: flex; align-items: end; justify-content: space-between; gap: 18px; }
    .filter-panel-head p, .priority-head p, .filter-help, .priority-note { margin: 8px 0 0; color: var(--cp-text-muted); }
    .service-filter-set { margin: 22px 0 0; padding: 0; border: 0; }
    .service-filter-set legend { font-weight: 750; }
    .service-filter-options { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 10px; }
    .service-filter { display: inline-flex; min-height: 44px; align-items: center; gap: 9px; padding: 9px 12px; background: var(--cp-surface); border: 1px solid var(--cp-border); border-radius: 0.625rem; cursor: pointer; }
    .service-filter.active { color: var(--cp-accent); border-color: var(--cp-accent); background: var(--cp-accent-soft); font-weight: 700; }
    .service-filter input { inline-size: 1.05rem; block-size: 1.05rem; accent-color: var(--cp-accent); }
    .service-filter-count { color: var(--cp-text-muted); font-size: 0.82rem; font-weight: 600; }
    .toolbar { display: grid; grid-template-columns: minmax(220px, 1fr) auto; gap: 12px; margin-top: 20px; }
    .search {
      width: 100%; padding: 13px 16px; color: var(--cp-text); background: var(--cp-surface);
      border: 1px solid var(--cp-border); border-radius: 0.625rem; outline: none;
    }
    .search:focus { border-color: var(--cp-accent); box-shadow: 0 0 0 3px var(--cp-accent-soft); }
    .filters { display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
    .filter {
      min-height: 44px; padding: 10px 14px; color: var(--cp-text-muted); background: var(--cp-surface);
      border: 1px solid var(--cp-border); border-radius: 999px; cursor: pointer;
    }
    .filter:hover, .filter.active {
      color: var(--cp-accent-fg);
      background: linear-gradient(110deg, var(--cp-link), var(--cp-accent), var(--cp-warning));
      border-color: var(--cp-border-strong);
    }
    .clear-filters {
      min-height: 44px; padding: 10px 14px; color: var(--cp-link); background: transparent;
      border: 1px solid var(--cp-border-strong); border-radius: 999px; cursor: pointer; font-weight: 700;
    }
    .clear-filters:hover { color: var(--cp-accent); border-color: var(--cp-accent); background: var(--cp-surface); }
    .priority-list { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 10px; margin-top: 18px; }
    .priority-card { display: flex; min-width: 0; flex-direction: column; gap: 10px; padding: 16px; background: var(--cp-surface); border: 1px solid var(--cp-border); border-radius: 0.625rem; }
    .priority-card h3 { margin: 0; font-size: 1rem; letter-spacing: -0.015em; }
    .priority-card a { color: var(--cp-link); font-size: 0.88rem; font-weight: 700; text-decoration: none; }
    .priority-card a:hover { color: var(--cp-accent); text-decoration: underline; }
    .priority-card a:focus-visible { outline: 3px solid var(--cp-accent); outline-offset: 3px; }
    .priority-reasons { display: flex; flex-wrap: wrap; gap: 6px; }
    .message-list { display: grid; gap: 10px; }
    .message { padding: 20px; transition: transform 140ms ease, border-color 140ms ease, box-shadow 140ms ease; }
    .message:hover { transform: translateY(-2px); border-color: var(--cp-border-strong); box-shadow: var(--cp-shadow); }
    .message-top { display: flex; justify-content: space-between; gap: 20px; }
    .message h3 { margin: 6px 0 10px; font-size: 1.12rem; letter-spacing: -0.02em; }
    .message-id { color: var(--cp-text-soft); font-family: Consolas, "Courier New", Courier, monospace; font-size: 0.78rem; }
    .message-date { min-width: 105px; color: var(--cp-text-muted); font-size: 0.82rem; text-align: right; }
    .ja-lead { margin: 6px 0 0; color: var(--cp-text); font-size: 0.95rem; line-height: 1.6; }
    .ja-lead.pending { color: var(--cp-text-soft); font-size: 0.82rem; }
    .message-top h3 { font-size: 1.2rem; line-height: 1.45; }
    .select-card { display: block; margin-bottom: 4px; font-size: 0.82rem; color: var(--cp-text-muted); cursor: pointer; }
    .select-card input { margin-right: 4px; }
    .export-actions { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin: 8px 0 12px; }
    .export-actions button { font: inherit; padding: 6px 12px; border: 1px solid var(--cp-border, #c8c6c4); border-radius: 0.5rem; background: var(--cp-surface-soft); color: inherit; cursor: pointer; }
    .message-original { margin-top: -4px; color: var(--cp-text-soft); font-size: 0.84rem; }
    .message-summary { margin: 16px 0 0; color: var(--cp-text-muted); }
    .message-links { display: flex; flex-wrap: wrap; gap: 8px; margin: 12px 0 0; }
    .message-link { color: var(--cp-link); font-size: 0.86rem; font-weight: 700; text-decoration: none; }
    .message-link:hover { color: var(--cp-accent); text-decoration: underline; }
    .title-link { color: inherit; text-decoration: none; }
    .title-link:hover { color: var(--cp-link); text-decoration: underline; }
    .title-link:focus-visible { outline: 3px solid var(--cp-accent); outline-offset: 3px; }
    .notice { padding: 12px 16px; border-left: 4px solid var(--cp-warning); background: var(--cp-surface-soft); color: var(--cp-text); border-radius: 0.625rem; }
    #health-title { font-size: 1.35rem; }
    .panel > summary, .insights > summary { cursor: pointer; font-weight: 750; }
    .compact-disclosure { padding: 14px 18px; margin-bottom: 14px; }
    .compact-disclosure > p { color: var(--cp-text-muted); }
    .jump-links { display: flex; gap: 14px; flex-wrap: wrap; margin-top: 16px; }
    .jump-links a { color: var(--cp-link); font-weight: 700; }
    .health-grid p { font-size: 0.84rem; }
    .health-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 220px), 1fr)); gap: 10px; margin-top: 16px; }
    .health-grid p { margin: 0; padding: 12px; background: var(--cp-surface-soft); border: 1px solid var(--cp-border); border-radius: 0.625rem; }
    .message-facts { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; margin: 16px 0; }
    .message-facts div { min-width: 0; padding: 12px; background: var(--cp-surface-soft); border-radius: 0.625rem; }
    .message-facts dt { font-weight: 750; }
    .message-facts dd { margin: 6px 0 0; color: var(--cp-text-muted); font-size: 0.88rem; overflow-wrap: anywhere; }
    .message, .priority-card, .message-list, .priority-list { min-width: 0; overflow-wrap: anywhere; }
    .message-top > div { min-width: 0; }
    .advanced-filters { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 190px), 1fr)); gap: 12px; margin-top: 16px; align-items: end; }
    .advanced-filters label { display: grid; gap: 6px; font-size: 0.88rem; }
    .share-status { min-height: 1.5em; color: var(--cp-text-muted); margin: 8px 0 0; }
    .message-list { counter-reset: visible-message; }
    .message-list > .message { counter-increment: visible-message; }
    .message-list .message-id::before { content: counter(visible-message) ". "; color: var(--cp-text-muted); }
    .metrics { grid-template-columns: repeat(auto-fit, minmax(min(100%, 210px), 1fr)); gap: 10px; margin-bottom: 24px; }
    .metric { min-height: 0; padding: 14px 18px; flex-direction: row; align-items: baseline; flex-wrap: wrap; gap: 8px; }
    .metric-value { font-size: 2rem; }
    .hero { padding: 32px 8px 24px; }
    .hero h1 { font-size: clamp(1.7rem, 6vw, 2.3rem); }
    .demo-links { order: 3; flex: 1 1 100%; flex-wrap: nowrap; overflow-x: auto; }
    .demo-link { flex-shrink: 0; }
    select { font: inherit; }
    @media (max-width: 640px) { .message-facts { grid-template-columns: 1fr; } }
    .related-documents { margin-top: 12px; }
    .related-documents ul { margin: 8px 0; padding-left: 24px; }
    .document-link { color: var(--cp-link); text-underline-offset: 3px; }
    .document-link:hover { color: var(--cp-accent); }
    .document-link:focus-visible, .message-link:focus-visible { outline: 3px solid var(--cp-accent); outline-offset: 3px; }
    .message-content { margin-top: 16px; border-top: 1px solid var(--cp-border); padding-top: 12px; }
    .message-content summary { cursor: pointer; font-weight: 700; }
    .message-body { margin: 12px 0 0; color: var(--cp-text-muted); white-space: normal; }
    .message-details { width: 100%; margin-top: 14px; border-collapse: collapse; font-size: 0.88rem; }
    .message-details th, .message-details td { padding: 8px; border: 1px solid var(--cp-border); text-align: left; vertical-align: top; overflow-wrap: anywhere; }
    .message-details th { width: 30%; background: var(--cp-surface-soft); }
    .chips { display: flex; flex-wrap: wrap; gap: 6px; }
    .chip { padding: 4px 9px; color: var(--cp-text-muted); background: var(--cp-surface-soft); border-radius: 999px; font-size: 0.75rem; }
    .chip.major { color: var(--cp-accent); background: var(--cp-accent-soft); font-weight: 700; }
    .chip.high { color: var(--cp-danger); font-weight: 700; }
    .chip.due { color: var(--cp-warning); font-weight: 700; }
    .empty { padding: 32px; color: var(--cp-text-muted); text-align: center; }
    .empty p { margin: 0 0 14px; }
    footer { padding: 56px 8px 0; color: var(--cp-text-muted); font-size: 0.82rem; }
    .repo-link { color: var(--cp-link); font-weight: 700; text-decoration: none; }
    .repo-link:hover { color: var(--cp-accent); text-decoration: underline; }
    @media (max-width: 820px) {
      .metrics, .services, .priority-list { grid-template-columns: repeat(2, 1fr); }
      .insight-grid { grid-template-columns: 1fr; }
      .toolbar { grid-template-columns: 1fr; }
      .filters { justify-content: flex-start; }
      .demo-links { order: 3; flex-basis: 100%; }
      .context-panel { grid-template-columns: 1fr; }
    }
    @media (max-width: 520px) {
      .shell { width: min(100% - 20px, 1180px); padding-top: 10px; }
      .nav-meta { display: none; }
      .hero { padding-top: 64px; }
      .metrics { grid-template-columns: 1fr 1fr; }
      .metric { min-height: 120px; padding: 16px; }
      .metric-value { font-size: 2.1rem; }
      .services, .priority-list, .context-grid { grid-template-columns: 1fr; }
      .filter-panel-head, .priority-head { align-items: start; flex-direction: column; }
      .message-top { display: block; }
      .message-date { margin-top: 8px; text-align: left; }
    }
  </style>
</head>
<body>
  <div class="aurora" aria-hidden="true"></div>
  <main class="shell">
    <nav class="nav" aria-label="Demo navigation">
      <div class="brand"><span class="brand-mark">M</span><span>Microsoft 365 Change Radar</span></div>
      <div class="demo-links">
        <a class="demo-link" href="https://aktsmm.github.io/azure-ops-pulse-demo/#/overview">Azure Ops Pulse</a>
        <a class="demo-link" href="https://aktsmm.github.io/azure-update-digest/">Azure Update Digest</a>
        <a class="demo-link" href="https://aktsmm.github.io/m365-message-center-dashboard/" aria-current="page">M365 Change Radar</a>
        <a class="demo-link" href="https://aktsmm.github.io/m365-copilot-update-digest/">M365 Copilot Update Digest</a>
        <a class="demo-link" href="https://aktsmm.github.io/daily-dev-byte/">Daily Dev Byte</a>
        <a class="demo-link" href="https://aktsmm.github.io/vscode-copilot-digest/index.html">VS Code Copilot Digest</a>
      </div>
      <div class="nav-actions">
        <button class="theme-toggle" id="theme-toggle" type="button" aria-label="表示テーマをダークに切り替えます" aria-pressed="false"></button>
        <div class="nav-meta"><div id="generated"></div><div class="source-status" id="source-status"></div></div>
      </div>
    </nav>

    <header class="hero">
      <div class="eyebrow">Microsoft 365 Change Radar · lab-public</div>
      <h1>いま確認すべき、Microsoft 365 の変更。</h1>
      <p class="lede">Message Center の通知を日本語で要約。期限・影響・公式資料を一覧のまま確認できます（公開承認済みテスト テナントの通知のみ）。</p>
      <p class="hero-stats" id="hero-stats" role="status"></p>
      <a class="hero-repo-link" href="https://admin.microsoft.com/#/MessageCenter" target="_blank" rel="noopener noreferrer">Microsoft 365 管理センターの Message Center を開く</a>
      <p class="hero-access-note">利用にはサインインと対象テナントでの適切な権限が必要です。</p>
      <a class="hero-repo-link" href="https://github.com/aktsmm/m365-message-center-dashboard">GitHub リポジトリを開く</a>
      <div class="jump-links"><a href="#filter-title">通知を探す</a><a href="#priority-title">対応の優先度</a><a href="#messages-title">通知一覧へ</a></div>
    </header>

    <details class="panel compact-disclosure"><summary>公開データの範囲と注意点</summary>
    <section class="context-panel" aria-labelledby="context-title">
      <div>
        <div class="eyebrow">公開データの範囲</div>
        <h2 id="context-title">このページについて</h2>
        <p>明示的に承認されたテスト テナントの lab-public スナップショットを表示しています。絞り込みは公開済みコンテンツを整理するためのもので、アクセス制御やデータ保護ではありません。</p>
      </div>
      <dl class="context-grid">
        <div><dt>スナップショット更新</dt><dd id="context-generated">—</dd></div>
        <div><dt>公開中の更新</dt><dd id="context-total">—</dd></div>
        <div><dt>データソース</dt><dd id="context-source">—</dd></div>
      </dl>
    </section>
    </details>

    <section class="panel" aria-labelledby="health-title" style="padding: 20px; margin-bottom: 18px">
      <h2 id="health-title">データと要約の状態</h2>
      <div class="health-grid" id="health-status" role="status"></div>
      <p class="notice" id="repair-status">自動修復は承認済みの保存データだけを使い、翻訳は1回4件まで進めます。未照合の保存訳は原文抜粋と区別し、起動要求だけで修復完了とは扱いません。</p>
      <p class="section-note">取得・AI要約・公式資料の確認は別の処理です。古い状態を「確認済み」に置き換えず、原文と照合してから表示します。</p>
    </section>
    <section class="metrics" aria-label="公開スナップショットの集計">
      <article class="metric"><div class="metric-label">公開中の更新</div><div class="metric-value" id="metric-total">0</div></article>
      <article class="metric metric-alert"><div class="metric-label">重要な変更</div><div class="metric-value" id="metric-major">0</div></article>
      <article class="metric"><div class="metric-label">今後30日以内の対応期限</div><div class="metric-value" id="metric-due">0</div></article>
      <article class="metric"><div class="metric-label">直近7日間の更新</div><div class="metric-value" id="metric-updated">0</div></article>
    </section>

    <details class="panel compact-disclosure">
      <summary id="services-title">サービス別の更新件数</summary>
      <p class="section-note">件数は重複するため、合計は公開中の更新件数と一致しない場合があります。</p>
      <div class="services" id="services"></div>
    </details>

    <details class="panel compact-disclosure">
      <summary id="document-status-title">公式資料の自動調査・状態の説明</summary>
        <p id="document-coverage" role="status"></p>
        <p>新しい通知も自動で検索・本文確認します。資料未確認は「資料が存在しない」という意味ではありません。未確認は3日後、取得失敗は次回の補完で再試行します。</p>
    </details>
    <section class="filter-panel" aria-labelledby="filter-title">
      <div class="filter-panel-head">
        <div>
          <div class="eyebrow">表示条件</div>
          <h2 id="filter-title">注目するサービスで絞り込む</h2>
          <p>Microsoft Graph Message Center の公開済み <code>services</code> 値に基づきます。複数のサービスに該当する更新は、選択したサービスのいずれかに一致すれば表示します。</p>
        </div>
        <button class="clear-filters" id="clear-filters" type="button">条件をすべてクリア</button>
      </div>
      <fieldset class="service-filter-set" aria-describedby="service-filter-help">
        <legend>サービスを選択（複数選択可）</legend>
        <div class="service-filter-options" id="service-filters"></div>
      </fieldset>
      <p class="filter-help" id="service-filter-help">サービスを選択しない場合は、すべての公開済み更新を表示します。</p>
      <div class="toolbar">
        <input class="search" id="search" type="search" placeholder="タイトル、MC ID、日本語訳、公式資料を検索" aria-label="タイトル、MC ID、日本語訳、公式資料を検索">
        <div class="filters" aria-label="更新の表示条件">
          <button class="filter active" data-filter="all" type="button" aria-pressed="true">すべて</button>
          <button class="filter" data-filter="major" type="button" aria-pressed="false">重要な変更</button>
          <button class="filter" data-filter="due" type="button" aria-pressed="false">対応期限が記載</button>
          <button class="filter" data-filter="soon" type="button" aria-pressed="false">今後30日以内</button>
          <button class="filter" data-filter="overdue" type="button" aria-pressed="false">期限経過</button>
          <button class="filter" data-filter="high" type="button" aria-pressed="false">高重要度</button>
        </div>
        <div class="advanced-filters">
          <label>関連資料の状態<select id="document-filter" class="search">
            <option value="all">すべての調査状態</option><option value="verified">関連資料あり</option>
            <option value="no_verified_document">調査済み・対応資料未確認</option>
            <option value="fetch_failed">取得失敗・自動再試行</option><option value="not_researched">自動調査待ち</option>
          </select></label>
          <label>通知更新日（JST）・開始<input class="search" id="date-from" type="date"></label>
          <label>通知更新日（JST）・終了<input class="search" id="date-to" type="date"></label>
          <label>並び順<select class="search" id="sort-order">
            <option value="updated">通知更新日が新しい順</option>
            <option value="deadline">対応期限・優先度順</option>
            <option value="start">通知開始日が新しい順</option>
          </select></label>
          <button class="clear-filters" id="copy-view" type="button">現在の条件のリンクをコピー</button>
        </div>
        <p id="filter-error" class="notice" role="alert" hidden></p>
        <p id="share-status" class="share-status" role="status" aria-live="polite"></p>
      </div>
    </section>

    <section class="priority-section" aria-labelledby="priority-title">
      <div class="priority-head">
        <div>
          <div class="eyebrow">まず確認する更新</div>
          <h2 id="priority-title">確認の優先度</h2>
          <p class="priority-note">今後30日以内の期限と重要な変更を優先します。期限経過は対応完了を意味しません。原文の記載に基づく整理で、AIによるリスク判定ではありません。</p>
        </div>
        <div class="section-note" id="priority-scope"></div>
      </div>
      <div class="priority-list" id="priorities"></div>
    </section>

    <details class="insights compact-disclosure" id="weekly-summary" aria-label="週次要約">
      <summary>週次AI要約・利用部門との確認ポイント</summary>
      <p class="section-note">公開スナップショット全体が対象で、現在の絞り込みには連動しません。</p>
      <div id="insight-content"></div>
    </details>
    <section aria-labelledby="messages-title">
      <div class="section-head"><div><div class="eyebrow">Message Center 更新一覧</div><h2 id="messages-title">すべての公開済み更新</h2></div><div class="section-note" id="result-count" role="status" aria-live="polite" aria-atomic="true"></div></div>
            <div class="export-actions" role="group" aria-label="表示中の更新を書き出す">
              <span class="section-note" id="export-scope" role="status"></span>
        <button type="button" data-select-all>表示中をすべて対象にする</button>
                <button type="button" data-select-none>表示中をすべて除外</button>
        <button type="button" data-export="json">JSON（想定問答付き）</button>
              <button type="button" data-export="csv">CSV</button>
              <button type="button" data-export="notes">スライドノート用 想定問答（Markdown）</button>
            </div>      <div class="message-list" id="messages"></div>
    </section>

    <footer>
      <p>このラボでは、Message Center の本文と name/value 形式の詳細を公開しています。credential-like 値は出力前に redaction されます。正式な判断は Microsoft 365 管理センターで確認してください。</p>
      <p><a class="repo-link" href="https://github.com/aktsmm/m365-message-center-dashboard">GitHub: aktsmm/m365-message-center-dashboard</a> · <a class="repo-link" href="about/">更新のしくみ</a></p>
    </footer>
  </main>

  <script>
    __VIEW_HELPERS__
    const DATA = __DATA__;
    const INSIGHTS = __INSIGHTS__;
    const RELATED_DOCUMENTS = __DOCUMENTS__;
    const CONTENT_STATE = __CONTENT_STATE__;
    const MESSAGE_UPDATES = new Map((INSIGHTS?.messageUpdates || []).map(update => [update.id, update]));
    const MESSAGE_TRANSLATIONS = new Map((INSIGHTS?.messageTranslations || []).map(translation => [translation.id, translation]));
    const SERVICE_FOCUSES = [
      { slug: "identity", service: "Microsoft Entra", label: "Microsoft Entra（ID・アクセス）" },
      { slug: "copilot", service: "Microsoft 365 Copilot Chat", label: "Microsoft 365 Copilot Chat" },
      { slug: "m365", service: "Microsoft 365 suite", label: "Microsoft 365 suite" }
    ];
    const FOCUS_BY_SERVICE = new Map(SERVICE_FOCUSES.map(focus => [focus.service, focus]));
    const FOCUS_ORDER = new Map(SERVICE_FOCUSES.map((focus, index) => [focus.slug, index]));
    const state = { ...DashboardView.readFilters(window.location.href), focuses: [] };
    const themeToggle = document.getElementById("theme-toggle");
    const urlTheme = new URLSearchParams(window.location.search).get("scoutTheme");
    const forcedTheme = ["light", "dark"].includes(urlTheme) ? urlTheme : null;
    function renderThemeToggle() {
      const theme = document.documentElement.getAttribute("data-theme") || "light";
      themeToggle.textContent = theme === "dark" ? "ライト表示" : "ダーク表示";
      themeToggle.setAttribute("aria-pressed", String(theme === "dark"));
      themeToggle.disabled = Boolean(forcedTheme);
      themeToggle.setAttribute(
        "aria-label",
        forcedTheme
          ? `表示テーマは URL の scoutTheme=${forcedTheme} で固定されています`
          : `現在は${theme === "dark" ? "ダーク" : "ライト"}表示です。${theme === "dark" ? "ライト" : "ダーク"}表示に切り替えます`
      );
    }
    renderThemeToggle();
    themeToggle.addEventListener("click", () => {
      if (forcedTheme) return;
      const nextTheme = document.documentElement.getAttribute("data-theme") === "dark" ? "light" : "dark";
      localStorage.setItem("scoutTheme", nextTheme);
      document.documentElement.setAttribute("data-theme", nextTheme);
      renderThemeToggle();
    });
    const fmt = value => value && Number.isFinite(Date.parse(value)) ? new Intl.DateTimeFormat("ja-JP", { year: "numeric", month: "short", day: "numeric", timeZone: "Asia/Tokyo" }).format(new Date(value)) : "—";
    const escapeHtml = value => String(value ?? "").replace(/[&<>"']/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);
    const messageServices = message => Array.isArray(message.services)
      ? message.services.filter(service => typeof service === "string" && service.trim())
      : [];
    const getMessageFocusSlugs = message => {
      const services = messageServices(message);
      const known = services
        .map(service => FOCUS_BY_SERVICE.get(service)?.slug)
        .filter(Boolean);
      const hasOther = !services.length || services.some(service => !FOCUS_BY_SERVICE.has(service));
      return hasOther ? [...new Set([...known, "other"])] : [...new Set(known)];
    };
    const getAvailableFocuses = () => {
      const counts = new Map();
      DATA.messages.forEach(message => getMessageFocusSlugs(message).forEach(slug => {
        counts.set(slug, (counts.get(slug) || 0) + 1);
      }));
      const known = SERVICE_FOCUSES.map(focus => ({ ...focus, count: counts.get(focus.slug) || 0 }));
      return counts.get("other")
        ? [...known, { slug: "other", label: "その他のサービス", count: counts.get("other") }]
        : known;
    };
    const AVAILABLE_FOCUSES = getAvailableFocuses();
    const FOCUS_BY_SLUG = new Map(AVAILABLE_FOCUSES.map(focus => [focus.slug, focus]));
    const normalizeFocuses = values => [...new Set(
      String(values || "")
        .split(",")
        .map(value => value.trim().toLowerCase())
        .filter(slug => FOCUS_BY_SLUG.has(slug))
    )].sort((left, right) => (FOCUS_ORDER.get(left) ?? SERVICE_FOCUSES.length) - (FOCUS_ORDER.get(right) ?? SERVICE_FOCUSES.length));
    const focusValuesFromUrl = () => new URL(window.location.href).searchParams.getAll("focus").join(",");
    const readFocusesFromUrl = () => normalizeFocuses(focusValuesFromUrl());
    function writeFocusesToUrl(mode) {
      const url = DashboardView.writeFilters(window.location.href, state);
      url.searchParams.delete("focus");
      if (state.focuses.length) url.searchParams.set("focus", state.focuses.join(","));
      history[mode](null, "", url);
    }
    function normalizeFocusUrlOnLoad() {
      const raw = focusValuesFromUrl();
      state.focuses = normalizeFocuses(raw);
      const canonical = state.focuses.join(",");
      if (raw !== canonical) writeFocusesToUrl("replaceState");
    }
    const messageDomId = message => `message-${String(message.id ?? "").replace(/[^A-Za-z0-9_-]/g, character => `-${character.codePointAt(0).toString(16)}-`)}`;
    function displayMessageTitle(message) {
      const update = MESSAGE_UPDATES.get(String(message.id).toUpperCase());
      const japaneseTitle = update?.japaneseTitle || message.japaneseTitle;
      const generic = !japaneseTitle || /の(?:情報提供|変更予定|問題の予防または修正)に関するお知らせ/.test(japaneseTitle);
      return generic ? message.title : japaneseTitle;
    }
    const hasActiveConditions = () => state.focuses.length || state.filter !== "all" || state.query || state.documentStatus !== "all" || state.from || state.to;
    const filterLabel = () => ({
      major: "重要な変更",
      due: "対応期限が記載",
      high: "高重要度",
      soon: "今後30日以内の対応期限",
      overdue: "期限経過（対応状況は未確認）"
    })[state.filter];
    const describeConditions = () => {
      const conditions = [];
      if (state.focuses.length) conditions.push(state.focuses.map(slug => FOCUS_BY_SLUG.get(slug).label).join("、"));
      if (state.filter !== "all") conditions.push(filterLabel());
      if (state.query) conditions.push(`検索「${state.query}」`);
      if (state.documentStatus !== "all") conditions.push(document.getElementById("document-filter").selectedOptions[0].text);
      if (state.from || state.to) conditions.push(`通知更新日 ${state.from || "指定なし"} ～ ${state.to || "指定なし"} (JST)`);
      return conditions.length ? conditions.join("、") : "すべての公開済み更新";
    };
    const safeOfficialUrl = value => {
      try {
        const url = new URL(value);
        return url.protocol === "https:" && !url.username && !url.password && !url.port
          && ["admin.microsoft.com", "m365.cloud.microsoft", "learn.microsoft.com"].includes(url.hostname)
          ? url.href
          : null;
      } catch {
        return null;
      }
    };

    function originalMessageUrl(message) {
      const id = String(message.id);
      if (!/^MC\d+$/.test(id)) return null;
      const update = MESSAGE_UPDATES.get(id.toUpperCase());
      const candidates = [update?.messageUrl, ...(Array.isArray(message.details) ? message.details.map(detail => detail.value) : [])];
      for (const candidate of candidates) {
        const safe = safeOfficialUrl(candidate);
        if (!safe) continue;
        const url = new URL(safe);
        if (["admin.microsoft.com", "m365.cloud.microsoft"].includes(url.hostname)
          && /message.?center/i.test(safe) && safe.split(/[/?#:&=]/).includes(id)) return safe;
      }
      return `https://admin.microsoft.com/AdminPortal/home#/MessageCenter/:/messages/${encodeURIComponent(id)}`;
    }
    function messageLinks(message) {
      const original = originalMessageUrl(message);
      const entry = RELATED_DOCUMENTS[message.id];
      const status = {
        not_researched: "未調査（自動調査待ち）",
        no_verified_document: "対応する公式資料を確認できていません",
        fetch_failed: "公式資料の取得に失敗しました"
      };
      const documents = (entry?.documents || []).slice(0, 3);
      return `<div class="message-links">
        ${original ? `<a class="message-link original-link" href="${escapeHtml(original)}" target="_blank" rel="noopener noreferrer">メッセージ原文 ↗</a>` : ""}
        <a class="message-link detail-link" href="#${escapeHtml(messageDomId(message))}" data-open-detail="${escapeHtml(message.id)}">サイト内詳細</a>
      </div>
      <div class="related-documents"><strong>関連ドキュメント</strong>
        ${documents.length ? `<ul>${documents.map(document =>
          `<li><a class="document-link" href="${escapeHtml(document.url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(document.title)}</a> <span class="section-note">(${document.locale === "ja-jp" ? "日本語" : "英語"})</span></li>`).join("")}</ul>` : ""}
        ${entry?.status !== "verified" ? `<p class="section-note">${escapeHtml(status[entry?.status] || status.not_researched)}</p>` : ""}
        ${entry?.checkedAt ? `<small class="section-note">確認 ${fmt(entry.checkedAt)}</small>` : ""}
        ${entry?.nextAttemptAt ? `<small class="section-note"> · 次回確認予定 ${fmt(entry.nextAttemptAt)}</small>` : ""}
      </div>`;
    }
    function headlineInfo(message) {
      const translation = MESSAGE_TRANSLATIONS.get(String(message.id).toUpperCase());
      const status = CONTENT_STATE.messages[message.id]?.translation || "missing";
      const title = String(translation?.japaneseTitle || "").trim();
      const text = title || (translation ? DashboardView.headline(translation.japaneseDetailedSummary) : "");
      return { text, status, fromTitle: Boolean(title) };
    }
    function headlineHtml(message) {
      const { text, status, fromTitle } = headlineInfo(message);
      if (fromTitle) return "";
      if (!text) return `<p class="ja-lead pending">日本語タイトルは生成待ちです。</p>`;
      return `<p class="ja-lead" lang="ja">${escapeHtml(text)}${status === "current" ? "" : ` <span class="chip" title="保存済みの日本語要約の冒頭です。現在の原文版との照合は未完了です。">保存版・原文未照合</span>`}</p>`;
    }
    // A real Japanese title is the heading; the English original becomes a quiet subtitle.
    function cardHeading(message) {
      const { text, fromTitle } = headlineInfo(message);
      if (fromTitle) {
        return `<h3 lang="ja">${titleLink(message, text)}</h3><div class="message-original" lang="en">原題: ${escapeHtml(message.title)}</div>`;
      }
      const shown = displayMessageTitle(message);
      return `<h3>${titleLink(message)}</h3>${shown !== message.title ? `<div class="message-original">原題: ${escapeHtml(message.title)}</div>` : ""}${headlineHtml(message)}`;
    }
    const excludedIds = new Set();
    function updateExportScope(visible) {
      const chosen = visible.filter(message => !excludedIds.has(message.id)).length;
      document.getElementById("export-scope").textContent = chosen === visible.length
        ? `書き出し対象: 表示中の ${visible.length} 件すべて（不要なカードのチェックを外せます）`
        : `書き出し対象: ${chosen} 件（表示中 ${visible.length} 件から ${visible.length - chosen} 件を除外）`;
    }
    function exportRecords() {
      const visible = DashboardView.sortMessages(DATA.messages.filter(matches), state.sort);
      return visible.filter(message => !excludedIds.has(message.id)).map(message => {
        const { text, status } = headlineInfo(message);
        const entry = RELATED_DOCUMENTS[message.id];
        return DashboardView.exportRecord(message, { headline: text, translationStatus: status,
          originalUrl: originalMessageUrl(message), documentStatus: entry?.status || "not_researched",
          documents: (entry?.documents || []).slice(0, 3) });
      });
    }
    function downloadText(name, text, type) {
      const url = URL.createObjectURL(new Blob([text], { type }));
      const link = document.createElement("a");
      link.href = url;
      link.download = name;
      document.body.appendChild(link);
      link.click();
      link.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    }
    function titleLink(message, override) {
      const url = originalMessageUrl(message);
      const title = escapeHtml(override || displayMessageTitle(message));
      return url ? `<a class="title-link" href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer">${title}</a>` : title;
    }
    function deadlineChip(message) {
      if (!message.actionRequiredByDateTime) return "";
      const bucket = DashboardView.deadlineBucket(message);
      const label = bucket === "overdue" ? "期限経過・対応状況未確認" : bucket === "soon" ? "今後30日以内の期限" : "対応期限が記載";
      return `<span class="chip due">${label}: ${fmt(message.actionRequiredByDateTime)}</span>`;
    }
    function translationLabel(message) {
      const labels = { current: "日本語要約・原文照合済み", unverified: "保存済み日本語訳・原文版未照合",
        stale: "原文更新・日本語訳の再生成待ち", missing: "日本語訳の生成待ち" };
      const status = CONTENT_STATE.messages[message.id]?.translation || "missing";
      return `<span class="chip" title="日本語訳は原文の内容ハッシュで版を照合します。未照合・変更後は自動再生成の対象です。">${labels[status]}</span>`;
    }

    document.getElementById("generated").textContent = `更新 ${fmt(DATA.meta.generatedAt)}`;
    document.getElementById("source-status").textContent =
      DATA.meta.source === "fixture" ? "合成プレビュー データ" : "Microsoft Graph の公開スナップショット";
    document.getElementById("context-generated").textContent = fmt(DATA.meta.generatedAt);
    document.getElementById("context-total").textContent = `${DATA.summary.total} 件`;
    const documentCounts = DATA.messages.reduce((counts, message) => {
      const status = RELATED_DOCUMENTS[message.id]?.status || "not_researched";
      counts[status] = (counts[status] || 0) + 1;
      return counts;
    }, {});
    document.getElementById("document-coverage").textContent =
      `現在の ${DATA.messages.length} 件: 関連資料あり ${documentCounts.verified || 0} 件、対応資料未確認 ${documentCounts.no_verified_document || 0} 件、取得失敗 ${documentCounts.fetch_failed || 0} 件、自動調査待ち ${documentCounts.not_researched || 0} 件。`;
    document.getElementById("context-source").textContent =
      DATA.meta.source === "fixture" ? "合成プレビュー" : "Microsoft Graph";
    document.getElementById("metric-total").textContent = DATA.summary.total;
    document.getElementById("metric-major").textContent = DATA.summary.majorChanges;
    document.getElementById("metric-due").textContent = DATA.messages.filter(message => DashboardView.deadlineBucket(message) === "soon").length;
    document.getElementById("metric-updated").textContent = DATA.messages.filter(message => {
      const updated = Date.parse(message.lastModifiedDateTime);
      return updated <= Date.now() && updated >= Date.now() - 7 * DashboardView.DAY;
    }).length;
    document.getElementById("hero-stats").innerHTML = [
      ["公開中", document.getElementById("metric-total").textContent, "件"],
      ["重要な変更", document.getElementById("metric-major").textContent, "件"],
      ["30日以内の期限", document.getElementById("metric-due").textContent, "件"],
      ["直近7日の更新", document.getElementById("metric-updated").textContent, "件"]
    ].map(([label, value, unit]) => `<span>${label}<strong>${escapeHtml(value)}<small> ${unit}</small></strong></span>`).join("");
    const translationCounts = Object.values(CONTENT_STATE.messages).reduce((counts, entry) => {
      counts[entry.translation] = (counts[entry.translation] || 0) + 1;
      return counts;
    }, {});
    const sourceFreshness = DashboardView.freshness(DATA.meta.generatedAt);
    document.getElementById("health-status").innerHTML = [
      `取得: ${fmt(DATA.meta.generatedAt)} · ${sourceFreshness === "current" ? "保存済みスナップショット" : sourceFreshness === "stale" ? "5日以上経過・更新状況の確認が必要" : "更新時刻を確認できません"}`,
      `週次AI要約: ${{ current: "原文版・参照IDの照合済み", unverified: "保存版・原文版未照合", stale: "原文更新後の再生成待ち", invalid: "参照整合性の検証待ち", missing: "生成待ち" }[CONTENT_STATE.summary.status]}`,
      `日本語要約: 原文照合済み ${translationCounts.current || 0} 件、未照合・再生成待ち ${DATA.messages.length - (translationCounts.current || 0)} 件`,
      `公式資料: 確認済み ${documentCounts.verified || 0} 件、未確認・処理待ち ${DATA.messages.length - (documentCounts.verified || 0)} 件`
    ].map(text => `<p>${escapeHtml(text)}</p>`).join("");

    const listItems = value => DashboardView.normalizeText(value)
      .split(/\r?\n/)
      .map(line => line.replace(/^\s*[-*・]\s*/, "").trim())
      .filter(Boolean)
      .map(line => `<li>${escapeHtml(line).replace(/\bMC\d+\b/g, id => DATA.messages.some(message => message.id === id)
        ? `<a href="#message-${id}" data-open-detail="${id}">${id}</a>` : id)}</li>`)
      .join("");
    const usableInsights = INSIGHTS && ["current", "unverified"].includes(CONTENT_STATE.summary.status);
    document.getElementById("insight-content").innerHTML = usableInsights
      ? `${CONTENT_STATE.summary.status === "unverified" ? `<p class="notice">保存済みの週次要約です。原文の版は未照合のため、自動再生成の対象です。</p>` : ""}
         <h2 class="insight-headline">${escapeHtml(INSIGHTS.headline)}</h2>
         <p class="insight-summary">${escapeHtml(INSIGHTS.executiveSummary)}</p>
         <div class="insight-grid">
           <article class="insight-column"><h3>今週確認</h3><ul>${listItems(INSIGHTS.thisWeek)}</ul></article>
           <article class="insight-column"><h3>今月準備</h3><ul>${listItems(INSIGHTS.thisMonth)}</ul></article>
           <article class="insight-column"><h3>継続監視</h3><ul>${listItems(INSIGHTS.watch)}</ul></article>
         </div>
         <details class="message-content"><summary>利用部門と確認したいこと</summary><ul>${listItems(INSIGHTS.customerQuestions)}</ul></details>
         <p class="section-note">週次要約の生成 ${fmt(INSIGHTS.summaryGeneratedAt || INSIGHTS.generatedAt)} · 原文を最終確認してください。</p>`
      : `<h2 class="insight-headline">原文に基づく確認候補</h2>
         <p class="notice">週次AI要約は、参照IDまたは原文の版の検証待ちです。未検証の内容は表示せず、自動修復の対象にしています。</p>
         <ul>${DashboardView.sortMessages(DATA.messages.filter(message => message.isMajorChange || message.actionRequiredByDateTime), "deadline").slice(0, 4).map(message =>
           `<li><a href="#${escapeHtml(messageDomId(message))}" data-open-detail="${escapeHtml(message.id)}">${escapeHtml(message.id)}</a>: ${escapeHtml(displayMessageTitle(message))} ${message.actionRequiredByDateTime ? `（期限 ${fmt(message.actionRequiredByDateTime)}）` : ""}</li>`).join("")}</ul>`;

    function matches(message) {
      if (state.documentStatus !== "all" && (RELATED_DOCUMENTS[message.id]?.status || "not_researched") !== state.documentStatus) return false;
      const details = Array.isArray(message.details) ? message.details : [];
      const haystack = [
        message.id,
        message.title,
        message.category,
        message.severity,
        message.japaneseSummary,
        message.bodyText,
        MESSAGE_TRANSLATIONS.get(message.id)?.japaneseTitle,
        MESSAGE_TRANSLATIONS.get(message.id)?.japaneseDetailedSummary,
        MESSAGE_TRANSLATIONS.get(message.id)?.japaneseBodyTranslation,
        ...(RELATED_DOCUMENTS[message.id]?.documents || []).map(document => document.title),
        ...(message.services || []),
        ...details.flatMap(detail => [detail.name, detail.value])
      ].join(" ").toLowerCase();
      if (state.query && !state.query.toLowerCase().split(/\s+/).every(term => haystack.includes(term))) return false;
      if (!DashboardView.inDateRange(message, state.from, state.to)) return false;
      if (state.focuses.length && !getMessageFocusSlugs(message).some(slug => state.focuses.includes(slug))) return false;
      if (state.filter === "major" && !message.isMajorChange) return false;
      if (state.filter === "due" && !message.actionRequiredByDateTime) return false;
      if (state.filter === "high" && !["high", "critical"].includes(String(message.severity).toLowerCase())) return false;
      if (state.filter === "soon" && DashboardView.deadlineBucket(message) !== "soon") return false;
      if (state.filter === "overdue" && DashboardView.deadlineBucket(message) !== "overdue") return false;
      return true;
    }

    function renderFocusControls() {
      document.getElementById("service-filters").innerHTML = AVAILABLE_FOCUSES.map(focus => `
        <label class="service-filter${state.focuses.includes(focus.slug) ? " active" : ""}">
          <input type="checkbox" data-focus="${escapeHtml(focus.slug)}" ${state.focuses.includes(focus.slug) ? "checked" : ""}>
          <span>${escapeHtml(focus.label)} <span class="service-filter-count">${focus.count} 件</span></span>
        </label>
      `).join("");
      document.getElementById("services").innerHTML = AVAILABLE_FOCUSES.length
        ? AVAILABLE_FOCUSES.map(focus => `<button class="service" type="button" data-focus-toggle="${escapeHtml(focus.slug)}" aria-pressed="${state.focuses.includes(focus.slug)}"><strong>${focus.count}</strong><span>${escapeHtml(focus.label)}</span></button>`).join("")
        : `<div class="empty">サービス情報はありません。</div>`;
      const otherFocus = FOCUS_BY_SLUG.get("other");
      document.getElementById("service-filter-help").textContent = otherFocus
        ? `サービスを選択しない場合は、すべての公開済み更新を表示します。${otherFocus.count} 件は「その他のサービス」として確認できます。`
        : "サービスを選択しない場合は、すべての公開済み更新を表示します。";
      document.querySelectorAll(".filter").forEach(button => {
        const active = button.dataset.filter === state.filter;
        button.classList.toggle("active", active);
        button.setAttribute("aria-pressed", String(active));
      });
    }

    function priorityComparison(left, right) {
      return DashboardView.priorityCompare(left, right);
    }

    function renderPriorities(visible) {
      const priorities = visible
        .filter(message => message.actionRequiredByDateTime || message.isMajorChange)
        .sort(priorityComparison)
        .slice(0, 4);
      document.getElementById("priority-scope").textContent = hasActiveConditions()
        ? "現在の絞り込み結果から表示"
        : "公開スナップショット全体から表示";
      document.getElementById("priorities").innerHTML = priorities.length ? priorities.map(message => {
        const update = MESSAGE_UPDATES.get(String(message.id).toUpperCase());
        const reasons = [
          deadlineChip(message),
          message.isMajorChange ? `<span class="chip major">重要な変更</span>` : ""
        ].filter(Boolean).join("");
        return `<article class="priority-card">
          <div class="message-id">${escapeHtml(message.id)}</div>
          ${cardHeading(message)}
          <div class="priority-reasons">${reasons}</div>
          <a href="#${escapeHtml(messageDomId(message))}">一覧の Message Center 更新を確認</a>
          ${messageLinks(message)}
        </article>`;
      }).join("") : `<div class="empty"><p>現在の表示条件では、「対応期限が記載」または「重要な変更」に該当する更新はありません。</p>${hasActiveConditions() ? `<button class="clear-filters" type="button" data-clear-filters>条件をすべてクリア</button>` : ""}</div>`;
    }

    function captureServiceControlFocus() {
      const active = document.activeElement;
      if (active?.matches("#service-filters input[data-focus]")) {
        return `#service-filters input[data-focus="${active.dataset.focus}"]`;
      }
      if (active?.matches("#services button[data-focus-toggle]")) {
        return `#services button[data-focus-toggle="${active.dataset.focusToggle}"]`;
      }
      return null;
    }

    function restoreServiceControlFocus(selector) {
      const control = selector && document.querySelector(selector);
      control?.focus({ preventScroll: true });
    }

    function render({ restoreServiceFocus = false } = {}) {
      const serviceFocusSelector = restoreServiceFocus ? captureServiceControlFocus() : null;
      syncViewControls();
      const error = state.from && state.to && state.from > state.to ? "通知更新日の開始日は、終了日以前を指定してください。" : state.warning;
      document.getElementById("filter-error").hidden = !error;
      document.getElementById("filter-error").textContent = error || "";
      const visible = DashboardView.sortMessages(DATA.messages.filter(matches), state.sort);
      const conditionText = describeConditions();
      document.getElementById("result-count").textContent = `${conditionText}。${visible.length === DATA.messages.length ? `${visible.length} 件` : `${visible.length} / ${DATA.messages.length} 件`}を表示しています。`;
      renderFocusControls();
      renderPriorities(visible);
      document.getElementById("messages").innerHTML = visible.length ? visible.map(message => {
        const update = MESSAGE_UPDATES.get(String(message.id).toUpperCase());
        const translation = MESSAGE_TRANSLATIONS.get(String(message.id).toUpperCase());
        const translationStatus = CONTENT_STATE.messages[message.id]?.translation || "missing";
        const high = ["high", "critical"].includes(String(message.severity).toLowerCase());
        const chips = [
          message.isMajorChange ? `<span class="chip major">重要な変更</span>` : "",
          high ? `<span class="chip high">${escapeHtml(message.severity)}</span>` : "",
          deadlineChip(message),
          translationLabel(message),
          `<span class="chip" title="関連資料の調査状態です。資料未確認は不存在を意味しません。">${RELATED_DOCUMENTS[message.id]?.documents?.length ? "公式資料あり" : "公式資料の確認待ち"}</span>`,
          `<span class="chip">${escapeHtml(message.category || "未分類")}</span>`,
          ...(message.services || []).map(service => `<span class="chip">${escapeHtml(service)}</span>`)
        ].filter(Boolean).join("");
        const body = message.bodyText
          ? `<p class="message-body">${escapeHtml(message.bodyText).replace(/\r?\n/g, "<br>")}</p>`
          : `<p class="message-body">本文はありません。</p>`;
        const detailRows = Array.isArray(message.details) ? message.details : [];
        const details = detailRows.length
          ? `<table class="message-details"><tbody>${detailRows.map(detail =>
              `<tr><th>${escapeHtml(detail.name)}</th><td>${escapeHtml(detail.value)}</td></tr>`
            ).join("")}</tbody></table>`
          : "";
        const fullContent = Object.prototype.hasOwnProperty.call(message, "bodyText")
          ? `<details class="message-content"><summary>Message Center の全文と詳細</summary>${body}${details}</details>`
          : "";
        const translationContent = translation
          ? `<details class="message-content message-translation"><summary>日本語訳と詳細要約${translationStatus !== "current" ? "（保存版・原文照合待ち）" : ""}</summary>
              ${translationStatus !== "current" ? `<p class="notice">この訳文は現在の原文との版照合が完了していません。古い時期・対応が残る可能性があるため、下の原文抜粋と管理センターで確認してください。自動再生成の対象です。</p>` : ""}
              <h4>詳細要約</h4><p class="message-body">${escapeHtml(translation.japaneseDetailedSummary).replace(/\r?\n/g, "<br>")}</p>
              <h4>${translation.sourceTruncated ? "本文の日本語訳（抜粋）" : "本文の日本語訳"}</h4>
              ${translation.sourceTruncated ? `<p class="insight-pending">原文の先頭 ${escapeHtml(translation.sourceCharacterCount)} 文字を翻訳しています。全文は「Message Center の全文と詳細」で確認してください。</p>` : ""}
              <p class="message-body">${escapeHtml(translation.japaneseBodyTranslation).replace(/\r?\n/g, "<br>")}</p>
            </details>`
          : `<details class="message-content message-translation"><summary>日本語訳と詳細要約</summary>
              <p class="insight-pending">この更新の AI 翻訳は、週次の限定バッチで生成予定です。未検証の訳文は表示しません。</p>
            </details>`;
        return `<article class="message" id="${escapeHtml(messageDomId(message))}">
          <div class="message-top">
            <div><div class="message-id">${escapeHtml(message.id)}</div>${cardHeading(message)}<div class="chips">${chips}</div></div>
            <div class="message-date"><label class="select-card"><input type="checkbox" data-select="${escapeHtml(message.id)}"${excludedIds.has(message.id) ? "" : " checked"}> 出力に含める</label><div>更新 ${fmt(message.lastModifiedDateTime)}</div><div>開始 ${fmt(message.startDateTime)}</div></div>
          </div>
          ${translationStatus === "current" ? `<p class="message-summary">${escapeHtml(translation.japaneseDetailedSummary)}</p>` : ""}
          ${(() => {
            const rows = DashboardView.facts(message).map(fact =>
              `<div><dt>${fact.label} <small class="section-note">原文抜粋（英語）</small></dt><dd>${escapeHtml(fact.text)}</dd></div>`).join("");
            if (!rows) return "";
            return translationStatus === "current"
              ? `<details class="message-content"><summary>原文抜粋（英語）: 変更・影響・時期・対応</summary><dl class="message-facts">${rows}</dl></details>`
              : `<dl class="message-facts">${rows}</dl>`;
          })()}
          ${messageLinks(message)}
          ${fullContent}
          ${translationContent}
        </article>`;
      }).join("") : `<div class="panel empty"><p>${escapeHtml(conditionText)}に一致するメッセージはありません。</p><button class="clear-filters" type="button" data-clear-filters>条件をすべてクリア</button></div>`;
      restoreServiceControlFocus(serviceFocusSelector);
      updateExportScope(visible);
    }
    function syncViewControls() {
      document.getElementById("search").value = state.query;
      document.getElementById("document-filter").value = state.documentStatus;
      document.getElementById("date-from").value = state.from;
      document.getElementById("date-to").value = state.to;
      document.getElementById("sort-order").value = state.sort;
    }

    function toggleFocus(slug) {
      state.focuses = state.focuses.includes(slug)
        ? state.focuses.filter(value => value !== slug)
        : normalizeFocuses([...state.focuses, slug].join(","));
      writeFocusesToUrl("pushState");
      render({ restoreServiceFocus: true });
    }

    function clearFilters({ restorePersistentFocus = false } = {}) {
      state.focuses = [];
      state.filter = "all";
      state.query = "";
      state.documentStatus = "all";
      state.from = "";
      state.to = "";
      state.sort = "updated";
      state.warning = "";
      document.getElementById("document-filter").value = "all";
      document.getElementById("search").value = "";
      writeFocusesToUrl("pushState");
      render();
      if (restorePersistentFocus) document.getElementById("clear-filters").focus({ preventScroll: true });
    }

    document.getElementById("search").addEventListener("input", event => {
      state.query = event.target.value;
      writeFocusesToUrl("replaceState");
      render();
    });
    document.getElementById("document-filter").addEventListener("change", event => {
      state.documentStatus = event.target.value;
      writeFocusesToUrl("pushState");
      render();
    });
    document.querySelectorAll(".filter").forEach(button => button.addEventListener("click", () => {
      state.filter = button.dataset.filter;
      writeFocusesToUrl("pushState");
      render();
    }));
    for (const [id, field] of [["date-from", "from"], ["date-to", "to"], ["sort-order", "sort"]]) {
      document.getElementById(id).addEventListener("change", event => {
        state[field] = event.target.value;
        state.warning = "";
        writeFocusesToUrl("pushState");
        render();
      });
    }
    document.getElementById("copy-view").addEventListener("click", async () => {
      writeFocusesToUrl("replaceState");
      try {
        await Promise.race([
          navigator.clipboard.writeText(window.location.href),
          new Promise((_, reject) => setTimeout(() => reject(new Error("clipboard-timeout")), 3000))
        ]);
        document.getElementById("share-status").textContent = "現在の検索・日付・サービス・資料条件のリンクをコピーしました。";
      } catch {
        document.getElementById("share-status").textContent = `コピー結果を確認できません。必要ならアドレス欄からこのURLをコピーしてください: ${window.location.href}`;
      }
    });
    document.getElementById("service-filters").addEventListener("change", event => {
      const checkbox = event.target.closest("input[data-focus]");
      if (checkbox) toggleFocus(checkbox.dataset.focus);
    });
    document.getElementById("services").addEventListener("click", event => {
      const button = event.target.closest("button[data-focus-toggle]");
      if (button) toggleFocus(button.dataset.focusToggle);
    });
    document.addEventListener("change", event => {
      const box = event.target.closest("input[data-select]");
      if (!box) return;
      if (box.checked) excludedIds.delete(box.dataset.select); else excludedIds.add(box.dataset.select);
      updateExportScope(DATA.messages.filter(matches));
    });
    document.addEventListener("click", event => {
      const selectAll = event.target.closest("[data-select-all]");
      const selectNone = event.target.closest("[data-select-none]");
      if (selectAll || selectNone) {
        DATA.messages.filter(matches).forEach(message => selectAll ? excludedIds.delete(message.id) : excludedIds.add(message.id));
        render();
        return;
      }
      const detailLink = event.target.closest("[data-open-detail]");
      if (detailLink) {
        const message = DATA.messages.find(item => item.id === detailLink.dataset.openDetail);
        if (message && !document.getElementById(messageDomId(message))) {
          clearFilters();
          document.getElementById("share-status").textContent = "参照された通知を開くため、表示条件をクリアしました。";
        }
        const article = message && document.getElementById(messageDomId(message));
        const detail = article?.querySelector(".message-content");
        if (detail) {
          event.preventDefault();
          detail.open = true;
          const url = new URL(window.location.href);
          url.hash = article.id;
          history.pushState(null, "", url);
          article.style.scrollMarginTop = `${document.querySelector(".nav").getBoundingClientRect().height + 24}px`;
          article.scrollIntoView({ block: "start" });
          detail.querySelector("summary")?.focus({ preventScroll: true });
        }
      }
      const exportButton = event.target.closest("[data-export]");
      if (exportButton) {
        const records = exportRecords();
        const stamp = new Date().toISOString().slice(0, 10);
        const kind = exportButton.dataset.export;
        if (kind === "json") downloadText(`m365-updates-${stamp}.json`, JSON.stringify({ generatedAt: DATA.meta.generatedAt, conditions: describeConditions(), items: records }, null, 2), "application/json");
        else if (kind === "csv") downloadText(`m365-updates-${stamp}.csv`, DashboardView.toCsv(records), "text/csv");
        else downloadText(`m365-qa-notes-${stamp}.md`, DashboardView.notesMarkdown(records, { generatedAt: DATA.meta.generatedAt, conditions: describeConditions() }), "text/markdown");
        return;
      }
      const clearButton = event.target.closest("[data-clear-filters], #clear-filters");
      if (clearButton) clearFilters({ restorePersistentFocus: clearButton.hasAttribute("data-clear-filters") });
    });
    window.addEventListener("popstate", () => {
      Object.assign(state, DashboardView.readFilters(window.location.href));
      state.focuses = readFocusesFromUrl();
      render();
    });
    normalizeFocusUrlOnLoad();
    render();
  </script>
</body>
</html>
'@

$html = $html.Replace('__DATA__', $safeJson)
$html = $html.Replace('__INSIGHTS__', $safeInsightsJson)
$html = $html.Replace('__DOCUMENTS__', $safeDocumentsJson)
$html = $html.Replace('__CONTENT_STATE__', $safeContentState)
$html = $html.Replace('__VIEW_HELPERS__', $viewHelpers)
$parent = Split-Path -Parent $OutputPath
if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
$html | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Host "Dashboard written to $OutputPath"
