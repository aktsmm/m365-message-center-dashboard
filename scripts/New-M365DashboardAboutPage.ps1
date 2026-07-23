<#
.SYNOPSIS
    Creates the static GitHub Pages explanation for the lab-public dashboard automation.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$html = @'
<!doctype html>
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>更新のしくみ | Microsoft 365 Change Radar</title>
  <style>
    :root { color-scheme: light; --cp-bg: #f7f4ef; --cp-surface: #fff; --cp-border: #dedede; --cp-text: #242424; --cp-muted: #5c5c5c; --cp-link: #0078d4; --cp-accent: #b11f4b; }
    @media (prefers-color-scheme: dark) { :root { color-scheme: dark; --cp-bg: #3d3b3a; --cp-surface: #292929; --cp-border: #474747; --cp-text: #dedede; --cp-muted: #b0b0b0; --cp-link: #4da6ff; --cp-accent: #fd8ea1; } }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--cp-bg); color: var(--cp-text); font-family: "Segoe UI", Aptos, Calibri, sans-serif; line-height: 1.6; }
    main { width: min(880px, calc(100% - 32px)); margin: 0 auto; padding: 56px 0 80px; }
    .eyebrow { color: var(--cp-muted); font-size: .82rem; font-weight: 800; letter-spacing: .12em; text-transform: uppercase; }
    h1 { margin: 12px 0 18px; font-size: clamp(2.5rem, 6vw, 4.5rem); line-height: 1; letter-spacing: -.06em; }
    h2 { margin-top: 40px; letter-spacing: -.03em; }
    p, li { color: var(--cp-muted); }
    .panel { margin-top: 24px; padding: 24px; background: var(--cp-surface); border: 1px solid var(--cp-border); border-radius: 16px; }
    .flow { padding-left: 24px; }
    a { color: var(--cp-link); font-weight: 700; }
    a:focus-visible { outline: 3px solid var(--cp-accent); outline-offset: 3px; }
  </style>
</head>
<body>
  <main>
    <div class="eyebrow">Lab-public automation</div>
    <h1>このダッシュボードの<br>更新のしくみ</h1>
    <p>これは明示的に承認されたテスト テナント専用の lab-public ダッシュボードです。Message Center の本文と selected details を公開しますが、credentials、tokens、credential-like values は公開前に除外または redaction されます。</p>
    <section class="panel">
      <h2>毎週の自動更新</h2>
      <ol class="flow">
        <li>GitHub Actions が Microsoft Graph の Message Center を取得します。</li>
        <li>公開用 snapshot を生成し、本文を安全なテキストとして、details を name/value として出力します。</li>
        <li>GitHub Agentic Workflow が同じ run の snapshot を検証し、MC ごとの日本語タイトル・100文字以内の要約・週次インサイトを作成します。本文翻訳は週次の限定バッチで生成し、未検証の訳文は表示しません。</li>
        <li>検証済みの snapshot、インサイト、公式リンクだけを GitHub Pages に公開します。</li>
      </ol>
    </section>
    <section class="panel">
      <h2>手動で更新するには</h2>
      <p>GitHub Actions の <strong>M365 Message Center Dashboard - Public Metadata</strong> を main ブランチで手動実行します。成功すると後続の Agentic Workflow が同一 snapshot を検証し、Pages を更新します。</p>
      <p>Agentic Workflow が provider HTTP 403 で失敗する場合は、組織の集中管理された Copilot billing/policy で <code>copilot-requests: write</code> を許可してください。設定前に再実行しても Agentic 出力は公開されません。</p>
    </section>
    <section class="panel">
      <h2>公開データとリンクの境界</h2>
      <p>MC カードの直接リンクは、その同じ MC の Graph details に存在する Message Center URL だけです。関連ドキュメントは、その MC の details に含まれる <code>learn.microsoft.com</code> URL だけを表示します。URL は生成・推測しません。</p>
    </section>
    <p><a href="../">ダッシュボードへ戻る</a> · <a href="https://github.com/aktsmm/m365-message-center-dashboard">GitHub リポジトリ</a></p>
  </main>
</body>
</html>
'@

$parent = Split-Path -Parent $OutputPath
if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
$html | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Host "About page written to $OutputPath"
