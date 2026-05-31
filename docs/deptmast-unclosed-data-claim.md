# Verification: Does DEPTMAST contain unclosed-period data?

**TL;DR — No.** DEPTMAST has the structural appearance of being able to hold per-month data inside an unclosed period (it has separate columns `DP_C1` through `DP_C12` for the twelve current-year months), but in practice every column for an unclosed month is **empty across every row** on both our production replica and our staging copy of the source. DEPTMAST and GLCAL move in lock-step — when a month closes on the AS/400, both tables get populated at the same time.

This document records the verification work performed 2026-05-31 in response to the claim that DEPTMAST holds unclosed data. Seven independent tests, all consistent with "DEPTMAST does not have it."

---

## Context — why this matters

Crystal can produce monthly income statements for any unclosed period out of Intellidealer's report writer. Our SQL replica, by design today, can only produce them for closed periods. The question is: **is DEPTMAST a shortcut that already has the unclosed data we need?** If yes, building the monthly-grain reporting would be trivial — query DEPTMAST. If no, we need to extend the ETL to replicate the underlying journal-line table (`YTDJRL`) from the AS/400.

I tested the "yes" hypothesis seven different ways. All seven results say no.

---

## How DEPTMAST is *structured* — why the claim is plausible

DEPTMAST has one row per `(Co, Div, CC, Acct)` combination — currently 4,906 rows — and each row has 24 amount columns:

| Columns | What they represent |
|---|---|
| `DP_C1`, `DP_C2`, ..., `DP_C12` | Current-year month 1 through 12 (= Jan–Dec 2026) |
| `DP_L1`, `DP_L2`, ..., `DP_L12` | Prior-year month 1 through 12 (= Jan–Dec 2025) |

So *structurally*, the table absolutely could hold per-month detail for the current year. The question is whether the source populates these columns as activity happens during the month, or only at formal period close.

---

## Tests run on 2026-05-31

All queries executed against `dbo` schema in `sqldb-acctdata-prod-eastus-001` and `stg` schema (the direct staging copy of the AS/400 source).

### Test 1 — current state of GLCAL

```sql
SELECT MIN(GB_DATE), MAX(GB_DATE), COUNT(DISTINCT GB_DATE) FROM dbo.GLCAL;
```

**Result:** GLCAL has 86 distinct periods from 201901 through **202602**. So the latest period Crystal has formally closed on the source is **February 2026**. Months 3–12 of 2026 are unclosed.

### Test 2 — ETL freshness

```sql
SELECT TableName, MAX(EndedUtc) FROM dbo.AcctLoadControl 
 WHERE Status='COMPLETE' GROUP BY TableName;
```

| Table | Last successful run (UTC) |
|---|---|
| ACCMAST | 2026-05-31 11:02 |
| COACMAST | 2026-05-31 11:04 |
| DEPTMAST | **2026-05-31 11:06** |
| GLCAL | 2026-05-29 19:03 |
| GLFIS | 2026-05-31 11:02 |

DEPTMAST was loaded **today** at 11:06 UTC. The state we're examining is fresh, not stale.

### Test 3 — DEPTMAST `DP_C*` column scan

```sql
SELECT 'DP_C1' AS col, SUM(DP_C1), 
       SUM(CASE WHEN DP_C1<>0 THEN 1 ELSE 0 END) AS nonzero_rows
  FROM dbo.DEPTMAST
UNION ALL
SELECT 'DP_C2', SUM(DP_C2), SUM(CASE WHEN DP_C2<>0 THEN 1 ELSE 0 END) FROM dbo.DEPTMAST
UNION ALL ... -- repeat for DP_C3..DP_C12
```

