# Intellidealer Reconciliation Reference

How our `acctdata` replica (YTDJRL / COACMAST.CA_CUR / GLCAL) compares to Intellidealer-generated reports. Every discrepancy chased has a clean explanation — none are bugs. Six classified causes + reconciliation queries.

Reference Intel PDFs from Crystal: [`docs/intellidealer-reports/`](intellidealer-reports/) (8 reports covering Jan 2026 + Apr 2026 across All Entities, Chiefland, Parts SBS, and Sales-by-Make).

## What matches exactly

| Granularity | Match against Intel | Notes |
|---|---|---|
| Per-account, per-month (closed periods) | ✓ to the dollar | e.g. acct 32000 Sales-New-Kubota Jan 2026 |
| Per-branch (CC suffix) total revenue, per-month (closed periods) | ✓ to the dollar | e.g. Chiefland Jan 2026 $702,028; Chiefland by dept all 4 columns match |
| Per-DFS-dept (CC leading digit) totals | ✓ to the dollar | After fixing the dept-mapping bug — see commit `2dde14a` |
| All-entities totals, closed periods, unfiltered | ✓ to the dollar | Jan 2026: $19,682,496 mine = Intel exactly |

## Six explained discrepancies

Every diff we've observed has a clean cause. None are bugs in our data.

### 1. April 2026 All Entities: $26.7M (Intel) vs $32.7M (ours) → +$6M

**Cause:** Crystal posted ~$6M of back-dated April entries to the AS/400 source between Intel's run on 5/9/26 and our most-recent ETL pull. Apr was still in active close on the source — our data is more current than Intel's 5/9 snapshot.

### 2. Per-account 1-3% diffs (e.g. Kubota Sales 32000 Jan)

**Cause:** same as #1 in miniature. Continuous late postings to the source. Closed periods are stable; near-close periods drift small amounts.

### 3. YJ_UID-cutoff approximation undercounts roll-ups by ~$1.6M/month

**Cause:** `YJ_UID` is *replica-side ingestion time*, not source-side posting time. Verified empirically:

- Intel Jan 2026 (run 3/15/26 21:05) = **$19,682,496** (matches our current unfiltered total)
- 106 Jan-dated rows totaling $1.59M have `YJ_UID >= 202603152105` (after Intel ran)
- 100 of those have no earlier-UID counterpart for the same (date, account, CC) — they're genuinely new rows in our replica
- They must have existed on the AS/400 source on 3/15 (Intel saw them) but took weeks/months to flow into our replica via ETL Copy

So `YJ_UID < intel_run_ts` filters out rows we ingested late, even though the source had them earlier. Roll-ups undercount by ~$1.6M/mo. Per-branch / per-account drift is sub-$2K because late ingests spread thinly across detail.

### 4. DFS Departmental Sales COGS $186K higher than Intel (Jan 2026)

**Cause:** our v2 CFO restructure ([cfo-feedback-2026-05-28.md](cfo-feedback-2026-05-28.md) action 2.4) moves 3 "contra-revenue" accounts out of Equipment COGS into Equipment Sales:
- 42210 COS - Finance Income Reserve
- 42005 Freight/Setup Fees
- 42212 Finance Income Flat Rate

Intel uses standard ACCMAST classification (these stay in COGS). For Jan 2026, those 3 accounts net to about −$185K — exactly the COGS diff. Net Income is identical either way.

### 5. Parts SBS per-branch values $1.6K–$47K lower than our dept-3 sum

**Cause:** Intel's *Parts SBS* report has a stricter definition of "Parts revenue" than the main P&L. It excludes serialized parts (accts 33200 Stihl Serialized, 33230 Other Serialized) and reports them separately as "SERIALIZED GROSS MARGIN". Verified for Deland Jan:

| | $ |
|---|---:|
| Our dept-3 total | 357,068 |
| Less 33200 Stihl Serialized | (45,140) |
| Less 33230 Other Serialized | (1,550) |
| = Parts SBS "Revenue" | 310,378 |

Matches Intel Parts SBS Deland Revenue exactly.

### 6. Intel's Chiefland P&L Parts column ($79,042) vs Intel's Parts SBS Chiefland ($77,452) — *Intel disagrees with itself*

**Cause:** same as #5. Chiefland P&L includes serialized parts in the Parts column; Parts SBS doesn't. Both Intel reports are internally consistent; they just use different "Parts revenue" definitions.

## The YJ_UID column — proper interpretation

`YJ_UID` is `decimal(18,0)`, format `YYYYMMDDHHMMSS####` (14-digit timestamp + 4-digit sequence). On the AS/400 source, this is the row's last-modified timestamp.

**In our replica, what's stamped reflects when our ETL Copy pulled that row in.** The source can hold a row for weeks before an incremental Copy picks it up. Source-side YJ_UID is preserved through the Copy, but the effective behavior we observe is ingestion timing (see #3 above for evidence).

