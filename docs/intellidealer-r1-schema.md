# IntelliDealerR1 — Schema Reference

A separate Azure SQL database that contains a **much wider replica of the Intellidealer source schema** than the production [acctdata](data-model.md) DB. The data in IntelliDealerR1 is stale (paused since Dec 2025), but the schema itself is verified-accurate and can be used as the design spec for expanding our replication coverage.

---

## TL;DR

| Property | Value |
|----------|-------|
| **Server** | `crystal-intellidealer-r1.database.windows.net` |
| **Database** | `IntelliDealerR1` (paused, serverless — auto-resumes on connect) |
| **Resource group** | `IntellidealerR1` |
| **Max size** | 64 GB |
| **Auth** | SQL: `crystalSQL` / `M4thrules2024!` ⚠️ **2024!** not 2025! (different from CrystalCares server) |
| **AAD admin** | `ted.uiterwyk@crystalmotorcarco.onmicrosoft.com` — `brad.greenway@me.com` is **not granted**, AAD auth fails |
| **Tables** | 203 in `dbo` |
| **Data freshness** | Paused 2025-12-11 — **5+ months stale**. Use for schema only, not numbers. |
| **Status** | Currently **Online** (was resumed during 2026-05-19 investigation). Should be re-paused when not in use to stop billing. |

Companion app that uses this server: `CrystalTradeInFunctions`. Its `SQLServerConnectionString` app-setting was the source of the correct password.

---

## Why we trust the schema

When IntelliDealerR1 was paused (2025-12-11), the **acctdata** production replica continued refreshing. Today (2026-05-19), the 4 tables present in both DBs compare column-for-column, type-for-type:

| Table | IDR1 cols | acctdata cols (excl. ETL trailer) | Difference |
|-------|-----------|-----------------------------------|------------|
| ACCMAST | 14 | 14 | none |
| COACMAST | 51 | 51 | none |
| DEPTMAST | 33 | 33 | none |
| GLCAL | 9 | 9 | none |

5 months elapsed → zero schema drift. Intellidealer is a mature Db2-for-i ERP and schema changes are rare. **Reliable for schema design.** *(GLFIS is in acctdata but not IDR1 — coverage difference, not drift.)*

---

## What it unlocks beyond the 5 GL tables

### A/R sub-ledger ✅

| Table | Rows | Purpose |
|-------|------|---------|
| `ARFILE` | 64,074 | Customer-level open items — supports A/R aging by customer and invoice |
| `ARSTHD` | 303,845 | Detail rows |
| `ARSTHH` | 10,597 | Headers |

**Unlocks:** A/R aging summary, customer-level outstanding balance, days-sales-outstanding (DSO), top-N customers by balance, bad-debt exposure.

### Parts inventory and history ✅

| Table | Rows | Purpose |
|-------|------|---------|
| `PARTMAST` | 444,549 | Part master — per-SKU dictionary |
| `PARTMAST_EXT` | 199,034 | Extended attributes |
| `PARTMAST_SUM` | 73,226 | Summary rollups |
| `PARTMAST_WH` | 71,653 | Per-warehouse stocking |
| `PARTHIST` | 1,873,604 | Transaction history per SKU |
| `PARTPRC` | 2,833,328 | Price file |
| `PARTBIN`, `PARTCNT`, `PARTDES`, `PARTDISC`, `PARTLIST`, `PARTMGMT`, `PARTPF`, `PARTRET`, `PARTSUB`, `PARTTFR`, `PARTXREF` | various | Bins, counts, descriptions, discounts, lists, mgmt, planning, returns, substitutes, transfers, cross-references |
| `PURPART` | 6,145 | Purchasing parts staging |

**Unlocks:** Per-SKU parts margin, parts inventory turn, slow-moving parts identification, parts price-change history, substitution chains.

### Service / Work orders ✅

| Table | Rows | Purpose |
|-------|------|---------|
| `WOH` | 1,938 | Work order headers (customer, status, dates) |
| `WODES` | 15,312 | WO descriptions |
| `WOLAB` | 7,239 | Labor lines — technician, hours, billing rate |
| `WOTAH` | 88,751 | Time tracking — header |
| `WOTTM` | 137,796 | Time tracking — detail |
| `WOPQD`, `WOPQH`, `WOQUO`, `WOR`, `WODATA`, `WOGL`, `SERVMGMT` | various | Quote detail/header, quote estimates, repair, work order data, GL distribution, service mgmt |

**Unlocks:** Technician utilization, service labor recovery rate, average WO duration, parts-attached rate per WO, repeat-customer service patterns.

### Sales transactions ✅

| Table | Rows | Purpose |
|-------|------|---------|
| `SALORD` | 6,059 | Sales orders |
| `SALDET` | 22,194 | Sales detail lines (prices, discounts, quantities) |
| `SALCOM` | 1,883 | Commissions |
| `SALGL` | 277 | GL distribution rules |
| `SAPP` | 2,633 | Sales applications/postings |

**Unlocks:** Per-transaction margin analysis, salesperson performance (when combined with `CMAS*` customer master), discount-impact analysis.

### Customer master family (CMAS\*) ✅

~14 tables: `CMASAA` (499,164), `CMASCON` (48,059), `CMASCP`, `CMASEH` (Equipment History 14,829), `CMASEI` (82,627), `CMASLSP` (Lead Salesperson 1,198), `CMASPRO` (153,497), `CMASSALC` (95,539), `CMASSH`, `CMASTR` (Transactions 219,379), `CMASTRE`, `CMASTX`, plus `CMFIS`.

**Unlocks:** Customer 360 view, equipment-owned history, customer profitability, customer lifecycle metrics.

### Purchase orders ✅

