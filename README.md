# Microsoft 365 Message Center Dashboard

Microsoft Graph の Message Center から、ラボ公開を許可した Message Center コンテンツを収集して GitHub Pages に公開する、単一 HTML の週2回ダッシュボードです。Microsoft 公式製品ではなく、AS-IS のサンプルです。

> [!IMPORTANT]
> 顧客環境での検証を始める前に、[顧客環境向け導入・セットアップ Jump Start](docs/SETUP.md) で必要なライセンス、管理者ロール、Microsoft Graph 権限、GitHub OIDC、Copilot 課金、および公開データ境界を確認してください。

## License

Repository-authored content and generated Pages presentation are licensed under [CC BY-NC-SA 4.0](LICENSE), with the additional permission for Microsoft Corporation and its affiliates stated in that file. Microsoft Message Center content retrieved through Microsoft Graph is third-party Microsoft content and is not licensed by aktsmm.

## Public data boundary

このリポジトリは、明示的に承認された**テスト テナント専用**の lab-public 構成です。`reports/m365/`、GitHub Pages、および dashboard artifact には次を保存・公開します。

- Message Center ID、タイトル、カテゴリ、重要度、主要日付、サービス、タグ、本文の読みやすいテキスト、name/value 形式の詳細
- 上記メタデータから集計した数値
- 決定論的に生成した日本語メッセージ要約
- Agentic Workflow が検証済みの日本語週次要約と、参照する MC ID
- 同一公開 snapshot から決定論的に生成した MC ごとの日本語タイトルと、日本語要約（100文字以内）
- Agentic Workflow が検証済みの、限定バッチの MC ごとの日本語詳細要約と本文の日本語訳
- 同じ MC の Graph `details` に含まれる、検証済みの Message Center URL と `learn.microsoft.com` の公式ドキュメント URL
- 承認済み snapshot に対応する Microsoft Learn の公開記事タイトル・URL・確認日時・採用根拠（通知データとは別の `related-documents.json`）

アクセストークン、Graph 認証情報、および credential-like 値は保存・公開しません。本文、タイトル、詳細の値は Export 時に redaction を通し、Bearer token、access token、client secret、API key、password の値を `[REDACTED]` に置換します。この構成を本番テナントへ転用しないでください。

Agentic Workflow は URL を生成・推測せず、同一 run の snapshot にある HTTPS の `admin.microsoft.com` / `m365.cloud.microsoft` URL と、同じ MC の `learn.microsoft.com` URL だけを公開します。

