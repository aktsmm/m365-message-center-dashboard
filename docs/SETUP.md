# 顧客環境向け導入・セットアップ Jump Start

このガイドは、`m365-message-center-dashboard` を顧客の検証環境へ導入し、Microsoft 365 Message Center の情報を GitHub Pages に公開するまでの事前準備と初回実行を説明します。

> [!CAUTION]
> このリポジトリは **lab-public の AS-IS サンプル**です。最初は、公開を明示的に許可した**検証用テナント**だけを接続してください。`reports/m365/`、Actions artifact、Git 履歴、および GitHub Pages には、Message Center のタイトル、本文、日付、サービス、公式リンク、要約、翻訳などが保存または公開されます。
>
> 本番テナントへ接続する前に、データ分類、法務・プライバシー、保存期間、公開先、インシデント対応、および redaction の妥当性について顧客の承認が必要です。GitHub Pages は、リポジトリが private でもインターネットへ公開される場合があります。

## 1. 最初に決めること

次の項目が未決定なら、Entra アプリや GitHub Pages を有効化しないでください。

- [ ] 接続先は公開可能なデータだけを含む検証用 Microsoft 365 テナント
- [ ] GitHub の所有者は顧客の Organization（推奨）
- [ ] リポジトリの default branch は `main`
- [ ] GitHub Pages の公開範囲と URL を顧客が承認済み
- [ ] `reports/m365/` と Git 履歴の保存期間を決定済み
- [ ] Microsoft Entra、Microsoft 365、GitHub の各担当者を指名済み
- [ ] GitHub Actions、Pages、Copilot の利用量と費用を監視する担当者を指名済み
- [ ] 初回実行後に公開内容を確認するレビュー担当者を指名済み

このワークフローは `workflow_run.branches: [main]` を使用し、`reports/m365/` を `main` へ直接 push します。default branch の変更、必須 Pull Request、ruleset、branch protection、または GitHub Pages environment の承認規則がある場合は、現在の方式を許可するか、顧客の運用方式に合わせてワークフローを変更してから実行してください。

## 2. 必要なライセンス、サービス、ロール

### サービスと費用

| 項目 | 必要条件 | 補足 |
| --- | --- | --- |
| Microsoft 365 | Message Center に対象テナントのメッセージが存在すること | Graph API に個別 add-on が必要とは公式 API 仕様に記載されていませんが、利用可能な Message Center データはテナントの契約サービスに依存します。 |
| Microsoft Graph | Application permission `ServiceMessage.Read.All` | `/admin/serviceAnnouncement/messages` の最小アプリケーション権限です。サインインしたユーザーではなくアプリとして読み取ります。 |
| Microsoft Entra ID | アプリ登録と workload identity federation | Azure サブスクリプションは不要です。client secret も作成しません。 |
| GitHub Actions | リポジトリで Actions を実行可能 | Public repository の標準 GitHub-hosted runner は無料です。Private repository はプランの無料枠と超過料金を確認してください。 |
| GitHub Pages | **Source: GitHub Actions** を利用可能 | Public repository は GitHub Free で利用できます。Private repository での利用可否とアクセス制御は GitHub プランと Organization ポリシーを確認してください。 |
| GitHub Copilot / Agentic Workflows | Copilot 推論を許可するアカウントまたは Organization ポリシー | Agentic Workflows は Public Preview です。Organization 所有では Organization 課金を推奨します。AI credits と予算を確認してください。 |
| このリポジトリの利用許諾 | [CC BY-NC-SA 4.0 と追加許諾](../LICENSE) に適合 | NonCommercial 制限の免除は Microsoft Corporation とその affiliates に限定されています。その他の顧客は商用・社内業務利用を含め法務確認が必要です。取得した Microsoft Message Center コンテンツは、このリポジトリのライセンス対象ではありません。 |

### 担当者と最小権限

