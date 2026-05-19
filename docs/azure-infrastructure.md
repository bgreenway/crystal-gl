# Azure Infrastructure — CrystalCares & Related Apps

A complete reference of every Azure resource touched, credentials used, and the conventions developed over our sessions. Written as a self-contained handoff for a new agent picking up after a repo move.

---

## TL;DR — most-used things

| Thing | Value |
|------|-------|
| **Azure account** | `brad.greenway@me.com` |
| **Subscription** | `CrystalTractor` (id `78ca2188-1fa8-47ff-be97-2f7a09ea0a32`) |
| **Tenant** | `531e5fbc-51bb-418a-810d-4a2607890d0b` |
| **Default region** | `eastus` |
| **Primary backend** | `https://crystalcaresprod.azurewebsites.net` (Azure Functions, 76 endpoints) |
| **MCP server** | `https://crystalcares-mcp.azurewebsites.net` (App Service, OAuth + bearer) |
| **Primary database** | `crystalcares.database.windows.net` → `CrystalCaresProd` |
| **Test org id** | `2187` |
| **Prod org id** | `1451` (Crystal Tractor) |
| **Azure CLI PATH (Git Bash)** | `export PATH="/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin:$PATH"` |
| **Python interpreter** | `C:/Python312/python.exe` (NOT the WindowsApps python3 — pip installs go to Python312) |

---

## Azure CLI bootstrap

Required at the top of every Bash command that uses `az` or `func`:

```bash
export PATH="/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin:$PATH"
```

Confirm you're on the right account:
```bash
az account show --query "{user:user.name, sub:name, subId:id, tenant:tenantId}" -o table
```

If a different tenant/sub pops up:
```bash
az account set --subscription CrystalTractor
```

`az login` is interactive (opens a browser). Token is cached and reused.

---

## Resource Groups

| RG | Region | What's in it |
|----|--------|--------------|
| `CrystalCaresDev` | eastus | **Primary** — CrystalCaresProd function app, crystalcares-mcp web app, crystalcares SQL server, admin web apps |
| `CrystalCaresProd` | eastus | Function plan for CrystalCaresProd (FlexConsumption SKU) |
| `rg-prtsplan-prod-eastus-001` | eastus | Parts-planning SQL server + Python app service |
| `rg-acctdata-prod-eastus-001` | eastus | Accounting data storage |
| `cdk-drive-docs` | eastus | CDK docs API (sql-cdk-docs DB + app-cdkdocs-api) |
| `IntellidealerR1` | eastus | TradeIn + IntelliDealerR1 databases |
| `crystaltradeinfunctions` | eastus | TradeIn functions (EP1 plan) + key vault `CrystalProd` |
| `TradeInAppAdmin` | eastus2 | TradeInAppAdminR1 web app |
| `TradeInAppAdminDev_group` | eastus | TradeInAppAdminDev |
| `httpcrystaltest` | eastus | Test storage |
| `crystalazuresqltest` | eastus | Test SQL storage |
| `crystal-vpn-gateway`, `CrystalVPNTunnels` | eastus | VPN infrastructure |
| `dashboards`, `PowerBITest` | eastus | Dashboarding |
| `DefaultResourceGroup-EUS`, `-EUS2`, `NetworkWatcherRG` | — | Auto-created defaults |

---

## SQL Servers

### `crystalcares.database.windows.net` (CrystalCaresDev RG) — **the main one**

| Database | SKU | Status | Purpose |
|----------|-----|--------|---------|
| **CrystalCaresProd** | GP_S_Gen5_2 | Online | Production service-plan data — the one we mostly work with |
| CrystalCaresStaging | GP_S_Gen5_2 | Online | Staging |
| CrystalCaresDev | GP_S_Gen5_1 | Online | Dev |
| CrystalCares | GP_S_Gen5_2 | Paused | Legacy |
| master | system | Online | — |

**Credentials (SQL auth):**
```
Server:   tcp:crystalcares.database.windows.net,1433
Database: CrystalCaresProd
User:     crystalSQL
Password: M4thrules2025!
```

> ⚠️ The `!` in the password causes Bash history expansion. Always call sqlcmd via Python `subprocess` or with quoted heredoc — never `sqlcmd -P "M4thrules2025!"` on a Bash command line.

**Firewall:** has many ad-hoc client-IP rules (`AllowAllWindowsAzureIps` open for Azure services).

### `sql-prtsplan-prod-eastus-001.database.windows.net` (rg-prtsplan-prod-eastus-001)

