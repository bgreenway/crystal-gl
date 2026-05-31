# Balance Sheet Tool — Design and Open Questions

A focused design note for the `balance_sheet` MCP tool. Captures the approach, the three open questions that need verification before implementation, and the reconciliation strategy against Crystal's existing report.

Goal: produce a Balance Sheet that **reconciles line-for-line** to Crystal's existing format ([Balance Sheet Summary.xlsx](Balance%20Sheet%20Summary.xlsx) for Tallahassee, [Balane Sheet Detail.xlsx](Balane%20Sheet%20Detail.xlsx) for the underlying detail).

---

## Approach

For a target `period` and optional `branch`:

1. Sum `dbo.GLCAL.GB_AMT` for BS-side accounts only (assets / liabilities / equity — P&L accounts excluded by `ACCMAST.ACTYP`).
2. Group the sums into Crystal's named buckets — the same sections shown in [Balance Sheet Summary.xlsx](Balance%20Sheet%20Summary.xlsx):
   - **Current Assets:** Cash Equivalents, Accounts Receivable, Whole Goods Inventory, Parts and Other Inventories, Other Current Assets
   - **Fixed Assets** (single line in summary; expanded in detail)
   - **Other Assets:** Notes Receivable, Capitalized Loan Costs and Deposits, Intangible Assets, Due from Affiliates, Other Miscellaneous Assets
   - **Current Liabilities:** Trade Accounts Payable, Wholegoods Payable, Accrued Liabilities
   - **Long Term Liabilities:** Long Term Debt - Mortgage, Long Term Acquisition Financing
   - **Equity:** Common Stock, Net Contribution of Capital, Retained Earnings, Current Year Profit (Loss)
3. Sign-flip liabilities and equity for display so they appear positive on the report.
4. Compute **Current Year Profit (Loss)** from the same `v_IncomeStatementLines.NetIncomeImpact` aggregation that powers the P&L tools — slot it into the Equity section.
5. Return the Assets / Liabilities / Equity structure with the standard accounting identity verified: `Total Assets = Total Liabilities + Total Equity`.

---

## Three things to verify before writing SQL

### 1. `GB_AMT` semantics for BS accounts — RESOLVED 2026-05-27

**`GLCAL.GB_AMT` is dual-mode:**

- For **BS accounts** (`ACTYP='1'`) — period-end **running balance** (snapshot). Query: `WHERE GB_DATE = <period>`. Do NOT sum across periods.
- For **P&L accounts** (`ACTYP='2'` or `'3'`) — period **activity** (flow). Query: `SUM(GB_AMT) WHERE GB_DATE BETWEEN x AND y`. Sums across the fiscal year give annual totals.

**How it was verified:** traced Petty Cash (10140) over 9 months — values stable around $7K–$14K (snapshot pattern, balances only change when activity hits the account). Traced Sales — New Sany (31001) over 12 months of 2025 — values varied $0.4M–$1.8M monthly, summing to the annual revenue total ($11.58M). And `GLFIS` annual rollups match `SUM(GLCAL monthly)` for P&L accounts, confirming the flow semantic for P&L.

This closes open question #1 in [mcp-server-spec.md](mcp-server-spec.md#13-open-questions-for-review). For implementation: the `balance_sheet` tool query is `SELECT … FROM GLCAL WHERE GB_DATE = ? AND ACTYP='1'` with no date-range sum.

### 2. Account → BS section mapping — partially revised 2026-05-27

Crystal's BS buckets ("Cash Equivalents", "Whole Goods Inventory", "Due from Affiliates", etc.) are **not** directly stored in the 5 replicated tables. Three candidate sources for the mapping:

| Candidate | Source | Status |
|-----------|--------|--------|
| `ACCMAST.ACTYP` + `ACLIA` | Single-char codes in the account master | **Two-level only**: `ACTYP='1'` partitions BS from P&L; within BS, `ACLIA='A'` = Asset and `ACLIA='L'` = Liability+Equity (no separate Equity class). Too coarse for named sub-buckets like "Cash Equivalents". |
| `COACMAST.CA_GLFA` (alias) | Numeric alias account observed to encode section in its leading digits (`F202`=cash, `F231`=inventory, `F310`=floorplan payable, `F370`=retained earnings, `F335`=note payable) | **Most viable** — verified during 2026-05-27 BS work that account-number prefix rules (10x=cash, 12x=wholegoods inventory, 13x=parts inventory, 15x=PP&E, 20350=floorplan, 25x/26x=notes payable, etc.) produce clean grouping consistent with the Summary spreadsheet. The `CA_GLFA` alias likely encodes the same groupings with finer resolution. |
| [Balane Sheet Detail.xlsx](Balane%20Sheet%20Detail.xlsx) | ~~Account-level rows organized under Crystal's actual BS headings~~ | **NOT a usable mapping source.** Verified 2026-05-27: the Detail file is the **full CoA × all CCs** (147 distinct CCs, 32,542 rows), and ~99% of amount cells are empty. The "TALLAHASSEE" header is the user's branch context, not a row filter. Section structure isn't carried row-by-row either. |