| Column | Period | Closed? | Sum | Non-zero rows | Total rows |
|---|---:|:---:|---:|---:|---:|
| `DP_C1` | 202601 | ✓ closed | $0 | **3,493** | 4,906 |
| `DP_C2` | 202602 | ✓ closed | −$80,289 | **3,568** | 4,906 |
| `DP_C3` | 202603 | ✗ unclosed | $0 | **0** | 4,906 |
| `DP_C4` | 202604 | ✗ unclosed | $0 | **0** | 4,906 |
| `DP_C5` | 202605 | ✗ unclosed | $0 | **0** | 4,906 |
| `DP_C6` | 202606 | ✗ unclosed | $0 | **0** | 4,906 |
| `DP_C7` | 202607 | ✗ unclosed | $0 | **0** | 4,906 |
| `DP_C8` | 202608 | ✗ unclosed | $0 | **0** | 4,906 |
| `DP_C9` | 202609 | ✗ unclosed | $0 | **0** | 4,906 |
| `DP_C10` | 202610 | ✗ unclosed | $0 | **0** | 4,906 |
| `DP_C11` | 202611 | ✗ unclosed | $0 | **0** | 4,906 |
| `DP_C12` | 202612 | ✗ unclosed | $0 | **0** | 4,906 |

**Result:** for every unclosed month (Mar through Dec 2026), **exactly zero rows out of 4,906 have any non-zero value.** Not "small numbers" — literal zero across the entire table.

This is not a sum that nets to zero; the count of rows with any non-zero value in those columns is zero.

### Test 4 — is the SOURCE itself empty, or did our ETL filter the data?

`stg.DEPTMAST` is a direct copy of the source-side DEPTMAST from the last ETL pull. If the source had data and our ETL filtered it, we'd see data in `stg` but not in `dbo`. They match exactly:

| Column | Non-zero rows in `dbo.DEPTMAST` | Non-zero rows in `stg.DEPTMAST` |
|---|---:|---:|
| `DP_C1` | 3,493 | 3,493 |
| `DP_C2` | 3,568 | 3,568 |
| `DP_C3` | **0** | **0** |
| `DP_C4` | **0** | **0** |
| ... | 0 | 0 |
| `DP_C12` | **0** | **0** |

**Result:** the source itself is empty for unclosed months. Our ETL is doing exactly what it should — copying the full table — and the source has no data to copy for those columns.

### Test 5 — lock-step timing: when did DP_C2 get its values vs when did GLCAL 202602 appear?

```sql
SELECT MIN(DateModifiedUtc) FROM dbo.DEPTMAST WHERE DP_C2 <> 0;
SELECT MIN(DateAddedUtc)    FROM dbo.GLCAL WHERE GB_DATE = 202602;
```

| Event | Timestamp |
|---|---|
| GLCAL 202602 rows first appeared | 2026-05-22 **16:05** UTC |
| DEPTMAST `DP_C2` first became non-zero | 2026-05-22 **19:06** UTC |
| Gap between them | ~3 hours, same ETL day |

**Result:** February's GLCAL row and February's DP_C2 values appeared in our replica within hours of each other on the same day. Before 2026-05-22, neither existed. After 2026-05-22, both exist. This is the signature of *both being populated by the same close event* — they're not independent data sources.

### Test 6 — sum match: do DP_C* columns equal GLCAL for the same period?

```sql
SELECT 'DP_C2 sum'  AS x, SUM(DP_C2) FROM dbo.DEPTMAST
UNION ALL
SELECT 'GLCAL 202602', SUM(GB_AMT) FROM dbo.GLCAL WHERE GB_DATE = 202602;
```

| Source | Sum |
|---|---:|
| DEPTMAST `DP_C2` (sum across all rows) | −$80,289.05 |
| GLCAL `GB_AMT` for `GB_DATE = 202602` | −$80,289.05 |
| Difference | **$0.00** (exact match) |

**Result:** for the months DEPTMAST DOES have data, the sum matches GLCAL **to the penny**. This is more confirmation that DEPTMAST is a re-shaped view of the same data GLCAL holds — not a separate, finer-grained source.

### Test 7 — spot-check a high-activity account

Account `32000` (Sales — New Kubota) has roughly $130M of annual revenue. If anywhere should show unclosed activity, it's here. For Mar–Dec 2026:

```sql
SELECT 'DP_C3 sum for 32000' AS x, SUM(DP_C3) FROM dbo.DEPTMAST WHERE DP_ACC='32000'
UNION ALL ... -- repeat through DP_C12
```

