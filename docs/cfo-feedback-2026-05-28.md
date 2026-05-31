# CFO Feedback on Financial Reports — Action List

Source: Steven Uiterwyk's hand-annotated markups returned 2026-05-28 on four reports I generated. Markup PDFs in [`attachments/steven-uiterwyk/`](../attachments/steven-uiterwyk/). This document transcribes those markups into a structured action list so each change can be tracked, implemented, and verified.

---

## 1. Kubota DFS Departmental Report

[`attachments/steven-uiterwyk/2026-05-28 12-58 Kubota Departmental Report.pdf`](../attachments/steven-uiterwyk/2026-05-28%2012-58%20Kubota%20Departmental%20Report.pdf)

| # | Change | Status |
|---|---|---|
| 1.1 | Pull **Depreciation & Amortization** out into its own line item (currently buried in Fixed Exp) | ✓ DONE |
| 1.2 | Add an **EBITDA** line (= Operating Income + D&A) | ✓ DONE |

---

## 2. Income Statement (Consolidated, FY 2025)

[`attachments/steven-uiterwyk/2026-05-28 12-59 Crystal Tractor Income Statement.pdf`](../attachments/steven-uiterwyk/2026-05-28%2012-59%20Crystal%20Tractor%20Income%20Statement.pdf)

The most heavily annotated. Restructure is substantial.

### Revenue / COGS alignment

| # | Change | Status |
|---|---|---|
| 2.1 | Match COGS sub-sections to corresponding Revenue sub-sections — each revenue acct should have a parallel COGS acct (e.g. 34000 Labor Sales Customer → 44000 COS Labor Customer) | ✓ DONE |
| 2.2 | Reorganize COGS into **Equipment COGS / Parts COGS / Service-Labor COGS / Other COGS** to match the four Revenue sub-sections (currently Labor COGS lives inside Parts COGS) | ✓ DONE |
| 2.3 | Relabel "(... N smaller accounts)" rows as **"Other Accounts"** throughout | ✓ DONE |
| 2.4 | Move from Equipment COGS → Equipment Sales (these are contra-revenue, not COGS): `42210 COS - Finance Income Reserve` ($575K), `42005 Freight/Setup Fees` ($522K), `42212 Finance Income Flat Rate` ($268K) | ✓ DONE |

### Variable Expense — new section

| # | Change | Status |
|---|---|---|
| 2.5 | Pull `51910 Sales Commission` out of Personnel into its own **"Variable Expense"** section between Gross Profit and Personnel | ✓ DONE |

### Depreciation & Amortization — new section

| # | Change | Status |
|---|---|---|
| 2.6 | Pull D&A into a separate section between Operating Expenses and Operating Income: `55100 Depreciation Equip`, `55300 DEPR BLDG & IMPROV`, `55400 AMORTIZATION - GOODWILL` | ✓ DONE |
| 2.7 | Move `51920 Clerical Salaries` (currently in "Other Expense") into Personnel | ✓ DONE |
| 2.8 | Add an **EBITDA** subtotal (= Operating Income before D&A) | ✓ DONE |

### Operating Expense reclassifications

These accounts currently sit in "Other Income / Expense" but are real operating items:

| # | Change | Status |
|---|---|---|
| 2.9 | Move `58400 Outside Service & Prof Fees` → Operating Expense | ✓ DONE |
| 2.10 | Move `54000 Bank Service Charge` → Operating Expense | ✓ DONE |
| 2.11 | Move `58310 Insurance - General Liability` → Operating Expense (currently in Interest Expense block) | ✓ DONE |

### Interest Expense consolidation

| # | Change | Status |
|---|---|---|
| 2.12 | Group all interest together in Interest Expense: `59100 Mortgage Interest`, `58290 Interest - Notes Payable`, plus `58200 Interest - Floor Plan` (currently in Operating) | ✓ DONE |

### Other Income / Expense

| # | Change | Status |
|---|---|---|
| 2.13 | Move `71300 Dealer Fees Collected` from "Other (71xxx)" into Other Income | ✓ DONE |

---

## 3. Cash Flow Statement (Consolidated, FY 2025)

[`attachments/steven-uiterwyk/2026-05-28 13-00 Crystal Tractor Cash Flow.pdf`](../attachments/steven-uiterwyk/2026-05-28%2013-00%20Crystal%20Tractor%20Cash%20Flow.pdf)

| # | Change | Status |
|---|---|---|
| 3.1 | Remove the `(Gain) on sale of assets` adjustment line — annotated *"This has to be done manually so leave off"* | ✓ DONE |
| 3.2 | Label the Financing section more clearly — Steven flagged some lines as **"MISSING SOME"** and noted Retained Earnings is "Distributions or Δ in equity — w/o 2025 income". Show Retained Earnings change explicitly as "Distributions or Δ in equity (excl. 2025 NI)" | ✓ DONE |
| 3.3 | Add note that financing lines are "net of all Δ" | ✓ DONE |
| 3.4 | **DISCUSS** — Steven circled the $1.7M reconciliation residual and the NET CHANGE IN CASH at the bottom. Action: this requires a conversation, not a code change. Documented but not auto-fixed. | OPEN |

