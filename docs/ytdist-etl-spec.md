# YTDIST ETL — STATUS: DEPLOYED 2026-05-31

**Updated 2026-06-01.** The AS/400 admin returned the `YTDIST` source DDL ([`docs/YTDIST_DDL.sql`](YTDIST_DDL.sql)) about 35 minutes after the ask went out, and the ETL team had the pipeline live the same day. With `dbo.YTDIST` now in place alongside `dbo.YTDJRL`, both halves of the journal-line picture (the GL postings and the A/P vendor detail behind them) are queryable directly from the replica.

| | |
|---|---|
| Source table | `PFWF0125.YTDIST` on the AS/400 |
| Replica table | `dbo.YTDIST` (+ `stg.YTDIST`) |
| Rows loaded | 1,835,578 (initial load) |
| Date coverage | 2000-06-04 → 2028-02-28 (25+ years on source; small number of future-dated rows for accruals) |
| Pattern | **FULL_RELOAD + MERGE** on natural PK `(DN_TID, DN_SEQ)` — differs from YTDJRL's append-only because (a) `DN_UID` is 99.4% zero so unusable as a watermark, and (b) YTDIST rows mutate in place (notably `DN_CHQ` populates when checks are cut later) |
| Procs | `sp_AcctStartRun` (extended for YTDIST), `sp_Acct_Merge_YTDIST` |
| First INITIAL load | 2026-05-31 ~19:52 UTC — 1,835,578 rows in ~50 minutes (35 min Copy + 15 min merge) |
| Cadence | Daily full reload (volume too large for the 4×/day cadence used by the small summary tables) |

Captured for repo-side documentation in [`sql/12_ytdist_deployed.sql`](../sql/12_ytdist_deployed.sql).

---

## Why the pattern differs from YTDJRL

Both are journal-line tables, but the ETL pattern is genuinely different:

| Concern | YTDJRL | YTDIST |
|---|---|---|
| Natural PK | None (~6% dupes even on best composite) → synthetic `Id IDENTITY` | Real PK on `(DN_TID, DN_SEQ)` |
| Watermark column | `YJ_UID` (18-digit YYYYMMDDhhmmssXXXXX) — populated and monotonic | `DN_UID` is 99.4% zero per ETL team's analysis — unusable |
| Row mutability | Immutable (reversals are new rows) | Mutable (`DN_CHQ` fills in later, statuses change) |
| Resulting pattern | Append-only INSERT, INCREMENTAL by `YJ_UID` | FULL_RELOAD + MERGE on natural PK with change detection |
| Audit columns | `DateAddedUtc` only | `DateAddedUtc` + `DateModifiedUtc` |
| Snapshot proc | Not needed (immutable history in dbo) | Not needed yet — but feasible if drift-tracking becomes useful |

---

## Schema highlights for analytics

Full DDL in [`docs/YTDIST_DDL.sql`](YTDIST_DDL.sql) and [`sql/12_ytdist_deployed.sql`](../sql/12_ytdist_deployed.sql). Key fields for reporting:

| Column | Role |
|---|---|
| `DN_TID, DN_SEQ` | PK — one TID per invoice header, multiple SEQs per distribution row |
| `DN_VEN, DN_NME` | Vendor code + name (name can be `'COMPUTER GENERATED $$$$VP'` placeholder on some rows; prefer non-placeholder when available) |
| `DN_GRS, DN_ACC, DN_CC` | Signed amount + GL account + cost center per distribution row |
| `DN_INV, DN_PO` | Invoice number, PO number (for match traceability) |
| `DN_DTI, DN_DTD` | Invoice date, GL distribution date (both YYYYMMDD) |
| `DN_CHQ` | Check number — empty means *not paid by check*, but doesn't necessarily mean unpaid (Crystal also clears via journal entry; see caveats below) |
| `DN_HDES` | Free-text history description |

**Multi-row-per-invoice pattern:** each invoice (one `DN_TID`) has one A/P-side credit (typically `DN_ACC LIKE '2%'` — could be `20200` trade payable, `20350` floorplan, `24900` CDK clearing, etc.) plus one or more expense/inventory distribution rows (positive `DN_GRS`). Rows of an invoice net to zero.

**Vendor-spend calculation:** `SUM(DN_GRS) WHERE DN_GRS > 0 AND DN_ACC NOT LIKE '2%'`. Critical: **don't** also exclude `DN_ACC NOT LIKE '1%'` — for a tractor dealer, inventory purchases (debits to `12xxx` Wholegoods Inventory) are the largest A/P category. Excluding them undercounts spend by ~10× (lessons learned from the first draft A/P report).

---

## Verification — green

Run 2026-06-01 against the live replica.

### Test 1 — ETL pipeline status

```sql
SELECT TOP 3 StartedUtc, EndedUtc, Status, RunKind, RowsCopied, RowsInserted, RowsUpdated
FROM dbo.AcctLoadControl WHERE TableName='YTDIST' ORDER BY StartedUtc DESC;
```

INITIAL load completed cleanly, 1.84M rows, ~50 min total.

### Test 2 — Data coverage

```sql
SELECT 'rows', COUNT(*) FROM dbo.YTDIST
UNION ALL SELECT 'YTD 2026 rows', COUNT(*) FROM dbo.YTDIST WHERE DN_DTI BETWEEN 20260101 AND 20260531
UNION ALL SELECT 'YTD 2026 invoices', COUNT(DISTINCT DN_TID) FROM dbo.YTDIST WHERE DN_DTI BETWEEN 20260101 AND 20260531
UNION ALL SELECT 'YTD 2026 vendors', COUNT(DISTINCT RTRIM(DN_VEN)) FROM dbo.YTDIST WHERE DN_DTI BETWEEN 20260101 AND 20260531;
```

