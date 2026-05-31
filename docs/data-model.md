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
| `CA_YTD`, `CA_CUR`, `CA_L12` | dec(13,2) | YTD-through-last-closed-period, **LIVE current YTD/balance**, rolling trailing 12 months — see [§ COACMAST balance fields](#coacmast-balance-fields--the-live-current-state) below |

**Primary key:** `(CA_CO, CA_CC, CA_ACC, CA_DIV)` — 11,140 rows in Azure.

### 3. DEPTMAST — Departmental Master ([DEPTMAST_DDL.sql](DEPTMAST_DDL.sql))

Pre-aggregated 12-month buckets per Co/Div/CC/Account. Each row carries **current-year months 1–12 (`DP_C1`..`DP_C12`)** and **last-year months 1–12 (`DP_L1`..`DP_L12`)**.

| Column | Type | Meaning |
|--------|------|---------|
| `DP_CO` | char(2) | **Company** |
| `DP_DIV` | char(2) | **Division** |
| `DP_CC` | char(3) | **Cost Center** |
| `DP_ACC` | char(5) | **Account Number** |
| `DP_C1`..`DP_C12` | dec(13,2) | Current-year month buckets |
| `DP_L1`..`DP_L12` | dec(13,2) | Last-year month buckets |
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

## Cost-center encoding — branch and department

Crystal's 3-digit cost center is a composite key: **leading digit = Kubota DFS department, trailing 2 digits = branch location**. Verified empirically 2026-05-27 by matching `SUM(GB_AMT)` on acct `32000` (Sales — New Kubota) per CC suffix against the per-branch columns of [Sales and Gross Summary.xlsx](Sales%20and%20Gross%20Summary.xlsx) — 12 of 17 active branches matched to the dollar, the rest within 2% (snapshot timing drift).

### Leading digit — department

| Leading digit | Department | Notes |
|---:|---|---|
| `0` | **Corporate / Balance Sheet** | All BS account activity posts to `0xx`; CC `000` is the central/holding CC |
| `1` | Admin (overhead) | Branch-allocated admin and management overhead |
| `2` | Sales | Equipment sales department |
| `3` | Service | Labor / service department |
| `4` | Parts | Parts department |
| `5` | Rental | Rental department (small in Crystal's GL) |

So CC `211` = Sales department at branch 11 (Live Oak); CC `301` = Service department at branch 01 (Deland).

The Kubota DFS 6-department layout (`Sales | Service | Parts | Rental | Total Fixed | Admin`) is derived from this leading digit — **not** from `GB_DIV`. Every P&L row in the replica has `Division='01'`, so the dept split lives entirely in the cost-center code.

### Trailing 2 digits — branch location

| CC suffix | Branch |  | CC suffix | Branch |
|---:|---|---|---:|---|
| `01` | Deland | | `10` | Starke |
| `02` | Leesburg | | `11` | Live Oak |
| `03` | Parts Warehouse | | `12` | Madison |
| `04` | Chiefland | | `13` | Panama City |
| `05` | Spring Hill | | `14` | Tallahassee |
| `06` | Ocala | | `15` | Cairo |
| `07` | Homosassa | | `16` | Jacksonville |
| `08` | Hastings | | `17` | Lecanto |
| `09` | Palatka | | `18` | Dothan (no 2025 activity) |

**Common query patterns:**

```sql
-- Department-level P&L (Kubota DFS):
GROUP BY LEFT(GB_GLC, 1)   -- 2=Sales, 3=Service, 4=Parts, 5=Rental, 1=Admin

-- Branch-level P&L (all departments combined):
GROUP BY RIGHT(GB_GLC, 2)  -- 01..18 = the branches above

-- One department at one branch (e.g. Tallahassee Sales):
WHERE GB_GLC = '214'

-- Total Fixed (per Kubota DFS): Service + Parts + Rental
WHERE LEFT(GB_GLC, 1) IN ('3', '4', '5')
```

**Caveat — sub-entity CCs.** Branches may also pull from sub-entity CCs `091`/`093`/`094`/`096` (Tallahassee's BS Detail uses `091` and `093`, for example). For BS at the branch level, filtering on `RIGHT(GB_GLC,2)` alone may understate; cross-check against the Detail spreadsheet for the branch you care about.

### Cost center vs. profit center — terminology

The DDLs label the `CA_CC` / `GB_GLC` / `GF_GLC` / `DP_CC` column as **"Cost Center"** — that's the legacy IBM i / DMS convention. In strict management-accounting terms, most of Crystal's CCs are actually **profit centers** (they carry both revenue and direct costs):

| CC leading digit | Department | Carries revenue? | Technically… |
|:---:|---|:---:|---|
| `2xx` | Sales | ✓ | **Profit center** |
| `3xx` | Service | ✓ | **Profit center** |
| `4xx` | Parts | ✓ | **Profit center** |
| `5xx` | Rental | ✓ (small) | Profit center |
| `1xx` | Admin | ✗ (opex only) | **True cost center** |
| `0xx` | Corporate / BS | — (no P&L) | Neither — BS bucket |

So when finance/management refers to these as "profit centers" they're using the more accurate term for what those buckets actually are. Both labels refer to the same dimension; pick by audience:

- Talking SQL / DDL / ETL → "cost center" (matches the column names)
- Talking accounting / management reporting → "profit center" (more accurate for `2xx`–`5xx`)
- Mixed audience → "Cost center (CC) — Crystal's profit centers, per the leading-digit department code"

---

## COACMAST balance fields — the live "current state"

GLCAL only carries **closed** monthly balances; it stops at whatever period Crystal has formally closed on Intellidealer. `COACMAST` carries three pre-computed balance fields per `(Co, Div, CC, Acct)` row that hold the **live source-side state**, refreshed with every ETL run. These are the only place in the replica with leading-edge / unclosed data.

| Field | Semantic | What it equals (verified 2026-05-29) |
|---|---|---|
| `CA_YTD` | Year-to-date **through the last closed period** | For P&L: matches `SUM(GLCAL.GB_AMT) WHERE GB_DATE BETWEEN <Jan> AND <MaxPeriod>` to the dollar. For BS: matches `GLCAL.GB_AMT @ MaxPeriod`. |
| **`CA_CUR`** | **LIVE current YTD activity (P&L) or running balance (BS)** — includes unclosed periods | For P&L: typically ~2.5× CA_YTD across the chart (matches "5 months CA_CUR vs 2 months CA_YTD" = 3 months of unclosed activity post-MaxPeriod). For BS: reflects current operational drift (inventory turn, floorplan paydown, etc.). |
| `CA_L12` | Rolling **trailing 12 months** as of current source date | For P&L: 12-month run-rate ending at "now". |

**Why this matters.** GLCAL is always behind the source by however many periods Crystal hasn't yet closed. CA_CUR fills that gap for *aggregate* current-state queries (you lose the monthly breakout, but gain ~3 months of freshness). Use the right field for the question:

| Question | Use |
|---|---|
| "What was March 2026 revenue?" | GLCAL — but it has to exist first (currently doesn't). |
| "What's our YTD revenue right now?" | `-SUM(CA_CUR)` over `ACTYP IN ('2','3')` accounts. |
| "What's the current Floorplan balance?" | `-SUM(CA_CUR)` for acct `20350` (sign-flip for L+E). |
| "What's our trailing-12-month revenue?" | `-SUM(CA_L12)` for revenue accounts. |
| "Reconcile against the GLCAL Feb 2026 view" | `CA_YTD` (matches GLCAL exactly). |

**Verification 2026-05-29 (GLCAL MaxPeriod = 202602):**
- Acct `32000` (Sales-New Kubota): `CA_YTD` = −$19.89M = GLCAL Jan+Feb 2026 to the dollar; `CA_CUR` = −$51.19M (~2.57× larger ≈ YTD through May 2026).
- Acct `12000` (Wholegoods Inv): `CA_YTD` = $55.11M = GLCAL @ 202602; `CA_CUR` = $45.26M (inventory sold down $9.85M since Feb).
- Acct `20350` (Floorplan): `CA_YTD` = −$48.65M; `CA_CUR` = −$38.59M (paydown $10.06M ≈ matches inventory decrease — confirms operational coherence).
- A current-as-of-source BS built from `CA_CUR` + rolling CA_CUR-derived NI into RE balances **to the dollar**.

**Gotchas:**
- CA_CUR has **no time dimension** — it's a single aggregate. You can't ask "what was March-only?" with it.
- Sign convention is the same as `GLCAL.GB_AMT` (revenue stored credit-negative, expense debit-positive). Flip signs for natural-direction reporting.
- DEPTMAST's `DP_C*` columns are NOT a leading-edge data source — they're in lock-step with GLCAL and empty beyond MaxPeriod. Don't confuse the two.
- Check `LastSeenUtc` on `dbo.COACMAST` to understand staleness (CA_CUR is fresh-as-of-last-ETL).

### Data overlap between GLCAL and COACMAST — how to avoid double-counting

This is the single most important thing to internalize before mixing the two tables in a query.

#### The overlap structure

The same closed-period activity is represented in **three places at once**:

```
                              Jan 2026         Feb 2026         Mar..May 2026
                              (closed)         (closed)         (unclosed)
                              ━━━━━━━━━━       ━━━━━━━━━━       ━━━━━━━━━━━━━
GLCAL  (monthly rows)         [   row   ]      [   row   ]      (no rows)
CA_YTD (aggregate per acct)   [─── = SUM(GLCAL closed) ───]     (excluded)
CA_CUR (aggregate per acct)   [─── = SUM(GLCAL closed) ───][─── live ───]
CA_L12 (rolling 12 months)    (covers a moving 12-month window ending "now")
```

GLCAL holds the closed periods at monthly grain. CA_YTD holds the exact same data as a single year-to-date aggregate (the SUM across closed periods). CA_CUR holds the same data as CA_YTD *plus* unclosed activity. The closed-period activity is shared by GLCAL, CA_YTD, and CA_CUR simultaneously.

#### Empirical consistency

Verified 2026-05-29 across the entire chart of accounts (GLCAL MaxPeriod = 202602):

| Identity | Rows tested | Mismatches |
|---|---:|---:|
| P&L: `CA_YTD` = `SUM(GLCAL.GB_AMT)` over `GB_DATE BETWEEN 202601 AND 202602` per `(Co, Div, CC, Acct)` | 8,643 | **0** |
| BS: `CA_YTD` = `GLCAL.GB_AMT @ 202602` per `(Co, Div, CC, Acct)` | 2,336 | **0** |

So CA_YTD is a perfectly redundant aggregation of GLCAL's closed-period data — useful as a convenience field or as a cross-check, but it carries no information GLCAL doesn't already have.

#### The double-counting trap

Because the overlap is real (same data in multiple fields), summing across them double-counts. Examples:

```sql
-- ❌ WRONG — double-counts Jan+Feb 2026 activity
SELECT
    (SELECT SUM(g.GB_AMT) FROM dbo.GLCAL g
     WHERE g.GB_DATE BETWEEN 202601 AND 202602 AND g.GB_GLA='32000')   -- Jan+Feb closed
  + (SELECT SUM(c.CA_CUR) FROM dbo.COACMAST c WHERE c.CA_ACC='32000')  -- includes Jan+Feb!
  AS bogus_double_counted_ytd;

-- ❌ WRONG — also double-counts (CA_YTD == GLCAL SUM, adding them duplicates)
SELECT SUM(GB_AMT) + SUM(CA_YTD) ...

-- ✅ RIGHT — for current YTD use CA_CUR alone (it already includes closed periods)
SELECT -SUM(c.CA_CUR) AS current_ytd_revenue
FROM dbo.COACMAST c
INNER JOIN dbo.ACCMAST a ON a.ACCO=c.CA_CO AND a.ACACC=c.CA_ACC
WHERE a.ACTYP IN ('2','3') AND a.ACSTA<>'D';

-- ✅ RIGHT — for just the unclosed-period activity (March-May 2026 only)
SELECT -SUM(c.CA_CUR - c.CA_YTD) AS unclosed_period_revenue
FROM dbo.COACMAST c
INNER JOIN dbo.ACCMAST a ON a.ACCO=c.CA_CO AND a.ACACC=c.CA_ACC
WHERE a.ACTYP IN ('2','3') AND a.ACSTA<>'D';

-- ✅ RIGHT — for monthly granularity on closed periods only
SELECT GB_DATE, SUM(GB_AMT) FROM dbo.GLCAL
WHERE GB_GLA='32000' AND GB_DATE BETWEEN 202601 AND 202602
GROUP BY GB_DATE;
```

#### Useful identities

For any current-year P&L account in steady state:

```
CA_YTD       = SUM(GLCAL.GB_AMT) for GB_DATE in [Jan..MaxPeriod] of current year
CA_CUR       = CA_YTD + UnclosedActivity
              = SUM(GLCAL closed) + UnclosedActivity
UnclosedActivity = CA_CUR - CA_YTD          ← Mar..present, no monthly grain
```

For any BS account in steady state:

```
CA_YTD       = GLCAL.GB_AMT @ MaxPeriod  (snapshot at last closed period-end)
CA_CUR       = current live balance        (CA_YTD + post-close drift)
```

For prior years (P&L), GLCAL is the only source:

```
SUM(GLCAL) over [Jan..Dec PriorYear]  →  prior year's full P&L activity
(CA_YTD, CA_CUR, CA_L12 reset/roll each January and don't reach into prior years cleanly)
```

#### The "pick one source per statement" rule

For each financial statement, pick a single primary source and never sum across the GLCAL/CA_YTD/CA_CUR boundary. Pattern reference for the report types built so far:

| Report | Primary source | Why |
|---|---|---|
| Full-year prior-year IS (e.g. 2025) | `v_IncomeStatementLines` over `GLCAL` | All twelve months are closed; GLCAL is the source of truth. |
| Year-end BS (e.g. 12/31/2025) | `GLCAL @ 202512` | Closed period-end snapshot. |
| Branch / department slices of closed-period data | `v_IncomeStatementLines` or `GLCAL` | Monthly grain available; consistent with the above. |
| Statement of Cash Flows (closed years) | `GLCAL @ BOY` and `GLCAL @ EOY` + `v_IncomeStatementLines` for NI/D&A | Both BS endpoints in GLCAL; P&L from the view. |
| **Current-year YTD IS (live)** | `COACMAST.CA_CUR` alone | Includes closed + unclosed; no monthly grain available for the unclosed block. |
| **Current BS (live, as-of-source)** | `COACMAST.CA_CUR` alone | Live balances; roll CA_CUR-derived current-year NI into RE to balance. |
| Trailing 12-month run-rate | `COACMAST.CA_L12` alone | The window is defined by the source. |

The common failure mode the rule prevents: trying to "get the best of both" by combining GLCAL monthly detail with CA_CUR to produce a more granular live report. That mixes overlapping data sources.

If you genuinely need both monthly granularity *and* current-state freshness in one report, the only correct construction is:

1. Use GLCAL for the closed months (monthly grain).
2. Use `CA_CUR − CA_YTD` for the unclosed block (single aggregate, no further breakdown).
3. Label the unclosed block clearly so it isn't read as a single closed month.

#### One known edge case — reversals can make CA_CUR smaller than CA_YTD

Acct `42002` (INV COS CHARGEBACKS) on 2026-05-29: `CA_YTD` = $178,263 but `CA_CUR` = $93,889. CA_CUR is *smaller* in magnitude — a credit / reversal posted in the unclosed Mar–May block that partially offset the Jan-Feb activity. So `CA_CUR − CA_YTD = −$84,374`. The model still holds (unclosed activity is just negative for this account); but it confirms that unclosed-period activity can move in either direction, and code that assumes `|CA_CUR| ≥ |CA_YTD|` will have edge cases.

#### Quick reference

```
Question                                Source                  Don't also add
─────────────────────────────────────  ──────────────────────  ──────────────────────────
"Specific closed month (e.g. Feb 26)"   GLCAL row at GB_DATE    CA_YTD or CA_CUR
"Closed-period YTD"                     GLCAL sum OR CA_YTD     the other one
"Live YTD as of source today"           CA_CUR                  anything GLCAL/CA_YTD
"Unclosed-period activity only"         CA_CUR − CA_YTD         —
"Trailing 12 months"                    CA_L12                  GLCAL or CA_CUR
"Closed BS snapshot at MaxPeriod"       GLCAL @ MaxPeriod       CA_YTD (redundant)
"Live BS as of source today"            CA_CUR                  GLCAL or CA_YTD
"Prior year (any month/total)"          GLCAL only              CA_* are current-year
```

Rule of thumb: if your query mentions both `GLCAL` and `COACMAST.CA_*` in the same arithmetic expression, you almost certainly have a double-counting bug. The two sources are alternative representations of the same underlying activity, not complementary streams.

#### Why we can't get monthly granularity inside the unclosed block

Inside the unclosed block (e.g. Mar–May 2026 right now), the replica gives only the *combined* aggregate via `CA_CUR − CA_YTD`. There is no way to split that into individual months from any of the 5 replicated tables.

This is a sourcing gap, **not** a Intellidealer gap. A finer-grained activity table must exist on the source — the close process is mechanically `SUM(activity) GROUP BY (Co, Div, CC, Acct, Period)`, which requires sub-monthly input on the AS/400. Circumstantial evidence: `GB_YE='Y'` rows in GLCAL flag year-end adjustment entries, which can only originate from per-posting metadata; Crystal also generates per-month management-report spreadsheets from Intellidealer for unclosed periods (e.g. the May-2026 Sales & Gross Summary). The table simply isn't in our replica. See [reporting-catalog.md §"Data availability — Tier 3"](reporting-catalog.md#tier-3--truly-missing-need-separate-sourcing-or-not-in-our-environment) for the candidate IBM i table names worth searching the source for.

Until that table is replicated, the replica's "monthly resolution" floor is the closed-period boundary: monthly grain up to MaxPeriod via GLCAL; aggregate beyond MaxPeriod via `CA_CUR − CA_YTD`; no monthly detail inside the unclosed block.

---

## Structural model — hybrid masters and the hidden transaction stream

A cleaner mental model for the whole replica, which makes the rules above fall out naturally:

### COACMAST is a hybrid table (master + aggregate)

A COACMAST row mixes two different kinds of data:

| Field type | Examples | Aggregation of activity? |
|---|---|:---:|
| Dimensional / identity | `CA_CO`, `CA_DIV`, `CA_CC`, `CA_ACC`, `CA_STA` | No — defines "this `(Co, Div, CC, Acct)` combo is valid" |
| Mapping / configuration | `CA_GLFA` (alias), `CA_GLCP` (COGS %), `CA_BRT`/`CA_BAC` (bank routing), `CA_GLWA` (rental depreciation acct), `CA_GLC1`–`CA_GLC4` (pricing routing), `CA_CNHA`, etc. | No — declarative posting rules; static config |
| Sub-ledger pointers | `CA_SLC`, `CA_SLS` | No — pointers to a sub-ledger table |
| Pre-computed balance aggregates | `CA_YTD`, `CA_CUR`, `CA_L12` | **Yes — aggregations of an underlying transaction stream** |

So a COACMAST row is partly dimensional (defining the chart of accounts), partly configuration (how to post), and partly a pre-rolled-up summary of activity. It is *not* a pure dimension table by modern data-warehouse standards.

### All balance-carrying tables are aggregations of a single source posting table

Every numeric balance in the replica — GLCAL, GLFIS, DEPTMAST, and COACMAST's balance fields — is a different aggregation of journal-line activity. That activity lives in **`YTDJRL` (Year-to-Date Journals)** on the Intellidealer AS/400 source, per the official **Intellidealer 6.0 System Flowchart** ([`docs/Intellidealer system flow chart.pdf`](Intellidealer%20system%20flow%20chart.pdf)). `YTDJRL` is the canonical posting table — every sub-system (sales, A/P, work orders, payroll, inventory) flows into it, and from there it aggregates into GLCAL / GLFIS / DEPTMAST / COACMAST.

**`YTDJRL` is NOT replicated to acctdata** (and also not in IntelliDealerR1 — verified 2026-05-31). This is the single gap that, when closed, gives us monthly grain for any period (closed or unclosed) and JE-level audit trail in one step.

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  YTDJRL  on Intellidealer source — CANONICAL JOURNAL-LINE TABLE      │
   │  Per Intellidealer 6.0 System Flowchart (CDK Global, 2019)           │
   │  Sits next to GLCAL / GLFIS / SUBLED in the GL module                │
   │  Receives postings from every sub-system; aggregates into GLCAL      │
   │                                                                      │
   │  ✗ NOT replicated to acctdata or IDR1 as of 2026-05-31                │
   │  → see docs/journal-line-etl-spec.md for the one-table replication    │
   └─────────────────────────────────┬────────────────────────────────────┘
                                      │
                                      │  per posting: Co, Div, CC, Acct,
                                      │  date, amount, source-system,
                                      │  customer/vendor/invoice references
                                      ▼
            ┌──────────────────┬───────────────────────┬───────────────────────┐
            │                  │                       │                       │
            ▼                  ▼                       ▼                       ▼

   GLCAL.GB_AMT       GLFIS.GF_H1..H12       DEPTMAST.DP_C1..DP_L12     COACMAST.CA_YTD/CUR/L12
   ──────────────     ────────────────────   ─────────────────────────  ───────────────────────
   per (key, month)   per (key, year)        per (key) — wide 24 col    per (key)
   monthly grain      annual rollup          current + prior year       YTD-closed + LIVE + L12
   closed only        closed years           same scope as GLCAL        closed → live (CA_CUR)
   append rows        append rows            overwrite on close         overwrite (some live)
```

`(key)` above = `(Co, Div, CC, Acct)`. The four downstream rollups are not independent — they're all derived from `YTDJRL`. That's why they're mathematically consistent (CA_YTD = SUM(GLCAL closed periods) to the dollar; DEPTMAST.DP_C* matches GLCAL by month).

**An earlier 2026-05-29 version of this section** named five sub-system tables (`CGIHIST`, `YTDIST`, `SUBLED`, `PARTHIST`, `INVHCC`) as the source. That was the result of trying to reverse-engineer the gap from what was discoverable in IDR1. Empirical reconciliation showed those five tables only cover ~80% of revenue and far less of OpEx/BS activity — they're sub-system *participants* in the posting flow, not the consolidated source. `YTDJRL` is the right answer; the other tables are useful for source-system traceability but secondary. See [reporting-catalog.md](reporting-catalog.md#tier-3--truly-missing-need-separate-sourcing-or-not-in-our-environment) for the corrected gap classification.

### Why this matters

Three consequences fall out of this structural model:

1. **None of the four can disagree.** They're alternative rollups of the same input, computed by the source. So `CA_YTD = SUM(GLCAL closed months in current year)` to the penny is not a coincidence — it's algebraically required (and we've verified it across all 8,643 P&L rows). The same logic explains why DEPTMAST `DP_C2` matches `GLCAL @ 202602` exactly.

2. **The overlap structure** (GLCAL ⊂ CA_YTD ⊂ CA_CUR, and DEPTMAST in lock-step with GLCAL) isn't a quirk — it's the inevitable shape of multiple aggregations over the same input. The "pick one source per statement" rule works because each of the four is *complete* for its grain; there's no information you'd gain by combining them.

3. **The monthly-resolution floor is set by the rollup tables' own granularity.** Since no rollup table is finer than monthly (and none has rows for unclosed periods), we can't answer "March 2026 alone" — not because the data doesn't exist on the source, but because every rollup we have aggregates that month away. Only the journal-line table can break the floor.

### What this implies for the gap

The "structural" version of the ETL ask: *"We have four aggregation tables over an input we don't see. We want the input."* That single missing table unlocks the grain of all four downstream tables simultaneously — it's not a one-feature ask, it's a foundation ask.

ACCMAST follows the same pattern in miniature: it's a pure dimension (no aggregates), and its closest "rollup" sibling is `v_IncomeStatementLines`, which is a *view* over GLCAL + ACCMAST that the replica builds (also derived from the same hidden stream by extension).

---

## The Azure replica

**Server:** `sql-prtsplan-prod-eastus-001.database.windows.net`
**Database:** `sqldb-acctdata-prod-eastus-001`
**Schemas:** `dbo` (production), `stg` (staging — transient ETL workspace, holds latest run only), `snap` (historical change-capture snapshots)

### Tables and views

| Object | Rows (as of 2026-05-29) | Role |
|---|---:|---|
| `dbo.ACCMAST` | 810 | Account dictionary |
| `dbo.COACMAST` | 11,150 | Chart of accounts + balance aggregates |
| `dbo.DEPTMAST` | 4,906 | Wide 24-bucket rollup (current + prior year) |
| `dbo.GLCAL` | 193,619 | Atomic monthly balances |
| `dbo.GLFIS` | 17,367 | Annual rollup with month buckets |
| `dbo.v_IncomeStatementLines` | 153,900 | Pre-joined reporting view over GLCAL + ACCMAST (P&L only) |
| `dbo.AcctLoadControl` | run log | One row per ETL run per table |
| `dbo.AcctSnapshotControl` | 2 | One row per snapshotted table (GLCAL, GLFIS) — watermarks |
| `stg.ACCMAST` / `COACMAST` / `DEPTMAST` / `GLCAL` / `GLFIS` | same as dbo | Transient staging — populated from source by ADF, then merged into `dbo`. Currently holds last run's data; not authoritative. |
| `snap.GLCAL` | 4,906 (1 snapshot date so far) | Sparse change-capture snapshots — only contains rows that changed between ETL runs |
| `snap.GLFIS` | (sparse) | Same pattern for annual rollup |

### ETL — stored-procedure pipeline

The pipeline is fully driven by stored procedures and runs as an ADF pipeline per table.

| Procedure | Purpose |
|---|---|
| `sp_AcctStartRun(@TableName)` | Allocates `RunId`, picks ODD/EVEN credential pair by calendar month, opens a `RUNNING` row in `AcctLoadControl` |
| `sp_Acct_Merge_<Table>(@RunId)` | MERGE `stg.<Table>` → `dbo.<Table>` with **change detection** — only writes rows where values actually differ (`GB_AMT`/`UPDATE_IDENT`/etc. changed). Updates `LastSeenUtc` and `LastRunId` on changed rows; stamps `FirstSeenUtc` on inserts. One proc per table (×5). |
| `sp_AcctFinalize(@RunId)` | Marks `COMPLETE` and stamps `EndedUtc` |
| `sp_Acct_Snapshot_GLCAL`, `sp_Acct_Snapshot_GLFIS` | Capture historical snapshots — see next sub-section |

**Key architectural choices** (called out in the proc comments):

- **Every run is a full reload.** The source-side `UPDATE_IDENT` audit identifier is unusable as an incremental watermark (`0` for whole tables, `-999999` sentinel for most of COACMAST). The ADF Copy pulls every row from the source; the MERGE step then writes only the differences. A steady-state reload of ~222K rows typically touches very few `dbo` rows.
- **ODD/EVEN credential rotation** is decided at run-start, so a run that crosses a calendar-month boundary doesn't switch credentials mid-flight.
- **Failures are recorded inline.** A merge proc that errors sets `Status='FAILED'` + `EndedUtc` + `ErrorMessage` on the `AcctLoadControl` row, then re-throws so ADF marks the pipeline failed.

The `AcctLoadControl` columns:

```
RunId, TableName, Status, CredentialPairUsed, UserSecretName, PassSecretName,
StartedUtc, EndedUtc, RowsCopied, RowsInserted, RowsUpdated, RowsMerged, ErrorMessage
```

Credentials live in Key Vault `CrystalProd` (`crystaltradeinfunctions` RG) — secrets `Intellidealer-User-Odd-Months`, `Intellidealer-User-Even-Months`, plus password counterparts. See [azure-infrastructure.md](azure-infrastructure.md#key-vaults).

### Historical change-capture — the `snap.*` schema

The replica also captures **sparse historical snapshots** of GLCAL and GLFIS — useful for tracking when closed-period balances change after first posting (late adjustments, period reopen-and-repost, etc.).

**Mechanics** (per `sp_Acct_Snapshot_GLCAL` body):

1. Watermark lookup: read `LastCapturedThroughUtc` from `AcctSnapshotControl` for the table.
2. Identify changes: rows in `dbo.GLCAL` where `LastSeenUtc > @LastCaptured AND LastSeenUtc <= SYSUTCDATETIME()`. **These are exactly the rows the last merge actually wrote** (inserts or value changes).
3. MERGE into `snap.GLCAL` keyed by `(SnapshotDate, GB_CO, GB_DIV, GB_GLA, GB_GLC, GB_DATE)` — `SnapshotDate` is *Eastern Time today*, not UTC.
4. Stamp `ChangeKind = 'I'` if the row was newly inserted today, `'U'` if it was a value change to an existing row.
5. Advance watermark + record `LastRowsCaptured` on `AcctSnapshotControl`.

| `snap.GLCAL` column | What it carries |
|---|---|
| `SnapshotDate` | Eastern-Time calendar date of the snapshot run |
| All `GB_*` columns | The new state of the changed row |
| `ChangeKind` | `'I'` (insert) or `'U'` (update) |
| `SourceFirstSeenUtc`, `SourceLastSeenUtc`, `SourceRunId` | Audit fields copied from `dbo.GLCAL` at capture time |
| `SnapshotCapturedUtc` | When the snapshot proc actually ran |

**Properties to internalize:**

- **Sparse-by-design.** If no GLCAL rows changed since the last snapshot run, `LastRowsCaptured = 0` and nothing is appended. Typical steady-state days will capture nothing.
- **One row per `(SnapshotDate, PK)`.** If the same row changes twice in the same Eastern day, only the latest state survives in `snap.GLCAL` for that day (MERGE updates rather than appending).
- **Same grain as the source table.** `snap.GLCAL` rows are still keyed by `GB_DATE` (monthly); `snap.GLFIS` by `GF_YR`. Snapshots add a *time axis on top of* the existing grain — they don't unlock sub-monthly detail.
- **Use cases.** Detect late-posted adjustments to closed periods; reconstruct "what did Feb 2026's balance look like a month ago?"; track when year-end close-to-RE entries actually posted.
- **Not a substitute for the missing journal-line table.** See [§ "Structural model"](#structural-model--hybrid-masters-and-the-hidden-transaction-stream) and [reporting-catalog.md Tier 3](reporting-catalog.md#tier-3--truly-missing-need-separate-sourcing-or-not-in-our-environment).

### Reporting view — `dbo.v_IncomeStatementLines`

A pre-joined, report-friendly view (153,900 rows as of 2026-05-29) with friendly column names:

```
Company, Division, Branch, AccountNumber, AccountName, Period, PeriodYear,
PeriodMonth, PeriodStart, AcctType, AcctSubType, ExpenseType, MCRatioCode,
ReportGroupCode, Section, SectionOrder, Amount, NetIncomeImpact
```

This is the easiest starting point for income-statement queries — no joins required. Filters to P&L (`ACTYP IN ('2','3')`) only; for BS work, go straight to GLCAL.

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
-- DEPTMAST DP_C1..DP_C12 should equal GLCAL monthly for current year
SELECT
    d.DP_CO, d.DP_DIV, d.DP_CC, d.DP_ACC,
    d.DP_C1 AS Dept_Jan, d.DP_C2 AS Dept_Feb, -- ...
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
- **DEPTMAST is denormalized**: `DP_C1..DP_C12` and `DP_L1..DP_L12` are wide aggregates of GLCAL. Treat GLCAL as source of truth; use DEPTMAST when you specifically need the prior-year comparison without doing the join yourself. Note the IBM i source exposes both long names (`DP_C1`) and short names (`DPC1`) — Azure preserved the long names for this table, so query with `DP_C1`/`DP_L1`.
- **Year boundary**: `GB_YE='Y'` rows in GLCAL flag year-end adjustment entries — exclude or include carefully depending on whether you want stated or operating numbers.
- **Sign conventions**: Amount sign follows accounting (debits positive on asset/expense, credits positive on liability/equity/revenue). `v_IncomeStatementLines.NetIncomeImpact` already flips signs so revenues are positive and expenses negative — preferable to raw `GB_AMT` for P&L work.
- **`GB_AMT` is dual-mode** (verified 2026-05-27): for **BS accounts** (`ACTYP='1'`) each row is the **period-end running balance** (snapshot — pull the single row at the desired period, do NOT sum). For **P&L accounts** (`ACTYP IN ('2','3')`) each row is the period's **activity** (flow — sum across periods for YTD or annual). The `v_IncomeStatementLines` view filters to P&L only and treats `GB_AMT` as a flow. `GLFIS` annual rollups equal the sum of `GLCAL` monthly activity for P&L accounts — confirms the flow semantic. This was open question #1 in [mcp-server-spec.md §13](mcp-server-spec.md#13-open-questions-for-review).
- **Crystal's GL is a self-balancing per-branch ledger** (verified 2026-05-27): for any period, sum BS account snapshots (post year-end NI roll-in) for `WHERE RIGHT(GB_GLC,2) = '<branch>'` — Assets = Liab+Equity to the dollar for every active branch (01..17). Each branch's books close internally, with no inter-branch GL reconciliation needed. The Tallahassee Summary spreadsheet diverges from this raw view because it applies management-report allocations (cash, AR pushed to "Due from Affiliates") on top of the GL — see [balance-sheet-design.md §4](balance-sheet-design.md) for the raw-GL vs management-report distinction.

---

## Pointers for next steps

- **Reporting queries** → start from `dbo.v_IncomeStatementLines` (it already has the joins, sign conventions, and section grouping).
- **Ad-hoc analytics across periods** → query `dbo.GLCAL` joined to ACCMAST/COACMAST as in [Sample query 1](#1-monthly-balance-with-friendly-account-name--alias).
- **Year-over-year comparisons** → use DEPTMAST's `DPC*` / `DPL*` columns for the simplest pre-built comparison, or aggregate GLCAL twice.
- **Annual rollups** → GLFIS is already aggregated by fiscal year × month bucket — cheap to query.
- **Alias-grouped reports** → group by `COACMAST.CA_GLFA` (alias) to roll up multiple GL accounts into reporting buckets matching the spreadsheet *Alias Account* column.
- **Agents** → the connection recipe above + the column glossary in this file are enough for a tool/agent to author queries directly against the live replica. The `v_IncomeStatementLines` view is the most agent-friendly entry point.
- **Data freshness** → check `dbo.AcctLoadControl` for the last successful `Status='COMPLETE'` per table; rows are typically refreshed monthly after Intellidealer closes a period.