**Recommended path (revised):** start with leading-digit account-number rules (already proven to balance per-branch BS to the dollar — see §4 below) and refine sub-bucket labels by joining to `COACMAST.CA_GLFA` aliases. Cross-check named buckets against the Tallahassee Summary spreadsheet's section labels. Only if alias coverage is incomplete should a static `(Co, Acct, CC) → BS_Section` table become necessary.

### 3. Branch dimension — RESOLVED 2026-05-27

Crystal's BS is per-branch (the sample file is Tallahassee). Both questions are answered:

- **Branch lives in `GLCAL.GB_GLC` (cost center), not `GB_DIV`.** All replica data has `Division='01'`; the branch and department dimensions are both encoded in the 3-digit cost-center code.
- **Trailing 2 digits = branch location.** Verified via the column order in [Sales and Gross Summary.xlsx](Sales%20and%20Gross%20Summary.xlsx) cross-checked against `SUM(GB_AMT)` per CC suffix for acct `32000`: `01`=Deland, `02`=Leesburg, `03`=Parts Warehouse, `04`=Chiefland, `05`=Spring Hill, `06`=Ocala, `07`=Homosassa, `08`=Hastings, `09`=Palatka, `10`=Starke, `11`=Live Oak, `12`=Madison, `13`=Panama City, `14`=Tallahassee, `15`=Cairo, `16`=Jacksonville, `17`=Lecanto, `18`=Dothan (no 2025 activity).
- **Leading digit of CC = Kubota DFS department:** 0=BS/Corporate, 1=Admin, 2=Sales, 3=Service, 4=Parts, 5=Rental.