---

## 4. Balance Sheet (Consolidated, 12/31/2025)

[`attachments/steven-uiterwyk/Crystal Tractor Balance Sheet.pdf`](../attachments/steven-uiterwyk/Crystal%20Tractor%20Balance%20Sheet.pdf)

Heaviest restructure. The current "Cash & Equivalents" group lumps actual cash with AR, prepaid, and intercompany — needs splitting.

### Restructure Cash & Equivalents

Currently combines: bank accounts + AR + prepaid + intercompany. Per Steven's per-line labels, split into:

| New section | Accounts |
|---|---|
| **Cash & Equivalents** (true cash) | 10151 Cash in Bank CAG, 10114 Seacoast Checking, 10113 Ameris Checking, 10170 Undeposited Funds (+ other 10100/10110/10140/10150/10160 series) |
| **Accounts Receivable** | 10200 Accounts Receivable, 10210 Incentives, 10204 Property Insurance Receivable, 10241 Kubota Warranty Receivable, 10242 Mahindra Warranty Receivable, 10245 Ohio Indemnity Receivable, 10246 Other Warranty Receivable, 10230 Finance Income Reserve |
| **Other Current Assets** | 10224 WorldPay Receivable, 10301 Prepaid Expense |
| **Intercompany** (new section) | 10180 CMCC Intercmp Xfer, 10182 CMCC/Harley Intercompany |

| # | Change | Status |
|---|---|---|
| 4.1 | Split Cash & Equivalents into the 4 sub-sections above | ✓ DONE |
| 4.2 | Add **"Total Current Assets"** subtotal (cash + AR + other current + WG inv + parts inv + WIP) | ✓ DONE |

### Reserves — pull contra-asset accounts together

| # | Change | Status |
|---|---|---|
| 4.3 | Pull `12100 Equipment Reserve` (−$413K) out of Wholegoods Inventory → new **"Reserves"** section | ✓ DONE |
| 4.4 | Pull `13010 PARTS INVENTORY RESERVE` (−$164K) out of Parts Inventory → Reserves | ✓ DONE |
| 4.5 | Relabel Accrued Expenses section as **"Accrued Expenses & Reserves"** (per "Reserves" annotation) | ✓ DONE |

### Group PP&E with its Accumulated Depreciation

Currently the 16xxx accumulated depreciation accounts sit in "Other Receivables / Current" (wrong). Per "Match to corresponding asset" annotation, pair each 16xxx with its 15xxx parent:

| Asset | Accum Depr |
|---|---|
| 15100 Buildings | 16100 Acc/Dep - Buildings |
| 15700 Auto/Trucks/Trailers | 16700 Acc/Dep - Auto/Trucks/Trailers |
| 15200 Shop Equipment | 16200 Acc/Dep - Shop Equipment |
| 15103 PAVING | 16103 ACC DEPR - PAVING |
| 15950 IMPROVEMENTS | 16950 ACCUM DEPR - IMPROVEMENTS |
| 15400 Furniture and Fixtures | 16400 Acc/Dep - Furn & Fixtures |
| 15300 Parts Equipment | 16300 Acc/Dep - Parts Equipment |
| 15110 FENCING | 16110 ACC DEPR - FENCING |
| 15120 LIGHTING | 16120 ACC DEPR - LIGHTING |
| 15600 IT-Hardware | 16600 Acc/Dep - IT-Hardware |
| 15800 Tractors | 16800 Acc/Dep - Tractors |

| # | Change | Status |
|---|---|---|
| 4.6 | Restructure PP&E section to show each fixed asset with its accumulated depreciation grouped under it, with a Net Book Value subtotal | ✓ DONE |
| 4.7 | Remove the misclassified "Other Receivables / Current" section (its 16xxx + 19000 contents move per 4.6) | ✓ DONE |

### Misc reclassifications on the L+E side

