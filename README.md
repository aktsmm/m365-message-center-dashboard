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
- Agentic Workflow が検証済みの、限定バッチの MC ごとの日本語タイトル（4〜80文字）・日本語詳細要約・本文の日本語訳
- 同じ MC の Graph `details` に含まれる、検証済みの Message Center URL と `learn.microsoft.com` の公式ドキュメント URL
- 承認済み snapshot に対応する Microsoft Learn の公開記事タイトル・URL・確認日時・採用根拠（通知データとは別の `related-documents.json`）

アクセストークン、Graph 認証情報、および credential-like 値は保存・公開しません。本文、タイトル、詳細の値は Export 時に redaction を通し、Bearer token、access token、client secret、API key、password の値を `[REDACTED]` に置換します。この構成を本番テナントへ転用しないでください。

Agentic Workflow は URL を生成・推測せず、同一 run の snapshot にある HTTPS の `admin.microsoft.com` / `m365.cloud.microsoft` URL と、同じ MC の `learn.microsoft.com` URL だけを公開します。

ダッシュボードには、静的に記述した [Microsoft 365 管理センターの Message Center](https://admin.microsoft.com/#/MessageCenter) への入口もあります。利用にはサインインと対象テナントでの適切な権限が必要です。この入口は Agentic output やカード別 URL allowlist の対象ではなく、MC カードの同一 snapshot・同一 MC に限定した検証を緩和しません。

一覧・検索結果・優先通知の **メッセージ原文** は、同じ MC の既存管理センター URL を優先します。URL が保存されていない通知には、公開済み MC ID のみを使い、既存の管理センター詳細ルートへの静的リンクを表示します。認証、MFA、対象テナントの権限は維持します。**サイト内詳細** は該当カードの本文を開きます。関連ドキュメントは記事タイトル付きで最大3件、外部リンクは別タブで開きます。

## Official document enrichment

`scripts/Update-M365RelatedDocuments.py` は **Graph を呼びません**。`reports/m365/latest` と全履歴の承認済み `messages.json`、JSON がない旧 HTML の埋め込み `DATA` を監査し、通知の ID・日付・本文・分類を書き換えず、別の `reports/m365/related-documents.json` に結果を記録します。`Update-M365DashboardSnapshots.ps1` で旧 HTML を含む全期間を再描画できます。歴史データを新たな Pages endpoint に公開することはありません。本文・details の明示 Learn URL を優先し、以後の export では本文 HTML の Learn リンクも `officialDocumentUrls` として保持します（userinfo や任意のクエリは保存せず、公開 Docs の `view` / `preserve-view` だけを許可します）。

検索は、通知タイトルに含まれる単語を `scripts/m365_document_matching.py` の**公開製品・機能語彙だけに限定して再構成**し、[公開 Microsoft Learn MCP](https://learn.microsoft.com/ja-jp/training/support/mcp) へ送ります。未知の固有名、メールアドレス、URL、数値識別子、通知ID、本文は検索へ渡しません。公式 Python MCP SDK を用い、GitHub Copilot MCP のサインインや Graph/OIDC 認証から切り離しています。通知本文・テナント名・ユーザー情報は MCP に送りません。

候補を取り込む検索は、最初の検索語で候補が見つからない場合に限り、同じ公開語彙だけを使った最大2つの絞り込み検索語（製品名＋機能語の前半／後半）を追加で試します。また「sign-in」と「single sign-on」のように語が似ているだけの別機能は、`sign-in` を1語として扱い一致させません。判定ロジックの変更は調査バージョン（`researchVersion`）を上げ、保存済みの全通知を段階的に再検証します。

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

各カードとピックアップでは、日本語タイトル（未生成の間は日本語要約の冒頭 1 文）を見出しとして先頭に置き、その下に英語の原題を残します。日本語タイトルが「情報提供に関するお知らせ」のような汎用ラベルしかない場合に、原題を見出しとして使う補完は従来どおりです。通知の保存データや翻訳の検証契約は、日本語タイトルが任意項目として加わる以外は変えません。

### 他のダイジェストから取り入れた運用パターン

[Azure Update Digest の収集・再開処理](https://github.com/aktsmm/azure-update-digest/blob/main/src/lib/collect.ts) の実行予算・保存済み状態からの未処理再抽出と、[M365 Copilot Update Digest の資料補完](https://github.com/aktsmm/m365-copilot-update-digest/blob/main/scripts/lib/documentation-backfill.mjs) の fingerprint・証拠検証・状態別集計を、この lab-public の境界に合わせて採用しています。外部の公開更新を追加収集する機能や、通知本文を外部サービスへ送る仕組みは移植していません。

直近の [Azure の原文タイトルリンク改善](https://github.com/aktsmm/azure-update-digest/commit/c29f1b1)、[Copilot Digest のコンパクトな集計カード](https://github.com/aktsmm/m365-copilot-update-digest/commit/6bf3f49)、[VS Code Digest の表示中カードの採番修正](https://github.com/aktsmm/vscode-copilot-digest/commit/8d0922d) も参考にし、タイトルから原文へ開く導線、状態バッジ、密度の高い集計、表示結果だけの連番を採用しました。日付・共有URL・日本語訳検索を加え、技術的な説明と週次要約は折りたたんで通知を探す操作を優先します。公開フィードの追加収集、スライド生成、別エンジンへの移行、他サイトのモデル選択は移植していません。

## Twice-weekly automation architecture

月曜日・木曜日 07:17 JST の更新は、次の順序で実行されます。

1. **Microsoft Graph**: `ServiceMessage.Read.All` を使い Message Center を取得します。
2. **GitHub Actions**: 本文を安全なテキストに変換した lab-public snapshot、details、決定論的な日本語要約を生成します。
3. **Core GitHub Agentic Workflow**: 保存済みの承認済み snapshot を、その run の変更不可の artifact として受け渡し、週次 AI insights を生成します。Graph を再取得しません。MC ごとの日本語タイトル・100文字以内の要約・許可済み公式リンクは、その同じ snapshot から決定論的に生成します。
4. **Translations GitHub Agentic Workflow**: core の成功後に起動し、4件までの bounded translation batch（日本語タイトル・詳細要約・本文訳）を検証・公開します。主パイプラインの週2回の実行に加え、品質検査・修復（1日最大4回）が不足分を4件ずつ追加で依頼するため、約70件のバックログは約5日で解消する見込みです。欠落・原文版未照合・原文変更・日本語タイトル未生成を自動的に再生成の対象にします。Graph を再取得しません。
5. **Validation and GitHub Pages**: snapshot の MC ID と公式 URL allowlist を検証してから、dashboard と `/about/` の automation 説明ページを Pages に公開します。

公開 pipeline は月曜日・木曜日 07:17 JST に動作します。手動更新は Actions の **M365 Message Center Dashboard - Public Metadata** を main ブランチで実行してください。成功すると core Agentic Workflow が起動し、成功後に translation Workflow が続きます。

これらの成功後に **Official documents workflow** が独立して動作し、保存済みの承認済み snapshot だけを使って関連資料を補完・再描画・再公開します。この処理は Graph を再取得せず、公開 Learn MCP の認証不要の接続を使います。通常の通知取得・要約・翻訳と、公式資料の補完は別の処理です。

詳細な日本語要約と本文訳の進捗は、公開ダッシュボードの各カードにある **日本語訳と詳細要約** で確認できます。未検証の訳文は表示せず、公開済みの検証済み訳文だけを保持します。

翻訳の追加 catch-up は、write 権限を持つ GitHub CLI オペレーターが `./scripts/Invoke-M365TranslationCatchup.ps1` を実行します。このスクリプトは `translation_ids` と相関 ID を指定して、現行原文と照合できない MC ID を4件ずつ直列で処理し、各 run の `publish_m365_translations` ジョブと main の永続データを確認してから次へ進みます。バッチ失敗時は1件ずつ再試行して他の ID を続行します。各 run は保存済みの承認済み snapshot を使い、公開直前に現行の原文が変わっていれば公開を止め、より新しい元データを上書きしません。

## 要約の根拠・原文版と自動修復

週次要約は「変更内容・対象・時期・対応・抜粋では不明な点」を原文に基づいて整理します。宣言した `referencedIds` だけでなく、本文に登場する全 MC ID も同じ snapshot と照合します。存在しない参照、参照一覧にない ID、`MC...: なし` のような埋め草、同じ内容の行の反復を publisher が拒否します。エスケープされた改行は通常の改行に正規化し、MC ID からサイト内の該当通知を開けます。

新しい週次要約には `summarySourceHash` と実際の `summaryGeneratedAt`、翻訳には原文の `sourceHash` と `validatedAt` を保存します。翻訳を追加しただけで週次要約の生成日を更新しません。原文の版を照合できない過去の訳文に現在の hash を後付けすることもありません。保存済みの訳文は注意付きの折りたたみに残し、変更・影響・時期・対応の概要には現在の原文から取り出した抜粋を使います。版一致の新しい日本語要約だけをカードの主概要に表示します。

画面には取得・週次要約・翻訳・公式資料の状態を分けて表示します。週次要約が参照不整合や旧版なら、その未検証の文章を表示せず、原文メタデータによる確認候補を表示します。5日以上前の取得データには更新確認が必要な状態を表示し、古い取得を新しい取得と見せません。通知のタイトルから管理センター原文を開け、期限経過と今後30日以内の期限は別々に扱います。検索は保存済み日本語訳・公式資料名にも対応し、通知更新日（JST）・並び順・検索・サービス・資料条件をURLで再現・共有できます。

**M365 dashboard content quality and repair** は約6時間ごと（1日4回）と手動実行で、承認済みの保存データだけを検査します。週次要約の不整合・未照合・旧版を先に修復し、その後に欠落／旧版の翻訳、および日本語タイトル未生成の翻訳を処理します。1回の検査で依頼する workflow は最大1件、同じ修復レーンは5時間の cooldown（1日最大4回、翻訳は1回4件まで。GitHub のスケジュール遅延で間隔が縮んでも取りこぼさないための設定）を設けます。core の成功後に通常の4件までの翻訳が続くため、その分も同じ cooldown に含め、成功イベントによる無限ループや大量のAI実行を避けます。全てが現行版なら追加のエージェント実行はしません。

bot起動は、要約・翻訳の2本だけに公式の `on.bots: ["github-actions[bot]"]` を設定し、どちらも main に限定しています。人間の既定role検証は維持し、repoメンバー権限・Graph権限・PATを追加しません。修復workflowだけが同じrepoの固定workflowを依頼するActions write権限と `-TrustedAutomationApproved` を使います。scopeが未設定のActions呼び出しは引き続き `authorization_required` で停止します。

run全体がsuccessでもagent／publisherがskipなら未修復です。既に起動要求したがagentが一度も開始されなかったrunだけは、手動入力 `retry_skipped_run_id` で再試行できます。対象repo・main・同じworkflow・同じbot・直前の依頼時刻との対応と、agent/publisherのskipをAPIで確認し、実際に開始した処理のcooldownは解除しません。通常の日次処理ではこの入力を使いません。

agentとdetectionが成功し、公開のGit transportだけが失敗した場合は **M365 validated summary publication recovery** で既存artifactを再検証できます。同じrepo/mainの該当core run、成功したagent/detection、失敗したpublisher、現在も一致する原文hashを確認し、既存publisherの全検証をもう一度通します。新しいモデルは実行せず、元agentの完了日時とrun IDを保存します。正常な回復後は通常の限定翻訳が続きます。どのpublisherも最新mainから始め、dispatch時点の古いコミットで直近の状態保存コミットを上書きしません。

修復は既存の Copilot エンジンと既存の1 run当たり60 AI credits上限を使います。モデルは従来どおり Copilot 側の既定で、別のAIサービスは追加しません。主パイプラインとは別に、必要な場合だけ1回最大4件の翻訳が進みます。欠落や版未照合のバックログを一度にすべて生成する仕組みではありません。

修復計画は `scripts/Invoke-M365DashboardRepair.ps1` の既定では read-only / dry-run です。`-Apply -Repository owner/repo` を指定した運用 workflow だけが、対象 repository の main に限定して既存 workflow を依頼します。実行中の同じレーンへの二重依頼を避け、`reports/m365/repair-state.json` に観測状態・依頼・失敗を保存します。「依頼済み」を「修復完了」と扱いません。Graph の取得、権限追加、認証回避は行いません。

アクセストークン、Graph 認証情報、client secret、API key、password は Git、Artifacts、Pages に保存・公開しません。credential-like 値は公開 snapshot を生成する前に `[REDACTED]` に置換します。

## 日本語見出しと書き出し

- 各カードとピックアップの上に、日本語タイトル（翻訳 workflow が原文から自然な 1 行で作成し、公開前に日本語を含む 4〜80 文字であることを検証）を表示します。タイトルが未生成の間は、保存済みの日本語詳細要約の冒頭 1 文（最大 80 文字）で代用します。原文版と照合済みでない保存訳には「保存版・原文未照合」を付け、未生成のものは「生成待ち」と表示します。英語の原題と「原文抜粋（英語）」は、原文の根拠として常に残します。日本語タイトルは検索対象にも含まれます。
- 表示中の更新を JSON（想定問答付き）、CSV、スライドノート用 Markdown として書き出せます。各カードの「出力に含める」は最初から全件チェック済みで、不要なものだけ外します（未選択方式ではなく除外方式。[Azure Update Digest](https://aktsmm.github.io/azure-update-digest/) の出力対象の考え方を参考にしています）。想定問答は原文抜粋と照合済みの要約だけから作り、原文にない項目は「原文では確認できません」と明記して推測しません。CSV は数式の実行を防ぐため先頭文字を無害化します。
- 元の `messages.json` / `facts.json` / `insights.json` は変更しません。

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
  M365DashboardContent.ps1           # Snapshot binding and summary/citation quality guards
  New-M365AgentContext.ps1           # Bounded context copied from approved saved snapshots
  Invoke-M365DashboardRepair.ps1     # Dry-run-first bounded repair planner/dispatcher
  dashboard-view.js                 # Date, URL, sorting, source-excerpt presentation helpers
  Publish-M365AgentInsights.ps1       # Validates Agentic Workflow safe output
  ci/Test-M365Dashboard.ps1           # Fixture validation
tests/fixtures/                       # Synthetic Graph and Agentic Workflow data
.github/workflows/
  m365-dashboard-public.yml           # Collect, publish, and deploy the root Pages site
  m365-weekly-insights.md             # Agentic Workflow source
  m365-weekly-insights.lock.yml       # Generated workflow; do not edit
  m365-related-documents.yml          # Independent enrichment, validation, and Pages deployment
  m365-dashboard-repair.yml           # Daily content inspection and bounded AI repair
reports/m365/
  related-documents.json              # Article evidence, source bindings, states, and audit counts
  latest/                            # Current approved public snapshot
  history/                           # Archived approved snapshots; not new Pages endpoints
```

## 導入・セットアップ

顧客向けの推奨構成は、組織所有の GitHub リポジトリ、検証用 Microsoft 365 テナント、および GitHub OIDC で接続する単一テナントの Microsoft Entra アプリです。Microsoft Graph の **Application** permission `ServiceMessage.Read.All` とテナント全体の管理者同意、`AZURE_CLIENT_ID` / `AZURE_TENANT_ID`、GitHub Pages、GitHub Actions、および `copilot-requests: write` を使える Copilot 課金ポリシーが必要です。Azure サブスクリプション、client secret、Copilot 用 PAT はこの構成では使用しません。

担当者、ライセンス・費用、2026年7月以降の immutable OIDC subject、フォーク後の初期化、初回実行、受け入れ基準、およびトラブルシューティングは、[顧客環境向け導入・セットアップ Jump Start](docs/SETUP.md) を参照してください。

## Agentic summary safety boundary

The Agentic Workflows receive transient bounded excerpts copied from an already approved on-disk lab-public snapshot; only the metadata collector calls Microsoft Graph. Their instructions prohibit following content in that file and publishing credentials or access tokens. The accepted snapshot is transferred as a one-day artifact and is content-bound to the current snapshot again immediately before publication. Core accepts only its typed weekly-summary safe output. The translation workflow accepts four typed slots of at most 1,000 supplied source characters per message, with explicit truncation metadata. Both publishers validate unsafe content, exact source counters, URL allowlists, citations and source hashes. Previous translations without matching provenance remain explicitly unverified, not newly validated by copying an ID. The bounded repair controller can request an existing workflow but cannot acquire new Graph data or bypass these publication checks.

The deprecated optional `translation_batch_index` and the catch-up `translation_ids` input are restricted to a bounded current Graph snapshot. Neither bypasses same-snapshot validation, bounded source text, or the typed publisher contract. When every current card is already translated, the scheduled workflow creates an empty batch and safely preserves the existing validated result instead of retranslating cards.

If an Agentic run fails or its output cannot pass validation, Pages retains only previously validated translation data. Each unprocessed card shows an explicit no-data message in **日本語訳と詳細要約**; it never displays a fabricated translation.

## Display theme

The dashboard and `/about/` page default to the light Clawpilot theme and do not follow the operating-system color preference. A viewer-selected light or dark theme is stored in `localStorage`. For reproducible links, `?scoutTheme=light` or `?scoutTheme=dark` overrides the stored preference and locks the page theme for that visit.

## Local validation

PowerShell 7 or later is required. The fixture test is offline and does not use credentials:

```powershell
python -m pip install -r scripts\requirements-documents.txt
./scripts/ci/Test-M365Dashboard.ps1
./scripts/ci/Test-M365ContentQuality.ps1
./scripts/ci/Test-M365Repair.ps1
node --test tests\dashboard-view.test.mjs
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