Full encoding table and query patterns now live in [data-model.md](data-model.md#cost-center-encoding--branch-and-department).

---

## 4. Raw-GL view vs management-report view — discovered 2026-05-27

The biggest finding from the 2026-05-27 BS build: **Crystal's published per-branch BS is NOT a straight projection of the GL.** Two distinct views coexist.

### 4.1 The raw-GL view (what `dbo.GLCAL` actually contains)

A per-branch BS built with the simple filter `WHERE RIGHT(GB_GLC, 2) = '<branch>' AND ACTYP='1'`, post-close (NI rolled into RE):

- **Every one of the 17 active branches balances to the dollar** ($0 residual between Assets and Liab+Equity).
- Branch BS totals range $0.3M (Palatka) to $7.5M (Live Oak); chain total reconciles to the consolidated BS.
- This reveals that **Crystal's GL is structured as a self-balancing per-branch ledger** — each branch's books close independently, with no inter-branch reconciliation needed at the GL level. That's an unusually clean structural property and is the basis for any branch-level BS we build straight from the GL.

### 4.2 The management-report view (what the Summary spreadsheet shows)

The Tallahassee Summary spreadsheet shows **TOTAL ASSETS = −$145K** and `Due from Affiliates = −$4.2M`. By contrast, the raw-GL Tallahassee BS for the same branch (Dec 2025) shows **TOTAL ASSETS = +$4.6M** with positive component balances throughout.

The gap is real and explainable: Crystal's management report applies **inter-branch / sub-entity allocations** on top of the raw GL. Centrally-held assets (cash at corporate bank accounts, central AR, central inventory) get pushed off branch books through the `Due from Affiliates` line. The Tallahassee Detail file showing composite IDs like `10100091` / `10100093` (Seacoast Checking at sub-entity CCs `091` and `093`) reflects that Crystal's bank accounts and other central assets live at sub-entity cost centers, not at the branch.

A single confirmed data point: `Financed Clearing` at CC `18000014` = **$47,664** in the Detail file, which closely matches the Tallahassee Summary's `Cash Equivalents` line of **$47,825**. So the suffix-14 filter is correct *for the GL portion of branch-attributed activity*; the additional ~$160 plus all the central assets / `Due from Affiliates` adjustments come from the allocation layer.

### 4.3 Implication for the `balance_sheet` tool

There are two distinct tools hiding here, and the spec needs to pick one (or build both):

| Tool variant | Returns | Reconciles to |
|---|---|---|
| `balance_sheet(branch=…, view="raw_gl")` | What the GL actually posts to that branch's CCs | Balances internally to $0; nothing external to reconcile against |
| `balance_sheet(branch=…, view="report")` | The Tallahassee-Summary-style management view | The native Crystal spreadsheet — requires modeling Crystal's allocation rules |

The raw-GL view is **free** — already implemented experimentally and known to balance. The report view requires reverse-engineering Crystal's allocation rules (probably by working backward from a series of `(raw_gl, summary_spreadsheet)` reconciliation pairs across multiple branches).

**Recommended:** ship the raw-GL view first as `balance_sheet(branch=…)` since it's foundational. Treat the management-report view as a follow-on (`balance_sheet_report` or a `view="report"` flag) once we've codified the allocation layer.

---

## Reconciliation strategy

Two reconciliation targets, based on which view (see §4):

### Raw-GL view — internal balancing check

No external reference needed; the GL self-reconciles:

1. For each branch suffix `01..17`, sum BS account snapshots at any period-end and confirm Assets = Liab+Equity (post-NI-roll). This already works as of 2026-05-27 — every branch balances to the dollar.
2. Confirm the chain total matches the consolidated BS produced from `WHERE ACTYP='1'` with no CC filter.

### Management-report view — Tallahassee Summary spreadsheet

Use [Balance Sheet Summary.xlsx](Balance%20Sheet%20Summary.xlsx) (Tallahassee) as the golden test once the allocation rules are modeled:

1. Run `balance_sheet(branch="Tallahassee", period=<period the spreadsheet represents>, view="report")`.
2. Compare every line (Cash Equivalents, AR, …, Due from Affiliates, …, TOTAL ASSETS, …, TOTAL LIABILITIES AND EQUITY).
3. Investigate any difference > rounding; differences will mostly trace back to allocation rule edge cases.

**Timing note:** the Summary spreadsheet was generated ~2026-05-22 and reflects data through ~April 2026. The replica is currently through **February 2026** (as of 2026-05-27 ETL); the AcctLoadControl pipeline advances by roughly one period per cycle. Pick reconciliation target periods that exist in both sources — most likely Dec 2025 or earlier — or wait for further ETL advances. See [reporting-catalog.md](reporting-catalog.md#0-crystals-actual-report-formats-working-spreadsheets-in-this-folder) § "Open question — data freshness in the spreadsheets".

---

## Riskiest assumption

For the **raw-GL view**: none significant — the model is already empirically verified balancing.

For the **management-report view**: modeling Crystal's inter-branch / sub-entity allocation rules. Without them, the report-style tool won't reconcile to Crystal's Summary spreadsheet. There's no documented source for these rules in the replica — they appear to live in the Intellidealer report generator. Expect this to require a reverse-engineering pass against several `(branch, period)` pairs where we have both the raw GL and the published spreadsheet.

---

## Implementation plan

1. ~~**Verify GB_AMT semantics**~~ — done 2026-05-27 (§1).
2. **Write `balance_sheet(branch?, period, view="raw_gl")` tool** — straightforward; the working script from the 2026-05-27 BS PDF run already does the math. Group by account-number leading-digit rules; sign-flip liabilities; roll branch-level NI from `v_IncomeStatementLines` into Retained Earnings.
3. **Extract sub-bucket labels** by joining to `COACMAST.CA_GLFA` aliases; cross-check against the Summary spreadsheet's section names. Only build a static `BSSectionMap` if alias coverage is insufficient.
4. **Add to `crystal-gl-mcp`** server, register in tool list, redeploy.
5. **(Future)** Reverse-engineer Crystal's allocation layer for the `view="report"` variant. Begin with Tallahassee + 1–2 other branches where both raw-GL and Summary spreadsheets are available; codify the rules; ship as a second tool.
6. **Document** the leading-digit account-number → BS section rules in [data-model.md](data-model.md) so future agents understand the convention.

---

## Output shape (summary mode)

```json
{
  "branch": "Tallahassee",
  "period": 202604,
  "sections": [
    {
      "category": "ASSETS",
      "groups": [
        {
          "name": "CURRENT ASSETS",
          "lines": [
            {"name": "Cash Equivalents",        "amount":  47825},
            {"name": "Accounts Receivable",     "amount":  40019},
            {"name": "Whole Goods Inventory",   "amount": -16445},
            {"name": "Parts and Other Inventories", "amount": 151707}
          ],
          "subtotal": 223106
        },
        {"name": "FIXED ASSETS", "lines": [...], "subtotal": 397311},
        {"name": "OTHER ASSETS", "lines": [...], "subtotal": -765520}
      ],
      "total": -145104
    },
    {
      "category": "LIABILITIES",
      "groups": [
        {"name": "CURRENT LIABILITIES", "lines": [...], "subtotal": 117557},
        {"name": "LONG TERM LIABILITIES", "lines": [...], "subtotal": 0}
      ],
      "total": 117557
    },
    {
      "category": "EQUITY",
      "groups": [
        {"name": "EQUITY", "lines": [
          {"name": "Common Stock", "amount": 0},
          {"name": "Net Contribution of Capital", "amount": 0},
          {"name": "Retained Earnings", "amount": -180912},
          {"name": "Current Year Profit (Loss)", "amount": -81748}
        ], "subtotal": -262660}
      ],
      "total": -262660
    }
  ],
  "balance_check": {
    "total_assets":  -145104,
    "total_l_and_e": -145103,
    "diff": 1,
    "ok": true
  },
  "meta": { "as_of": "...", "query_ms": ..., "source": "dbo.GLCAL + BSSectionMap" }
}
```

(Numbers above are from the Tallahassee summary file — that's the target the tool should reproduce.)