| Period | DEPTMAST `DP_C*` for 32000 | GLCAL rows for 32000 |
|---|---:|---:|
| 202603 (Mar) | $0.00 | 0 |
| 202604 (Apr) | $0.00 | 0 |
| 202605 (May) | $0.00 | 0 |
| 202606 (Jun) | $0.00 | 0 |
| 202607 (Jul) | $0.00 | 0 |
| ... | $0.00 | 0 |
| 202612 (Dec) | $0.00 | 0 |

**Result:** zero. Even on the largest-dollar revenue account in the chart, DEPTMAST has nothing for unclosed months.

---

## Where IS the unclosed-period data, then?

It's in **`COACMAST.CA_CUR`** — but only as an *aggregate*, not broken out by month.

`COACMAST` has three balance fields per `(Co, Div, CC, Acct)` row:
- `CA_YTD` — year-to-date through the last closed period (= matches GLCAL exactly)
- `CA_CUR` — **live current-state YTD** (includes the unclosed-period activity)
- `CA_L12` — trailing twelve months

The difference `CA_CUR − CA_YTD` gives the aggregate activity that has occurred **since the last close**. For top accounts as of today (2026-05-31):

| Account | Name | `CA_YTD` (through Feb) | `CA_CUR` (live today) | Unclosed-block aggregate |
|---|---|---:|---:|---:|
| 32000 | Sales — New Kubota | −$19.9M | −$51.8M | **−$31.9M** |
| 42000 | COS — New Kubota Equipment | $17.7M | $45.9M | $28.3M |
| 12000 | Inventory — Wholegoods | $55.1M | $44.9M | −$10.2M |
| 20350 | Floorplan Payable | −$48.6M | −$38.2M | $10.5M |
| 33100 | Sales Parts Other — Counter | −$0.9M | −$2.6M | −$1.6M |
| 51900 | Salaries | $0.9M | $2.3M | $1.4M |
| 55100 | Depreciation Equip | $0.4M | $0.8M | $0.4M |

These numbers prove the unclosed-period TOTALS exist in our replica (in `COACMAST.CA_CUR`). What's missing is the **monthly decomposition** — we can see that ~$31.9M of new-Kubota sales has happened since Feb 28, but we can't tell from any table in our replica how much of that was in March vs April vs May.

---

## What would actually close the gap

Replicating **one table** from the AS/400 source: **`YTDJRL`** (Year-to-Date Journals), per the official Intellidealer 6.0 System Flowchart. This is the canonical journal-line table where every per-transaction posting lives with its date and amount. It sits in the GL module alongside GLCAL/GLFIS/SUBLED on the source but was never included in the original ETL scope.

Full specification: [docs/journal-line-etl-spec.md](journal-line-etl-spec.md).

---

## Summary of evidence

| Test | What it shows | Result |
|---|---|---|
| 1 | GLCAL's latest closed period is 202602 | Mar–Dec 2026 are unclosed |
| 2 | DEPTMAST was loaded today | Data is fresh, not stale |
| 3 | DP_C3 through DP_C12 are zero across all 4,906 rows | DEPTMAST has no data for unclosed months |
| 4 | stg.DEPTMAST (direct source copy) is also empty | The source itself is empty — not an ETL filter |
| 5 | DEPTMAST DP_C2 and GLCAL 202602 came in 3 hours apart | Both populated by the same close event |
| 6 | DP_C2 sum = GLCAL 202602 sum exactly | They're the same data, two presentations |
| 7 | Spot-check on top-revenue account 32000 — all zero | Holds even for the biggest-dollar accounts |

All seven point the same way. DEPTMAST does not, today, hold unclosed-period data on either the replica side or the source side. Its `DP_C*` columns are populated by the same period-close event that creates GLCAL rows.

---

## Side observation: schema rename

While performing this verification I noticed that the replica's audit columns have been renamed at some point recently:

| Old name (used in earlier docs) | Current name |
|---|---|
| `FirstSeenUtc` | `DateAddedUtc` |
| `LastSeenUtc` | `DateModifiedUtc` |

This affects every table — `GLCAL`, `GLFIS`, `COACMAST`, `ACCMAST`, `DEPTMAST`. The stored procedures we drafted earlier in `sql/07-10_*.sql` reference the old names and would need updating before deployment. The change appears to have happened on the ETL side recently (after 2026-05-29). Worth confirming with the ETL team that this was intentional and that no downstream consumers were silently broken.