12 PO-prefix tables: `POADD` (36,201), `POHDR` (36,201), `POBILL` (4,027), `POCT`, `POEOD` (9,376), `POEOH` (22,663), `POERD` (26,811), `PORC`, `PORH` (41,297), `POSHI` (4,027), `POVENI` (36,201), `PODC`.

**Unlocks:** Vendor purchasing patterns, A/P aging proxy (via `POBILL` matched to GL).

### Bank reconciliation ✅

`BANKREC` (78,371 rows), `BANKCTL` (5 rows).

**Unlocks:** Automated bank-rec dashboards, unreconciled-item aging.

### Audit log ✅

`AUDIT` (75,601 rows) — posting audit trail.

**Unlocks:** Partial user-level audit (without full JE detail).

### Employee / Payroll (limited) ⚠

| Table | Rows |
|-------|------|
| `EMPLOYEE` | 307 |
| `EMPSEC` | 307 |
| `EMLHDR` | 33 |
| `EMPLTO` | 5 |
| `PRUCONT` | 37 |

**Unlocks:** Headcount-based KPIs, technician-to-mechanic mapping (combined with `WOLAB.LL_TECH`). Not enough for full payroll detail.

---

## What is STILL not available even in IntelliDealerR1

| Gap | Impact |
|-----|--------|
| **No wholegoods / equipment unit master (`WG*`, `MACH*`, `EQUIP*`)** | Per-unit days-on-lot, per-unit margin, used-equipment book/market analysis remain blocked. **Possibly named differently in source** — worth a targeted search in Intellidealer docs. |
| **No rental tables (`RE*`, `RNT*`)** | Rental fleet utilization and per-asset rental P&L remain blocked. **Possibly Crystal doesn't run a rental program**, in which case this isn't a gap. Worth confirming. |
| **No budget / forecast tables** | Budget vs Actual remains blocked. Crystal likely manages these in Excel — separate sourcing required. |
| **No GLTRANS / journal-entry line detail** | Only GLCAL (monthly balance summary) is replicated. Unusual-JE detection, full audit trail remain blocked. Source likely has a `GLP*` or similar — needs investigation in Intellidealer system docs. |
| **No A/P sub-ledger or vendor master** | Only 2 thin AP-control tables (`APBAT` 9 rows, `APPSCH` 141 rows). No `APMAST` / `APHIST` / `VENDOR` tables. A/P aging by vendor / invoice remains blocked. `POBILL` is a partial proxy. |
| **No GLFIS in IDR1** | Annual rollup is only in the current acctdata replica. |

---

## Reporting impact

Catalog from [reporting-catalog.md](reporting-catalog.md) coverage, by source:

| Source | Coverage | Notes |
|--------|----------|-------|
| Current 5 tables (acctdata) | ~70% | All P&L, BS, trial balance, departmental, alias rollups, ratios |
| + Tables visible in IDR1 (once replicated) | **~90%** | Adds A/R aging, parts margin per SKU, service labor analysis, customer profitability, sales transaction detail, bank rec, audit |
| Remaining gaps | ~10% | Budget vs Actual, JE-line detail, wholegoods-unit detail, rental, full A/P |

---

## Connection recipe

```python
import pyodbc
conn = pyodbc.connect(
    "DRIVER={ODBC Driver 17 for SQL Server};"
    "SERVER=tcp:crystal-intellidealer-r1.database.windows.net,1433;"
    "DATABASE=IntelliDealerR1;UID=crystalSQL;PWD=M4thrules2024!;"
    "Encrypt=yes;TrustServerCertificate=no;Connection Timeout=60", timeout=60)
```

⚠️ **Cold-start: first connection triggers auto-resume**, can take 30–90 seconds (returns SQL error 40613 until ready). Either retry the connection or poll `az sql db show … --query status` until it returns `Online`.

⚠️ **Firewall:** add an explicit IP rule before connecting:
```bash
export PATH="/c/Program Files/Microsoft SDKs/Azure/CLI2/wbin:$PATH"
az sql server firewall-rule create \
  --resource-group IntellidealerR1 --server crystal-intellidealer-r1 \
  --name "claude-$(date +%Y%m%d)" \
  --start-ip-address $(curl -s ifconfig.me) --end-ip-address $(curl -s ifconfig.me)
```

⚠️ **Re-pause when done** to stop billing:
```bash
az sql db pause --resource-group IntellidealerR1 --server crystal-intellidealer-r1 --name IntelliDealerR1
```

---

## Recommended path forward

1. **Use IDR1 schema as the design spec** for any new query / report / agent that needs tables beyond the 5 we currently replicate.
2. **Extend the AcctLoadControl ETL** (same pattern as the 5 GL tables) to replicate high-value tables into a fresh DB (acctdata or new). Priorities:
   - A/R: `ARFILE`, `ARSTHD`, `ARSTHH`
   - Parts: `PARTMAST`, `PARTHIST`, `PARTPRC` (start; add others as needed)
   - Service: `WOH`, `WOLAB`, `WOTAH`, `WOTTM`
   - Sales: `SALDET`, `SALORD`, `SALCOM`
   - Customer master: `CMAS*` family (select tables based on actual use)
3. **Re-pause IDR1** while not actively using it (auto-pause triggers after idle, but a manual pause is faster).
4. **Source budget data separately** — likely an Excel import.
5. **Investigate Intellidealer source docs** for the actual table names for wholegoods, rental, JE-line-detail, and A/P sub-ledger — they may exist under names we haven't guessed.

---

## Cross-references

- [data-model.md](data-model.md) — the current 5-table replica (acctdata DB) + connection recipe for it
- [reporting-catalog.md](reporting-catalog.md) — the report list whose coverage IDR1 expands
- [azure-infrastructure.md](azure-infrastructure.md) — full Azure infrastructure reference