| 作業 | 担当者・権限 | 実行後も必要か |
| --- | --- | --- |
| アプリ登録の作成・更新 | アプリ登録が許可されたユーザー、Application Developer、または顧客ポリシー上のアプリ管理担当者 | アプリ所有者は保守のため残すことを推奨 |
| `ServiceMessage.Read.All` の追加 | 対象アプリを更新できるアプリ所有者または管理者 | いいえ |
| Microsoft Graph application permission への管理者同意 | **Privileged Role Administrator**、Global Administrator、または必要な同意権限を持つ custom role | 初回と権限変更時のみ。可能なら PIM で時間制限 |
| Message Center の手動比較 | Message center reader など、Message Center を閲覧できる Microsoft 365 管理ロール | 運用レビューで必要 |
| Copilot Organization ポリシーの変更 | GitHub Organization owner | 初回とポリシー変更時のみ |
| Actions secrets、Pages、ruleset の設定 | GitHub repository administrator | 保守担当として必要 |
| ワークフローの手動実行と確認 | GitHub repository write access | 初回および障害対応時 |
| 定期実行 | Entra service principal の Graph application permission と GitHub Actions `GITHUB_TOKEN` | 継続して必要 |

> [!IMPORTANT]
> Application Administrator、Cloud Application Administrator、AI Administrator は、Microsoft Graph の **application permissions（app roles）** に対するテナント全体の同意には使用できません。`ServiceMessage.Read.All` の同意には Privileged Role Administrator、Global Administrator、または同等の custom role を使用します。

データプライバシー タグの Message Center 投稿をポータルで確認する担当者には、Global Administrator または Message center Privacy reader が別途必要な場合があります。Global Administrator は常用せず、最小権限のロールを選択してください。

## 3. GitHub リポジトリを準備する

1. 顧客の GitHub Organization に、このリポジトリを fork または copy します。
2. Default branch が `main` であることを確認します。別名を使う場合は、3つのワークフローの `branches: [main]`、catch-up script、および OIDC subject を一貫して変更する必要があります。
3. **Actions はまだ実行せず、Pages もまだ有効化しません。**
4. フォークに継承された `reports/m365/` を確認します。

   ```powershell
   git ls-files reports/m365
   git rm -r --dry-run reports/m365
   ```

5. 顧客の保存方針と dry run の対象をレビューして承認を得た後、必要な場合だけ、顧客リポジトリから継承 snapshot を削除してコミットします。

   ```powershell
   git rm -r reports/m365
   git commit -m "Remove inherited lab dashboard snapshots"
   git push
   ```

削除コミットだけでは、既存の Git 履歴からデータは消えません。この手順の目的は、顧客の Pages で upstream の snapshot を現在データとして公開しないことです。履歴自体の取り扱いは、顧客の保持・法務方針に従って別途決定してください。

Public repository の fork では scheduled workflow が既定で無効です。後の手順で **Actions** タブから必要なワークフローを有効化します。

## 4. Microsoft Entra アプリを作成する

