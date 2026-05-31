# Journal-Line ETL Extension — Spec for the ADF Owner

**Updated 2026-05-31** — scope revised down from 5 tables to **1 table (`YTDJRL`)** based on the Intellidealer 6.0 System Flowchart confirming the canonical journal-line source. The earlier 5-table draft (preserved in `sql/07-10_*.sql`) is now superseded by this spec.

---

## Context — why we're doing this

The current acctdata replica covers the five GL summary tables (ACCMAST, COACMAST, DEPTMAST, GLCAL, GLFIS). They give us excellent **closed-period** reporting but no monthly grain inside an unclosed period — Crystal's report writer can produce stand-alone April-2026 monthly figures, but our SQL data can't, because the four downstream rollup tables aggregate away the per-transaction detail.

Per the official **Intellidealer 6.0 System Flowchart** (CDK Global, 2019; see [`docs/Intellidealer system flow chart.pdf`](Intellidealer%20system%20flow%20chart.pdf)), the canonical journal-line posting table is:

> **`YTDJRL` — Year-to-Date Journals.** Sits in the GL module alongside `GLCAL`, `GLFIS`, `SUBLED`, and `ACCMAST`. Every sub-system posting (sales, A/P, work orders, payroll, depreciation, manual JE, bank rec) consolidates into this table, which then aggregates upward into `GLCAL`.

**`YTDJRL` was never replicated.** It exists on the live AS/400 source but is not in `acctdata` or `IntelliDealerR1`. Replicating this single table closes the journal-line gap and unlocks monthly-grain reporting for any period.

---

## What we need from the AS/400 admin / Intellidealer admin

Three single-sentence questions. The whole package depends on these.

| # | Question | Why it matters |
|---:|---|---|
| 1 | What is the IBM i `(library/file)` for `YTDJRL` on the live source? | The ADF Copy needs the exact source path. Almost certainly `PFWF0125/YTDJRL` (same library as GLCAL), but worth confirming. |
| 2 | Do the existing `Intellidealer-User-Odd-Months` / `Intellidealer-User-Even-Months` credentials have read permission on `YTDJRL`? | Almost certainly yes (same library, same accounting module), but a one-sentence confirmation avoids a surprise. |
| 3 | Can you `DSPFFD` (or equivalent) and send the column list + types for `YTDJRL`? | Once we have the schema, the SQL package (table DDL + merge proc + snapshot proc) is a few hours' work, mirroring the existing GL ETL pattern. |

Optional but useful:
- Approximate row count and how many years of history `YTDJRL` retains on the source (informs ETL cadence + initial load duration).
- Whether `YTDJRL` is truncated/archived periodically (e.g. year-end roll into `YTDJRLH` or similar).

---

## ETL pipeline shape (once schema is known)

The pipeline follows the exact same pattern as the existing five GL summary tables:

```
1. ADF calls sp_AcctStartRun('YTDJRL')        → allocates RunId
2. ADF truncates stg.YTDJRL
3. ADF Copy: PFWF0125/YTDJRL → stg.YTDJRL     (stamps RunId on every row)
4. ADF calls sp_Acct_Merge_YTDJRL(@RunId)     → MERGE with change detection
5. ADF calls sp_Acct_Snapshot_YTDJRL          → captures any changed rows
6. ADF calls sp_AcctFinalize(@RunId)
```

Same cadence as the existing five (4×/day at 03:00, 11:00, 15:00, 19:00 UTC). Same failure-handling. Same secret rotation.

---

## SQL package contents (to be drafted once schema is in hand)

Will be added to `sql/`:

| File | Contents |
|---|---|
| `11_ytdjrl_schema.sql` | `dbo.YTDJRL`, `stg.YTDJRL`, `snap.YTDJRL` table definitions + indexes |
| `12_ytdjrl_procedures.sql` | `sp_Acct_Merge_YTDJRL` (change-detection MERGE pattern) |
| `13_ytdjrl_snapshot.sql` | `sp_Acct_Snapshot_YTDJRL` (watermark-driven capture) |
| `14_ytdjrl_control.sql` | Extend `sp_AcctStartRun` allow-list to include `'YTDJRL'`; insert row into `AcctSnapshotControl` |

All four files will mirror the existing patterns (see `sp_Acct_Merge_GLCAL` and `sp_Acct_Snapshot_GLCAL` for the templates). Total work to draft them: an hour or two once the schema is available.

---

## Pre-deploy sanity checks (once deployed)

