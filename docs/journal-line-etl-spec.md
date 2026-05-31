# Journal-Line ETL — STATUS: DEPLOYED 2026-05-31

**Updated 2026-05-31.** The AS/400 admin returned the `YTDJRL` source DDL ([`docs/YTDJRL_DDL.sql`](YTDJRL_DDL.sql)) and the ETL team built the pipeline against the live replica the same day. The journal-line gap that motivated this spec is now closed.

| | |
|---|---|
| Source table | `PFWF0125.YTDJRL` on the AS/400 |
| Replica table | `dbo.YTDJRL` (+ `stg.YTDJRL`) |
| Rows loaded | 801,685 (initial load) |
| Date coverage | 2019-01-29 → 2026-06-30 (7+ years on source; no archive cycle observed) |
| Pattern | **Append-only** (no MERGE, no snapshot). YJ_UID watermark; strict-greater-than across runs |
| Procs | `sp_AcctStartRun` (extended), `sp_Acct_Insert_YTDJRL` |
| First INITIAL load | 2026-05-31 14:21 UTC — 801,683 rows in ~16 minutes |
| First INCREMENTAL  | 2026-05-31 15:02 UTC — 2 rows, watermark advanced cleanly |

Captured for repo-side documentation in [`sql/11_ytdjrl_deployed.sql`](../sql/11_ytdjrl_deployed.sql).

---

## Why the append-only departure from the 5-table pattern

The existing five summary tables (ACCMAST/COACMAST/DEPTMAST/GLCAL/GLFIS) use FULL_RELOAD + change-detection MERGE because they're small (few thousand rows each) and their source-side rows mutate in place. `YTDJRL` is different on both counts:

| Concern | Resolution |
|---|---|
| 800K+ rows growing daily | Incremental INSERT only what's new; full reload would be wasteful |
| No usable business key | Even `(YJ_CO, YJ_DIV, YJ_JRL, YJ_ACC, YJ_CC, YJ_AMT, YJ_FILA)` has ~6% dupes (per ETL team analysis). Resolved with a synthetic `Id BIGINT IDENTITY` PK |
| Rows never mutate (journal postings are immutable; reversals are new rows with non-zero `YJ_RDT`) | MERGE/change-detection adds no value; pure INSERT is correct |
| Audit / change history | The dbo table itself IS the immutable audit trail. **No `snap.YTDJRL` needed.** |
| Watermark | `YJ_UID` is an 18-digit value of the form `YYYYMMDDhhmmssXXXXX`, monotonic per row. Strict-greater-than (`WHERE YJ_UID > @WatermarkFrom`) prevents any row from crossing run boundaries. |

`AcctSnapshotControl` intentionally has **no row** for `YTDJRL`. Adding one would seed a watermark for a snapshot proc that doesn't exist and shouldn't.

---

## Verification — five tests, all green

Run 2026-05-31 against `dbo` / `stg` on the production replica.

### Test 1 — ETL pipeline status

```sql
SELECT TOP 5 StartedUtc, Status, RunKind, RowsCopied, WatermarkFrom, WatermarkTo
FROM dbo.AcctLoadControl WHERE TableName='YTDJRL' ORDER BY StartedUtc DESC;
```

| StartedUtc | Status | RunKind | RowsCopied | WatermarkFrom | WatermarkTo |
|---|---|---|---|---|---|
| 2026-05-31 15:02 | COMPLETE | INCREMENTAL | 2 | 202605310947083127 | 202605311038083134 |
| 2026-05-31 14:21 | COMPLETE | INITIAL | 801,683 | 0 | 202605310947083127 |

Both pipelines green. Watermark advances cleanly between runs.

### Test 2 — Date coverage includes unclosed periods

```sql
SELECT MIN(YJ_DT) min_dt, MAX(YJ_DT) max_dt, COUNT(*) total_rows,
       SUM(CASE WHEN YJ_DT >= 20260301 THEN 1 ELSE 0 END) AS unclosed_rows
FROM dbo.YTDJRL;
```