## How to apply

- **For "what's the current state"** (default user question): use live YTDJRL or COACMAST.CA_CUR with no UID filter. Don't apologize for being more current than a printed Intel report.
- **For per-account or per-branch comparisons** to Intel for closed periods: should match exactly. If they don't, check the dept-mapping ([department_encoding_in_cc.md](data-model.md) section) and the v2 CFO reclassifications ([cfo-feedback-2026-05-28.md](cfo-feedback-2026-05-28.md)).
- **For Intel-exact reconciliation at a past moment**: there isn't a clean way. Closest path is to ask Crystal to regenerate the Intel report now — both should agree on closed periods. For unclosed periods, our data will be more current.
- **For "approximately what Intel saw on date X"**: YJ_UID cutoff is a rough approximation; expect ~$1.6M/mo undercount on roll-ups.

## Quick reconciliation queries

```sql
-- Per-account match (closed period, current data):
SELECT SUM(-y.YJ_AMT) FROM dbo.YTDJRL y
WHERE RTRIM(y.YJ_ACC) = '32000'           -- e.g. Kubota new sales
  AND y.YJ_DT BETWEEN 20260101 AND 20260131;

-- Per-branch revenue (CC trailing 2 digits = branch code):
SELECT SUM(-y.YJ_AMT) FROM dbo.YTDJRL y
JOIN dbo.ACCMAST am ON RTRIM(am.ACACC) = RTRIM(y.YJ_ACC)
WHERE am.ACTYP = '2' AND LEFT(RTRIM(am.ACACC),1) = '3'
  AND y.YJ_DT BETWEEN 20260101 AND 20260131
  AND RIGHT(RTRIM(y.YJ_CC),2) = '04';     -- Chiefland

-- Per-DFS-dept (CC leading digit, with CORRECTED mapping):
SELECT LEFT(RTRIM(y.YJ_CC),1) AS dept, SUM(-y.YJ_AMT) AS revenue
FROM dbo.YTDJRL y JOIN dbo.ACCMAST am ON RTRIM(am.ACACC) = RTRIM(y.YJ_ACC)
WHERE am.ACTYP = '2' AND LEFT(RTRIM(am.ACACC),1) = '3'
  AND y.YJ_DT BETWEEN 20260101 AND 20260131
  AND LEN(RTRIM(y.YJ_CC)) >= 3
GROUP BY LEFT(RTRIM(y.YJ_CC),1) ORDER BY dept;
-- Result mapping: 1=Admin, 2=Sales, 3=Parts, 4=Service, 5=Rental, 6=Used

-- Approximate Intel snapshot at past timestamp (expect ~$1.6M/mo undercount on roll-ups):
SELECT SUM(-y.YJ_AMT) FROM dbo.YTDJRL y
JOIN dbo.ACCMAST am ON RTRIM(am.ACACC) = RTRIM(y.YJ_ACC)
WHERE am.ACTYP = '2' AND LEFT(RTRIM(am.ACACC),1) = '3'
  AND y.YJ_DT BETWEEN 20260401 AND 20260430
  AND y.YJ_UID < 202605091508000000;       -- Intel ran 5/9/26 3:08PM
```

## Cost-center dept mapping (corrected)

| CC leading digit | Department |
|---:|---|
| `1` | Admin |
| `2` | Sales |
| `3` | **Parts** |
| `4` | **Service** |
| `5` | Rental |
| `6` | Used |
| `0` | Corporate / Balance Sheet |

The Parts/Service mapping was originally inverted in code; commit `2dde14a` fixed it after the Intellidealer Jan 2026 reconciliation surfaced the bug.

## Source PDFs for verification

8 reference PDFs in [`docs/intellidealer-reports/`](intellidealer-reports/):

- `0126`/`0426 All Entities Income Statement.pdf` — top-line monthly P&L (6 dept columns)
- `0126`/`0426 Chiefland Income Statement.pdf` — single-branch P&L
- `0126`/`0426 Crystal Tractor Parts SBS Income Statement.pdf` — by-branch parts (excludes serialized)
- `0126`/`0426 Sales and Gross by Make ... SBS MTD.pdf` — by-branch by-make detail

Generated by Crystal user "Bobbi-Jo" via Intellidealer's web reporting (Microsoft Print To PDF rasterized output — `pdftotext` won't work, must use a PDF reader that handles images).

## Not yet verified (no Intel PDFs available)

- Feb 2026 / Mar 2026 totals (closed periods; should match per #1's logic but unproven)
- Balance Sheet against Intel (no Intel BS PDF on file)
- Personnel / Operating expense detail line items (only verified at the dept aggregate)
- Sales-by-Make detail row-by-row (only spot-checked Kubota Sales)

If a new Intel report comes in for any of these, run the reconciliation queries above against it. The pattern is consistent enough that match-or-clean-explanation should hold.
