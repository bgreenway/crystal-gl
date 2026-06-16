# Crystal Tractor — Accounting Data Pipeline + MCP Server

Crystal Tractor's general-ledger data — replicated from Intellidealer (IBM i / Db2 for i) into Azure SQL, queryable through curated tools and a live MCP server, with reproducible PDF report generators.

```
   Intellidealer (AS/400 source)              ┌─ docs/intellidealer-reports/ (8 reference PDFs)
        │                                     │
   Azure Data Factory (4×/day + daily)        │
        │                                     │
        ▼                                     │
   sqldb-acctdata-prod-eastus-001     ◄───── (verified to-the-dollar)
        │
        ├─ dbo.GLCAL / GLFIS / ACCMAST / COACMAST / DEPTMAST  (closed-period GL)
        ├─ dbo.YTDJRL  (journal-line postings, append-only)
        └─ dbo.YTDIST  (A/P vendor invoice distributions)
              │
              ├──► MCP/server.py  ──► https://crystal-gl-mcp.azurewebsites.net/mcp
              │       (16 tools: income_statement, balance_sheet_v2, pnl_through,
              │        ap_analysis, dfs_departmental, cash_flow, branch_list,
              │        period_coverage, load_status, query_sql, ...)
              │
              └──► scripts/reports/  ──► PDF reports
                      (BS, IS, Cash Flow, DFS Departmental, A/P Analysis)
```

## Live MCP server

The Crystal GL data is queryable directly via MCP at:

**`https://crystal-gl-mcp.azurewebsites.net/mcp`**

Auth: Bearer token OR OAuth flow (server is configured for both). Tools are documented in their docstrings; key ones:

- `income_statement(period, ...)` — closed-period P&L from `v_IncomeStatementLines`
- `pnl_through(through=YYYYMMDD)` — P&L for any date including unclosed months (uses YTDJRL roll-forward)
- `balance_sheet_v2(period=..., through=...)` — BS for any date; defaults to live `COACMAST.CA_CUR`
- `cash_flow(year, through=...)` — Indirect-method SCF
- `dfs_departmental(year)` — Kubota DFS 5-column departmental P&L
- `ap_analysis(period_from, period_to)` — A/P spend + top vendors from YTDIST
- `branch_list()` — code↔name lookup for the 18 Crystal branches
- `period_coverage()`, `load_status()` — replica freshness checks
- `query_sql(sql)` — read-only escape hatch

## CLI report generators

Reproducible PDF reports in [`scripts/reports/`](scripts/reports/):

| Script | Generates | Default |
|---|---|---|
| [`ap_analysis.py`](scripts/reports/ap_analysis.py) | A/P spend, top vendors, concentration, aging, anomalies, YTDJRL recon | YTD current year |
| [`income_statement.py`](scripts/reports/income_statement.py) | Consolidated P&L with CFO v2 sections, EBITDA, branch filter | Live YTD current year |
| [`balance_sheet.py`](scripts/reports/balance_sheet.py) | BS with CFO v2 layout (Cash split, Reserves, Intercompany), NI roll-in | Live `CA_CUR` |
| [`cash_flow.py`](scripts/reports/cash_flow.py) | Indirect-method SCF with reconciliation residual | Live YTD current year |
| [`dfs_departmental.py`](scripts/reports/dfs_departmental.py) | 7-column Kubota DFS dept P&L | Live YTD current year |

All accept `--period YYYYMM` (historical) or `--through YYYYMMDD` (YTD through a specific date) or `--year YYYY`. See [`scripts/reports/README.md`](scripts/reports/README.md) for full flag reference.

```sh
az login                                  # one-time, refreshes for 30 days
cd scripts/reports
python ap_analysis.py                     # YTD current year A/P analysis
python income_statement.py --year 2025    # 2025 full-year P&L
python balance_sheet.py --through 20260415  # BS rolled forward to Apr 15
```

## Documentation

