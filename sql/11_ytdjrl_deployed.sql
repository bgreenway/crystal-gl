-- ===========================================================================
-- 11_ytdjrl_deployed.sql
--
-- DEPLOYED 2026-05-31 — captured from the live acctdata replica for
-- repo-side documentation. The ETL team built this directly against the live
-- DB; this file mirrors that state so the SQL is version-controlled with the
-- rest of the project.
--
-- Pattern departure from the existing five GL summary tables:
--   - Append-only (no MERGE). YTDJRL rows are immutable journal postings;
--     reversals are inserted as new rows with a non-zero YJ_RDT.
--   - Synthetic IDENTITY PK (Id bigint). The source has no usable business
--     key — even (CO,DIV,JRL,ACC,CC,AMT,FILA) leaves ~6% dupes per the ETL
--     team's analysis.
--   - Watermarked by YJ_UID (decimal(18,0), an 18-digit timestamp+sequence
--     of the form YYYYMMDDhhmmssXXXXX). Strict-greater-than ensures no row
--     crosses run boundaries — safe for pure INSERT.
--   - Audit columns: DateAddedUtc only (no DateModifiedUtc — rows never
--     change). This also means sp_Acct_Snapshot_YTDJRL is NOT NEEDED; the
--     dbo table itself is the immutable history.
--
-- Source DDL from the AS/400: docs/YTDJRL_DDL.sql.
-- ===========================================================================

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ---------------------------------------------------------------------------
-- dbo.YTDJRL — Year-to-Date Journals (canonical journal-line table)
-- Source: PFWF0125.YTDJRL on the AS/400 (Intellidealer 6.0)
-- ---------------------------------------------------------------------------
CREATE TABLE dbo.YTDJRL (
    Id              BIGINT          IDENTITY(1,1)  NOT NULL,
    YJ_CO           CHAR(2)         NOT NULL,
    YJ_DIV          CHAR(2)         NOT NULL,
    YJ_JRL          CHAR(4)         NOT NULL,    -- Journal number
    YJ_CC           CHAR(3)         NOT NULL,    -- Cost center (a.k.a. profit center)
    YJ_ACC          CHAR(5)         NOT NULL,    -- GL account
    YJ_FILA         CHAR(3)         NOT NULL,    -- Filler
    YJ_AMT          NUMERIC(12,2)   NOT NULL,    -- Posting amount (signed: credits negative)
    YJ_OSJ          CHAR(1)         NOT NULL,    -- One-sided journal flag (" " or "Y")
    YJ_RDT          NUMERIC(6,0)    NOT NULL,    -- Reversal date YYMMDD; 0 if not reversal
    YJ_RJRL         CHAR(4)         NOT NULL,    -- Reversal journal number
    YJ_UID          DECIMAL(18,0)   NOT NULL,    -- Update ID — watermark column
    YJ_PDT          NUMERIC(8,0)    NOT NULL,    -- Posting date YYYYMMDD (when row hit GL)
    YJ_FILC         CHAR(22)        NOT NULL,
    YJ_DT           NUMERIC(8,0)    NOT NULL,    -- Transaction date YYYYMMDD (business date)
    YJ_FILD         CHAR(2)         NOT NULL,
    YJ_MEM          CHAR(1)         NOT NULL,    -- Memo flag
    YJ_SRC          CHAR(1)         NOT NULL,    -- Source system code
    YJ_STA          CHAR(1)         NOT NULL,    -- Status
    YJ_RID          CHAR(1)         NOT NULL,    -- Record ID
    YJ_USE          CHAR(10)        NOT NULL,    -- In-use flag
    YJ_CRT          CHAR(10)        NOT NULL,    -- Created-by user
    YJ_DES          CHAR(40)        NOT NULL,    -- Description / memo
    UPDATE_IDENT    DECIMAL(7,0)    NOT NULL,    -- IBM i row-version
    DateAddedUtc    DATETIME2(3)    NOT NULL CONSTRAINT DF_YTDJRL_DateAddedUtc DEFAULT SYSUTCDATETIME(),
    LastRunId       UNIQUEIDENTIFIER NULL,
    CONSTRAINT PK_YTDJRL PRIMARY KEY CLUSTERED (Id)
);
CREATE INDEX IX_YTDJRL_YJ_UID ON dbo.YTDJRL(YJ_UID);
GO

