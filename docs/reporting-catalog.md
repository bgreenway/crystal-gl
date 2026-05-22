# Crystal GL — Reporting Catalog

A fairly exhaustive list of useful accounting reports we can build from the Azure replica of Intellidealer GL data. Items marked **★** are highest-value / most-commonly-requested. Items marked **⚠** depend on data we may not currently have replicated (flagged inline).

For schema details, table descriptions, and the connection recipe, see [data-model.md](data-model.md).

---

## 0. Crystal's actual report formats (working spreadsheets in this folder)

Eight working spreadsheets exported from Intellidealer (May 2026) reveal the exact reporting structure Crystal already uses. These are the report shapes we should target with MCP tools, dashboards, and agent outputs — they're what the business reads today.

### Reports inventory

| Spreadsheet | Type | Shape | What it shows |
|-------------|------|-------|---------------|
| [Cash Today Summary.xlsx](Cash%20Today%20Summary.xlsx) | Chain-wide cash snapshot | 34 rows × 3 cols | Cash in Bank, Contracts in Transit, Vehicle A/R, **TOTAL CASH EQUIVALENTS**, New/Used Inventory, New Floor Plan, NEW NET EQUITY, Trade Payoffs, **NET CASH POSITION**, Factory Receivables |
| [Cash Detail.xlsx](Cash%20Detail.xlsx) | Cash detail by account | 73 rows × 3 cols | Account-by-account cash balances (Seacoast, PNC, Ameris, Financed Clearing, etc.) — one row per bank account with Co/CC composite ID |
| [Balance Sheet Summary.xlsx](Balance%20Sheet%20Summary.xlsx) | BS by location (summary) | 55 rows × 3 cols | Standard Assets / Liabilities / Equity sections, single column per location header. Example file is `TALLAHASSEE`. |
| [Balane Sheet Detail.xlsx](Balane%20Sheet%20Detail.xlsx) | BS by location (detail) | **32,542 rows** × 3 cols | Account-level detail underneath each BS line. Filename has a typo (*Balane*). |
| [Income Statement Summary.xlsx](Income%20Statement%20Summary.xlsx) | Departmental P&L (summary) | 84 rows × **20 cols** | 6-department layout: **Sales \| Service \| Parts \| Rental Dept \| Total Fixed \| Admin** with %, Current Month, Prior Month, Change, YTD, % columns. Standard Kubota DFS shape. |
| [Income Statement Detail.xlsx](Income%20Statement%20Detail.xlsx) | Departmental P&L (detail) | **8,727 rows** × 20 cols | Same column structure, account-level rows underneath each P&L line. |
| [Sales and Gross Summary.xlsx](Sales%20and%20Gross%20Summary.xlsx) | Branch × brand revenue | 160 rows × **43 cols** | **18 branches** across the columns, ~30+ equipment brands across the rows (Kubota, Mahindra, Takeuchi, JCB, Bobcat, Sany, Wacker Neuson, …) — revenue / COGS / margin per brand-branch combination. |
| Sales and Gross Detail.xls | Account-level sales detail | (older `.xls` format, 4.5 MB) | Per-document detail underneath the summary; probably one row per equipment unit sold. |

### What these artifacts reveal about Crystal

1. **18 retail branches**, not a single dealership. Branch names: *Deland, Leesburg, Parts Warehouse, Chiefland, Spring Hill, Ocala, Homosassa, Hastings, Palatka, Starke, Live Oak, Madison, Panama City, Tallahassee, Cairo, Jacksonville, Lecanto, Dothan*. Plus rolled-up totals: *Total Tractor, Total 00-09, Total 10-19*. Reports come in **per-branch flavors** as well as chain-wide.
2. **Multi-brand dealership**, not Kubota-only. Brands tracked separately in the Sales & Gross report: Kubota (primary), Mahindra, Takeuchi, JCB, Bobcat, Sany Compact, Sany Large, Wacker Neuson, and ~20 more.
3. **Standard 6-department P&L structure**: `Sales | Service | Parts | Rental Dept | Total Fixed | Admin`. *Total Fixed* is a subtotal of Service+Parts+Rental (the "Fixed Operations" recurring side of the business). This matches the **Kubota Dealer Financial Statement (DFS)** layout — Crystal almost certainly submits this same format to Kubota corporate.
4. **Detailed expense taxonomy.** The IS detail uses Crystal's full chart of accounts:
   - *Variable Expense* (one bucket)
   - *Personnel Expense*: Owners Compensation, Supervisory Compensation, Clerical Compensation, Other Salaries, Absentee Compensation, Payroll Taxes, Employee Benefits
   - *Semi-Fixed Expenses*: Company Vehicle Expenses, Transportation Credits, Other Supplies, Advertising, Policy Work, Data Processing, Outside Services, Telephone, Training Expense, Interest Floorplan, Interest Other, Other Semi-Fixed
   - *Fixed Expenses*: Rent, Amortization, Repairs-Buildings, Depreciation-Building, RE Taxes, Insurance, Mortgage Interest, Utilities, Other Taxes, Repairs-Equipment, Depreciation-Equipment, Other Fixed
   - *Operating Income → Other Income/Deductions → Net Income*
