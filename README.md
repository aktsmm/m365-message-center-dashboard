# Microsoft 365 Message Center Dashboard

Microsoft Graph の Message Center から、ラボ公開を許可した Message Center コンテンツを収集して GitHub Pages に公開する、単一 HTML の週2回ダッシュボードです。Microsoft 公式製品ではなく、AS-IS のサンプルです。

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

アクセストークン、Graph 認証情報、および credential-like 値は保存・公開しません。本文、タイトル、詳細の値は Export 時に redaction を通し、Bearer token、access token、client secret、API key、password の値を `[REDACTED]` に置換します。この構成を本番テナントへ転用しないでください。

Agentic Workflow は URL を生成・推測せず、同一 run の snapshot にある HTTPS の `admin.microsoft.com` / `m365.cloud.microsoft` URL と、同じ MC の `learn.microsoft.com` URL だけを公開します。

## Twice-weekly automation architecture

月曜日・木曜日 07:17 JST の更新は、次の順序で実行されます。

1. **Microsoft Graph**: `ServiceMessage.Read.All` を使い Message Center を取得します。
2. **GitHub Actions**: 本文を安全なテキストに変換した lab-public snapshot、details、決定論的な日本語要約を生成します。
3. **Core GitHub Agentic Workflow**: 同じ run の snapshot を入力として週次 AI insights を生成します。MC ごとの日本語タイトル・100文字以内の要約・許可済み公式リンクは、その同じ snapshot から決定論的に生成します。
4. **Translations GitHub Agentic Workflow**: core の成功後にのみ起動し、4件までの bounded translation batch を検証・公開します。週2回の実行により、最大8カード/週が詳細な日本語要約と本文訳の対象になります。
5. **Validation and GitHub Pages**: snapshot の MC ID と公式 URL allowlist を検証してから、dashboard と `/about/` の automation 説明ページを Pages に公開します。

公開 pipeline は月曜日・木曜日 07:17 JST に動作します。手動更新は Actions の **M365 Message Center Dashboard - Public Metadata** を main ブランチで実行してください。成功すると core Agentic Workflow が起動し、成功後に translation Workflow が続きます。

翻訳の catch-up は **M365 translation catch-up controller** を main ブランチで手動実行します。未翻訳の現行 MC ID を4件ずつ直列で処理し、バッチ失敗時は1件ずつ再試行して他の ID を続行します。各翻訳 run は同一 run の Graph snapshot を使うため、対象が消えた場合も未検証の訳文を公開しません。

アクセストークン、Graph 認証情報、client secret、API key、password は Git、Artifacts、Pages に保存・公開しません。credential-like 値は公開 snapshot を生成する前に `[REDACTED]` に置換します。

## Repository layout

```text
scripts/
  Export-M365MessageCenter.ps1        # Graph lab-public export and transient AI context
  New-M365MessageCenterDashboard.ps1  # Standalone HTML renderer
  New-M365DashboardAboutPage.ps1       # Static Pages automation explanation
  Publish-M365AgentInsights.ps1       # Validates Agentic Workflow safe output
  ci/Test-M365Dashboard.ps1           # Fixture validation
tests/fixtures/                       # Synthetic Graph and Agentic Workflow data
.github/workflows/
  m365-dashboard-public.yml           # Collect, publish, and deploy the root Pages site
  m365-weekly-insights.md             # Agentic Workflow source
  m365-weekly-insights.lock.yml       # Generated workflow; do not edit
reports/m365/                         # The only path workflows commit
```

## Entra ID and GitHub Actions setup

1. Create or select a Microsoft Entra application registration.
2. Add Microsoft Graph **Application** permission `ServiceMessage.Read.All`, then grant tenant admin consent.
3. Create a federated credential for this repository's GitHub Actions workflow. No Azure subscription is required.
4. In **Settings → Secrets and variables → Actions**, configure the required repository secrets:

   | Secret | Purpose |
   | --- | --- |
   | `AZURE_CLIENT_ID` | Client ID of the Entra application or managed identity |
   | `AZURE_TENANT_ID` | Directory (tenant) ID used only by the OIDC login |

   The workflows intentionally use `allow-no-subscriptions: true`; do not configure an Azure subscription secret.
5. In **Settings → Pages**, set **Source** to **GitHub Actions**.
6. Enable GitHub Copilot Agentic Workflows for the repository or organization. Organization-owned repositories must also authorize `copilot-requests: write` through the centralized Copilot billing and policy configuration. A provider HTTP 403 means that organization setting is not enabled; rerunning cannot publish Agentic output until it is corrected.

Run **M365 Message Center Dashboard - Public Metadata** manually once after configuration. It runs twice weekly on Monday and Thursday at 07:17 JST and publishes the dashboard at the GitHub Pages root. The core Agentic Workflow publishes the validated weekly brief, and its successful completion starts the bounded translations workflow.

## Agentic summary safety boundary

The Agentic Workflows receive a transient compact context containing untrusted Message Center excerpts. Their instructions prohibit following content in that file and prohibit publishing credentials or access tokens. Each pre-agent step derives a lab-public snapshot from its Graph pull and transfers it as a one-day artifact; the snapshot contains readable body text and selected details after credential-like values are redacted. The core workflow accepts only the `publish_m365_dashboard` safe output for the weekly brief, while `Publish-M365AgentInsights.ps1` derives every card's Japanese title, short summary, and official links from that exact snapshot. The separate translations workflow accepts only `translation_updates`; its four-message batch supplies at most 1,000 source characters per message with explicit truncation metadata. Because it runs after every successful core run, it advances up to eight cards per week. The catch-up controller serializes larger backlogs and isolates a failed batch to individual IDs. Both publishers reject unsafe markup, credential-like content, fabricated URLs, oversized or low-quality translations, mismatched translation source metadata, and MC IDs that are absent from their exact same-run snapshots before rendering the public dashboard.

The deprecated optional `translation_batch_index` and the controller-only `translation_ids` input are restricted to a bounded current Graph snapshot. Neither bypasses same-snapshot validation, bounded source text, or the serialized publisher contract.

If an Agentic run fails or its output cannot pass validation, Pages retains only previously validated translation data. Each unprocessed card shows an explicit no-data message in **日本語訳と詳細要約**; it never displays a fabricated translation.

## Local validation

PowerShell 7 or later is required. The fixture test is offline and does not use credentials:

```powershell
./scripts/ci/Test-M365Dashboard.ps1
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