-- ---------------------------------------------------------------------------
-- stg.YTDJRL — transient staging; populated by ADF Copy, drained by sp_Acct_Insert_YTDJRL
-- ---------------------------------------------------------------------------
CREATE TABLE stg.YTDJRL (
    YJ_JRL          CHAR(4)         NULL,
    YJ_CC           CHAR(3)         NULL,
    YJ_ACC          CHAR(5)         NULL,
    YJ_FILA         CHAR(3)         NULL,
    YJ_AMT          NUMERIC(12,2)   NULL,
    YJ_OSJ          CHAR(1)         NULL,
    YJ_RDT          NUMERIC(6,0)    NULL,
    YJ_RJRL         CHAR(4)         NULL,
    YJ_UID          DECIMAL(18,0)   NULL,
    YJ_PDT          NUMERIC(8,0)    NULL,
    YJ_CO           CHAR(2)         NULL,
    YJ_DIV          CHAR(2)         NULL,
    YJ_FILC         CHAR(22)        NULL,
    YJ_DT           NUMERIC(8,0)    NULL,
    YJ_FILD         CHAR(2)         NULL,
    YJ_MEM          CHAR(1)         NULL,
    YJ_SRC          CHAR(1)         NULL,
    YJ_STA          CHAR(1)         NULL,
    YJ_RID          CHAR(1)         NULL,
    YJ_USE          CHAR(10)        NULL,
    YJ_CRT          CHAR(10)        NULL,
    YJ_DES          CHAR(40)        NULL,
    UPDATE_IDENT    DECIMAL(7,0)    NULL,
    LoadRunId       CHAR(36)        NULL,
    LoadedAt        CHAR(26)        NULL
);
GO

-- ---------------------------------------------------------------------------
-- sp_AcctStartRun — extended to accept 'YTDJRL' with optional incremental
-- watermark. Captured as of 2026-05-31; supersedes the version in
-- sql/02_procedures.sql (and the rewrite drafted in sql/10_acctcontrol_seed.sql).
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_AcctStartRun
    @TableName      VARCHAR(30),
    @RunId          UNIQUEIDENTIFIER OUTPUT,
    @CredentialPair VARCHAR(4)       OUTPUT,
    @UserSecretName NVARCHAR(127)    OUTPUT,
    @PassSecretName NVARCHAR(127)    OUTPUT,
    @RunKind        VARCHAR(15)      = 'FULL_RELOAD',
    @WatermarkFrom  BIGINT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @TableName NOT IN ('ACCMAST','COACMAST','DEPTMAST','GLCAL','GLFIS','YTDJRL')
        THROW 50002, 'TableName must be ACCMAST, COACMAST, DEPTMAST, GLCAL, GLFIS or YTDJRL', 1;

    IF @RunKind NOT IN ('FULL_RELOAD','INCREMENTAL','INITIAL')
        THROW 50003, 'RunKind must be FULL_RELOAD, INCREMENTAL or INITIAL', 1;

    SET @RunId = NEWID();

    IF MONTH(GETDATE()) % 2 = 1
    BEGIN
        SET @CredentialPair = 'ODD';
        SET @UserSecretName = 'Intellidealer-User-Odd-Months';
        SET @PassSecretName = 'Intellidealer-Password-Odd-Months';
    END
    ELSE
    BEGIN
        SET @CredentialPair = 'EVEN';
        SET @UserSecretName = 'Intellidealer-User-Even-Months';
        SET @PassSecretName = 'Intellidealer-Password-Even-Months';
    END

    -- Watermark selection: only YTDJRL uses incremental. INCREMENTAL pulls the
    -- last COMPLETE WatermarkTo (FAILED runs do not advance, so a retry picks
    -- up the same window). INITIAL forces 0 (full reload via the strict-gt
    -- WHERE clause). FULL_RELOAD leaves the watermark NULL.
    IF @TableName = 'YTDJRL' AND @RunKind = 'INCREMENTAL'
        SELECT @WatermarkFrom = ISNULL(CAST(MAX(WatermarkTo) AS BIGINT), 0)
        FROM   dbo.AcctLoadControl
        WHERE  TableName = 'YTDJRL' AND Status = 'COMPLETE';
    ELSE IF @TableName = 'YTDJRL' AND @RunKind = 'INITIAL'
        SET @WatermarkFrom = 0;

    INSERT INTO dbo.AcctLoadControl (
        RunId, TableName, Status, RunKind, CredentialPairUsed,
        UserSecretName, PassSecretName, WatermarkFrom
    )
    VALUES (
        @RunId, @TableName, 'RUNNING', @RunKind, @CredentialPair,
        @UserSecretName, @PassSecretName, @WatermarkFrom
    );
END
GO

