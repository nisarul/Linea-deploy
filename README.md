# Linea Deploy

Azure infrastructure + GitHub CD pipelines for the Linea ecosystem.

> Production deployment of [Linea-server](https://github.com/nisarul/Linea-server)
> + [Linea-web](https://github.com/nisarul/Linea-web), authenticated by
> [Microsoft Entra ID](https://entra.microsoft.com), hosted on
> [Azure Container Apps](https://learn.microsoft.com/azure/container-apps/), driven by
> tag-triggered GitHub Actions with OIDC federated credentials (no long-lived secrets).

## Topology

```
linea-vnet (10.0.0.0/16)
└─ aca subnet (10.0.0.0/23)   delegated to Container Apps,
                              service endpoint to Microsoft.Storage

resourceGroup (Linea-rg)
├─ Log Analytics workspace
├─ Premium FileStorage account     public access disabled,
│    ├─ NFSv4.1 share: server-data  subnet-restricted via service
│    └─ NFSv4.1 share: web-data     endpoint
└─ Container Apps managed env      (workload-profiles mode,
   ├─ linea-server  internal :8080  VNet-integrated)
   └─ linea-web     external :8090
```

- **Single replica per app.** Both apps are stateful: Linea-server keeps a Badger KV per
  genealogy; the Linea-web BFF keeps a Badger session store.
- **Premium NFSv4.1 storage.** Real POSIX fsync semantics, low latency. The storage
  account is locked to the Container Apps subnet via a `Microsoft.Storage` service
  endpoint — there is no public path to the file shares.
- **Internal traffic.** linea-web's BFF reverse-proxies `/api/*` to `linea-server`'s
  internal Container Apps FQDN — never goes out to the public internet.
- **Public URL.** Azure's default `<app>.<env>.azurecontainerapps.io` for now. A custom
  domain + Front Door can be added later without changing the topology.

## One-time setup (manual)

These steps run **once** per environment, before the first `Deploy infra` workflow run.
They cover Entra ID app registrations (for end-user sign-in) and the GitHub OIDC
federated credential (for CI to deploy without a stored secret).

### 1. Azure subscription context

```sh
az login
az account set --subscription <SUBSCRIPTION_ID>
TENANT_ID=$(az account show --query tenantId -o tsv)
SUB_ID=$(az account show --query id -o tsv)
RG=Linea-rg
LOC=centralindia
az group create -n $RG -l $LOC
```

### 2. Entra ID app registration for Linea-web (BFF)

Confidential client; the BFF holds the secret.

```sh
# Placeholder redirect — we'll patch it after the first infra deploy
# when we know the Container App's public FQDN.
WEB_APP=$(az ad app create \
  --display-name "Linea-web" \
  --sign-in-audience AzureADMyOrg \
  --web-redirect-uris "https://localhost/auth/callback" \
  --query appId -o tsv)

WEB_SECRET=$(az ad app credential reset --id $WEB_APP --append --years 2 --query password -o tsv)

echo "LINEA_WEB_CLIENT_ID=$WEB_APP"
echo "LINEA_WEB_CLIENT_SECRET=$WEB_SECRET"
```

### 3. Entra ID app registration for Linea-cli (public)

```sh
CLI_APP=$(az ad app create \
  --display-name "Linea-cli" \
  --sign-in-audience AzureADMyOrg \
  --is-fallback-public-client true \
  --public-client-redirect-uris "http://localhost" \
  --query appId -o tsv)

echo "LINEA_CLI_CLIENT_ID=$CLI_APP"
```

### 4. Service principal + federated credentials for GitHub Actions

```sh
SP_APP=$(az ad app create --display-name "linea-deploy-gh" --query appId -o tsv)
az ad sp create --id $SP_APP > /dev/null
SP_OBJECT=$(az ad sp show --id $SP_APP --query id -o tsv)

# Grant Contributor on the resource group only.
az role assignment create \
  --assignee-object-id $SP_OBJECT \
  --assignee-principal-type ServicePrincipal \
  --role Contributor \
  --scope /subscriptions/$SUB_ID/resourceGroups/$RG

# Federated credential for each repo + ref. Repeat for each repo.
for repo in nisarul/Linea-deploy nisarul/Linea-server nisarul/Linea-web; do
  az ad app federated-credential create --id $SP_APP --parameters @- <<EOF
{
  "name": "${repo//\//-}-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:$repo:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF

  # Also federate for tag pushes (so the Release workflows can deploy).
  az ad app federated-credential create --id $SP_APP --parameters @- <<EOF
{
  "name": "${repo//\//-}-tags",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:$repo:ref:refs/tags/*",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF

  # And for the "prod" GitHub Environment used by the deploy jobs.
  # GitHub mints tokens with this subject when a job declares
  # `environment: prod`, regardless of the ref.
  az ad app federated-credential create --id $SP_APP --parameters @- <<EOF
{
  "name": "${repo//\//-}-env-prod",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:$repo:environment:prod",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF
done

echo "AZURE_CLIENT_ID=$SP_APP"
echo "AZURE_TENANT_ID=$TENANT_ID"
echo "AZURE_SUBSCRIPTION_ID=$SUB_ID"
```

### 5. GitHub secrets / variables

Set these on **each of** `Linea-deploy`, `Linea-server`, `Linea-web` (under
Settings → Secrets and variables → Actions). The `Linea-deploy` repo additionally
needs the OIDC issuer + Linea-web app reg values.

**Repository secrets (all three repos)**

| Name                    | Value                                                       |
|-------------------------|-------------------------------------------------------------|
| `AZURE_CLIENT_ID`       | `$SP_APP` from step 4                                       |
| `AZURE_TENANT_ID`       | `$TENANT_ID`                                                |
| `AZURE_SUBSCRIPTION_ID` | `$SUB_ID`                                                   |

**Repository variables (all three repos)**

| Name                    | Value                                                       |
|-------------------------|-------------------------------------------------------------|
| `AZURE_RESOURCE_GROUP`  | `Linea-rg`                                                  |

**Additional secrets (Linea-deploy only)**

| Name                       | Value                                                                |
|----------------------------|----------------------------------------------------------------------|
| `OIDC_ISSUER`              | `https://login.microsoftonline.com/<TENANT_ID>/v2.0`                 |
| `LINEA_WEB_CLIENT_ID`      | `$WEB_APP`                                                           |
| `LINEA_WEB_CLIENT_SECRET`  | `$WEB_SECRET`                                                        |
| `GHCR_USERNAME`            | GitHub username or org account that can pull the GHCR images         |
| `GHCR_PAT`                 | GitHub PAT with at least `read:packages` for `ghcr.io/nisarul/*`     |

> Notes for private GHCR images:
> - `Deploy infra` now passes GHCR credentials to Azure Container Apps so image pulls succeed.
> - If images are public, you can leave `GHCR_USERNAME` and `GHCR_PAT` empty.

## Deployment

### First deploy

1. Run the **Deploy infra** workflow in this repo (Actions → Deploy infra → Run workflow).
   It creates the resource group contents and prints the public URL of `linea-web`.
  If your GHCR images are private, set `GHCR_USERNAME` and `GHCR_PAT` in this repo first.
2. Take that URL — e.g. `https://linea-web.victoriousrock-abc123.centralindia.azurecontainerapps.io` —
   and patch the `Linea-web` app registration's reply URLs:

   ```sh
   az ad app update --id $WEB_APP \
     --web-redirect-uris "https://<WEB_FQDN>/auth/callback"
   ```

3. Re-run **Deploy infra** so `LINEA_OIDC_REDIRECT_URL` in the Container App matches.

### Add "Sign in with Google" (federate Google through Entra ID)

Linea uses a single OIDC issuer (Entra). To offer Google sign-in without
introducing a second IdP in the app, federate Google as an external identity
provider in your Entra tenant. Users see "Sign in with Google" on the Entra
login page; Entra issues the ID token; the BFF and `linea-server` see no
difference.

1. Create the Google OAuth 2.0 client.
   - Google Cloud Console → APIs & Services → Credentials → Create credentials → OAuth client ID.
   - Application type: **Web application**.
   - Authorized JavaScript origins: `https://login.microsoftonline.com`
   - Authorized redirect URIs:
     `https://login.microsoftonline.com/te/<TENANT_ID>/oauth2/authresp`
   - Copy the generated **Client ID** and **Client secret**.

2. Add Google as an identity provider in Entra.
   - Microsoft Entra admin center → External Identities → All identity providers → + Google.
   - Paste the Google Client ID and Client secret. Save.

3. Allow Google users to actually sign in to your app.
   - Your Linea-web app registration → **Authentication** → ensure "Supported account types" is
     "Accounts in any organizational directory and personal Microsoft accounts" or use a
     **user flow** (External Identities → User flows) that includes Google.
   - For a personal-tenant setup, you typically attach the app to a sign-up/sign-in user flow
     and set `LINEA_OIDC_ISSUER` to the user-flow issuer URL. For a single-tenant app where
     Google users are added as guests, no issuer change is needed.

4. Test.
   - Open `https://<WEB_FQDN>` and click sign in.
   - On the Entra page, "Sign in with Google" appears alongside the standard sign-in.

No app, BFF, or `linea-server` changes are required. The ID token issuer remains
your Entra tenant (or the user-flow issuer), `aud` remains the Linea-web client id,
and signature verification continues to use the discovery JWKS.

### Subsequent deploys

- Pushing a `v*.*.*` tag to `Linea-server` builds + pushes the image to GHCR and runs
  `az containerapp update --image ghcr.io/nisarul/linea-server:<tag>` against the
  `linea-server` Container App.
- Pushing a `v*.*.*` tag to `Linea-web` does the same for `linea-web`.

Both repos' `release.yml` workflows are wired to:
- build with Buildx, push to `ghcr.io/<owner>/<repo>`,
- log in to Azure via OIDC (no static creds),
- `az containerapp update --image` to flip the running revision.

## Validation

```sh
# 1. Bicep compiles
az bicep build --file infra/main.bicep

# 2. What-if before applying
az deployment group what-if \
  --resource-group Linea-rg \
  --template-file infra/main.bicep \
  --parameters @infra/main.parameters.json
```

## Cost (rough, central-india, 2026 pricing)

- Container Apps (2 single-replica apps, Consumption profile): ~$15-25 / month at idle.
- Premium FileStorage (LRS, 2 × 100 GiB provisioned): ~$32 / month.
- Log Analytics (light traffic): ~$2-5 / month.
- VNet, service endpoint: free.

≈ **$50-60 / month** for a quiet personal deployment.

> If you outgrow 100 GiB on either share, the `shareSizeGiB` parameter scales linearly
> (Premium Files is ~$0.16/GiB/month). You can also halve cost by sharing one 100 GiB
> share with subpaths, but that's a larger refactor not worth doing until needed.

## License

AGPL-3.0-or-later.