ダッシュボードには、静的に記述した [Microsoft 365 管理センターの Message Center](https://admin.microsoft.com/#/MessageCenter) への入口もあります。利用にはサインインと対象テナントでの適切な権限が必要です。この入口は Agentic output やカード別 URL allowlist の対象ではなく、MC カードの同一 snapshot・同一 MC に限定した検証を緩和しません。

一覧・検索結果・優先通知の **メッセージ原文** は、同じ MC の既存管理センター URL を優先します。URL が保存されていない通知には、公開済み MC ID のみを使い、既存の管理センター詳細ルートへの静的リンクを表示します。認証、MFA、対象テナントの権限は維持します。**サイト内詳細** は該当カードの本文を開きます。関連ドキュメントは記事タイトル付きで最大3件、外部リンクは別タブで開きます。

## Official document enrichment

`scripts/Update-M365RelatedDocuments.py` は **Graph を呼びません**。`reports/m365/latest` と全履歴の承認済み `messages.json`、JSON がない旧 HTML の埋め込み `DATA` を監査し、通知の ID・日付・本文・分類を書き換えず、別の `reports/m365/related-documents.json` に結果を記録します。`Update-M365DashboardSnapshots.ps1` で旧 HTML を含む全期間を再描画できます。歴史データを新たな Pages endpoint に公開することはありません。本文・details の明示 Learn URL を優先し、以後の export では本文 HTML の Learn リンクも `officialDocumentUrls` として保持します（userinfo や任意のクエリは保存せず、公開 Docs の `view` / `preserve-view` だけを許可します）。

検索は、通知タイトルに含まれる単語を `scripts/m365_document_matching.py` の**公開製品・機能語彙だけに限定して再構成**し、[公開 Microsoft Learn MCP](https://learn.microsoft.com/ja-jp/training/support/mcp) へ送ります。未知の固有名、メールアドレス、URL、数値識別子、通知ID、本文は検索へ渡しません。公式 Python MCP SDK を用い、GitHub Copilot MCP のサインインや Graph/OIDC 認証から切り離しています。通知本文・テナント名・ユーザー情報は MCP に送りません。

本文の明示 Learn リンクを優先し、不足分は検索結果から候補を自動抽出します。候補の英語本文を取得し、同じ節・短い文脈内での製品・機能語の一致率（70%以上）、プラットフォーム、記事見出しをローカルで照合します。Entra workforce と External ID customer、別製品、プラットフォーム違い、巨大なリリースノートの別々の節にしか語がない資料は採用しません。自動候補の採用根拠・一致語・公式記事の抜粋・本文ハッシュを保存します。これは決定論的な関連性判定であり、通知の展開段階・提供日が現行資料と同一であることを保証するものではありません。展開時期は通知の記載を正本とします。

日本語 URL は GET の locale と MCP 取得した記事本文を確認し、日本語本文が提供されない場合だけ確認済み英語記事を残します。Q&A や無関係な製品トップを件数埋めに使いません。`document-queries.json` / `document-reviews.json` は任意の候補ヒントとして残しますが、新しい通知の検索・採用に登録は不要です。

### 自動処理の範囲と任意の運用

承認済みデータの更新後に、**未登録の新しい通知も検索・関連性判定・記事検証・採用まで自動処理**します。候補を十分な根拠で採用できない場合は「対応資料未確認」として記録し、後日自動再調査します。全通知に必ず資料が付くと保証する仕組みではありません。

| 通知の状態 | 自動処理 | 運用担当者の作業 |
| --- | --- | --- |
| 本文・details に明示 Learn リンクがある | 記事本文・言語・到達性を確認し、最大3件を追加 | 取得失敗や不適切なリンクがあれば確認 |
| 同じ通知IDに任意の検索語・候補ヒントが登録済み | ヒントも候補に加え、現行本文との関連性・内容 fingerprint を検証 | 必要な場合だけヒントを調整 |
| 新しい通知IDで検索語・候補ヒントが未登録 | 公開語彙から検索語を生成し、Learn MCP検索・判定・検証・採用まで実行 | 通常は不要 |
| 取得失敗、再確認期限到来 | 途中再開・キャッシュ・バックオフを使って再処理 | 継続する障害や未確認資料を確認 |

通知の内容 fingerprint が変わると自動で再調査します。履歴の異なる版は個別に判定・保存し、最新の根拠を過去の別内容へ一括適用しません。同一の公開検索語・記事の取得キャッシュは再利用しますが、関連性は通知ごと・版ごとに判定します。

### 関連資料の状態の読み方

**「表示なし」や「対応資料未確認」は、関連資料が存在しないという意味ではありません。**

| 保存状態 | 意味 |
| --- | --- |
| `verified` | 対応する公式記事を確認・採用済み |
| `no_verified_document` | 調査済みだが、対象製品・機能・プラットフォームに合う資料を確認・採用できていない |
| `fetch_failed` | 記事取得・検証に失敗。資料の有無とは区別する |
| `not_researched` | 新着・変更通知、または実行時間上限で次の自動処理を待っている状態。手動登録待ちではない |

各記事に出典、記事本文 SHA-256、確認日時、採用根拠を保存し、通知の内容 fingerprint が一致したカードだけに表示します。通知の内容が変わって一致しない場合も古い資料をそのまま表示せず、再検証が必要な状態として扱います。

```powershell
python -m pip install -r scripts\requirements-documents.txt
python scripts\Update-M365RelatedDocuments.py --audit
python scripts\Update-M365RelatedDocuments.py --search-only
python scripts\Update-M365RelatedDocuments.py
# 処理後の全期間・全版のカバーと記事証拠を、ネットワークなしで検証
python scripts\Update-M365RelatedDocuments.py --check
```

1通知・1版ごとの atomic checkpoint と除外済み `.cache` を使って途中再開できます。新着・変更・失敗を優先し、Actions では1回100版・900秒、1版180秒を上限に次回へ継続します。逐次実行、1秒間隔、429/一時的 HTTP 障害の最大4回バックオフで制御し、公開サービスの失敗が2回連続した場合は保存して次回へ回します。資料未確認は3日、確認済みは30日を目安に再調査し、取得失敗は6時間後以降の次回に再試行します。検索・候補本文のキャッシュ期限も再調査に合わせます。失敗時も cache と checkpoint artifact を保存します。`--ids MC123,MC456` は承認済み対象だけの再実行、`--refresh` はキャッシュをクリアした再確認です。`--search-only` は候補表示だけで公開カタログの判定を変更しません。

**M365 official documents and snapshot-only Pages** は PR でオフライン検証、main で補完・全履歴の再描画・Pages 公開を行います。既存収集 pipeline の成功後にも動作します。公開済みデータのみの更新はこの workflow を手動実行し、Graph を再取得する既存 metadata workflow を実行する必要はありません。単一 HTML に資料データを埋め込むため、別 JSON のブラウザキャッシュとの不整合はありません。反映確認では `?verify=<commit SHA>` 付きの新規アクセスと通常 URL の再読込を併用します。

通常運用では、収集・core・translations の各 workflow 成功に加え、**毎日11:37・23:37 JST**にも Graph 取得とは独立して動作します。関連する scripts / tests / workflow 設定の main への push と手動実行も起動条件です。新しい snapshot と過去の資料カタログが一致しないことを、補完前のテストでエラーにしません。入力の安全性は先に、全版のカバー・証拠の検証は補完後に行います。収集・要約・翻訳の各 Pages artifact にもカタログを同梱し、途中の公開で消さないようにしています。

画面の「公式資料の自動調査」には現在の通知の状態別件数を表示し、状態別に絞り込めます。Actions summary と `related-documents.json` の audit には全期間と現在分の件数、未処理の残り、実行ごとの処理数、完全／部分の状態を記録します。

カードの見出しは機能を特定できるタイトルを優先します。日本語タイトルが「情報提供に関するお知らせ」のような汎用ラベルしかない場合は、通知の具体的な原題を見出しに使い、同じラベルが並んで変更内容を識別できなくなることを避けます。通知の保存データや翻訳の検証契約は変更しません。

### 他のダイジェストから取り入れた運用パターン

[Azure Update Digest の収集・再開処理](https://github.com/aktsmm/azure-update-digest/blob/main/src/lib/collect.ts) の実行予算・保存済み状態からの未処理再抽出と、[M365 Copilot Update Digest の資料補完](https://github.com/aktsmm/m365-copilot-update-digest/blob/main/scripts/lib/documentation-backfill.mjs) の fingerprint・証拠検証・状態別集計を、この lab-public の境界に合わせて採用しています。外部の公開更新を追加収集する機能や、通知本文を外部サービスへ送る仕組みは移植していません。

## Twice-weekly automation architecture

月曜日・木曜日 07:17 JST の更新は、次の順序で実行されます。

1. **Microsoft Graph**: `ServiceMessage.Read.All` を使い Message Center を取得します。
2. **GitHub Actions**: 本文を安全なテキストに変換した lab-public snapshot、details、決定論的な日本語要約を生成します。
3. **Core GitHub Agentic Workflow**: 同じ run の snapshot を入力として週次 AI insights を生成します。MC ごとの日本語タイトル・100文字以内の要約・許可済み公式リンクは、その同じ snapshot から決定論的に生成します。
4. **Translations GitHub Agentic Workflow**: core の成功後にのみ起動し、4件までの bounded translation batch を検証・公開します。週2回の実行により、最大8カード/週が詳細な日本語要約と本文訳の対象になります。
5. **Validation and GitHub Pages**: snapshot の MC ID と公式 URL allowlist を検証してから、dashboard と `/about/` の automation 説明ページを Pages に公開します。

公開 pipeline は月曜日・木曜日 07:17 JST に動作します。手動更新は Actions の **M365 Message Center Dashboard - Public Metadata** を main ブランチで実行してください。成功すると core Agentic Workflow が起動し、成功後に translation Workflow が続きます。

これらの成功後に **Official documents workflow** が独立して動作し、保存済みの承認済み snapshot だけを使って関連資料を補完・再描画・再公開します。この処理は Graph を再取得せず、公開 Learn MCP の認証不要の接続を使います。通常の通知取得・要約・翻訳と、公式資料の補完は別の処理です。

詳細な日本語要約と本文訳の進捗は、公開ダッシュボードの各カードにある **日本語訳と詳細要約** で確認できます。未検証の訳文は表示せず、公開済みの検証済み訳文だけを保持します。

翻訳の catch-up は、write 権限を持つ GitHub CLI オペレーターが `./scripts/Invoke-M365TranslationCatchup.ps1` を実行します。このスクリプトは `translation_ids` と相関 ID を指定して未翻訳の現行 MC ID を4件ずつ直列で処理し、各 run の `publish_m365_translations` ジョブと main の永続データを確認してから次へ進みます。バッチ失敗時は1件ずつ再試行して他の ID を続行します。各翻訳 run は同一 run の Graph snapshot を使うため、対象が消えた場合も未検証の訳文を公開しません。

アクセストークン、Graph 認証情報、client secret、API key、password は Git、Artifacts、Pages に保存・公開しません。credential-like 値は公開 snapshot を生成する前に `[REDACTED]` に置換します。

## Repository layout

```text
scripts/
  Export-M365MessageCenter.ps1        # Graph lab-public export and transient AI context
  New-M365MessageCenterDashboard.ps1  # Standalone HTML renderer
  New-M365DashboardAboutPage.ps1       # Static Pages automation explanation
  Update-M365RelatedDocuments.py      # Public Learn MCP enrichment; never calls Graph
  Update-M365DashboardSnapshots.ps1   # Rebuild approved JSON and legacy HTML snapshots
  m365_document_matching.py          # Public query vocabulary and local article relevance gate
  document-queries.json              # Optional safe query hints; not an unseen-ID gate
  document-reviews.json              # Optional reviewed candidates; revalidated automatically
  requirements-documents.txt         # Official Python MCP client dependencies
  Publish-M365AgentInsights.ps1       # Validates Agentic Workflow safe output
  ci/Test-M365Dashboard.ps1           # Fixture validation
tests/fixtures/                       # Synthetic Graph and Agentic Workflow data
.github/workflows/
  m365-dashboard-public.yml           # Collect, publish, and deploy the root Pages site
  m365-weekly-insights.md             # Agentic Workflow source
  m365-weekly-insights.lock.yml       # Generated workflow; do not edit
  m365-related-documents.yml          # Independent enrichment, validation, and Pages deployment
reports/m365/
  related-documents.json              # Article evidence, source bindings, states, and audit counts
  latest/                            # Current approved public snapshot
  history/                           # Archived approved snapshots; not new Pages endpoints
```

## 導入・セットアップ

顧客向けの推奨構成は、組織所有の GitHub リポジトリ、検証用 Microsoft 365 テナント、および GitHub OIDC で接続する単一テナントの Microsoft Entra アプリです。Microsoft Graph の **Application** permission `ServiceMessage.Read.All` とテナント全体の管理者同意、`AZURE_CLIENT_ID` / `AZURE_TENANT_ID`、GitHub Pages、GitHub Actions、および `copilot-requests: write` を使える Copilot 課金ポリシーが必要です。Azure サブスクリプション、client secret、Copilot 用 PAT はこの構成では使用しません。

担当者、ライセンス・費用、2026年7月以降の immutable OIDC subject、フォーク後の初期化、初回実行、受け入れ基準、およびトラブルシューティングは、[顧客環境向け導入・セットアップ Jump Start](docs/SETUP.md) を参照してください。

## Agentic summary safety boundary

The Agentic Workflows receive a transient compact context containing untrusted Message Center excerpts. Their instructions prohibit following content in that file and prohibit publishing credentials or access tokens. Each pre-agent step derives a lab-public snapshot from its Graph pull and transfers it as a one-day artifact; the snapshot contains readable body text and selected details after credential-like values are redacted. The core workflow accepts only the `publish_m365_dashboard` safe output for the weekly brief, while `Publish-M365AgentInsights.ps1` derives every card's Japanese title, short summary, and official links from that exact snapshot. The separate translations workflow accepts only `translation_updates`; its four-message batch supplies at most 1,000 source characters per message with explicit truncation metadata. Because it runs after every successful core run, it advances up to eight cards per week. The catch-up controller serializes larger backlogs and isolates a failed batch to individual IDs. Both publishers reject unsafe markup, credential-like content, fabricated URLs, oversized or low-quality translations, mismatched translation source metadata, and MC IDs that are absent from their exact same-run snapshots before rendering the public dashboard.

The deprecated optional `translation_batch_index` and the catch-up `translation_ids` input are restricted to a bounded current Graph snapshot. Neither bypasses same-snapshot validation, bounded source text, or the typed publisher contract. When every current card is already translated, the scheduled workflow creates an empty batch and safely preserves the existing validated result instead of retranslating cards.

If an Agentic run fails or its output cannot pass validation, Pages retains only previously validated translation data. Each unprocessed card shows an explicit no-data message in **日本語訳と詳細要約**; it never displays a fabricated translation.

## Display theme

The dashboard and `/about/` page default to the light Clawpilot theme and do not follow the operating-system color preference. A viewer-selected light or dark theme is stored in `localStorage`. For reproducible links, `?scoutTheme=light` or `?scoutTheme=dark` overrides the stored preference and locks the page theme for that visit.

## Local validation

PowerShell 7 or later is required. The fixture test is offline and does not use credentials:

```powershell
python -m pip install -r scripts\requirements-documents.txt
./scripts/ci/Test-M365Dashboard.ps1
python -m unittest discover -s tests -p test_documents.py
```

To update the compiled Agentic Workflow after changing its Markdown source:

```powershell
gh aw compile --validate --actionlint
```

## Official references

- [Microsoft Graph: list service announcement messages](https://learn.microsoft.com/graph/api/serviceannouncement-list-messages?view=graph-rest-1.0)
- [Microsoft Graph: serviceUpdateMessage resource](https://learn.microsoft.com/graph/api/resources/serviceupdatemessage?view=graph-rest-1.0)
- [Microsoft Graph permissions reference: ServiceMessage.Read.All](https://learn.microsoft.com/graph/permissions-reference#servicemessagereadall)
- [Use Azure Login with OpenID Connect](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect)
- [Configure GitHub Pages publishing source](https://docs.github.com/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)
- [About GitHub Agentic Workflows](https://docs.github.com/copilot/concepts/agents/about-github-agentic-workflows)