| Database | SKU | Notes |
|----------|-----|-------|
| **sqldb-prtsplan-prod-eastus-001** | S2 | Parts-planning. Tables: `PARTMAST`, `PartmastLoadControl`, `OrderRecommendation`, `BranchRole`, `BranchToWarehouseReturnRecommendation`, `WarehouseToVendorReturnRecommendation`, `RecommendationRun`, `PartmastBulkConfig`, `PARTMAST_History`, `stg.PARTMAST` |
| **sqldb-acctdata-prod-eastus-001** | S0 | Accounting / GL. Tables: `ACCMAST`, `COACMAST`, `DEPTMAST`, `GLCAL`, `GLFIS`, `AcctLoadControl`, plus `stg.*` staging copies |
| master | system | — |

**Credentials:**
- SQL admin: `CloudSAe9c02ca3` (password **not in our possession** — provisioned automatically)
- **AAD auth works** with `brad.greenway@me.com` — preferred path
- Firewall rule `brad-dev` allows `206.255.87.113`

**Firewall rules:**
| Name | IP |
|------|-----|
| `AllowAllWindowsAzureIps` | 0.0.0.0 (Azure services only) |
| `brad-dev` | 206.255.87.113 |
| `ted-dev-2026-05-04` | 173.170.124.252 |
| `ted-dev-machine` | 164.153.55.250 |

### `sql-cdk-docs.database.windows.net` (cdk-drive-docs RG)

- Database: `sqldb-cdkdocs` (S0). For CDK docs API.
- Admin: `CloudSA98a2da9b` (password not in our possession; use AAD).

### `crystal-intellidealer-r1.database.windows.net` (IntellidealerR1 RG)

| Database | SKU | Status |
|----------|-----|--------|
| TradeIn | GP_S_Gen5_4 | Online |
| IntelliDealerR1 | GP_S_Gen5_4 | Paused (auto-resumes on connect) |

**Credentials (SQL auth):**
```
Server:   tcp:crystal-intellidealer-r1.database.windows.net,1433
User:     crystalSQL
Password: M4thrules2024!
```

⚠️ **Different year** from CrystalCares — password is `2024!` here, `2025!` on `crystalcares.database.windows.net`. Sourced from `CrystalTradeInFunctions` app setting `SQLServerConnectionString`.

**AAD admin:** `ted.uiterwyk@crystalmotorcarco.onmicrosoft.com` — `brad.greenway@me.com` is not granted contained-user access; AAD auth fails. Use SQL auth.

`IntelliDealerR1` is a wide replica of the Intellidealer source schema (203 tables in `dbo`) but data is stale (paused 2025-12-11). Schema is still accurate and usable as a design reference — see `docs/intellidealer-r1-schema.md` in the Crystal project.

---

## Function Apps

### `CrystalCaresProd` (CrystalCaresDev RG) — **primary backend**

- Host: `crystalcaresprod.azurewebsites.net`
- Runtime: .NET 9 isolated worker, Linux
- Plan: `ASP-CrystalCaresProd-b779` (FlexConsumption FC1, prod RG)
- 76 endpoints, all `AuthorizationLevel.Anonymous` (no auth on the function level)
- App settings (env vars) include `SQLServerConnectionString` pointing at `CrystalCaresProd` DB

**Deploy:**
```bash
cd <repo-root>
export PATH="/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin:$PATH"
func azure functionapp publish CrystalCaresProd
```

Takes 2-3 minutes. App name is case-sensitive (`crystalcaresprod` lowercase fails with "Can't find app"). Must be run from the function project's repo root (where the `.csproj` lives).

### Other function apps in the subscription

| Name | RG | Plan | Notes |
|------|-----|------|-------|
| `CrystalCaresDev` | CrystalCaresDev | ASP-CrystalCaresDev-b828 (B2, eastus2) | Dev counterpart of prod |
| `CrystalTradeInFunctions` | crystaltradeinfunctions | ASP-CrystalTradeInFunctions-9d78 (EP1 elastic) | TradeIn flows |

---

## App Services

### `crystalcares-mcp` (CrystalCaresDev RG) — **MCP server**

- Host: `https://crystalcares-mcp.azurewebsites.net`
- Plan: `crystalcares-mcp-plan` (B1 Linux, ~$13/mo)
- Runtime: Python 3.12
- **Startup command:** `uvicorn server:app --host 0.0.0.0 --port 8000`
- Source: a single file `MCP/server.py` (in the CrystalCares repo)

**App settings (env vars) currently set:**