5. **Three columns Crystal expects in any P&L view**: Current Month, Prior Month (comparative), Year-to-Date.
6. **Crystal's BS treats branches as cost centers**, not standalone entities. The example Tallahassee BS shows TOTAL ASSETS = **−$145K** and `Due from Affiliates` = **−$4.2M** — only makes sense as a sub-unit operating through intercompany. **Whatever BS tool we build needs to support this branch-level view, not just a consolidated entity-level BS.**

### Implications for MCP tool design

These artifacts give us the exact target shapes for the high-value tools. Plan to add:

| MCP tool | Mirrors this report | Notes |
|----------|---------------------|-------|
| `cash_today_summary()` | [Cash Today Summary.xlsx](Cash%20Today%20Summary.xlsx) | Chain-wide cash position card |
| `cash_detail(company?, branch?)` | [Cash Detail.xlsx](Cash%20Detail.xlsx) | Bank-account-level rollforward |
| `balance_sheet(branch?, period)` | [Balance Sheet Summary.xlsx](Balance%20Sheet%20Summary.xlsx) | Per-branch BS; support `branch=None` for consolidated |
| `balance_sheet_detail(branch?, period)` | [Balane Sheet Detail.xlsx](Balane%20Sheet%20Detail.xlsx) | Account-level drill-down |
| `income_statement_dept(period, branch?, comparative?)` | [Income Statement Summary.xlsx](Income%20Statement%20Summary.xlsx) | 6-dept layout with Current/Prior/YTD columns |
| `income_statement_detail(period, branch?, dept?)` | [Income Statement Detail.xlsx](Income%20Statement%20Detail.xlsx) | Account rows under each dept |
| `sales_and_gross(period, branch?, brand?)` | [Sales and Gross Summary.xlsx](Sales%20and%20Gross%20Summary.xlsx) | Brand × Branch revenue/COGS/margin grid |
| `kubota_dfs(period)` | [Income Statement Summary.xlsx](Income%20Statement%20Summary.xlsx) (alias) | Same data, framed as the Kubota DFS submission |

Each of these is a deterministic SQL aggregation over the existing replica — no new ETL needed.

### Open question — data freshness in the spreadsheets

These spreadsheets were generated **on or near 2026-05-22** (file timestamps) and show YTD numbers consistent with **data through April 2026**. The Income Statement Summary explicitly labels the comparative column `PRIOR MO (Apr26-Apr26)`. But our GL replica's most recent period is **January 2026** (see [data-model.md](data-model.md#etl--dboacctloadcontrol)).

That means either:
- Crystal has closed Feb / Mar / Apr 2026 in Intellidealer **since our last ETL run (2026-05-14)**, so a fresh ETL invocation would pull them, OR
- These spreadsheets were generated from a different Intellidealer instance / snapshot we're not replicating.

Worth confirming — if the AS/400 source now has data through April, **re-running the AcctLoadControl pipeline should bring the replica current** without any code changes.

---

## 1. Core Financial Statements

- **★ Income Statement (P&L) — Kubota DFS format** — the 6-department layout (`Sales | Service | Parts | Rental | Total Fixed | Admin`) with `Current Month | Prior Month | YTD` columns. Mirrors [Income Statement Summary.xlsx](Income%20Statement%20Summary.xlsx). The detail variant ([Income Statement Detail.xlsx](Income%20Statement%20Detail.xlsx)) drops account-level rows under each dept.
- **★ Balance Sheet — by branch** — Crystal runs BS at the branch level, not just consolidated; the per-branch view shows intercompany via `Due from Affiliates` (often a large negative for satellite branches). Mirrors [Balance Sheet Summary.xlsx](Balance%20Sheet%20Summary.xlsx) (summary) and [Balane Sheet Detail.xlsx](Balane%20Sheet%20Detail.xlsx) (account-level). Need a `branch=None` mode for consolidated.
- **★ Trial Balance** — every active account with period-end balance. Sanity check: debits = credits.
- **Statement of Retained Earnings** — beginning RE + net income − distributions = ending RE.
- **Statement of Cash Flows (indirect)** — derived from net income + non-cash + working-capital changes.
- **Comparative Financial Statements** — current period / prior period / prior year side-by-side for all three statements.

