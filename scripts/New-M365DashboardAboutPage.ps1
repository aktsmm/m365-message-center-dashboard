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
    document.head.append(Object.assign(document.createElement("link"), { rel: "icon", href: "data:," }));
  </script>
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
        <a class="demo-link" href="https://aktsmm.github.io/azure-update-digest/">Azure Update Digest</a>
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
        <li>core GitHub Agentic Workflow が保存済みの承認済み snapshot をその run の artifact として受け取り、週次インサイトを作成します。MC ごとの日本語タイトル・100文字以内の要約・公式リンクは、その snapshot から決定論的に生成します。Graph を再取得しません。</li>
        <li>core の成功後に translations GitHub Agentic Workflow が起動し、実行ごとに最大3件の日本語タイトル・「変更・影響・時期・対応」・詳細な日本語要約・本文訳を検証します。主パイプラインの月曜日・木曜日の実行に加え、品質検査・修復が1日最大6回、不足分を3件ずつ追加で依頼します。欠落・原文版未照合・原文変更・日本語の4行が未生成のものも再生成の対象です。</li>
        <li>検証済みの snapshot、インサイト、公式リンク、翻訳だけを GitHub Pages に公開します。</li>
      </ol>
    </section>
    <section class="panel">
      <h2>関連ドキュメントの自動補完</h2>
      <p>収集・core・translations の各 workflow 成功後に、独立した <strong>M365 official documents and snapshot-only Pages</strong> が自動実行されます。保存済みの承認済み snapshot を調べ、本文・details の明示 Learn リンクを優先し、不足分は公式記事を自動検索・検証して、タイトル付きで最大3件を表示します。この補完処理は Microsoft Graph を再取得しません。</p>
      <p><a href="https://learn.microsoft.com/ja-jp/training/support/mcp" target="_blank" rel="noopener noreferrer">公開 Microsoft Learn MCP</a> を公式 Python MCP SDK から利用します。認証不要の公開ドキュメント取得であり、GitHub Copilot MCP のサインインや通知取得の OIDC 認証とは独立しています。検索語は公開製品・機能語彙だけから自動構成し、通知本文・テナント名・ユーザー情報は送りません。</p>
      <p><strong>新しい通知も検索・判定・記事検証・採用まで自動処理します。</strong> 通知IDごとの手動登録は不要です。明示リンクを優先し、不足分は公開 Learn MCP から候補を探します。取得した公式記事の同じ節で製品・機能語・プラットフォームを照合し、名前が似ているだけの別機能や無関係な製品トップは採用しません。通知の展開日・提供段階は通知自体の記載を正本とします。</p>
      <p>更新成功後に加え、毎日11:37・23:37 JSTにも保存済みデータだけを再調査します。対応資料未確認は3日後、確認済み資料は30日後を目安に再確認し、取得失敗は次回再試行します。1回100版・900秒の上限に達したら、次回に続きから処理します。</p>
      <p>日本語記事の本文を確認して優先し、未提供の場合だけ確認済み英語記事を残します。出典・確認日時・採用根拠を保存し、通知の内容 fingerprint が一致する場合だけ表示します。1通知ごとのチェックポイント、キャッシュ、レート制限時のバックオフで途中再開できます。</p>
    </section>
    <section class="panel">
      <h2>関連資料が表示されない場合</h2>
      <p><strong>表示なしは「資料が存在しない」という意味ではありません。</strong></p>
      <ul>
        <li><strong>対応資料未確認:</strong> 調査したものの、対象製品・機能・プラットフォームに合う記事を確認・採用できていません。</li>
        <li><strong>未調査:</strong> 新着・変更通知、または実行上限による自動調査待ちです。手動登録待ちではなく、次回の補完で優先処理します。</li>
        <li><strong>取得失敗:</strong> 記事の取得・検証に失敗しています。資料の有無とは区別し、次回再試行します。</li>
      </ul>
      <p>無関係な製品トップや Q&amp;A で件数を埋めません。日本語訳の生成待ちと、関連資料の調査状態も別々に管理します。</p>
      <p>一覧には現在の通知の状態別件数と絞り込みを表示します。履歴の内容が異なる版は別々に判定し、古い通知へ最新の資料を無条件に適用しません。Actions summary と保存カタログで、全期間の件数・未処理の残り・完全／部分の状態を確認できます。</p>
    </section>
    <section class="panel">
      <h2>認証と公開の境界</h2>
      <ol class="flow">
        <li><strong>テスト テナントと取得方法:</strong> 表示する Message Center データは、個人検証用テスト テナントから取得しています。Microsoft Entra アプリケーションがアプリケーション専用アクセスで収集しており、特定の Microsoft 365 ユーザーのサインインを通じた取得ではありません。この静的ダッシュボードは本番テナントでの判断に用いるシステムではありません。</li>
        <li><strong>Microsoft Entra ID と Microsoft Graph:</strong> GitHub Actions は OIDC で Microsoft Entra ID に認証し、管理者が同意した Microsoft Graph の読み取り専用のアプリケーション権限で Message Center を取得します。パスワード、アクセストークン、認証情報は公開データに含めません。</li>
        <li><strong>GitHub Actions と GitHub Pages:</strong> 取得したデータは credential-like 値を除外または redaction し、検証した snapshot だけを静的ページとして公開します。このダッシュボードの閲覧に Microsoft Graph へのサインインは必要ありません。</li>
        <li><strong>GitHub Agentic Workflows:</strong> エージェントには同じ run の、範囲を限定して redaction 済みの snapshot だけを渡し、日本語の要約と翻訳を作成します。この artifact は承認済みの保存データから作り、Graph を重複取得しません。公開前に publisher が snapshot との一致や安全性を検証し、処理中に変わった新しい原文を古い artifact で上書きしません。</li>
      </ol>
    </section>
    <section class="panel">
      <h2>要約の根拠と原文の版</h2>
      <p>要約は「何が変わるか・誰に影響するか・いつ・何をするか・抜粋では不明な点」で整理します。本文に書かれた MC ID も元 snapshot と照合し、存在しない参照、埋め草、同じ行の反復を拒否します。MC ID は該当通知へのリンクとして使えます。</p>
      <p>新しく検証した要約・翻訳には原文の内容ハッシュを保存します。元の版を証明できない保存済み訳文に、後から「現行版」の印は付けません。保存版は注意付きで参照でき、現在の原文から抽出した変更・影響・時期・対応を併記します。週次要約に不整合がある場合は、その文章を出さず、原文に基づく確認候補を表示します。</p>
      <p>検索には保存済み日本語訳と資料名も含め、日付・サービス・並び順・検索条件をURLで共有できます。期限経過と今後30日以内の期限を分け、期限経過を対応完了とはみなしません。</p>
    </section>
    <section class="panel">
      <h2>毎日の検査と、上限付きの自動修復</h2>
      <p>bot起動は公式の <code>on.bots</code> で要約・翻訳の2本だけを許可し、mainに限定します。人間の既定role検証と公開前の検証は維持し、PAT・Graph権限・repoメンバー権限を追加しません。run全体の成功だけでagentやpublisherの実行成功とは判断しません。</p>
      <p><strong>M365 dashboard content quality and repair</strong> が約2時間ごと（依頼は1日最大6回）と手動実行で保存済みデータを検査します。週次要約の不整合・旧版を先に、次に翻訳の欠落・版未照合・日本語タイトル未生成を、既存のエージェント workflow へ依頼します。1回の検査につき依頼は最大1件、同じレーンには3時間の間隔を設けます。</p>
      <p>core成功後に続く通常の3件までの翻訳も同じ間隔に含め、無限ループや大量のAI実行はしません。全てが現行版なら追加実行は不要です。既存の Copilot エンジンと1 run当たり60 AI creditsの上限を使用し、別のAIサービスやGraph取得を追加しません。</p>
      <p>原文版未照合のバックログは一度に全件を生成せず、1回最大3件ずつ進めます。依頼・失敗・観測状態は <code>repair-state.json</code> に保存し、「依頼済み」を「修復完了」とは扱いません。取得・要約・翻訳・資料の状態は画面で別々に確認できます。</p>
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