| min_dt | max_dt | total_rows | unclosed_rows (Mar-Dec 2026) |
|---|---|---|---|
| 20190129 | 20260630 | 801,685 | 41,107 |

This was the original gap: 41,107 journal lines from periods that haven't closed yet on the source. Previously invisible to us.

### Test 3 — Aggregate-sum reconciliation to GLCAL (closed period 202602)

```sql
WITH yj AS (SELECT RTRIM(YJ_ACC) acc, SUM(YJ_AMT) j FROM dbo.YTDJRL
             WHERE YJ_DT BETWEEN 20260201 AND 20260229 GROUP BY YJ_ACC),
     gl AS (SELECT RTRIM(GB_GLA) acc, SUM(GB_AMT) g FROM dbo.GLCAL
             WHERE GB_DATE = 202602 GROUP BY GB_GLA)
SELECT 'YTDJRL P&L' k, SUM(yj.j) v
  FROM yj JOIN dbo.ACCMAST am ON RTRIM(am.ACACC) = yj.acc WHERE am.ACTYP IN ('2','3')
UNION ALL SELECT 'GLCAL  P&L', SUM(gl.g)
  FROM gl JOIN dbo.ACCMAST am ON RTRIM(am.ACACC) = gl.acc WHERE am.ACTYP IN ('2','3');
```

| Source | P&L sum (Feb 2026) |
|---|---:|
| YTDJRL | −$14,254.05 |
| GLCAL  | −$14,254.05 |
| Difference | **$0.00** (exact) |

Note: only P&L accounts (`ACTYP IN ('2','3')`) reconcile this way. GLCAL mixes BS-snapshot rows with P&L-flow rows for the same period; YTDJRL is pure flow (every row is a posting). Restricting to P&L apples-to-apples.

### Test 4 — Per-account drift (Feb 2026, P&L only)

```sql
-- Same yj/gl CTEs as Test 3
SELECT COUNT(*) AS drifted_accounts
FROM yj FULL JOIN gl ON yj.acc = gl.acc
JOIN dbo.ACCMAST am ON RTRIM(am.ACACC) = COALESCE(yj.acc, gl.acc)
WHERE am.ACTYP IN ('2','3') AND ABS(ISNULL(yj.j,0) - ISNULL(gl.g,0)) > 0.005;
```

**Result: 0 drifted accounts.** Every P&L account in GLCAL Feb 2026 sums identically from YTDJRL.

### Test 5 — Monthly P&L for unclosed periods (the original goal)

```sql
WITH y AS (SELECT CAST(YJ_DT AS INT)/100 period, RTRIM(YJ_ACC) acc, SUM(YJ_AMT) amt
             FROM dbo.YTDJRL WHERE YJ_DT BETWEEN 20260301 AND 20260531
             GROUP BY CAST(YJ_DT AS INT)/100, YJ_ACC)
SELECT period,
       SUM(CASE WHEN am.ACTYP='2' THEN -amt ELSE 0 END) AS revenue,
       SUM(CASE WHEN am.ACTYP='3' THEN  amt ELSE 0 END) AS expense,
       SUM(CASE WHEN am.ACTYP IN ('2','3') THEN -amt ELSE 0 END) AS net_income
  FROM y JOIN dbo.ACCMAST am ON RTRIM(am.ACACC) = y.acc
 WHERE am.ACTYP IN ('2','3') GROUP BY period ORDER BY period;
```

| Period | Revenue | Expense | Net Income |
|---:|---:|---:|---:|
| 202601 (closed) | $3.32M | $3.40M | −$0.08M |
| 202602 (closed) | $3.13M | $3.11M | +$0.01M |
| **202603 (unclosed)** | **$4.31M** | **$3.66M** | **+$0.65M** |
| **202604 (unclosed)** | **$6.26M** | **$5.21M** | **+$1.05M** |
| **202605 (unclosed, MTD)** | **$2.88M** | **$3.74M** | **−$0.86M** |

