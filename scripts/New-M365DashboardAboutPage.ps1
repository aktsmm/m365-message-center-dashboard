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
  <script>
    (() => {
      const param = new URLSearchParams(window.location.search).get("scoutTheme");
      const forcedTheme = ["light", "dark"].includes(param) ? param : null;
      const storedTheme = localStorage.getItem("scoutTheme");
      const theme = forcedTheme || (["light", "dark"].includes(storedTheme) ? storedTheme : "light");
      document.documentElement.setAttribute("data-theme", theme);
    })();
  </script>
  <title>更新のしくみ | Microsoft 365 Change Radar</title>
  <style>
    :root { color-scheme: light; --cp-bg: #f8f4ed; --cp-bg-elevated: #fdfaf5; --cp-surface: #fff; --cp-surface-soft: #f4ede4; --cp-border: #e4d9cc; --cp-border-strong: #a28c77; --cp-text: #2d2822; --cp-text-muted: #665d54; --cp-link: #94412f; --cp-accent: #a33e2c; --cp-accent-fg: #fff; --cp-shadow: 0 18px 48px rgba(45, 40, 34, 0.12); }
    html[data-theme="dark"] { color-scheme: dark; --cp-bg: #292521; --cp-bg-elevated: #322d28; --cp-surface: #39332d; --cp-surface-soft: #433a32; --cp-border: #5d5044; --cp-border-strong: #86705c; --cp-text: #f4eae0; --cp-text-muted: #d2c1b2; --cp-link: #ffc0a8; --cp-accent: #ffb09c; --cp-accent-fg: #332018; --cp-shadow: 0 18px 48px rgba(0, 0, 0, 0.4); }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--cp-bg); color: var(--cp-text); font-family: "Segoe UI", Aptos, Calibri, sans-serif; line-height: 1.6; }
    main { width: min(880px, calc(100% - 32px)); margin: 0 auto; padding: 56px 0 80px; }
    .nav { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 12px 16px; background: var(--cp-surface); border: 1px solid var(--cp-border); border-radius: 16px; box-shadow: var(--cp-shadow); }
    .brand { font-weight: 800; letter-spacing: -.02em; }
    .theme-toggle { padding: 8px 12px; color: var(--cp-text); background: var(--cp-surface-soft); border: 1px solid var(--cp-border-strong); border-radius: 999px; cursor: pointer; font-weight: 700; }
    .theme-toggle:hover { color: var(--cp-accent); border-color: var(--cp-accent); }
    .theme-toggle:focus-visible, a:focus-visible { outline: 3px solid var(--cp-accent); outline-offset: 3px; }
    .theme-toggle:disabled { cursor: not-allowed; opacity: .72; }
    .eyebrow { color: var(--cp-text-muted); font-size: .82rem; font-weight: 800; letter-spacing: .12em; text-transform: uppercase; }
    h1 { margin: 12px 0 18px; font-size: clamp(2.5rem, 6vw, 4.5rem); line-height: 1; letter-spacing: -.06em; }
    h2 { margin-top: 40px; letter-spacing: -.03em; }
    p, li { color: var(--cp-text-muted); }
    .panel { margin-top: 24px; padding: 24px; background: var(--cp-surface); border: 1px solid var(--cp-border); border-radius: 16px; box-shadow: var(--cp-shadow); }
    .flow { padding-left: 24px; }
    a { color: var(--cp-link); font-weight: 700; }
  </style>
</head>
<body>
  <main>
    <nav class="nav" aria-label="Dashboard navigation">
      <div class="brand">Microsoft 365 Change Radar</div>
      <button class="theme-toggle" id="theme-toggle" type="button" aria-label="表示テーマをダークに切り替えます" aria-pressed="false"></button>
    </nav>
    <div class="eyebrow">Lab-public automation</div>
    <h1>このダッシュボードの<br>更新のしくみ</h1>
    <p>これは明示的に承認されたテスト テナント専用の lab-public ダッシュボードです。Message Center の本文と selected details を公開しますが、credentials、tokens、credential-like values は公開前に除外または redaction されます。</p>
    <section class="panel">
      <h2>週2回の自動更新（月曜日・木曜日 07:17 JST）</h2>
      <ol class="flow">
        <li>GitHub Actions が Microsoft Graph の Message Center を取得します。</li>
        <li>公開用 snapshot を生成し、本文を安全なテキストとして、details を name/value として出力します。</li>
        <li>core GitHub Agentic Workflow が同じ run の snapshot を検証し、週次インサイトを作成します。MC ごとの日本語タイトル・100文字以内の要約・公式リンクは、その snapshot から決定論的に生成します。</li>
        <li>core の成功後に translations GitHub Agentic Workflow が起動し、実行ごとに最大4件の詳細な日本語要約と本文訳を検証します。月曜日・木曜日の実行により、最大8カード/週が翻訳対象になります。未検証の訳文は表示しません。</li>
        <li>検証済みの snapshot、インサイト、公式リンク、翻訳だけを GitHub Pages に公開します。</li>
      </ol>
    </section>
    <section class="panel">
      <h2>手動で更新するには</h2>
      <p>GitHub Actions の <strong>M365 Message Center Dashboard - Public Metadata</strong> を main ブランチで手動実行します。月曜日・木曜日 07:17 JST の定期実行と同じく、成功後に core Agentic Workflow、さらに成功後の translations Workflow が順に Pages を更新します。</p>
      <p>Agentic Workflow は組織課金が有効な組み込み <code>GITHUB_TOKEN</code> と <code>copilot-requests: write</code> を使います。個人アクセストークンや <code>COPILOT_GITHUB_TOKEN</code> のリポジトリ secret は不要です。provider HTTP 403 で失敗する場合は、組織の Copilot policy で <strong>Allow use of Copilot CLI billed to the organization</strong> を有効にしてください。設定前に再実行しても Agentic 出力は公開されません。</p>
      <p>2026年7月23日時点の保存済み最新 snapshot では、現行 74 カードの 74/74 件に検証済みの詳細な日本語要約と本文訳があります。</p>
    </section>
    <section class="panel">
      <h2>公開データとリンクの境界</h2>
      <p>MC カードの直接リンクは、その同じ run の Graph snapshot にある同じ MC の HTTPS Message Center URL だけです。関連ドキュメントは、その MC の details に含まれる <code>learn.microsoft.com</code> URL だけを表示します。URL は生成・推測しません。</p>
      <p>safe output は unsafe markup、credential-like 値、snapshot にない MC ID、許可されていない URL、翻訳元メタデータの不一致を拒否します。検証できない場合は、以前に検証済みの翻訳だけを保持し、未処理カードにはデータ未準備を表示します。</p>
    </section>
    <section class="panel">
      <h2>表示テーマ</h2>
      <p>ダッシュボードとこのページはライトテーマを既定とし、OS の色設定には追従しません。切り替えたライトまたはダークテーマはこのブラウザーに保存されます。再現可能なリンクには <code>?scoutTheme=light</code> または <code>?scoutTheme=dark</code> を付けると、その表示に固定されます。</p>
    </section>
    <p><a href="../">ダッシュボードへ戻る</a> · <a href="https://github.com/aktsmm/m365-message-center-dashboard">GitHub リポジトリ</a></p>
  </main>
  <script>
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
  </script>
</body>
</html>
'@

$parent = Split-Path -Parent $OutputPath
if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
$html | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Host "About page written to $OutputPath"