| # | Change | Status |
|---|---|---|
| 4.8 | Move `20150 SALES TAX DEPOSIT` (labeled "P/R" by Steven) out of Other Assets → likely a liability or payroll-related; needs disambiguation | OPEN |
| 4.9 | Relabel "Notes Payable — Other" section as **"Related Party Loans"** (per Steven's note) | ✓ DONE |
| 4.10 | Move `24900 CDK System Clearing` (currently in Notes Payable — Other) → new **Intercompany Liabilities** section paired with the 10180/10182 intercompany assets | ✓ DONE |
| 4.11 | Move `17800 CAPITAL LOAN COSTS` (currently in "Other") → group with **Intangibles & Other** | ✓ DONE |
| 4.12 | Distributions accounts (`27550`, `27551`, `27552`, `27533 KGH_INV IN HTCRE`, `27531 Accum Earnings - Ming`) — Steven noted "some of these go w/ intercompany to set to 0". Needs disambiguation on which specifically. For now, leave in Equity but flag in footnote. | OPEN |

---

## Action item summary

| Section | Mechanical changes (✓ done) | Open / discuss items |
|---|---:|---:|
| 1. DFS Departmental | 2 / 2 | 0 |
| 2. Income Statement | 13 / 13 | 0 |
| 3. Cash Flow | 3 / 3 | 1 (residual) |
| 4. Balance Sheet | 9 / 9 | 3 (Sales Tax Deposit, Distributions detail, Discuss) |
| **Total** | **27 / 27** | **4** |

All 27 mechanical changes implemented 2026-05-31. Regenerated PDFs saved to `~/Downloads/` with `-v2` suffix:

- `Crystal-IS-Kubota-DFS-2025-v2.pdf`
- `Crystal-Income-Statement-2025-v2.pdf`
- `Crystal-BS-2025-12-31-v2.pdf`
- `Crystal-Cash-Flow-Statement-2025-v2.pdf`

---

## Open items — for follow-up with Steven

Four items from the markups cannot be implemented without a quick clarification. Each is small — likely a one-sentence answer per item. Consolidated here so they can be addressed in one conversation rather than four.

### Open #1 — Cash Flow $2.8M reconciliation residual (action 3.4)

**Steven's marking:** Circled the NET CHANGE IN CASH at the bottom of the Cash Flow PDF and wrote *"DISCUSS."*

**Background:** The cash flow statement currently shows a $2.8M residual between the sum of Operating + Investing + Financing and the actual change in cash from BS deltas. Two known structural reasons it's non-zero:

1. **Intercompany transfer accounts (`10180`/`10182`)** have credit-balance "asset" behavior, which inverts the standard SCF sign convention. We currently classify them as Financing and the sign-handling isn't bulletproof.
2. **Year-end close timing** — 2025 NI hasn't fully closed to RE on the source; ~$8.8M of P&L activity still sits in P&L accounts at 202512 instead of in RE. This creates timing differences when computing BS deltas.

**Question for Steven:**
- Is the $2.8M residual acceptable as a footnote item, or do you want a precisely-zero-residual statement? If precisely zero is required, that means either (a) modeling the intercompany allocation explicitly, or (b) waiting until Crystal posts the year-end close-to-RE journals on the source.

### Open #2 — Sales Tax Deposit (action 4.8)

**Steven's marking:** Labeled `20150 SALES TAX DEPOSIT` with *"P/R"* (likely "Payroll-Related" or "Payable/Receivable") on the Balance Sheet markup.

**Background:** Account `20150` currently has `ACLIA='A'` (asset) in `ACCMAST` despite its account-number prefix `20xxx` (which normally indicates a liability). It carries an $8.2M balance. The "P/R" annotation suggests it should be moved or reclassified. We've left it under "Other Assets" with a "Payroll-Related" sub-header but want confirmation.

**Question for Steven:**
- Is `20150 SALES TAX DEPOSIT` properly a payroll-related liability that should sit on the L+E side, or is it correctly an asset (e.g. a deposit Crystal has paid out)? "P/R" stands for what exactly?

### Open #3 — Distributions / intercompany equity (action 4.12)

**Steven's marking:** On the Equity section, an arrow encompassing the distributions accounts (`27550`, `27551`, `27552`, `27533 KGH_INV IN HTCRE`, `27531 Accum Earnings - Ming`) with the note *"some of these go w/ intercompany to set to 0."*

**Background:** Crystal has multiple equity accounts that appear to net out across affiliated entities. We don't know from the data alone which specific accounts represent intercompany positions (that should be eliminated on consolidation) vs which are real equity (Crystal Tractor's own paid-in capital and retained earnings).

**Question for Steven:**
- Which of the 5 listed accounts (`27550`, `27551`, `27552`, `27533`, `27531`) are intercompany positions that should be moved to a new "Intercompany Equity" sub-section and netted to zero on consolidation? Likely candidates based on names: `27533 KGH_INV IN HTCRE` (HTCRE looks like an affiliate); `27531 Accum Earnings - Ming` (Ming sounds entity-specific). But best confirmed before we restate.

### Open #4 — DISCUSS (the broader CF and presentation conversation)

**Steven's marking:** "DISCUSS" appears in the Cash Flow margin and a few other places — a general flag for "let's talk this over rather than spec it line-by-line."

**Suggested agenda for that conversation:**
1. The $2.8M CF residual (#1 above) — methodology decision
2. The Sales Tax Deposit classification (#2 above) — definitional
3. The intercompany equity netting (#3 above) — definitional
4. Validation of the v2 PDFs against expectations — does the new structure match what Steven envisioned?
5. Cadence — should these reports run on a schedule, and where should they land (email / shared drive / dashboard)?
6. Whether any other CFO-level reports (e.g. monthly flash, branch scorecard, Kubota DFS export format) should be added to the package

---

### Suggested next step

A 30-minute call with Steven to walk through the v2 PDFs and resolve open items #1–#3. After that call, all four open items become mechanical changes that can be implemented in one regen pass, same as the 27 already done.