Mar–May 2026 monthly P&L was previously available only out of Crystal's report writer. Now it's queryable directly.

---

## What this unlocks

| Capability | Before | After |
|---|---|---|
| Monthly P&L inside an unclosed period | Available only from Crystal report writer | Queryable directly from `dbo.YTDJRL` |
| Branch / dept / brand split of unclosed activity | Not possible from the replica | `GROUP BY YJ_CC` (per the CC encoding in [data-model.md](data-model.md)) |
| JE-level audit trail | Inferred from GLCAL rollups | Individual `YJ_JRL` + `YJ_DES` + `YJ_CRT` (user) rows |
| Live reconciliation | GLCAL only (closed) | YTDJRL flows → GLCAL period-end (exact P&L match) |
| Time-stamped postings | Inferred | `YJ_DT` (transaction date) + `YJ_PDT` (posting date) per row |

---

## Open follow-ups (low priority)

These don't block the core capability — they're polish.

1. **ETL cadence.** Today only two runs exist (initial + one incremental). Confirm with the ETL team that the YTDJRL pipeline is scheduled on the same 4×/day cadence as the other five (03/11/15/19 UTC), or whatever's preferred for the higher-volume journal-line table.
2. **Source retention.** YTDJRL on the source goes back to 2019. Ask the AS/400 admin whether it ever rolls into `YTDJRLH` or similar at year-end, so we know to back up the replica before that purge happens.
3. **Index review.** Current state has `PK_YTDJRL(Id)` clustered + `IX_YTDJRL_YJ_UID(YJ_UID)`. Reporting queries will mostly filter `(YJ_DT, YJ_ACC)` or `(YJ_DT, YJ_CC)`. Consider adding a covering index if those queries get slow at scale; not urgent at 800K rows.
4. **Status of the superseded 5-table draft.** [`sql/07_journal_line_schema.sql`](../sql/07_journal_line_schema.sql) through `sql/10_acctcontrol_seed.sql` remain in the repo as reference patterns but should **not be deployed** — they were drafted before we identified YTDJRL as the canonical source. They also reference the old audit column names (`FirstSeenUtc`/`LastSeenUtc`, since renamed to `DateAddedUtc`/`DateModifiedUtc`). Safe to delete if no longer wanted as reference.

---

## Investigation history (for the next agent or future-you)

1. **2026-05-22**: "No GLTRANS-style table found in IDR1; truly missing; need separate sourcing." (Tier 3 in `reporting-catalog.md`.)
2. **2026-05-29**: "Actually we found it — it's distributed across 5 sub-system history tables in IDR1." Drafted the original 5-table SQL package (`sql/07-10_*.sql`). Updated docs claiming this was the answer.
3. **2026-05-31** (morning): Brad pointed at the **Intellidealer 6.0 System Flowchart PDF** that was in `docs/` all along but never opened. The flowchart shows `YTDJRL` (Year-to-Date Journals) as the canonical posting table sitting next to GLCAL/GLFIS. `YTDJRL` not in IDR1; verified empirically that the 5-table approach only covers ~80% of revenue, ~26% of OpEx, ~10% of BS activity — i.e. those tables are participants in the posting flow, not the consolidated source.
4. **2026-05-31** (afternoon): AS/400 admin returned the `YTDJRL` DDL (saved to [`docs/YTDJRL_DDL.sql`](YTDJRL_DDL.sql)). ETL team built the pipeline against the live replica the same day with append-only / IDENTITY-PK / `YJ_UID`-watermark pattern. Five reconciliation tests confirm exact P&L match to GLCAL for closed periods and surface 41,107 previously-invisible journal lines from unclosed periods.

**Lesson**: when an Intellidealer-related question can't be answered from the replica schemas alone, **read the System Flowchart PDF before reverse-engineering.** It's the authoritative source for the IBM i posting flow.
