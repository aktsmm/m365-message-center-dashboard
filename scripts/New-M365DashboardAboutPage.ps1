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
    .nav { position: sticky; top: 12px; z-index: 10; display: flex; align-items: center; flex-wrap: wrap; gap: 12px 16px; padding: 12px 16px; background: var(--cp-surface); border: 1px solid var(--cp-border); border-radius: 16px; box-shadow: var(--cp-shadow); }
    .brand { font-weight: 800; letter-spacing: -.02em; }
    .demo-links { display: flex; flex: 1 1 100%; flex-wrap: wrap; align-items: center; gap: 6px; order: 3; }
    .demo-link { padding: 6px 9px; color: var(--cp-link); border: 1px solid transparent; border-radius: 999px; font-size: .78rem; font-weight: 700; text-decoration: none; }
    .demo-link:hover { color: var(--cp-accent); border-color: var(--cp-border-strong); background: var(--cp-surface-soft); }
    .demo-link[aria-current="page"] { color: var(--cp-accent-fg); background: linear-gradient(110deg, var(--cp-link), var(--cp-accent)); border-color: var(--cp-border-strong); }
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
    <nav class="nav" aria-label="Demo navigation">
      <div class="brand">Microsoft 365 Change Radar</div>
      <div class="demo-links">
        <a class="demo-link" href="https://aktsmm.github.io/azure-ops-pulse-demo/#/overview">Azure Ops Pulse</a>
        <a class="demo-link" href="https://aktsmm.github.io/m365-message-center-dashboard/" aria-current="page">M365 Change Radar</a>
        <a class="demo-link" href="https://aktsmm.github.io/m365-copilot-update-digest/">M365 Copilot Update Digest</a>
        <a class="demo-link" href="https://aktsmm.github.io/daily-dev-byte/">Daily Dev Byte</a>
        <a class="demo-link" href="https://aktsmm.github.io/vscode-copilot-digest/index.html">VS Code Copilot Digest</a>
      </div>
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
      <h2>関連ドキュメントの自動補完</h2>
      <p>収集・core・translations の各 workflow 成功後に、独立した <strong>M365 official documents and snapshot-only Pages</strong> が自動実行されます。保存済みの承認済み snapshot を調べ、本文・details の明示 Learn リンクや、同じ通知IDに登録済みの対応資料を検証し、記事タイトル付きで最大3件を表示します。この補完処理は Microsoft Graph を再取得しません。</p>
      <p><a href="https://learn.microsoft.com/ja-jp/training/support/mcp" target="_blank" rel="noopener noreferrer">公開 Microsoft Learn MCP</a> を公式 Python MCP SDK から利用します。認証不要の公開ドキュメント取得であり、GitHub Copilot MCP のサインインや通知取得の OIDC 認証とは独立しています。MCP に送る検索語は登録済みの公開製品名・機能名だけで、通知本文・テナント名・ユーザー情報は送りません。</p>
      <p><strong>全件の資料選定まで完全自動ではありません。</strong> 新しい通知IDで検索語・採用レビューが未登録なら、明示リンク以外はレビュー待ちの「未調査」として残します。運用担当者が対象機能・プラットフォームに合う候補を確認して登録します。名前が似ているだけの別機能の資料を自動流用しません。</p>
      <p>日本語記事の本文を確認して優先し、未提供の場合だけ確認済み英語記事を残します。出典・確認日時・採用根拠を保存し、通知の内容 fingerprint が一致する場合だけ表示します。1通知ごとのチェックポイント、キャッシュ、レート制限時のバックオフで途中再開できます。</p>
    </section>
    <section class="panel">
      <h2>関連資料が表示されない場合</h2>
      <p><strong>表示なしは「資料が存在しない」という意味ではありません。</strong></p>
      <ul>
        <li><strong>対応資料未確認:</strong> 調査したものの、対象製品・機能・プラットフォームに合う記事を確認・採用できていません。</li>
        <li><strong>未調査:</strong> 新しい通知の検索語が未登録など、レビュー待ちの状態です。</li>
        <li><strong>取得失敗:</strong> 記事の取得・検証に失敗しています。資料の有無とは区別し、次回再試行します。</li>
      </ul>
      <p>無関係な製品トップや Q&amp;A で件数を埋めません。日本語訳の生成待ちと、関連資料の調査状態も別々に管理します。</p>
    </section>
    <section class="panel">
      <h2>認証と公開の境界</h2>
      <ol class="flow">
        <li><strong>テスト テナントと取得方法:</strong> 表示する Message Center データは、個人検証用テスト テナントから取得しています。Microsoft Entra アプリケーションがアプリケーション専用アクセスで収集しており、特定の Microsoft 365 ユーザーのサインインを通じた取得ではありません。この静的ダッシュボードは本番テナントでの判断に用いるシステムではありません。</li>
        <li><strong>Microsoft Entra ID と Microsoft Graph:</strong> GitHub Actions は OIDC で Microsoft Entra ID に認証し、管理者が同意した Microsoft Graph の読み取り専用のアプリケーション権限で Message Center を取得します。パスワード、アクセストークン、認証情報は公開データに含めません。</li>
        <li><strong>GitHub Actions と GitHub Pages:</strong> 取得したデータは credential-like 値を除外または redaction し、検証した snapshot だけを静的ページとして公開します。このダッシュボードの閲覧に Microsoft Graph へのサインインは必要ありません。</li>
        <li><strong>GitHub Agentic Workflows:</strong> エージェントには同じ run の、範囲を限定して redaction 済みの snapshot だけを渡し、日本語の要約と翻訳を作成します。公開前に publisher が snapshot との一致や安全性を検証するため、エージェントの出力だけで公開されることはありません。</li>
      </ol>
    </section>
    <section class="panel">
      <h2>手動で更新するには</h2>
      <p>GitHub Actions の <strong>M365 Message Center Dashboard - Public Metadata</strong> を main ブランチで手動実行します。月曜日・木曜日 07:17 JST の定期実行と同じく、成功後に core Agentic Workflow、さらに成功後の translations Workflow が順に Pages を更新します。</p>
      <p>詳細な日本語要約と本文訳の進捗は、公開ダッシュボードの各カードにある「日本語訳と詳細要約」で確認できます。未検証の訳文は表示せず、公開済みの検証済み訳文だけを保持します。</p>
      <p>保存済みデータの関連資料や説明ページだけを更新する場合は、<strong>M365 official documents and snapshot-only Pages</strong> を main で実行します。通知の新規取得は行わず、未承認の実テナント・本番データを追加取得する必要もありません。</p>
    </section>
    <section class="panel">
      <h2>公開データとリンクの境界</h2>
      <p>「メッセージ原文」は、同じ MC の既存 HTTPS 管理センター URL を優先します。保存されていない場合は、公開済み MC ID と既存の管理センター詳細ルートによる静的リンクを表示します。「サイト内詳細」は該当カードの本文を開きます。認証・MFA・対象テナントの権限は維持します。</p>
      <p>関連ドキュメントは、その MC の明示 Learn リンク、または公開 Learn MCP で確認して採用した公式記事です。通知データとは別の <code>related-documents.json</code> に記事の証拠と調査状態を保存します。Agentic output の同一 snapshot・同一 MC に限定した URL allowlist は変更していません。</p>
      <p><a href="https://admin.microsoft.com/#/MessageCenter" target="_blank" rel="noopener noreferrer">Microsoft 365 管理センターの Message Center を開く</a>には、サインインと対象テナントでの適切な権限が必要です。この静的な公式入口は、MC カードの同一 snapshot・同一 MC に限定した URL 検証を緩和しません。</p>
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
