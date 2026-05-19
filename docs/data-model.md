# Crystal GL Data Model — Source, Replication, and Working Files

A self-contained guide tying together the artifacts in this folder, the Azure SQL replica of Intellidealer's GL tables, and the working spreadsheets. The goal is to enable writing SQL queries and building agents on top of this data.

---

## TL;DR

| Layer | Where | What |
|------|-------|------|
| **Source system** | Intellidealer (AS/400 / IBM i, Db2 for i), schema `PFWF0125` | Dealer management system — 5 GL tables described in [Intellidealer files system.pdf](Intellidealer%20files%20system.pdf) and [Intellidealer system flow chart.pdf](Intellidealer%20system%20flow%20chart.pdf) |
| **DDL exports** | [`*_DDL.sql`](.) in this folder | Schema-only dumps from Intellidealer (V7R5M0, generated 2026-05-14) — authoritative column definitions |
| **Azure replica** | `sql-prtsplan-prod-eastus-001.database.windows.net` / `sqldb-acctdata-prod-eastus-001`, schema `dbo` | Full row-for-row replica of the 5 tables, plus `stg.*` staging copies, `AcctLoadControl` (ETL log), `v_IncomeStatementLines` (reporting view) |
| **Working spreadsheets** | `*.xlsx` in this folder | Human-friendly extracts/pivots of the same data — see [Working files](#working-files) below |
| **Infra notes** | [azure-infrastructure.md](azure-infrastructure.md) | All Azure resources, creds, deploy commands |
| **Wider schema reference** | [intellidealer-r1-schema.md](intellidealer-r1-schema.md) | Paused IntelliDealerR1 DB — verified-accurate schema for ~200 additional source tables (A/R, parts, service, sales, customer master, etc.). Data is stale; schema is reliable. |

**Access:** AAD auth (`brad.greenway@me.com`) works against the Azure DB. See [Connection recipe](#connection-recipe).

---

## The five GL tables

All five share a dimensional spine of **Company → Division → Cost Center → Account**. The DDLs use IBM i 6-char short-name columns (e.g. `ACACC`) with SQL-style long aliases (`AC_ACC`) — the Azure replica keeps the short names.

### 1. ACCMAST — Account Master ([ACCMAST_DDL.sql](ACCMAST_DDL.sql))

The dictionary of account numbers and their names.

| Column | Type | Meaning |
|--------|------|---------|
| `ACSTA` | char(1) | Status (`D` = deleted/inactive, blank = active) |
| `ACCO` | char(2) | **Company** |
| `ACACC` | char(5) | **Account number** (5-digit, e.g. `10100`) |
| `ACNME` | char(30) | Account name (e.g. *"Seacoast Checking Acct - 9381"*) |
| `ACTYP` | char(1) | Account type |
| `ACLIA` | char(1) | Liability code |
| `ACMEM` | char(1) | Memo account code |
| `ACCT` | char(1) | Cash type |
| `ACLT` | char(2) | Labor type |
| `ACGRP` | char(5) | Report grouping code |
| `AC_MCR` | char(4) | MC ratio codes |
| `AC_ET` | char(1) | Expense type |

**Primary key:** `(ACCO, ACACC)` — 809 rows in Azure.

### 2. COACMAST — Chart of Accounts ([COACMAST_DDL.sql](COACMAST_DDL.sql))

Validates which Company / Cost Center / Account / Division combinations exist, and stores GL mapping fields including the **alias account** used by external reporting.

Key columns:

| Column | Type | Meaning |
|--------|------|---------|
| `CA_STA` | char(1) | Status |
| `CA_CO` | char(2) | **Company** |
| `CA_CC` | char(3) | **Cost Center** |
| `CA_ACC` | char(5) | **Account Number** |
| `CA_DIV` | char(2) | **Division** |
| `CA_GLFA` | char(5) | **Alias Account** — friendly grouping code (e.g. `F202`, `F202A`) |
| `CA_CNHA` | char(6) | CNH alias account |
| `CA_GLIC` / `CA_GLIA` | | Parts inventory cost-center / account |
| `CA_GLCC` / `CA_GLCA` | | Cost-of-sales cost-center / account |
| `CA_GLCP` | dec(5,3) | Cost-of-sales default % |
| `CA_GSC2..8` / `CA_GSA2..8` | | Sale cost-center / account by cash code (2,3,5,7,8) |
| `CA_GLC1..4` / `CA_GLA1..4` | | Sale cost-center / account by pricing level (1–4) |
| `CA_GLWC` / `CA_GLWA` | | Rental depreciation cost-center / account |
| `CA_EAR`, `CA_EWG` | | MyDealer A/R / equipment accounts |
| `CA_IAC` / `CA_IAA` | | Inventory accrual cost-center / account |
| `CA_BRT`, `CA_BAC` | | Bank routing # / account # |
| `CA_YTD`, `CA_CUR`, `CA_L12` | dec(13,2) | YTD amount, current YTD balance, last 12 months |

**Primary key:** `(CA_CO, CA_CC, CA_ACC, CA_DIV)` — 11,140 rows in Azure.

### 3. DEPTMAST — Departmental Master ([DEPTMAST_DDL.sql](DEPTMAST_DDL.sql))

Pre-aggregated 12-month buckets per Co/Div/CC/Account. Each row carries **current-year months 1–12 (`DPC1`..`DPC12`)** and **last-year months 1–12 (`DPL1`..`DPL12`)**.

| Column | Type | Meaning |
|--------|------|---------|
| `DP_CO` | char(2) | **Company** |
| `DP_DIV` | char(2) | **Division** |
| `DP_CC` | char(3) | **Cost Center** |
| `DP_ACC` | char(5) | **Account Number** |
| `DPC1`..`DPC12` | dec(13,2) | Current-year month buckets |
| `DPL1`..`DPL12` | dec(13,2) | Last-year month buckets |
| `DP_AL` | char(1) | Asset / Liability flag |
| `DP_GRP` | char(3) | Group work field |
| `DP_STA` | char(1) | Status |

**Primary key:** `(DP_CO, DP_DIV, DP_CC, DP_ACC)` — 4,835 rows in Azure.

### 4. GLCAL — G/L Calendar Month-End Balances ([GLCAL_DDL.sql](GLCAL_DDL.sql))

The atomic monthly balance fact. One row per Co/Div/CC/Acct **per month**.

| Column | Type | Meaning |
|--------|------|---------|
| `GB_STA` | char(1) | Status |
| `GB_CO` | char(2) | **Company** |
| `GB_DIV` | char(2) | **Division** |
| `GB_GLA` | char(5) | **Account Number** |
| `GB_GLC` | char(3) | **Cost Center** |
| `GB_DATE` | numeric(6,0) | **Period as CCYYMM** (e.g. `202504`) |
| `GB_AMT` | dec(13,2) | Amount |
| `GB_YE` | char(1) | Year-end flag |

**Primary key:** `(GB_CO, GB_DIV, GB_GLA, GB_GLC, GB_DATE)` — 188,713 rows in Azure (largest table; this is the fact table).

### 5. GLFIS — G/L Fiscal History ([GLFIS_DDL.sql](GLFIS_DDL.sql))

Annual rollup of GLCAL with 12 month buckets per fiscal year.

| Column | Type | Meaning |
|--------|------|---------|
| `GF_STA` | char(1) | Status |
| `GF_CO` | char(2) | **Company** |
| `GF_DIV` | char(2) | **Division** |
| `GF_GLA` | char(5) | **Account Number** |
| `GF_GLC` | char(3) | **Cost Center** |
| `GF_YR` | numeric(4,0) | **Fiscal year CCYY** (e.g. `2025`) |
| `GF_H1`..`GF_H12` | dec(13,2) | Month buckets |

**Primary key:** `(GF_CO, GF_DIV, GF_GLA, GF_GLC, GF_YR)` — 17,367 rows in Azure.

---

## Joining the tables

Natural join keys, by table:

```
ACCMAST   (ACCO, ACACC)
COACMAST  (CA_CO, CA_CC, CA_ACC, CA_DIV)
DEPTMAST  (DP_CO, DP_DIV, DP_CC, DP_ACC)
GLCAL     (GB_CO, GB_DIV, GB_GLA, GB_GLC, GB_DATE)
GLFIS     (GF_CO, GF_DIV, GF_GLA, GF_GLC, GF_YR)
```

Canonical join shape:

```
GLCAL  GB_CO=CA_CO AND GB_DIV=CA_DIV AND GB_GLA=CA_ACC AND GB_GLC=CA_CC  →  COACMAST   (alias account, mapping)
GLCAL  GB_CO=ACCO  AND GB_GLA=ACACC                                       →  ACCMAST    (account name)
GLCAL  GB_CO=DP_CO AND GB_DIV=DP_DIV AND GB_GLA=DP_ACC AND GB_GLC=DP_CC   →  DEPTMAST   (12-bucket dept rollup)
GLFIS  GF_CO=GB_CO AND GF_DIV=GB_DIV AND GF_GLA=GB_GLA AND GF_GLC=GB_GLC AND GF_YR=GB_DATE/100  →  GLCAL (annual ↔ monthly)
```

The dimensional spine on every fact-style table: **Co + Div + CC + Acct**. Add Period (`GB_DATE` for monthly, `GF_YR` for annual). DEPTMAST's bucket columns are the wide form of GLCAL's narrow rows.

---

## The Azure replica

**Server:** `sql-prtsplan-prod-eastus-001.database.windows.net`
**Database:** `sqldb-acctdata-prod-eastus-001`
**Schema:** `dbo` (production data) and `stg` (staging — empty at rest)

### Tables

| Table | Rows | Notes |
|-------|------|-------|
| `dbo.ACCMAST` | 809 | DDL columns + `FirstSeenUtc`, `LastSeenUtc`, `LastRunId` |
| `dbo.COACMAST` | 11,140 | Same — full chart of accounts |
| `dbo.DEPTMAST` | 4,835 | Same — departmental buckets |
| `dbo.GLCAL` | 188,713 | Same — atomic monthly balances |
| `dbo.GLFIS` | 17,367 | Same — annual history |
| `stg.<each>` | 0 | Staging copies — populated mid-load, cleared after merge |
| `dbo.AcctLoadControl` | 22 | ETL run log (see below) |
| `dbo.v_IncomeStatementLines` | 150,126 | Pre-joined reporting view (see below) |

### ETL — `dbo.AcctLoadControl`

Every load run is logged with:

```
RunId, TableName, Status, CredentialPairUsed, UserSecretName, PassSecretName,
StartedUtc, EndedUtc, RowsCopied, RowsInserted, RowsUpdated, RowsMerged, ErrorMessage
```

The pipeline rotates between two Intellidealer credential pairs (`ODD` / `EVEN`) stored as Key Vault secrets (`Intellidealer-User-Odd-Months`, `Intellidealer-User-Even-Months`). Latest cycle (2026-05-15): ACCMAST failed first run then all five tables completed successfully. The vault is `CrystalProd` in the `crystaltradeinfunctions` RG — firewall-restricted, see [azure-infrastructure.md](azure-infrastructure.md#key-vaults).

### Reporting view — `dbo.v_IncomeStatementLines`

A pre-joined, report-friendly view (150,126 rows) with friendly column names:

```
Company, Division, Branch, AccountNumber, AccountName, Period, PeriodYear,
PeriodMonth, PeriodStart, AcctType, AcctSubType, ExpenseType, MCRatioCode,
ReportGroupCode, Section, SectionOrder, Amount, NetIncomeImpact
```

This is the easiest starting point for income-statement queries — no joins required.

---

## Working files

The four spreadsheets in this folder map cleanly to specific tables/views:

| File | Maps to | Notes |
|------|---------|-------|
| [Historical Data GL.xlsx](Historical%20Data%20GL.xlsx) | `dbo.GLCAL` (1:1) | Columns: `Sta, Co, Div, Acc, Cost Ctr, Date, Amount, Year End` — direct extract of GLCAL |
| [Current Working FIle GL Data.xlsx](Current%20Working%20FIle%20GL%20Data.xlsx) | `dbo.DEPTMAST` (1:1) | Columns: `Co, DIV, CC, Acc #, DPC1..DPC12, DPL1..DPL12, A/L, Grp, Sta` — direct extract of DEPTMAST |
| [GL Data with Names and Alias example.xlsx](GL%20Data%20with%20Names%20and%20Alias%20example.xlsx) | **Pivoted derived view** | Columns: `Status, Co, Cost Ctr, Acct Numb, Div, Acct Name, Alias Account, <168 monthly columns 2019-01 → 2032-08>` — GLCAL pivoted by month, joined to ACCMAST (`Acct Name`) and COACMAST.CA_GLFA (`Alias Account`). Also contains a small *"Financial Statement Example"* sheet showing the desired P&L output. |
| [GL Data with Names and Alias1.xlsx](GL%20Data%20with%20Names%20and%20Alias1.xlsx) | Same pivot schema, mostly empty | Template / skeleton version with the same column layout but no balance values. Has additional empty `Raw Historical` and `Current` sheets. |

The "alias account" column (`COACMAST.CA_GLFA`) is the bridge to whatever external reporting structure Crystal uses — multiple GL accounts roll up to a single alias (e.g. all `Seacoast Checking` ledger lines share alias `F202`).

---

## Connection recipe

The DB is AAD-only for our use (the SQL admin password isn't ours). The flow: grab an AAD token via `az`, pass it to pyodbc as `SQL_COPT_SS_ACCESS_TOKEN`.

```bash
export PATH="/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin:$PATH"
TMPFILE="C:/Users/bradg/AppData/Local/Temp/aad_token.json"
az account get-access-token --resource https://database.windows.net/ > "$TMPFILE"

C:/Python312/python.exe - <<'PYEOF'
import json, struct, pyodbc

with open("C:/Users/bradg/AppData/Local/Temp/aad_token.json") as f:
    tok = json.load(f)["accessToken"]
tb = tok.encode("utf-16-le")
ts = struct.pack(f"=i{len(tb)}s", len(tb), tb)

conn = pyodbc.connect(
    "DRIVER={ODBC Driver 17 for SQL Server};"
    "SERVER=sql-prtsplan-prod-eastus-001.database.windows.net;"
    "DATABASE=sqldb-acctdata-prod-eastus-001;Encrypt=yes;TrustServerCertificate=no",
    attrs_before={1256: ts}, timeout=30)
cur = conn.cursor()
cur.execute("SELECT TOP 5 ACCO, ACACC, ACNME FROM dbo.ACCMAST")
for r in cur.fetchall(): print(r)
PYEOF
```

Token TTL is ~1 hour; re-run `az account get-access-token` when it expires.

---

## Sample queries

### 1. Monthly balance with friendly account name + alias

```sql
SELECT
    g.GB_CO   AS Co,
    g.GB_DIV  AS Div,
    g.GB_GLC  AS CostCtr,
    g.GB_GLA  AS Account,
    a.ACNME   AS AccountName,
    c.CA_GLFA AS Alias,
    g.GB_DATE AS PeriodCCYYMM,
    g.GB_AMT  AS Amount
FROM dbo.GLCAL g
LEFT JOIN dbo.ACCMAST  a ON a.ACCO=g.GB_CO AND a.ACACC=g.GB_GLA
LEFT JOIN dbo.COACMAST c ON c.CA_CO=g.GB_CO AND c.CA_DIV=g.GB_DIV
                        AND c.CA_ACC=g.GB_GLA AND c.CA_CC=g.GB_GLC
WHERE g.GB_DATE BETWEEN 202401 AND 202412
ORDER BY g.GB_CO, g.GB_GLA, g.GB_DATE;
```

### 2. P&L lines for a period (reporting view)

```sql
SELECT Company, AccountNumber, AccountName, Section, Amount, NetIncomeImpact
FROM dbo.v_IncomeStatementLines
WHERE Period = 202504
ORDER BY SectionOrder, AccountNumber;
```

### 3. Pivoted monthly matrix (what the *"GL Data with Names and Alias"* spreadsheet shows)

```sql
SELECT
    g.GB_CO, g.GB_DIV, g.GB_GLC, g.GB_GLA,
    a.ACNME, c.CA_GLFA AS Alias,
    SUM(CASE WHEN g.GB_DATE=202401 THEN g.GB_AMT END) AS [2024-01],
    SUM(CASE WHEN g.GB_DATE=202402 THEN g.GB_AMT END) AS [2024-02],
    -- ... etc
    SUM(CASE WHEN g.GB_DATE=202412 THEN g.GB_AMT END) AS [2024-12]
FROM dbo.GLCAL g
LEFT JOIN dbo.ACCMAST  a ON a.ACCO=g.GB_CO AND a.ACACC=g.GB_GLA
LEFT JOIN dbo.COACMAST c ON c.CA_CO=g.GB_CO AND c.CA_DIV=g.GB_DIV
                        AND c.CA_ACC=g.GB_GLA AND c.CA_CC=g.GB_GLC
GROUP BY g.GB_CO, g.GB_DIV, g.GB_GLC, g.GB_GLA, a.ACNME, c.CA_GLFA
ORDER BY g.GB_CO, g.GB_GLA;
```

### 4. Reconcile DEPTMAST against GLCAL (sanity check)

```sql
-- For company 01, division 01, account 10100, cost center 000:
-- DEPTMAST DPC1..DPC12 should equal GLCAL monthly for current year
SELECT
    d.DP_CO, d.DP_DIV, d.DP_CC, d.DP_ACC,
    d.DPC1 AS Dept_Jan, d.DPC2 AS Dept_Feb, -- ...
    (SELECT GB_AMT FROM dbo.GLCAL WHERE GB_CO=d.DP_CO AND GB_DIV=d.DP_DIV
        AND GB_GLA=d.DP_ACC AND GB_GLC=d.DP_CC AND GB_DATE=202401) AS GLCAL_Jan
FROM dbo.DEPTMAST d
WHERE d.DP_CO='01' AND d.DP_ACC='10100';
```

### 5. Last successful load per table

```sql
SELECT TableName, MAX(EndedUtc) AS LastSuccess, MAX(RowsCopied) AS LastRowsCopied
FROM dbo.AcctLoadControl
WHERE Status='COMPLETE'
GROUP BY TableName
ORDER BY TableName;
```

---

## Conventions and gotchas

- **All key columns are `CHAR`, not `INT`** — `'01'`, not `1`. Trailing spaces show up on raw `SELECT *` because of `CHAR(N)` padding; trim in display layers.
- **`GB_DATE` is `numeric(6,0)` formatted CCYYMM**, not a real date. Convert with `DATEFROMPARTS(GB_DATE/100, GB_DATE%100, 1)` to get a period-start `date`.
- **Status `'D'` rows are deleted/inactive** — most reporting queries should filter `WHERE ACSTA <> 'D'` (or the equivalent on `CA_STA`, `GB_STA`, etc.) unless you specifically need history.
- **`PFWF0125` schema** appears in the DDLs because that's the IBM i library on the source. The Azure replica drops it — tables live in `dbo`.
- **`UPDATE_IDENT` / `@@UPID`** is an IBM i audit identifier — present in every source table, preserved in the replica but not meaningful in Azure.
- **DEPTMAST is denormalized**: `DPC1..DPC12` and `DPL1..DPL12` are wide aggregates of GLCAL. Treat GLCAL as source of truth; use DEPTMAST when you specifically need the prior-year comparison without doing the join yourself.
- **Year boundary**: `GB_YE='Y'` rows in GLCAL flag year-end adjustment entries — exclude or include carefully depending on whether you want stated or operating numbers.
- **Sign conventions**: Amount sign follows accounting (debits positive on asset/expense, credits positive on liability/equity/revenue). `v_IncomeStatementLines.NetIncomeImpact` already flips signs so revenues are positive and expenses negative — preferable to raw `GB_AMT` for P&L work.

---

## Pointers for next steps

- **Reporting queries** → start from `dbo.v_IncomeStatementLines` (it already has the joins, sign conventions, and section grouping).
- **Ad-hoc analytics across periods** → query `dbo.GLCAL` joined to ACCMAST/COACMAST as in [Sample query 1](#1-monthly-balance-with-friendly-account-name--alias).
- **Year-over-year comparisons** → use DEPTMAST's `DPC*` / `DPL*` columns for the simplest pre-built comparison, or aggregate GLCAL twice.
- **Annual rollups** → GLFIS is already aggregated by fiscal year × month bucket — cheap to query.
- **Alias-grouped reports** → group by `COACMAST.CA_GLFA` (alias) to roll up multiple GL accounts into reporting buckets matching the spreadsheet *Alias Account* column.
- **Agents** → the connection recipe above + the column glossary in this file are enough for a tool/agent to author queries directly against the live replica. The `v_IncomeStatementLines` view is the most agent-friendly entry point.
- **Data freshness** → check `dbo.AcctLoadControl` for the last successful `Status='COMPLETE'` per table; rows are typically refreshed monthly after Intellidealer closes a period.