---

## 2. Time-Series & Trend Reports

- **★ 12-month rolling P&L** — month-by-month columns for the trailing 12 months (one row per P&L account; matches the spreadsheet pivot).
- **Year-over-year monthly comparison** — current month vs same month prior year, with $ and % variance.
- **Quarterly Summary** — Q1 / Q2 / Q3 / Q4 totals by year.
- **Period / YTD / Prior YTD** — three-column standard management report.
- **5-year trended P&L (from GLFIS)** — strategic review of major-account movements.
- **Seasonality profile by account** — average % of annual total by month for each account (useful for forecasting and anomaly detection).
- **Run-rate annualization** — YTD × 12 / N projected to year-end.

---

## 3. Departmental / Profit-Center Reporting

Crystal's actual departmental structure (from [Income Statement Summary.xlsx](Income%20Statement%20Summary.xlsx)): **Sales · Service · Parts · Rental · Total Fixed (= Service + Parts + Rental) · Admin**. Build tools against this exact taxonomy.

- **★ P&L by Department** — the 6-bucket Kubota DFS layout (see Section 1).
- **★ Branch scorecard (all 18 locations)** — revenue, gross margin, opex, net by branch. Branch list: Deland, Leesburg, Parts Warehouse, Chiefland, Spring Hill, Ocala, Homosassa, Hastings, Palatka, Starke, Live Oak, Madison, Panama City, Tallahassee, Cairo, Jacksonville, Lecanto, Dothan. Use `v_IncomeStatementLines.Branch`.
- **P&L by Cost Center** — finer-grained than department (the `CC` dimension across GLCAL / DEPTMAST / COACMAST).
- **Departmental contribution margin** — revenue − direct costs by department.
- **Cross-division allocation analysis** — overhead pushed between departments.
- **Department × Branch matrix** — every department side-by-side across every branch for the same period (full Crystal scorecard).

---

## 4. Variance & Budget Analysis

- **Month-over-month variance** — % and absolute change per account; sort by largest movers.
- **★ Year-over-year variance** — same period this year vs last; flag accounts ± N %.
- **Anomaly detection** — accounts where current month is N standard deviations from trailing-12 mean.
- **Budget vs Actual** — **⚠ requires a budget table** (not in the current 5 tables; needs sourcing).
- **Forecast vs Actual** — **⚠ same dependency.**
- **Large balance change alerts** — flag any account where month-over-month $ change exceeds a threshold.

---

## 5. Dealer-Specific Operational Reports

Crystal is a **multi-brand equipment dealer** across 18 retail locations. From [Sales and Gross Summary.xlsx](Sales%20and%20Gross%20Summary.xlsx) the tracked brands include: **Kubota (primary), Mahindra, Takeuchi, JCB, Bobcat, Sany Compact, Sany Large, Wacker Neuson**, and ~20 more (123 row labels total). Tools should support `brand` as a top-level dimension alongside branch.

- **★ Sales and Gross by brand × branch** — the YTD revenue / COGS / gross margin matrix from [Sales and Gross Summary.xlsx](Sales%20and%20Gross%20Summary.xlsx). 18 branches × ~30 brands. Detail variant: per-unit account-level from [Sales and Gross Detail.xls](Sales%20and%20Gross%20Detail.xls).
- **★ Wholegoods inventory turns** — Inventory of Wholegoods (acct `12000`, alias `F231`) balance trend vs Cost of New Equipment Sold. Days-on-lot. [Cash Today Summary.xlsx](Cash%20Today%20Summary.xlsx) tracks `NEW/USED TRACTORS` ($46.9M) and `NEW FLOOR PLAN` (-$38.4M) as headline numbers.
- **★ Floorplan / Net Equity card** — *NEW NET EQUITY* = inventory − floor plan. Crystal tracks this prominently on [Cash Today Summary.xlsx](Cash%20Today%20Summary.xlsx) ($8.55M as of late-April-2026). Plus `NET CASH POSITION` ($14.2M).
- **★ Cash position snapshot** — chain-wide: Cash in Bank + Contracts in Transit + Vehicle A/R = TOTAL CASH EQUIVALENTS. Mirrors [Cash Today Summary.xlsx](Cash%20Today%20Summary.xlsx).
- **★ Equipment sales performance** — New vs Used; per brand; revenue, COGS, gross margin per unit category. Crystal's blended Kubota margin runs ~11% based on the current YTD numbers ($14.2M margin / $130M Kubota revenue).
- **★ Parts department metrics** — parts inventory turn, parts COGS vs parts revenue, parts margin %.
- **★ Service department labor recovery** — labor sold vs labor cost; effective billing rate; technician utilization (financial proxy).
- **★ Rental fleet performance** — rental revenue vs rental depreciation (`CA_GLWA` accounts) vs net book value.
- **★ Floorplan analysis** — Floorplan Payable (alias `F310`, acct `20350`) balance vs Floorplan Interest Expense vs Wholegoods Inventory; coverage ratio.
- **Cost-of-Sales analysis** — actual COGS % vs `CA_GLCP` default (per-account expected COGS %).
- **Inventory accrual aging** — `CA_IAA` (inventory accrual account) balance over time; should clear within N days of receipt.
- **Used equipment write-down exposure** — used inventory balance vs market.
- **CNH alias rollup** — accounts grouped by `CA_CNHA` for CNH dealer reporting.
- **Kubota DFS-format report** — the 6-dept P&L matching [Income Statement Summary.xlsx](Income%20Statement%20Summary.xlsx). Crystal almost certainly submits this format to Kubota corporate periodically.
- **Per-brand DFS** — same Kubota DFS shape but filtered to each manufacturer (Mahindra, JCB, Takeuchi, etc.) for parallel reporting to other OEMs.

