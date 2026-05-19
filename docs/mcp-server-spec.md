# Crystal GL MCP Server — Specification

A specification for an MCP server that exposes the Crystal GL data ([data-model.md](data-model.md)) as agent-callable tools. Patterned after the existing `crystalcares-mcp` server documented in [azure-infrastructure.md](azure-infrastructure.md#crystalcares-mcp-crystalcaresdev-rg--mcp-server).

This is a design spec — not implementation. Use it to drive an implementation review before writing code.

---

## 1. Goals

- Expose curated financial reports (P&L, balance sheet, trial balance, etc.) as MCP tools so any agent can call them with structured parameters.
- Provide one guarded escape hatch (`query_sql`) for novel questions an agent might ask.
- Read-only by design — no writes to the production GL data.
- Reuse the existing OAuth+bearer pattern and deployment workflow from `crystalcares-mcp`.

---

## 2. Server identity

| Property | Value |
|----------|-------|
| **Name** | `crystal-gl-mcp` |
| **Host** | `https://crystal-gl-mcp.azurewebsites.net` |
| **Resource group** | `CrystalCaresDev` (co-located with existing MCP) |
| **App Service plan** | `crystalcares-mcp-plan` (reused — B1 Linux, ~$13/mo already paid) |
| **Runtime** | Python 3.12, FastAPI/Starlette + `mcp` package, uvicorn |
| **Source** | Single file `server.py` + `requirements.txt`, deployed via `az webapp deploy --type zip` |

The choice to host as a separate App Service (rather than extending `crystalcares-mcp`) is intentional: different domain, different audience (finance/CFO vs operations), more straightforward access control.

---

## 3. Authentication

Reuse the pattern proven in `crystalcares-mcp`:

| App setting | Purpose |
|-------------|---------|
| `MCP_TRANSPORT=http` | HTTP mode |
| `MCP_AUTH_MODE=both` | Accept OAuth JWT **or** static bearer |
| `MCP_BEARER_TOKEN` | Static token for scripts / curl |
| `OAUTH_PASSCODE` | Human passcode for `/authorize` login page |
| `MCP_JWT_SECRET` | HS256 signing secret for issued JWTs |
| `MCP_PUBLIC_URL=https://crystal-gl-mcp.azurewebsites.net` | OAuth issuer/audience |

Public endpoint: `GET /healthz` → `{"status":"ok"}`. Everything else requires `Authorization: Bearer <token>`.

---

## 4. Database connection

| App setting | Purpose |
|-------------|---------|
| `GL_SQL_SERVER=sql-prtsplan-prod-eastus-001.database.windows.net` | Server hostname |
| `GL_SQL_DATABASE=sqldb-acctdata-prod-eastus-001` | DB name |
| `GL_SQL_AUTH=managed_identity` *(preferred)* or `aad_token` or `sql_password` | Auth mode |
| `GL_SQL_USER` / `GL_SQL_PASSWORD` | Only if `GL_SQL_AUTH=sql_password` |
| `GL_SQL_TIMEOUT=30` | Query timeout seconds |
| `GL_SQL_MAX_ROWS=10000` | Hard ceiling on rows returned by any tool |

**Preferred auth path:** Managed Identity on the App Service granted `db_datareader` on the acctdata DB. Avoids password storage entirely. Falls back to AAD token via `DefaultAzureCredential` for local development, or SQL auth if explicitly configured.

**Read-only enforcement (defense in depth):**
1. The DB role granted is `db_datareader` only — write attempts fail at the DB layer.
2. The `query_sql` tool parses incoming SQL and rejects anything that isn't a single `SELECT` / `WITH ... SELECT` statement (no `INSERT`/`UPDATE`/`DELETE`/`DROP`/`EXEC`/`MERGE`/`;` chaining).
3. All queries are issued with `SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED` to avoid blocking the ETL.

---

## 5. Common conventions across tools

### Period encoding

All tools accept periods in any of these forms; the server normalizes to CCYYMM internally:

| Input | Parsed as |
|-------|-----------|
| `"2025-04"` | 202504 |
| `"2025-04-30"` | 202504 |
| `202504` (int) | 202504 |
| `"202504"` (str) | 202504 |
| `"Q1 2025"` | 202501–202503 (ranges only on tools that accept a range) |
| `"YTD"` | 202501..current period (resolved against the latest `GB_DATE` in GLCAL) |

### Company / Division / Cost Center filters

All reports accept optional filters:
- `company` (string, e.g. `"01"`)
- `division` (string, e.g. `"01"`)
- `cost_center` (string, e.g. `"000"`)
- `branch` (string, where applicable)

If omitted, the report aggregates across all values of that dimension.

### Output shape

All tools return a structured object with at least:
```json
{
  "data": [ ... rows ... ],
  "meta": {
    "row_count": N,
    "truncated": false,
    "query_ms": 123,
    "as_of": "2026-05-19T15:00:00Z",
    "period": 202504,
    "filters": { "company": "01" }
  }
}
```

If `truncated=true`, the row count hit `GL_SQL_MAX_ROWS` — agent should refine filters.

### Sign convention

- P&L tools return `NetIncomeImpact` (revenues positive, expenses negative). Always sign-flipped — no raw `GB_AMT` for income-statement output.
- Balance-sheet tools return signed balances as stored (debits positive on assets/expenses, credits positive on liabilities/equity/revenue).
- `query_sql` returns raw values without flipping.

### Error model

| Condition | HTTP | MCP error |
|-----------|------|-----------|
| Bad params (period parse, unknown company) | 400 | `INVALID_PARAMS` |
| Auth missing / expired | 401 | `UNAUTHORIZED` |
| SQL syntax / disallowed statement | 400 | `INVALID_SQL` |
| DB timeout | 408 | `TIMEOUT` |
| DB connection failed | 503 | `DB_UNAVAILABLE` |
| Result over `MAX_ROWS` | 200 | success with `truncated=true` |

---

## 6. Tool inventory

### 6.1 Reporting tools (curated)

#### `income_statement`

**Purpose.** Return a P&L for a single period, with revenues and expenses grouped by `Section` from `v_IncomeStatementLines`.

**Parameters:**
| Name | Type | Required | Default |
|------|------|----------|---------|
| `period` | string/int | yes | — |
| `company` | string | no | all |
| `division` | string | no | all |
| `branch` | string | no | all |
| `detail` | enum `"summary"|"by_account"` | no | `"summary"` |

**Returns:**
- `"summary"`: one row per Section with totals, plus `total_net_income`.
- `"by_account"`: one row per account within each section, sorted by `SectionOrder` then `AccountNumber`.

**SQL strategy.** `SELECT … FROM dbo.v_IncomeStatementLines WHERE Period=? AND …` with optional `GROUP BY Section` for summary form.

---

#### `balance_sheet`

**Purpose.** Return a balance sheet as of period-end.

**Parameters:**
| Name | Type | Required | Default |
|------|------|----------|---------|
| `period` | string/int | yes | — |
| `company` | string | no | all |
| `detail` | enum `"summary"|"by_account"` | no | `"summary"` |
| `comparative` | enum `"none"|"prior_period"|"prior_year"` | no | `"none"` |

**Returns.** Asset / Liability / Equity sections with totals. If `comparative` is set, includes a second column for the comparison period plus $ and % variance.

**SQL strategy.** Join `dbo.GLCAL` to `dbo.ACCMAST` filtered by `ACTYP` for asset/liability/equity classes. Period-end balance for BS accounts. **⚠ Open question for implementation:** confirm whether `GB_AMT` for BS accounts is the running balance or the period activity — adjust the query accordingly. (P&L accounts are period activity.)

---

#### `trial_balance`

**Purpose.** Every active account with period-end balance; debits and credits totaled.

**Parameters:** `period`, `company?`, `division?`, `include_zero` (default `false`).

**Returns.** One row per `(company, division, cost_center, account, account_name)` with signed balance. Plus a footer row with totals to demonstrate `Σ debits = Σ credits`.

---

#### `pnl_by_section`

**Purpose.** Summary of `v_IncomeStatementLines` grouped by Section for a single period or a range. Faster than `income_statement(detail="summary")` when an agent just wants section totals.

**Parameters:** `period_start`, `period_end?` (default = `period_start`), `company?`, `division?`.

**Returns.** One row per Section with `NetImpact` for the range.

---

#### `yoy_comparison`

**Purpose.** Current period vs same period prior year.

**Parameters:** `period`, `company?`, `division?`, `min_variance_pct` (default `0`).

**Returns.** One row per account with `current`, `prior_year`, `$ variance`, `% variance`. Filter applied if `min_variance_pct` set.

---

#### `monthly_trend`

**Purpose.** Time series for one or more accounts.

**Parameters:**
| Name | Type | Required | Default |
|------|------|----------|---------|
| `account` | string | yes (single) | — |
| `company` | string | no | all |
| `division` | string | no | all |
| `from_period` | string/int | no | 12 months back from latest |
| `to_period` | string/int | no | latest |

**Returns.** One row per period with `Amount`. Includes summary stats (`min`, `max`, `mean`, `stdev`, `latest`) for quick characterization.

---

#### `alias_rollup`

**Purpose.** Roll up multiple GL accounts to their alias account (`COACMAST.CA_GLFA`) — matches the spreadsheet *"Alias Account"* column.

**Parameters:** `period`, `alias?` (if omitted, returns all aliases), `company?`, `division?`.

**Returns.** If `alias` supplied: detail (each underlying account contributing). If `alias` omitted: one row per alias with rolled-up amount.

---

#### `account_search`

**Purpose.** Find accounts by partial name or number.

**Parameters:** `query` (string), `company?`, `limit` (default 25, max 100).

**Returns.** Matching accounts with company, account, name, type. Useful as a first step before calling another tool that requires an exact account.

---

#### `account_activity`

**Purpose.** Every period an account had non-zero amount, plus summary stats.

**Parameters:** `account`, `company?`, `division?`, `cost_center?`, `from_period?`, `to_period?`.

**Returns.** Period-by-period rows + summary block (`first_seen`, `last_seen`, `total`, `count`, `mean`, `stdev`).

---

### 6.2 Operational tools

#### `load_status`

**Purpose.** Last successful load per table from `dbo.AcctLoadControl`.

**Parameters.** None.

**Returns.** One row per table with `LastSuccess`, `LastRowsCopied`, time-since-last-load, `last_attempt_status` (in case the most recent attempt failed but a prior succeeded).

---

#### `data_freshness`

**Purpose.** How current is each table — most recent `LastSeenUtc` on rows in each replicated table.

**Returns.** Per-table `latest_row_utc`, `seconds_since_latest`, and the latest period number present in `dbo.GLCAL`.

---

#### `period_coverage`

**Purpose.** What periods have data in GLCAL (min, max, count, gaps if any).

**Parameters:** `company?`, `division?`.

**Returns.** `min_period`, `max_period`, `distinct_period_count`, `gaps` (list of missing periods if the sequence isn't continuous).

---

### 6.3 Diagnostic tools

#### `intercompany_check`

**Purpose.** Net the "PREFIX BALANCING" accounts (e.g. `27400`) across companies / divisions — should be zero.

**Parameters:** `period`, `account` (default `"27400"`).

**Returns.** Per-company subtotal + grand total. Flags if grand total differs from zero by more than $0.01.

---

#### `unmapped_accounts`

**Purpose.** GL accounts that have activity in GLCAL but no `CA_GLFA` alias assigned in COACMAST — i.e. wouldn't show up correctly in an alias-grouped report.

**Parameters:** `period?` (default latest).

**Returns.** Accounts missing alias mappings, with their period activity amount.

---

#### `orphan_accounts`

**Purpose.** Accounts in GLCAL with no matching COACMAST row (referential integrity check).

**Returns.** List of orphan `(Co, Div, Acct, CC)` tuples.

---

### 6.4 Escape hatch

#### `query_sql`

**Purpose.** Run an ad-hoc `SELECT` for questions the curated tools can't answer.

**Parameters:**
| Name | Type | Required | Default |
|------|------|----------|---------|
| `sql` | string | yes | — |
| `limit` | int | no | 100 (max 10,000) |
| `timeout_seconds` | int | no | 30 (max 60) |

**Guardrails:**
1. Statement must parse as a single SQL statement (no `;` chaining except for whitespace-trailing).
2. Statement must start (after whitespace/comments) with `SELECT` or `WITH`.
3. Reject any statement containing — outside of string literals — any of: `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `DROP`, `ALTER`, `CREATE`, `TRUNCATE`, `EXEC`, `EXECUTE`, `GRANT`, `REVOKE`, `xp_`, `sp_` (allow `sp_executesql` only in special-cases — initially no).
4. `LIMIT` (`TOP`) injected automatically if the query has no `TOP` clause.
5. Read-only DB user (defense in depth).
6. Query timeout enforced server-side.

**Returns.** Columns + rows + meta. If the query parses but errors at the DB layer, the DB error message is surfaced with the offending SQL fragment.

**Description hint to the agent.** The tool description should explicitly instruct: *"Use this only when no curated tool fits. Prefer specific tools (`income_statement`, `balance_sheet`, etc.) when they apply — they're faster, safer, and have richer output. Use `query_sql` for novel ad-hoc questions or experimental analysis."*

---

## 7. Tool metadata (registration order + description guidance)

When registered with the MCP, tools should be listed in this order so the agent sees the high-level reports first:

1. `income_statement`
2. `balance_sheet`
3. `trial_balance`
4. `pnl_by_section`
5. `yoy_comparison`
6. `monthly_trend`
7. `alias_rollup`
8. `account_search`
9. `account_activity`
10. `load_status`
11. `data_freshness`
12. `period_coverage`
13. `intercompany_check`
14. `unmapped_accounts`
15. `orphan_accounts`
16. `query_sql` (last — to discourage default use)

Each tool description should include:
- One-line purpose
- Example invocation
- When to use vs alternatives ("for whole-period P&L, use `income_statement`; for a single section across multiple periods, use `pnl_by_section` with a range")

---

## 8. Caching

Optional, but recommended:
- Cache results in-process for 60s keyed by `(tool_name, params_hash)`.
- Invalidate on `load_status` showing a newer `LastSuccess` than the cached entry.
- Skip caching for `query_sql`.

Saves DB round-trips when an agent makes follow-up questions that hit the same report.

---

## 9. Deployment

Same pattern as `crystalcares-mcp`:

```bash
# Zip just server.py + requirements.txt at the zip root
powershell.exe -NoProfile -Command "Compress-Archive -Path 'server.py','requirements.txt' \
    -DestinationPath 'C:/Users/bradg/AppData/Local/Temp/crystal_gl_mcp.zip' -Force"

export PATH="/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin:$PATH"
az webapp deploy --resource-group CrystalCaresDev --name crystal-gl-mcp \
  --src-path "C:/Users/bradg/AppData/Local/Temp/crystal_gl_mcp.zip" --type zip
```

Initial provisioning (one-time):

```bash
# Create the web app on the existing plan
az webapp create --resource-group CrystalCaresDev --plan crystalcares-mcp-plan \
  --name crystal-gl-mcp --runtime "PYTHON:3.12"

# Enable managed identity and grant DB access
az webapp identity assign --resource-group CrystalCaresDev --name crystal-gl-mcp

# Then in the SQL DB:
# CREATE USER [crystal-gl-mcp] FROM EXTERNAL PROVIDER;
# ALTER ROLE db_datareader ADD MEMBER [crystal-gl-mcp];

# Set startup command
az webapp config set --resource-group CrystalCaresDev --name crystal-gl-mcp \
  --startup-file "uvicorn server:app --host 0.0.0.0 --port 8000"

# App settings (use the same pattern as crystalcares-mcp)
az webapp config appsettings set --resource-group CrystalCaresDev --name crystal-gl-mcp \
  --settings MCP_TRANSPORT=http MCP_AUTH_MODE=both \
             MCP_PUBLIC_URL=https://crystal-gl-mcp.azurewebsites.net \
             MCP_HOST=0.0.0.0 MCP_PORT=8000 WEBSITES_PORT=8000 \
             SCM_DO_BUILD_DURING_DEPLOYMENT=true \
             GL_SQL_SERVER=sql-prtsplan-prod-eastus-001.database.windows.net \
             GL_SQL_DATABASE=sqldb-acctdata-prod-eastus-001 \
             GL_SQL_AUTH=managed_identity \
             GL_SQL_TIMEOUT=30 GL_SQL_MAX_ROWS=10000
```

Then generate and set `MCP_BEARER_TOKEN`, `OAUTH_PASSCODE`, `MCP_JWT_SECRET` via:

```bash
NEW=$(C:/Python312/python.exe -c "import secrets; print(secrets.token_urlsafe(48))")
az webapp config appsettings set --resource-group CrystalCaresDev --name crystal-gl-mcp \
  --settings MCP_BEARER_TOKEN="$NEW"
```

---

## 10. Local development

Provide a `.mcp.json` entry for Claude Code:

```json
{
  "crystal-gl": {
    "command": "C:/Python312/python.exe",
    "args": ["./server.py"],
    "env": {
      "MCP_TRANSPORT": "stdio",
      "GL_SQL_SERVER": "sql-prtsplan-prod-eastus-001.database.windows.net",
      "GL_SQL_DATABASE": "sqldb-acctdata-prod-eastus-001",
      "GL_SQL_AUTH": "aad_token"
    }
  }
}
```

This lets a developer run the same `server.py` locally over stdio against the production DB using their own AAD token via `DefaultAzureCredential`.

---

## 11. Out of scope (initial release)

- Write operations of any kind.
- Tools against the paused IntelliDealerR1 DB (we don't want to keep it warm).
- Tools for tables not yet in the acctdata replica (parts, A/R, service, sales, etc.) — these get added after the corresponding ETL is extended (see [intellidealer-r1-schema.md](intellidealer-r1-schema.md)).
- Budget vs Actual, JE-line audit — blocked on source data.
- Chart generation / file output — return structured data, let the agent format it.

---

## 12. Future extensions

When the ETL pipeline is extended to replicate the next tier of tables, add these tools without rebuilding the server:

| New tools | Depends on |
|-----------|-----------|
| `ar_aging(as_of, customer?)` | `ARFILE`, `ARSTHD` replicated |
| `customer_balance(customer)` / `customer_search(name)` | `ARFILE` + `CMAS*` replicated |
| `parts_margin(period)` / `part_lookup(sku)` | `PARTMAST`, `PARTHIST` replicated |
| `service_labor(period)` / `technician_utilization(period, tech?)` | `WOH`, `WOLAB`, `WOTAH`/`WOTTM` replicated |
| `sales_detail(period)` / `salesperson_performance(period)` | `SALDET`, `SALORD`, `SALCOM` replicated |
| `bank_rec_summary(as_of)` | `BANKREC` replicated |
| `audit_log_search(date, user?, table?)` | `AUDIT` replicated |

Each addition is a new function with a `@tool` decorator + a SQL query — no plumbing changes.

---

## 13. Open questions for review

Before implementation, confirm:

1. **BS account balance semantics** — is `GLCAL.GB_AMT` for balance-sheet accounts a period-end running balance, or period activity? Affects the `balance_sheet` tool query. (Probably running balance, but worth verifying with one calculation.)
2. **Year-end flag handling** — `GB_YE='Y'` rows: should `income_statement` include them by default? Probably yes for stated numbers, no for operating numbers. Default behavior + override param needed.
3. **Multiple companies** — Crystal has multiple companies (e.g. `01`, `02`?). Should the default be "all" or "primary company"? Need to confirm.
4. **Managed Identity vs SQL auth** — preferred but requires a one-time DB grant. If access can't be arranged, fall back to a dedicated SQL login (e.g. `crystal_gl_mcp_reader`) with `db_datareader` only, separate from `crystalSQL`.
5. **Caching layer** — in-process is simplest; if multi-instance is ever needed, add Redis. Skipping for v1.
6. **Rate limiting** — needed? The MCP is private to authenticated agents, but `query_sql` could be abused. Defer until observed.
