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

### 1. `GB_AMT` semantics for BS accounts: running balance or period activity?

P&L accounts are unambiguously **period activity** (each month's row is that month's amount). For balance-sheet accounts the convention could be either:

- **Running balance** — each row is the period-end balance. Query: `WHERE GB_DATE = <period>`.
- **Period activity** — each row is the change during that period. Query: `SUM(GB_AMT) WHERE GB_DATE <= <period>` from account inception.

**How to test (a small query):** pick a cash account (e.g. acct `10100` Seacoast Checking), pull the last 6 consecutive months from `dbo.GLCAL`, look at the pattern:

- If the numbers slowly drift up/down month-to-month → running balance.
- If they look like deposits/withdrawals (high variance, can flip sign) → period activity.

This was open question #1 in [mcp-server-spec.md](mcp-server-spec.md#13-open-questions-for-review).

### 2. Account → BS section mapping

Crystal's BS buckets ("Cash Equivalents", "Whole Goods Inventory", "Due from Affiliates", etc.) are **not** directly stored in the 5 replicated tables. Three candidate sources for the mapping:

| Candidate | Source | Status |
|-----------|--------|--------|
| `ACCMAST.ACTYP` | Single-char type code in the account master | Coarse — likely encodes top-level asset/liability/equity, not the named buckets |
| `COACMAST.CA_GLFA` (alias) | Numeric alias account observed to encode section in its leading digits (`F202`=cash, `F231`=inventory, `F310`=floorplan payable, `F370`=retained earnings, `F335`=note payable) | Promising but unverified |
| **[Balane Sheet Detail.xlsx](Balane%20Sheet%20Detail.xlsx)** | 32,542 account-level rows organized under Crystal's actual BS headings | **The mapping IS this file** |

**Recommended path:** extract the lookup from [Balane Sheet Detail.xlsx](Balane%20Sheet%20Detail.xlsx) directly. One-time extraction, produces a static `(Co, Acct, CC) → BS_Section` table that we either:

- Bake into the MCP server source (small JSON dict), or
- Load into a new `dbo.BSSectionMap` table in the acctdata DB.

Either way, the spreadsheet is the ground truth. Cross-check the result against `CA_GLFA` patterns to see if the alias rule alone would have worked — if it does, we can drop the static lookup later.

### 3. Branch dimension

Crystal's BS is per-branch (the sample file is Tallahassee). Two unknowns:

- Does *branch* in Crystal's reports correspond to `GLCAL.GB_GLC` (cost center) or `GLCAL.GB_DIV` (division)?
- What's the full list of cost-center / division values that constitute each branch? Crystal has **18 branches** per [Sales and Gross Summary.xlsx](Sales%20and%20Gross%20Summary.xlsx) — Deland, Leesburg, Parts Warehouse, Chiefland, Spring Hill, Ocala, Homosassa, Hastings, Palatka, Starke, Live Oak, Madison, Panama City, Tallahassee, Cairo, Jacksonville, Lecanto, Dothan.

**How to test:** pick a few accounts that appear in Tallahassee's Balance Sheet Detail file (with their composite account IDs like `10100091`, `10112000`). The composite ID structure already encodes Acct + something — decoding those 8-digit IDs may give the branch dimension for free.

---

## Reconciliation strategy

Use [Balance Sheet Summary.xlsx](Balance%20Sheet%20Summary.xlsx) (Tallahassee) as the golden test:

1. Run `balance_sheet(branch="Tallahassee", period=<period the spreadsheet represents>)`.
2. Compare every line (Cash Equivalents, AR, …, TOTAL ASSETS, …, TOTAL LIABILITIES AND EQUITY).
3. Investigate any difference > rounding.

**Important caveat about timing:** the spreadsheet was generated ~2026-05-22 and shows data through ~April 2026, but the **replica currently stops at January 2026**. So the reconciliation has to be one of:

- Wait for the ETL to refresh with the newer source data (re-run `AcctLoadControl`), then reconcile against April 2026 — preferred.
- Reconcile against a January 2026 snapshot if Crystal can regenerate the spreadsheet for that period.

See the freshness note in [reporting-catalog.md](reporting-catalog.md#0-crystals-actual-report-formats-working-spreadsheets-in-this-folder) — § "Open question — data freshness in the spreadsheets".

---

## Riskiest assumption

The account → BS section mapping (verification #2). Without it, the sections won't reconcile to Crystal's actual report. Mitigated by the fact that [Balane Sheet Detail.xlsx](Balane%20Sheet%20Detail.xlsx) exposes the mapping directly — extraction is an hour of work, not multi-day discovery.

---

## Implementation plan

1. **Verify GB_AMT semantics** for BS accounts (one SQL query, 5 min).
2. **Extract BS section mapping** from [Balane Sheet Detail.xlsx](Balane%20Sheet%20Detail.xlsx) → static JSON lookup or new `dbo.BSSectionMap` table.
3. **Identify branch → cost-center mapping** from composite account IDs in the detail file plus a spot-check query.
4. **Write `balance_sheet` tool** with the spec from [mcp-server-spec.md §6.1](mcp-server-spec.md#balance_sheet):
   - Params: `period`, `branch?`, `detail` (`summary` | `by_account`), `comparative` (`none` | `prior_period` | `prior_year`)
   - Returns: structured JSON matching Crystal's BS layout
5. **Reconcile** against Tallahassee spreadsheet (once ETL refreshes).
6. **Add to `crystal-gl-mcp`** server, register in tool list, redeploy.
7. **Document the mapping** in the data-model doc so future agents understand the alias → BS section convention.

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