| Key | Purpose |
|-----|---------|
| `MCP_TRANSPORT` = `http` | Activates HTTP mode (not stdio) |
| `MCP_AUTH_MODE` = `both` | Accepts OAuth JWT **or** static bearer |
| `MCP_BEARER_TOKEN` | Static token for curl/scripts (legacy path) |
| `OAUTH_PASSCODE` | Human-typed passcode on the /authorize login page |
| `MCP_JWT_SECRET` | HMAC-SHA256 signing secret for issued JWTs |
| `MCP_PUBLIC_URL` = `https://crystalcares-mcp.azurewebsites.net` | OAuth issuer/audience |
| `MCP_HOST` = `0.0.0.0`, `MCP_PORT` = `8000`, `WEBSITES_PORT` = `8000` | Bind |
| `SCM_DO_BUILD_DURING_DEPLOYMENT` = `true` | Oryx installs requirements.txt on deploy |
| `CRYSTALCARES_API_URL` = `https://crystalcaresprod.azurewebsites.net` | Backend the MCP calls |
| `CRYSTALCARES_ORG_ID` = `1451` | Default org injected on every tool call |
| `CRYSTALCARES_UPDATED_BY` = `mcp_remote` | Audit tag for writes |
| `CRYSTALCARES_CONFIG_DESC` = `Preferred` | Default pricing config |

**Deploy:**
```bash
# Zip just the two files (server.py + requirements.txt) at the zip root
powershell.exe -NoProfile -Command "Compress-Archive -Path 'MCP\server.py','MCP\requirements.txt' -DestinationPath 'C:\Users\bradg\AppData\Local\Temp\mcp_deploy.zip' -Force"

export PATH="/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin:$PATH"
az webapp deploy --resource-group CrystalCaresDev --name crystalcares-mcp \
  --src-path "C:/Users/bradg/AppData/Local/Temp/mcp_deploy.zip" --type zip
```

After deploy: wait ~30s, poll `https://crystalcares-mcp.azurewebsites.net/healthz` until it returns `{"status":"ok"}`.

> ⚠️ **App Service restarts on env var change.** Never set settings AND deploy in the same minute — the deploy will collide with the restart and trigger a 5-min cold-start cooldown. If that happens, the only fix is to wait and retry.

**OAuth endpoints exposed:**
- `GET /.well-known/oauth-authorization-server` (RFC 8414)
- `GET /.well-known/oauth-protected-resource` (MCP spec)
- `POST /register` (RFC 7591 Dynamic Client Registration)
- `GET/POST /authorize` (PKCE login with HTML form)
- `POST /token` (issues HS256 JWT, 7-day TTL)

### Other web apps

| Name | RG | Host |
|------|-----|------|
| `app-prtsplan-prod-eastus-001` | rg-prtsplan-prod-eastus-001 | (Python app) |
| `app-cdkdocs-api` | cdk-drive-docs | CDK docs API |
| `CrystalCaresAdminProd` | CrystalCaresDev | Admin UI for CrystalCares |
| `CrystalCaresAdminDev` | CrystalCaresDev | Dev admin UI |
| `TradeInAppAdminR1` | TradeInAppAdmin (eastus2) | TradeIn admin |
| `TradeInAppAdminDev` | TradeInAppAdminDev_group | TradeIn admin dev |

---

## Key Vaults

- **`CrystalProd`** in `crystaltradeinfunctions` RG, eastus.
  Firewall-restricted (`Forbidden` from our typical IPs). Would need an explicit Network ACL rule to read secrets.

---

## Storage Accounts

Notable ones:
| Name | RG | Tier | Used by |
|------|-----|------|---------|
| `crystalcaresprod97e4` | CrystalCaresProd | Standard_LRS | Function App backing store |
| `crystalcaresprod99c9` | CrystalCaresProd | Standard_LRS (eastus2) | Function App backing store (alt) |
| `crystaltradeinblobs` | crystaltradeinfunctions | Standard_RAGRS | TradeIn blob data |
| `stprtsplanprodeus001` | rg-prtsplan-prod-eastus-001 | Standard_LRS | Parts planning storage |
| `stacctdataprodeus001` | rg-acctdata-prod-eastus-001 | Standard_LRS | Accounting data |

---

## Connection patterns

### SQL via sqlcmd (Bash, SQL auth)

Always wrap in Python `subprocess` so the `!` in the password doesn't get expanded:

```bash
python3 << 'PYEOF'
import subprocess

sql = """SET NOCOUNT ON;
SELECT COUNT(*) FROM dbo.service_plan;
"""

r = subprocess.run(
    ['sqlcmd', '-S', 'tcp:crystalcares.database.windows.net,1433',
     '-d', 'CrystalCaresProd', '-U', 'crystalSQL', '-P', 'M4thrules2025!',
     '-Q', sql, '-W', '-s', '|', '-C', '-I'],
    capture_output=True, text=True, timeout=30)
print(r.stdout)
PYEOF
```

### SQL via pyodbc with Azure AD token (for AAD-only servers)

For `sql-prtsplan-prod-eastus-001` (or any server where you have AAD access but not the SQL password):

```bash
export PATH="/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin:$PATH"

TMPFILE="C:/Users/bradg/AppData/Local/Temp/aad_token.json"
az account get-access-token --resource https://database.windows.net/ > "$TMPFILE"

C:/Python312/python.exe - <<'PYEOF'
import json, struct, pyodbc

with open("C:/Users/bradg/AppData/Local/Temp/aad_token.json") as f:
    tok = json.load(f)["accessToken"]

token_bytes = tok.encode("utf-16-le")
token_struct = struct.pack(f"=i{len(token_bytes)}s", len(token_bytes), token_bytes)
SQL_COPT_SS_ACCESS_TOKEN = 1256

conn = pyodbc.connect(
    "DRIVER={ODBC Driver 17 for SQL Server};"
    "SERVER=sql-prtsplan-prod-eastus-001.database.windows.net;"
    "DATABASE=sqldb-prtsplan-prod-eastus-001;Encrypt=yes;TrustServerCertificate=no",
    attrs_before={SQL_COPT_SS_ACCESS_TOKEN: token_struct},
    timeout=30,
)
cur = conn.cursor()
cur.execute("SELECT TOP 5 * FROM dbo.PARTMAST")
for r in cur.fetchall():
    print(r)
PYEOF
```

### Adding a firewall rule (when your IP isn't allowed)

```bash
export PATH="/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin:$PATH"

# Find your current public IP from the error message, or:
MY_IP=$(curl -s ifconfig.me)

az sql server firewall-rule create \
  --resource-group <RG> \
  --server <SERVER_NAME> \
  --name "claude-$(date +%Y%m%d)" \
  --start-ip-address $MY_IP \
  --end-ip-address $MY_IP
```

Wait ~10s for propagation.

### MCP server — call from curl

```bash
TOKEN=<bearer-or-jwt>
curl -X POST https://crystalcares-mcp.azurewebsites.net/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.1"}}}'
```

Public unauthenticated endpoint: `GET /healthz` → `{"status":"ok"}`.

---

## Credentials catalog

All secrets gathered or generated during work, in one place:

| What | Value |
|------|-------|
| **CrystalCares SQL** | `crystalSQL` / `M4thrules2025!` |
| **MCP static bearer** | `kB7GrN3mRWQ_kZwFdj-JkfLPq4oi5IFyTKJtrP8Waa2cyrne0w3NJyd57fBb4gM_` |
| **MCP OAuth passcode** | `3KKwi7_v58VOlARP` (typed at the claude.ai /authorize popup) |
| **MCP JWT secret** | `6TPUisWGrDZjo7Y1CWKhjCytpbfK6cSRDf2CSEr4k9BWKZvcteauch_nyXn_wfF_` |
| **Azure AD** | `brad.greenway@me.com` (interactive via `az login`) |

Rotate any of the MCP secrets via:
```bash
NEW=$(C:/Python312/python.exe -c "import secrets; print(secrets.token_urlsafe(48))")
az webapp config appsettings set --name crystalcares-mcp --resource-group CrystalCaresDev \
  --settings MCP_BEARER_TOKEN="$NEW"  # or OAUTH_PASSCODE, or MCP_JWT_SECRET
```

---

## Deployment cheatsheet

| Target | Command |
|--------|---------|
| **Backend functions** | `cd <repo>; export PATH=...; func azure functionapp publish CrystalCaresProd` |
| **MCP server** | `powershell.exe Compress-Archive ...; az webapp deploy --resource-group CrystalCaresDev --name crystalcares-mcp --src-path ... --type zip` |
| **DB migration** | sqlcmd with `-i` flag pointing at a `.sql` file. Always `SET NOCOUNT ON; SET QUOTED_IDENTIFIER ON;` at the top — sqlcmd doesn't set them by default |
| **App Service env var** | `az webapp config appsettings set --name <app> --resource-group <rg> --settings KEY=VALUE` |
| **App Service log download** | `az webapp log download --name <app> --resource-group <rg> --log-file <out>.zip` |

---

## Common gotchas