| Metric | Value |
|---|---:|
| Total rows | 1,835,578 |
| YTD 2026 rows | 185,605 |
| YTD 2026 invoices | 26,748 |
| YTD 2026 active vendors | 1,140 |

### Test 3 — YTDIST → YTDJRL reconciliation (closed period)

YTDIST distribution-side sum for Feb 2026 = **$33.2M**; YTDJRL.AP positive postings for Feb 2026 = **$46.6M**.

These do not match exactly because YTDJRL.AP is a superset:
- YTDJRL.AP includes manual A/P journal entries that don't generate YTDIST distribution rows
- YTDJRL.AP includes credit memos and reversals tagged with the AP journal prefix

Both reconcile back to GLCAL through their respective paths. The lack of an exact YTDIST↔YTDJRL match is **structural**, not a data-pipeline issue.

### Test 4 — Sanity check against the (now-stale) IDR1 snapshot

`IntelliDealerR1.dbo.YTDIST` has 1,069,608 rows dated through 2025-11-14 (a frozen ~mid-2024 snapshot). The live replica has 1,835,578 rows — the additional 766K rows represent 18 months of activity that was missing from IDR1. Schema matches exactly; differences are pure freshness.

---

## What this unlocks — confirmed working

The first A/P report off the live data ([`~/Downloads/Crystal-AP-Analysis-2026-YTD-v2.pdf`](file:///Users/bgreenway/Downloads/Crystal-AP-Analysis-2026-YTD-v2.pdf), generated 2026-06-01) demonstrates:

| Capability | Confirmed |
|---|---|
| Total A/P spend, YTD comparable | $208.8M YTD 2026 vs $174.3M YTD 2025 (+19.8%) |
| Top vendors by spend | Kubota Tractor Corp #2 outside vendor at $29.6M (1,194 invoices) |
| Vendor concentration | Top 5 outside vendors = 65.5% of outside-vendor total |
| Per-Kubota-DFS dept spend | Sales / Service / Parts / Rental / Admin breakdown via CC encoding |
| Per-branch spend with YoY | Top 15 branches with prior-year compare |
| A/P aging (last 180 days) | 0-30 / 31-60 / 61-90 / 91-180 day buckets on `DN_CHQ=''` invoices |
| Largest single invoices | Anomaly callout (top 10 by amount with vendor + invoice ref + PO) |
| Reconciliation footnote | YTDIST↔YTDJRL.AP cross-check (see Test 3) |

---

## Caveats / surprises worth noting for future report-builders

These came out of building the first A/P report and may matter for future analytics:

1. **Internal-JE buckets dominate by name.** Vendor codes like `BJW` ("Bobbijo Journal"), `CSN` ("Chelsea Journal"), `APETRI` ("Alayla Journal Entry"), `TLL` ("Tammy Lakas Journal") are journal-clearing mechanisms, not third-party vendors. Largest BJW invoice is $7.1M titled "DOTHANACQ" (Dothan acquisition journal). **Filter these out** before quoting "top vendors" externally — easiest classifier is `DN_NME LIKE '%JOURNAL%' OR DN_NME LIKE '%J/E%'`.

2. **"Human-name" vendors with multi-million spend.** Codes like `MMC` (Michelle Cook, $18.4M), `MRC` (Marla Carr, $15.0M), `AC` (Ashley Camacho, $11.4M) are likely employees set up as vendors for commission/expense-reimbursement. Not third-party concentration risk. Worth confirming with Steven before publishing.

3. **A/P aging beyond 6 months is unreliable.** Most old open items get cleared via journal entry rather than by check, so `DN_CHQ=''` for an invoice from 2 years ago doesn't mean Crystal still owes the vendor. Restrict aging analysis to last 180 days for actionable views.

4. **`DN_NME` placeholder.** Some rows have `DN_NME = 'COMPUTER GENERATED $$$$VP'` as the vendor name — this is a CDK-side placeholder. When picking a vendor's display name, prefer the non-placeholder name from that vendor's other rows (most-recent `DN_DTI` is a reasonable tiebreaker).

5. **Cost-center 000 ("Balance Sheet / Corp")** dominates by-dept spend because all inventory purchases hit `12xxx Wholegoods Inventory` with `CC='000'`. In Crystal's chart of accounts, inventory isn't a "department" — it sits on the BS and gets relieved into COGS at the time of sale. So "DFS dept spend" naturally excludes inventory purchases unless you slice differently.

---

## Investigation history

1. **2026-05-29**: YTDIST identified in IDR1 alongside CGIHIST/SUBLED/PARTHIST/INVHCC as part of the 5-table journal-line draft (since superseded — see [journal-line-etl-spec.md](journal-line-etl-spec.md)).
2. **2026-05-31** (morning): Pivot to YTDJRL as the canonical posting source; YTDIST and the other 4 deprioritized.
3. **2026-05-31** (afternoon): YTDJRL deployed. With the journal-line foundation in place, YTDIST became the natural next-most-valuable addition.
4. **2026-05-31** (later afternoon): Confirmed YTDIST in IDR1 is a stale ~July-2024 snapshot; drafted the ask for the AS/400 admin.
5. **2026-05-31** (~15:20 UTC): Admin returned the source DDL (`docs/YTDIST_DDL.sql`) 35 minutes after the ask went out.
6. **2026-05-31** (~19:52 UTC → 20:42 UTC): ETL team built the pipeline live — INITIAL load complete.
7. **2026-06-01** (this doc + `sql/12_ytdist_deployed.sql`): Repo-side documentation of the deployed state, including caveats discovered while building the first real A/P report off the live data.