1. [Microsoft Entra admin center](https://entra.microsoft.com/) で **Entra ID → App registrations → New registration** を開きます。
2. 顧客が識別できる名前を設定します。例: `m365-message-center-dashboard-test`
3. **Accounts in this organizational directory only** を選択して single-tenant アプリを作成します。
4. Overview から次を記録します。

   | 値 | GitHub での用途 |
   | --- | --- |
   | Application (client) ID | `AZURE_CLIENT_ID` |
   | Directory (tenant) ID | `AZURE_TENANT_ID` |
   | Object ID | Federated credential の CLI 作成時に使用 |

5. **API permissions → Add a permission → Microsoft Graph → Application permissions** を選択します。
6. `ServiceMessage.Read.All` だけを追加します。Delegated permission を選ばないでください。
7. Privileged Role Administrator などの同意可能な担当者が権限内容を確認し、**Grant admin consent** を実行します。
8. Status が対象テナントに対して **Granted** になったことを確認します。

`ServiceMessage.Read.All` は、セキュリティやプライバシー関連を含む可能性があるテナント全体の service announcement message を、ユーザーなしで読み取れる権限です。不要な Graph 権限は追加しないでください。

## 5. GitHub OIDC の federated credential を作成する

3つのワークフローは、同じ `main` branch subject と `api://AzureADTokenExchange` audience を使用できます。client secret や証明書は不要です。

### 2026年7月15日以降に作成・rename・transfer した GitHub.com repository

新しい repository では、owner ID と repository ID を含む immutable subject が既定です。

```text
repo:<OWNER>@<OWNER_ID>/<REPOSITORY>@<REPOSITORY_ID>:ref:refs/heads/main
```

次の PowerShell 例は、**顧客側 repository の ID** を取得し、Microsoft Entra アプリに credential を作成します。`<...>` を顧客の値へ置き換えてください。

```powershell
$Owner = '<GITHUB_ORGANIZATION>'
$Repository = '<REPOSITORY_NAME>'
$TenantId = '<AZURE_TENANT_ID>'
$ClientId = '<AZURE_CLIENT_ID>'

gh auth status
$repo = gh api "repos/$Owner/$Repository" | ConvertFrom-Json
$subject = "repo:${Owner}@$($repo.owner.id)/${Repository}@$($repo.id):ref:refs/heads/main"

az login --tenant $TenantId --allow-no-subscriptions
$appObjectId = az ad app show --id $ClientId --query id -o tsv
$ficPath = Join-Path $env:TEMP 'm365-dashboard-fic.json'
@{
    name = 'github-main-immutable'
    issuer = 'https://token.actions.githubusercontent.com'
    subject = $subject
    audiences = @('api://AzureADTokenExchange')
} | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $ficPath -Encoding utf8

az ad app federated-credential create --id $appObjectId --parameters $ficPath
Remove-Item -LiteralPath $ficPath
```

出力した `$subject`、GitHub owner ID、repository ID を変更記録に残します。ID は upstream repository のものを流用しないでください。

### 既存 repository

2026年7月15日より前から存在し、immutable subject に opt-in していない repository は、次の name-based subject を発行する場合があります。

```text
repo:<OWNER>/<REPOSITORY>:ref:refs/heads/main
```

Name-based subject は rename、transfer、名前の再利用に弱いため、Microsoft と GitHub の移行手順に従って immutable subject へ移行することを推奨します。subject を推測して credential を追加しないでください。`azure/login` が `AADSTS700213` で失敗した場合は、エラーに示される subject、repository の作成・移行状態、owner/repository ID を照合してから修正します。

## 6. GitHub を設定する

### Actions と branch policy

1. **Settings → Actions → General** で GitHub Actions を許可します。
2. Organization の Actions policy で、このリポジトリが利用する actions と GitHub Agentic Workflows を許可します。
3. `GITHUB_TOKEN` がワークフローに宣言された `contents: write`、`pages: write`、`id-token: write`、`copilot-requests: write` を取得できることを確認します。
4. Ruleset または branch protection が Actions の `main` への自動コミットを禁止する場合は、例外を承認するか、Pull Request ベースへ設計変更します。

### Repository secrets

**Settings → Secrets and variables → Actions → Repository secrets** に、次の2つだけを追加します。

| Secret | 値 |
| --- | --- |
| `AZURE_CLIENT_ID` | Entra アプリの Application (client) ID |
| `AZURE_TENANT_ID` | Directory (tenant) ID |

次は追加しません。

- `AZURE_CLIENT_SECRET`
- `AZURE_SUBSCRIPTION_ID`
- `COPILOT_GITHUB_TOKEN`

ワークフローは `allow-no-subscriptions: true` と built-in `GITHUB_TOKEN` を使用します。

### GitHub Pages

1. **Settings → Pages** を開きます。
2. **Build and deployment → Source** を **GitHub Actions** に設定します。
3. Organization の Pages policy と `github-pages` environment の protection rule が自動デプロイを許可することを確認します。

通常の project Pages URL は次です。

```text
https://<OWNER>.github.io/<REPOSITORY>/
https://<OWNER>.github.io/<REPOSITORY>/about/
```

Repository 名が `<OWNER>.github.io` の場合だけ、account root に公開されます。

### Copilot Agentic Workflows

顧客導入では Organization 所有 repository を推奨します。

1. GitHub Organization owner が **Organization Settings → Copilot → Policies** を開きます。
2. **Copilot CLI** を有効にします。
3. **Allow use of Copilot CLI billed to the organization** を有効にします。
4. Billing、AI credits、cost center、budget、および利用監視を設定します。

このリポジトリの agentic workflow は `permissions: copilot-requests: write` と built-in `GITHUB_TOKEN` を使用します。`.md` source と compile 済み `.lock.yml` はコミット済みなので、実行だけなら `gh aw compile` は不要です。

現行の GitHub Docs では、個人所有 repository の built-in `GITHUB_TOKEN` 利用は repository owner の Copilot seat に課金されます。ただし Agentic Workflows は Public Preview であり、アカウント種別ごとの手順は変更される可能性があります。顧客の継続運用には Organization 所有と Organization 課金を優先し、個人所有を選ぶ場合は導入時点の GitHub Docs、owner の有効な Copilot seat、および初回の model access を必ず再確認してください。

## 7. 初回実行

1. GitHub の **Actions** タブで必要な workflow を有効化します。Fork の scheduled workflow が disabled の場合は個別に enable します。
2. **M365 Message Center Dashboard - Public Metadata** を開きます。
3. **Run workflow** で branch に `main` を選び、手動実行します。
4. 次の順序で成功することを確認します。

   1. `M365 Message Center Dashboard - Public Metadata`
   2. `Microsoft 365 Message Center weekly dashboard`
   3. `M365 bounded translations`

5. 最初の workflow で次を確認します。
   - OIDC による Microsoft Entra sign-in が成功
   - Microsoft Graph export が成功
   - `reports/m365/` だけが自動コミットの対象
   - Pages artifact と deployment が成功
6. 2つの Agentic Workflows で Copilot model access と safe output の検証が成功することを確認します。
7. Pages を開き、顧客の検証用テナントに属する Message Center ID、タイトル、本文、要約、翻訳だけが表示されることをレビューします。

## 8. 受け入れ基準

- [ ] Entra アプリは single tenant
- [ ] Microsoft Graph の Application permission は `ServiceMessage.Read.All` だけ
- [ ] Admin consent の Status は Granted
- [ ] Federated credential は顧客 repository の immutable ID と `main` に限定
- [ ] GitHub secrets は `AZURE_CLIENT_ID` と `AZURE_TENANT_ID` だけ
- [ ] client secret、Azure subscription secret、Copilot PAT を保存していない
- [ ] 3つの workflow が `main` で順番に成功
- [ ] `reports/m365/` と Pages に credential-like 値がない
- [ ] 継承した upstream snapshot を顧客 Pages の現在データとして公開していない
- [ ] Pages の公開範囲と内容を顧客レビュー担当者が承認
- [ ] 次の月曜日・木曜日 07:17 JST の scheduled run と監視担当を登録

## 9. トラブルシューティング

| 症状 | 主な原因 | 対応 |
| --- | --- | --- |
| `AADSTS700213` / federated identity record not found | Entra の subject と GitHub が発行した subject の不一致 | Immutable owner/repository ID、`main`、issuer、audience、repository の rename/transfer 状態を照合します。 |
| `azure/login` が subscription を要求 | Azure subscription 前提の credential または設定を使用 | このリポジトリは `allow-no-subscriptions: true` です。`AZURE_SUBSCRIPTION_ID` は追加せず、tenant ID と app ID を確認します。 |
| Graph が `403 Forbidden` | Delegated permission を選択、admin consent 未実施、または別 tenant へ sign-in | Application permission `ServiceMessage.Read.All`、Granted status、tenant ID を確認します。 |
| Message Center が0件 | 対象 tenant にメッセージがない、tenant 間違い、または取得期間外 | Microsoft 365 admin center の Message Center と比較し、検証 tenant、Graph 応答、180日 lookback を確認します。 |
| Copilot provider `401` / model catalog が空 | Organization 課金ポリシー、Copilot CLI policy、owner seat、または model access が未承認 | アカウント種別に対応する Copilot 課金・policy を修正します。認可が直るまで再実行だけを繰り返さないでください。 |
| `git push` が拒否 | Ruleset、branch protection、または Actions の write permission | `reports/m365/` の直接 push を許可するか、Pull Request ベースに設計変更します。 |
| Pages deployment が待機または失敗 | Source が GitHub Actions でない、Pages policy、environment approval | Pages source、Organization policy、`github-pages` environment を確認します。 |
| Fork で定期実行されない | Scheduled workflow が disabled | Actions タブで workflow を enable します。Public repository は活動が60日ない場合も schedule が自動停止することがあります。 |
| Core は成功したが翻訳が増えない | Bounded batch が完了済み、safe output validation failure、または対象 MC が snapshot から消失 | Translation workflow の job summary と artifact を確認します。未検証の翻訳を手動で `reports/m365/` に追加しないでください。 |

## 10. 運用と撤去

### 定期運用

- 月曜日・木曜日 07:17 JST の3-workflow chain を監視します。
- Actions minutes、artifact storage、Copilot AI credits、Organization budget を月次確認します。
- `reports/m365/history/` と Git 履歴の増加量を確認し、承認済みの保持方針を適用します。
- Entra の app owner、Graph permission、federated credential、GitHub Organization policy を定期レビューします。
- ワークフローや `.github/workflows/*.md` を変更した場合は、`gh aw compile --validate --actionlint` で `.lock.yml` を再生成してレビューします。

### 撤去

撤去は Microsoft Entra、GitHub、データ管理の各 owner が対象を確認してから実施します。

1. Scheduled workflow と手動実行を無効化します。
2. GitHub Pages の公開を停止します。
3. Entra アプリから GitHub federated credential を削除します。
4. `ServiceMessage.Read.All` の consent を取り消すか、専用アプリを削除します。
5. GitHub repository secrets を削除します。
6. `reports/m365/`、Actions artifacts、Pages、Git 履歴を承認済みの保持・削除方針に従って処理します。

## 11. 公式リファレンス

### Microsoft

- [Microsoft Graph: serviceAnnouncement messages の取得](https://learn.microsoft.com/ja-jp/graph/api/serviceannouncement-list-messages?view=graph-rest-1.0)
- [Microsoft Graph permissions reference: ServiceMessage.Read.All](https://learn.microsoft.com/ja-jp/graph/permissions-reference#servicemessagereadall)
- [Microsoft 365 Message Center で新機能と変更を追跡する](https://learn.microsoft.com/ja-jp/microsoft-365/admin/manage/message-center?view=o365-worldwide)
- [アプリケーションにテナント全体の管理者の同意を付与する](https://learn.microsoft.com/ja-jp/entra/identity/enterprise-apps/grant-admin-consent)
- [外部 ID プロバイダーを信頼するようにアプリを構成する](https://learn.microsoft.com/ja-jp/entra/workload-id/workload-identity-federation-create-trust)
- [GitHub Actions の federated credential を immutable subject に移行する](https://learn.microsoft.com/ja-jp/entra/workload-id/workload-identities-github-immutable-subjects)

### GitHub

- [Creating GitHub Agentic Workflows](https://docs.github.com/en/copilot/how-tos/github-agentic-workflows/creating-github-agentic-workflows)
- [About using Copilot CLI in GitHub Actions](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/copilot-cli-in-github-actions)
- [gh-aw authentication reference](https://github.github.com/gh-aw/reference/auth/)
- [Configuring OpenID Connect in Azure](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-azure)
- [OpenID Connect reference](https://docs.github.com/en/actions/reference/security/oidc)
- [Configuring a publishing source for GitHub Pages](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)
- [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
- [Disabling and enabling a workflow](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/disable-and-enable-workflows)