| Doc | What it covers |
|---|---|
| [`docs/data-model.md`](docs/data-model.md) | The five GL summary tables + YTDJRL/YTDIST, sign conventions, CC encoding, COACMAST balance-field semantics |
| [`docs/journal-line-etl-spec.md`](docs/journal-line-etl-spec.md) | YTDJRL ETL — STATUS: DEPLOYED. Source DDL + verification tests |
| [`docs/ytdist-etl-spec.md`](docs/ytdist-etl-spec.md) | YTDIST ETL — STATUS: DEPLOYED. A/P vendor-invoice detail |
| [`docs/intellidealer-reconciliation.md`](docs/intellidealer-reconciliation.md) | How our data matches/diverges from Intellidealer reports — 6 classified explanations, verification queries, what `YJ_UID` actually means |
| [`docs/cfo-feedback-2026-05-28.md`](docs/cfo-feedback-2026-05-28.md) | CFO Steven's markup of v1 reports → 27 v2 restructure actions, open items |
| [`docs/reporting-catalog.md`](docs/reporting-catalog.md) | What each Intellidealer table contains; tier-1 / tier-2 / tier-3 classification |
| [`docs/mcp-server-spec.md`](docs/mcp-server-spec.md) | MCP server design |
| [`docs/azure-infrastructure.md`](docs/azure-infrastructure.md) | Azure SQL server + App Service config |
| [`docs/intellidealer-reports/`](docs/intellidealer-reports/) | 8 reference PDFs from Crystal — used to verify our numbers match |

## Database access

```
Server   sql-prtsplan-prod-eastus-001.database.windows.net
Database sqldb-acctdata-prod-eastus-001
Auth     Azure AD (`az login` locally; Managed Identity in Azure)
```

Key tables in `dbo` schema:

| Table | Role |
|---|---|
| `GLCAL` | Monthly closed-period GL balances. P&L = monthly activity; BS = period-end running balance |
| `GLFIS` | Annual rollup |
| `ACCMAST` | Chart of accounts dictionary |
| `COACMAST` | COA with balance aggregates. **`CA_CUR` is the live current-state field** — includes unclosed-period activity |
| `DEPTMAST` | Wide 24-bucket COA-by-CC rollup |
| `YTDJRL` | **Canonical journal-line postings** (1.8M rows; append-only via YJ_UID watermark) |
| `YTDIST` | **A/P vendor-invoice distributions** (1.8M rows; FULL_RELOAD + MERGE on natural PK) |
| `v_IncomeStatementLines` | Pre-joined P&L reporting view over GLCAL + ACCMAST |

## SQL package

[`sql/`](sql/) holds version-controlled SQL for the ETL extensions we worked on:

- `11_ytdjrl_deployed.sql` — `dbo.YTDJRL` + `stg.YTDJRL` + `sp_Acct_Insert_YTDJRL` (deployed state captured for documentation)
- `12_ytdist_deployed.sql` — same for YTDIST
- `07-10_*.sql` — earlier 5-table journal-line draft, superseded by YTDJRL but kept as reference patterns

The five base GL summary tables (ACCMAST/COACMAST/DEPTMAST/GLCAL/GLFIS) plus their ETL procs were built by Crystal's ETL team — the SQL for those isn't in this repo.

## Cost-center encoding

Crystal's 3-digit cost centers encode **dept (leading digit) + branch (trailing 2 digits)**:

| Dept | Branch suffix |
|---|---|
| `0` BS / Corp | `01` Deland · `02` Leesburg · `03` Parts Warehouse · `04` Chiefland |
| `1` Admin     | `05` Spring Hill · `06` Ocala · `07` Homosassa · `08` Hastings |
| `2` Sales     | `09` Palatka · `10` Starke · `11` Live Oak · `12` Madison |
| `3` **Parts** | `13` Panama City · `14` Tallahassee · `15` Cairo · `16` Jacksonville |
| `4` **Service** | `17` Lecanto · `18` Dothan |
| `5` Rental    | `93` Wholesale (HD/CMCC) · `95` Corporate · `91` Other |
| `6` Used      |  |

(Parts=3, Service=4 — was originally inverted in code; corrected 2026-06-01 after Intellidealer reconciliation surfaced the bug.)

## Recent work history

| Date | Milestone |
|---|---|
| 2026-05-22 | Initial data-model documentation, balance sheet design, repo set up |
| 2026-05-27 | Branch + dept CC encoding verified against Sales and Gross Summary spreadsheet |
| 2026-05-28 | CFO Steven returns v1 markups — 27 v2 restructure actions documented |
| 2026-05-31 | YTDJRL ETL extension drafted, schema received, deployed same day, gap closed |
| 2026-05-31 | YTDIST ETL extension drafted, schema received, deployed same day |
| 2026-06-01 | Live MCP server deployed to Azure App Service; 5 report generators reproducible via CLI + MCP |
| 2026-06-01 | Intellidealer reconciliation against 8 reference PDFs — every diff classified + explained |
| 2026-06-03 | April $6M Intellidealer gap closed (HD intercompany eliminations posted on source) |

## Contact

Brad Greenway · `brad.greenway@me.com`
