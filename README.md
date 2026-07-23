# Microsoft 365 Message Center Dashboard

Microsoft Graph の Message Center から、公開を許可したメタデータだけを収集して GitHub Pages に公開する、単一 HTML の週次ダッシュボードです。Microsoft 公式製品ではなく、AS-IS のサンプルです。

## Public data boundary

`reports/m365/` と GitHub Pages へ保存・公開するのは、次だけです。

- Message Center ID、タイトル、カテゴリ、重要度、主要日付、サービス、タグ
- 上記メタデータから集計した数値
- Agentic Workflow が検証済みの週次要約と、参照する MC ID

Message Center の本文、詳細、テナント識別子、アクセストークン、Graph の認証情報は保存・公開しません。本文は Agentic Workflow の実行中だけに生成する一時コンテキストであり、Git、Pages、Artifacts には出力しません。

## Repository layout

```text
scripts/
  Export-M365MessageCenter.ps1        # Graph metadata export and transient AI context
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

The Agentic Workflow receives a transient file containing untrusted Message Center body text. Its instructions prohibit following content in that file and prohibit publishing bodies, tenant configuration, URLs, or credentials. The pre-agent step derives a public-metadata-only snapshot from the same Graph pull and transfers it as a one-day artifact; it never contains bodies, details, tenant identifiers, or credentials. The only accepted output is the `publish_m365_dashboard` safe output. `Publish-M365AgentInsights.ps1` rejects missing fields, unsafe markup, overly long content, and MC IDs that are absent from that exact public snapshot before rendering the public dashboard.

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
- [Microsoft Graph permissions reference: ServiceMessage.Read.All](https://learn.microsoft.com/graph/permissions-reference#servicemessagereadall)
- [Use Azure Login with OpenID Connect](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect)
- [Configure GitHub Pages publishing source](https://docs.github.com/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)
- [About GitHub Agentic Workflows](https://docs.github.com/copilot/concepts/agents/about-github-agentic-workflows)