```sql
-- 1. Allow-list accepts YTDJRL
DECLARE @r UNIQUEIDENTIFIER, @cp VARCHAR(4), @u NVARCHAR(127), @p NVARCHAR(127);
EXEC dbo.sp_AcctStartRun 'YTDJRL', @r OUTPUT, @cp OUTPUT, @u OUTPUT, @p OUTPUT;
DELETE FROM dbo.AcctLoadControl WHERE RunId = @r;

-- 2. Control row exists
SELECT * FROM dbo.AcctSnapshotControl WHERE TableName = 'YTDJRL';

-- 3. After first ETL run, reconcile YTDJRL → GLCAL for any closed month
-- (e.g. Feb 2026). Coverage should be ~100%; if not, there's a posting source
-- YTDJRL doesn't capture (unlikely but verify).
WITH j AS (
    SELECT GB_CO=JR_CO, GB_DIV=JR_DIV, GB_GLC=JR_CC, GB_GLA=JR_ACC,
           Period=JR_DATE/100, JR_AMT  -- assumed column names; will adjust based on actual schema
    FROM dbo.YTDJRL WHERE JR_DATE BETWEEN 20260201 AND 20260229
),
g AS (
    SELECT GB_CO, GB_DIV, GB_GLC, GB_GLA, GB_DATE AS Period, GB_AMT
    FROM dbo.GLCAL WHERE GB_DATE = 202602
)
SELECT j_sum=SUM(j.JR_AMT), g_sum=SUM(g.GB_AMT), diff=SUM(j.JR_AMT) - SUM(g.GB_AMT)
FROM j FULL JOIN g ON j.GB_CO=g.GB_CO AND j.GB_DIV=g.GB_DIV
       AND j.GB_GLC=g.GB_GLC AND j.GB_GLA=g.GB_GLA;
```

---

## What this unlocks once `YTDJRL` is flowing

Same list as before, but now achieved through one table instead of five:

| Capability | How |
|---|---|
| Monthly P&L inside any unclosed period | `SELECT SUM(JR_AMT) FROM YTDJRL WHERE JR_DATE BETWEEN <month_start> AND <month_end> GROUP BY JR_CO, JR_DIV, JR_CC, JR_ACC` |
| Branch / department / brand split of unclosed activity | Same, with grouping by CC suffix / prefix |
| JE-level audit trail | YTDJRL rows are individual postings with source-system, customer/vendor/invoice/order references |
| Unusual-JE detection | Pattern detection on YTDJRL.JR_AMT (round numbers, weekend posts, etc.) |
| "Who posted this, when?" traceability | YTDJRL captures the posting metadata directly |
| Full reconciliation back to GLCAL | `SUM(YTDJRL by month) == GLCAL.GB_AMT` |

---

## Status of the earlier 5-table SQL package

The files in `sql/07_journal_line_schema.sql` through `sql/10_acctcontrol_seed.sql` are **kept as reference patterns** but should **not be deployed** as the primary plan. The empirical reconciliation work that motivated this update (see the history below) showed the 5 tables only cover ~80% of revenue and less of OpEx/BS — they're useful supplementary sources for things like per-SKU parts margin (PARTHIST) or A/P drilldown (YTDIST), but not the foundation. `YTDJRL` is.

If you still want to deploy those five at some point, the SQL is ready and the spec is correct for what those tables individually do. Just don't claim they replace `YTDJRL` for financial-statement reconciliation.

---

## Investigation history (for the next agent or future-you)

This spec went through three versions as the investigation evolved:

1. **2026-05-22**: "No GLTRANS-style table found in IDR1; truly missing; need separate sourcing." (Tier 3 in `reporting-catalog.md`.)
2. **2026-05-29**: "Actually we found it — it's distributed across 5 sub-system history tables in IDR1." Drafted the original 5-table SQL package (`sql/07-10_*.sql`). Updated the docs claiming this was the answer.
3. **2026-05-31**: Brad pointed at the **Intellidealer 6.0 System Flowchart PDF** that was in `docs/` all along but never opened. The flowchart shows `YTDJRL` (Year-to-Date Journals) as the canonical posting table sitting next to GLCAL/GLFIS. **YTDJRL is not in IDR1** (verified by direct query). Empirical reconciliation confirmed the 5-table approach only covers ~80% of revenue, 26% of OpEx, ~10% of BS activity — i.e. the 5 tables are *participants* in the posting flow, not the consolidated source. `YTDJRL` is the right answer.

**Lesson**: when an Intellidealer-related question can't be answered from the replica schemas alone, **read the System Flowchart PDF before reverse-engineering.** It's the authoritative source for the IBM i posting flow.
