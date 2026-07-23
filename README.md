# Microsoft 365 Message Center Dashboard

Microsoft Graph の Message Center から、ラボ公開を許可した Message Center コンテンツを収集して GitHub Pages に公開する、単一 HTML の週次ダッシュボードです。Microsoft 公式製品ではなく、AS-IS のサンプルです。

## Public data boundary

このリポジトリは、明示的に承認された**テスト テナント専用**の lab-public 構成です。`reports/m365/`、GitHub Pages、および dashboard artifact には次を保存・公開します。

- Message Center ID、タイトル、カテゴリ、重要度、主要日付、サービス、タグ、本文の読みやすいテキスト、name/value 形式の詳細
- 上記メタデータから集計した数値
- 決定論的に生成した日本語メッセージ要約
- Agentic Workflow が検証済みの日本語週次要約と、参照する MC ID
- Agentic Workflow が検証済みの MC ごとの日本語タイトルと、日本語要約（100文字以内）
- 同じ MC の Graph `details` に含まれる、検証済みの Message Center URL と `learn.microsoft.com` の公式ドキュメント URL

アクセストークン、Graph 認証情報、および credential-like 値は保存・公開しません。本文、タイトル、詳細の値は Export 時に redaction を通し、Bearer token、access token、client secret、API key、password の値を `[REDACTED]` に置換します。この構成を本番テナントへ転用しないでください。

Agentic Workflow は URL を生成・推測せず、同一 run の snapshot にある HTTPS の `admin.microsoft.com` / `m365.cloud.microsoft` URL と、同じ MC の `learn.microsoft.com` URL だけを公開します。

## Repository layout

```text
scripts/
  Export-M365MessageCenter.ps1        # Graph lab-public export and transient AI context
  New-M365MessageCenterDashboard.ps1  # Standalone HTML renderer
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
6. Enable GitHub Copilot Agentic Workflows for the repository or organization. Organization-owned repositories also need the applicable Copilot billing and policy configuration.

Run **M365 Message Center Dashboard - Public Metadata** manually once after configuration. It runs weekly on Monday at 07:17 JST and publishes the dashboard at the GitHub Pages root. The subsequent Agentic Workflow replaces the initial placeholder with a validated weekly brief.

## Agentic summary safety boundary

The Agentic Workflow receives a transient file containing untrusted Message Center body text. Its instructions prohibit following content in that file and prohibit publishing credentials or access tokens. The pre-agent step derives a lab-public snapshot from the same Graph pull and transfers it as a one-day artifact; the snapshot contains readable body text and selected details after credential-like values are redacted. The only accepted output is the `publish_m365_dashboard` safe output. For every snapshot MC ID, its structured `message_updates` output must provide a Japanese title, a Japanese summary of 100 characters or fewer, and only snapshot-allowlisted URLs. `Publish-M365AgentInsights.ps1` rejects missing or duplicate updates, unsafe markup, credential-like content, fabricated URLs, non-Learn documentation URLs, overly long content, and MC IDs that are absent from that exact same-run snapshot before rendering the public dashboard.

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