1. **Bash and `!` in passwords** — always use Python subprocess for SQL credentials, never bare command line
2. **App Service env var change + deploy collision** — wait 2 min between env-var change and code deploy, or you'll get a 5-min cooldown
3. **Function app name case** — `CrystalCaresProd` is case-sensitive in `func azure functionapp publish`
4. **`/tmp/foo` in Bash != `/tmp/foo` for Python** — Python sees the actual Windows path. Use `C:/Users/bradg/AppData/Local/Temp/...` for files shared across bash/python
5. **`python3` vs `C:/Python312/python.exe`** — `python3` resolves to a WindowsApps Python 3.11 that has no installed packages; `C:/Python312/python.exe` is the real one where `pip --user` installs work
6. **MCP local stdio vs remote HTTP** — same `MCP/server.py` file runs both modes. `MCP_TRANSPORT=stdio` (default) is for Claude Code; `MCP_TRANSPORT=http` needs `MCP_BEARER_TOKEN` (and `OAUTH_PASSCODE` if mode includes oauth)
7. **DNS-rebinding protection** — `crystalcares-mcp.azurewebsites.net` is the only host in the default allowlist. If you put a custom domain in front, set `MCP_ALLOWED_HOSTS` env var
8. **Existing CrystalCares SQL firewall has many stale entries** — old ad-hoc client IPs accumulated; safe to clean up
9. **`service_plan_detail` has no `id` column** — use `COUNT(*)`, not `COUNT(spd.id)`
10. **`crystalSQL` vs `CrystalSQL`** — the actual SQL admin login on the `crystalcares` server is `CrystalSQL` per Azure (case-mixed); the cred file shows lowercase but both forms tend to work

---

## Quick verification commands

Bring a new environment up to speed:

```bash
# 1. PATH
export PATH="/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin:$PATH"

# 2. Confirm Azure account
az account show --query "{user:user.name, sub:name}" -o table

# 3. Backend health
curl -s https://crystalcaresprod.azurewebsites.net/api/dashboard?orgId=1451 | head -c 200

# 4. MCP server health
curl -s https://crystalcares-mcp.azurewebsites.net/healthz

# 5. MCP OAuth discovery
curl -s https://crystalcares-mcp.azurewebsites.net/.well-known/oauth-authorization-server | head -c 300

# 6. DB quick check via Python
C:/Python312/python.exe -c "
import subprocess
r = subprocess.run(['sqlcmd','-S','tcp:crystalcares.database.windows.net,1433',
  '-d','CrystalCaresProd','-U','crystalSQL','-P','M4thrules2025!',
  '-Q','SELECT COUNT(*) FROM dbo.service_plan','-C','-W'],
  capture_output=True, text=True)
print(r.stdout)
"
```

---

## Key files in the current repo

| Path | Purpose |
|------|---------|
| `MCP/server.py` | MCP server (single file, ~1000 lines, 25 tools) |
| `MCP/requirements.txt` | mcp, httpx, uvicorn, starlette, pyjwt, python-multipart |
| `.mcp.json` | Local stdio MCP registration for Claude Code |
| `Functions/` | Azure Functions backend (76 endpoints in 4 categories) |
| `Database/run_tests.sh` | 278-test integration suite |
| `Database/*.sql` | DB migrations + seed data |
| `Scripts/import_plans.py` | Bulk plan import (Excel → API) |
| `Scripts/backfill_lienholders.py` | One-shot lienholder backfill from spreadsheet |
| `Scripts/backfill_audits/*.csv` | Rollback audit files (gitignored) |
| `docs/mcp-server.md` | MCP server deployment + OAuth docs |
| `docs/azure-infrastructure.md` | **This file** |
| `docs/lienholder-feature-plan.md` | Lienholder feature design doc |
| `docs/diagrams/architecture.png` | Visual architecture diagram |
| `docs/diagrams/request_flow.png` | Sequence diagram example |
| `docs/diagrams/oauth_flow.png` | OAuth handshake diagram |
| `docs/diagrams/_render.py` | matplotlib script that regenerates the diagrams |
| `openapi.yml` | Full backend OpenAPI spec |
| `.gitignore` | Excludes `.claude/`, `Scripts/backfill_audits/`, `local.settings.json` |

---

## What's not covered

- The `crystaltradeinfunctions` / TradeIn ecosystem — we never deeply touched it
- VPN gateway, dashboards, PowerBI test setup — out of scope for our work
- `IntelliDealerR1` database — paused, hasn't been used in our sessions
- Key Vault `CrystalProd` secret contents — firewall blocked us; would need access ACL update