---

## 6. Working-Capital & Liquidity

- **Cash position** — all cash accounts (`ACCT='Y'` cash type) over time. The bank columns `CA_BRT` / `CA_BAC` give routing / account info per cash account.
- **★ A/R aging summary** — **⚠ requires sub-ledger detail** (only aggregate balances here; sub-ledger sequence lives in `CA_SLS` / `CA_SLC`).
- **★ A/P aging summary** — **⚠ same.**
- **Net working capital trend** — current assets − current liabilities over time.
- **Quick ratio / Current ratio** — monthly.
- **MyDealer A/R balances** — `CA_EAR` flagged accounts.

---

## 7. Account-Level Diagnostics & Cleanup

- **Activity report for a single account** — every month the account had non-zero amount, across years.
- **Top N accounts by absolute balance** — useful for materiality reviews.
- **Top N accounts by month-over-month movement** — flush out the big drivers.
- **Zero-activity accounts** — active accounts (`ACSTA <> 'D'`) with no movement in N months → cleanup candidates.
- **Deleted accounts with non-zero balances** — exception report (`ACSTA='D'` but balance ≠ 0).
- **Memo account audit** — `ACMEM` flagged accounts should not feed financial totals.
- **Status='D' coverage** — what % of each master is deleted; trend over time.
- **Orphan accounts in GLCAL** — `GB_*` keys with no matching COACMAST row.
- **Orphan accounts in ACCMAST** — accounts in dictionary but never used in GLCAL.

---

## 8. Alias / External Reporting Mapping

- **★ Alias-grouped P&L** — group by `CA_GLFA` to match the spreadsheet *Alias Account* column / external reporting buckets.
- **Alias coverage report** — % of GL balance that has a `CA_GLFA` assigned; flag unmapped accounts.
- **Alias drill-down** — for a given alias (e.g. `F231`), list every underlying GL account contributing.
- **CNH alias mapping audit** — same for `CA_CNHA`.
- **Multi-alias account discovery** — same GL account mapped to different aliases across cost centers (likely intentional but worth flagging).

---

## 9. Intercompany / Multi-Entity

- **★ Intercompany balancing audit** — accounts like `27400` ("PREFIX BALANCING") should net to zero across companies / divisions; flag imbalances.
- **CMCC Intercompany Transfer audit** — acct `10180` net flows.
- **Inter-division allocation reconciliation** — division-level pushes / pulls net to zero company-wide.
- **Company-level consolidated P&L** — sum across all companies after intercompany elimination.

---

## 10. Audit / Compliance / Period-Close

- **Year-end adjustments report** — `GB_YE='Y'` rows broken out by account.
- **Pre-close vs post-close comparison** — flag any movement after the year-end flag is set.
- **Period close checklist** — for each period, list of accounts requiring sign-off.
- **Unusual journal indicators** — round-number amounts, weekend posting dates, repeated reversals — **⚠ partial; we have monthly balances not JE-level detail. Recommend confirming whether JE detail is in another Intellidealer table not yet replicated.**
- **Audit trail** — `UPDATE_IDENT` / `LastRunId` / `LastSeenUtc` give a limited replica-side audit trail.

---

## 11. Data Quality & ETL Monitoring

