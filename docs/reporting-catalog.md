# Crystal GL — Reporting Catalog

A fairly exhaustive list of useful accounting reports we can build from the Azure replica of Intellidealer GL data. Items marked **★** are highest-value / most-commonly-requested. Items marked **⚠** depend on data we may not currently have replicated (flagged inline).

For schema details, table descriptions, and the connection recipe, see [data-model.md](data-model.md).

---

## 1. Core Financial Statements

- **★ Income Statement (P&L)** — by period, YTD, with prior-year comparison. `v_IncomeStatementLines` grouped by `Section` / `SectionOrder`.
- **★ Balance Sheet** — period-end snapshot. Asset / Liability / Equity accounts (filter by `ACCMAST.ACTYP`), with comparative columns (current vs prior month, vs prior year-end).
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

- **★ P&L by Division** — separates dealership business lines (parts, service, wholegoods, rental).
- **P&L by Cost Center** — finer-grained than division (the `CC` dimension across GLCAL / DEPTMAST / COACMAST).
- **Departmental contribution margin** — revenue − direct costs by department.
- **Branch / location scorecard** — revenue, gross margin, opex, net by branch (`v_IncomeStatementLines.Branch`).
- **Cross-division allocation analysis** — overhead pushed between departments.
- **Department comparison matrix** — every department side-by-side for the same period.

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

This is where Crystal's business (Kubota / CNH dealer) shows up:

- **★ Wholegoods inventory turns** — Inventory of Wholegoods (acct `12000`, alias `F231`) balance trend vs Cost of New Equipment Sold. Days-on-lot.
- **★ Equipment sales performance** — New vs Used; Kubota vs CNH; revenue, COGS, gross margin per unit category.
- **★ Parts department metrics** — parts inventory turn, parts COGS vs parts revenue, parts margin %.
- **★ Service department labor recovery** — labor sold vs labor cost; effective billing rate; technician utilization (financial proxy).
- **★ Rental fleet performance** — rental revenue vs rental depreciation (`CA_GLWA` accounts) vs net book value.
- **★ Floorplan analysis** — Floorplan Payable (alias `F310`, acct `20350`) balance vs Floorplan Interest Expense vs Wholegoods Inventory; coverage ratio.
- **Cost-of-Sales analysis** — actual COGS % vs `CA_GLCP` default (per-account expected COGS %).
- **Inventory accrual aging** — `CA_IAA` (inventory accrual account) balance over time; should clear within N days of receipt.
- **Used equipment write-down exposure** — used inventory balance vs market.
- **CNH alias rollup** — accounts grouped by `CA_CNHA` for CNH dealer reporting.
- **Kubota DFS-format report** — alias-grouped P&L matching Kubota's dealer financial statement layout (`CA_GLFA`).

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