-- ---------------------------------------------------------------------------
-- sp_Acct_Insert_YTDJRL — append-only loader. No MERGE; YJ_UID watermark
-- guarantees no row crosses run boundaries, so plain INSERT is safe.
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_Acct_Insert_YTDJRL
    @RunId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        DECLARE @RowsCopied INT = (SELECT COUNT(*) FROM stg.YTDJRL WHERE LoadRunId = CONVERT(CHAR(36), @RunId));
        DECLARE @WatermarkTo BIGINT = (
            SELECT CAST(MAX(YJ_UID) AS BIGINT)
            FROM stg.YTDJRL
            WHERE LoadRunId = CONVERT(CHAR(36), @RunId)
        );

        INSERT INTO dbo.YTDJRL (
            YJ_CO, YJ_DIV, YJ_JRL, YJ_CC, YJ_ACC, YJ_FILA,
            YJ_AMT, YJ_OSJ, YJ_RDT, YJ_RJRL, YJ_UID, YJ_PDT,
            YJ_FILC, YJ_DT, YJ_FILD, YJ_MEM, YJ_SRC, YJ_STA,
            YJ_RID, YJ_USE, YJ_CRT, YJ_DES, UPDATE_IDENT, LastRunId
        )
        SELECT
            s.YJ_CO, s.YJ_DIV, s.YJ_JRL, s.YJ_CC, s.YJ_ACC, s.YJ_FILA,
            s.YJ_AMT, s.YJ_OSJ, s.YJ_RDT, s.YJ_RJRL, s.YJ_UID, s.YJ_PDT,
            s.YJ_FILC, s.YJ_DT, s.YJ_FILD, s.YJ_MEM, s.YJ_SRC, s.YJ_STA,
            s.YJ_RID, s.YJ_USE, s.YJ_CRT, s.YJ_DES, s.UPDATE_IDENT, @RunId
        FROM stg.YTDJRL s
        WHERE s.LoadRunId = CONVERT(CHAR(36), @RunId);

        DECLARE @Inserted INT = @@ROWCOUNT;

        UPDATE dbo.AcctLoadControl
        SET    RowsCopied   = @RowsCopied,
               RowsInserted = ISNULL(@Inserted, 0),
               RowsUpdated  = 0,
               WatermarkTo  = @WatermarkTo
        WHERE  RunId = @RunId;
    END TRY
    BEGIN CATCH
        UPDATE dbo.AcctLoadControl
        SET    Status = 'FAILED', EndedUtc = SYSUTCDATETIME(), ErrorMessage = ERROR_MESSAGE()
        WHERE  RunId = @RunId;
        THROW;
    END CATCH
END
GO

-- ===========================================================================
-- Verification queries (run any time)
-- ===========================================================================

-- Row count + load history
--   SELECT TOP 5 StartedUtc, EndedUtc, Status, RunKind, RowsCopied, RowsInserted,
--                WatermarkFrom, WatermarkTo
--     FROM dbo.AcctLoadControl WHERE TableName = 'YTDJRL'
--     ORDER BY StartedUtc DESC;

-- Date coverage
--   SELECT MIN(YJ_DT) min_dt, MAX(YJ_DT) max_dt, COUNT(*) rows FROM dbo.YTDJRL;

-- P&L reconciliation to GLCAL for any closed period (Feb 2026 example):
--   WITH yj AS (SELECT RTRIM(YJ_ACC) acc, SUM(YJ_AMT) j FROM dbo.YTDJRL
--                WHERE YJ_DT BETWEEN 20260201 AND 20260229 GROUP BY YJ_ACC),
--        gl AS (SELECT RTRIM(GB_GLA) acc, SUM(GB_AMT) g FROM dbo.GLCAL
--                WHERE GB_DATE = 202602 GROUP BY GB_GLA)
--   SELECT 'YTDJRL P&L' k, CAST(SUM(yj.j) AS VARCHAR) v
--     FROM yj JOIN dbo.ACCMAST am ON RTRIM(am.ACACC) = yj.acc WHERE am.ACTYP IN ('2','3')
--   UNION ALL SELECT 'GLCAL  P&L', CAST(SUM(gl.g) AS VARCHAR)
--     FROM gl JOIN dbo.ACCMAST am ON RTRIM(am.ACACC) = gl.acc WHERE am.ACTYP IN ('2','3');
--   -- Both should equal exactly for any closed period.

-- Monthly P&L for unclosed periods (the original gap, now closed):
--   WITH y AS (SELECT CAST(YJ_DT AS INT)/100 period, RTRIM(YJ_ACC) acc, SUM(YJ_AMT) amt
--                FROM dbo.YTDJRL WHERE YJ_DT BETWEEN 20260301 AND 20260531
--                GROUP BY CAST(YJ_DT AS INT)/100, YJ_ACC)
--   SELECT period,
--          SUM(CASE WHEN am.ACTYP='2' THEN -amt ELSE 0 END) AS revenue,
--          SUM(CASE WHEN am.ACTYP='3' THEN  amt ELSE 0 END) AS expense,
--          SUM(CASE WHEN am.ACTYP IN ('2','3') THEN -amt ELSE 0 END) AS net_income
--     FROM y JOIN dbo.ACCMAST am ON RTRIM(am.ACACC) = y.acc
--    WHERE am.ACTYP IN ('2','3') GROUP BY period ORDER BY period;