- **★ Load health dashboard** — `dbo.AcctLoadControl` last-N runs, status, rows, duration.
- **Source-vs-replica row count check** — verify replica matches source for each table.
- **Period completeness** — for each Co / Div, are all expected periods present in GLCAL?
- **Refresh staleness** — how old is the most recent data per table.
- **Load duration trend** — flag growing load times.
- **Failed load investigation** — list of FAILED runs with error messages.

---

## 12. Forecasting & Predictive

- **Trailing 12-month run-rate** — annualized projection per account.
- **Seasonality-adjusted forecast** — apply month-of-year seasonality % to YTD to project full year.
- **Growth-rate forecast** — apply CAGR from GLFIS to extrapolate.
- **Cash runway** — months of cash at current burn rate.
- **Inventory turn forecast** — project wholegoods turn vs sales pipeline.

---

## 13. Executive / Dashboard / KPIs

- **★ CFO single-page dashboard** — revenue, gross margin %, opex %, EBITDA, working capital, cash, AR/AP, top 5 movers.
- **Daily / weekly flash report** — incremental revenue and key accounts posted since last report.
- **Net Income Bridge / Waterfall** — prior period net income → current period, decomposed by section.
- **Margin walk** — gross margin % decomposition by product line / department.

---

## 14. Agent-Friendly Natural-Language Queries

These map well to LLM-driven agents because they're parameterizable:

- "Show me [account] over the last [N] months"
- "What was [section] for [period] compared to [period]?"
- "Which accounts moved more than [%] vs last month?"
- "Summarize the P&L for [period] in plain English"
- "Why did [metric] change between [period1] and [period2]?" — drill-down agent
- "Build a P&L for division [X] for [year]"
- "What's the YTD net income vs prior YTD?"
- "Find any accounts that look unusual this period"
- "Reconcile [account A] against [account B]"
- "Generate the Kubota DFS for [period]"

---

## Data availability — the three-tier picture

After surveying the paused [IntelliDealerR1](intellidealer-r1-schema.md) DB (May 2026), we know which "blocked" items in the catalog have source tables available and which are truly missing.

### Tier 1 — already replicated in the current acctdata DB

The 5 GL tables: ACCMAST, COACMAST, DEPTMAST, GLCAL, GLFIS. Covers ~70% of the catalog. See [data-model.md](data-model.md).

### Tier 2 — schema known and available; data needs fresh replication

Tables that exist in IntelliDealerR1 (verified-accurate schema, but data is paused at 2025-12-11). Replicating these into acctdata or a new DB would push coverage to ~90%:

| Category | Tables | Unlocks |
|----------|--------|---------|
| A/R sub-ledger | `ARFILE`, `ARSTHD`, `ARSTHH` | A/R aging summary, customer balances, DSO |
| Parts | `PARTMAST`, `PARTHIST`, `PARTPRC` (+16 others) | Per-SKU margin, inventory turn, slow-moving parts |
| Service / WO | `WOH`, `WOLAB`, `WOTAH`, `WOTTM` (+8 others) | Technician utilization, service labor recovery |
| Sales transactions | `SALDET`, `SALORD`, `SALCOM` | Per-transaction margin, salesperson performance |
| Customer master | `CMAS*` family (~14 tables) | Customer 360, profitability |
| Purchase orders | 12 PO* tables | Vendor patterns, partial A/P aging proxy |
| Bank reconciliation | `BANKREC` | Bank rec automation |
| Audit log | `AUDIT` | Partial user-level audit trail |
| Employee (limited) | `EMPLOYEE`, `EMPSEC`, `EMLHDR`, `PRUCONT` | Headcount KPIs, technician mapping |

### Tier 3 — truly missing (need separate sourcing or not in our environment)

- **Wholegoods / equipment unit master** — no `WG*`/`MACH*`/`EQUIP*` tables found in either DB. Per-unit days-on-lot and per-unit equipment margin remain blocked. Possibly under a different name in Intellidealer; worth a targeted search.
- **Rental fleet tables** — no `RE*`/`RNT*` tables. May not be in Crystal's Intellidealer footprint at all.
- **Journal-entry line detail** — GLCAL is monthly balance only. No GLTRANS-style table in IDR1. Unusual-JE detection and full posting audit remain blocked.
- **Full A/P sub-ledger / vendor master** — only 2 thin AP control tables exist; no APMAST/APHIST/Vendor master. A/P aging by vendor remains blocked. `POBILL` is a partial proxy.
- **Budget / Forecast** — no budget tables anywhere. Crystal likely manages these in Excel — separate sourcing required.
