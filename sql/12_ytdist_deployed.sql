-- ===========================================================================
-- 12_ytdist_deployed.sql
--
-- DEPLOYED 2026-05-31 — captured from the live acctdata replica for
-- repo-side documentation. The ETL team built this directly against the
-- live DB the same day the AS/400 admin returned the source DDL.
--
-- Pattern departure from YTDJRL (the other journal-line table):
--   - FULL_RELOAD + MERGE on natural PK (DN_TID, DN_SEQ), not append-only.
--     Per the ETL team's analysis: "DN_UID is 99.4% zero, DN_TID is
--     sentinel-poisoned" — neither works as an incremental watermark.
--     YTDIST rows can also be updated in place (e.g., DN_CHQ populates
--     when checks are cut later), so MERGE with change-detection is the
--     only correct option.
--   - Natural PK on (DN_TID, DN_SEQ) — no synthetic IDENTITY needed.
--   - Audit columns: BOTH DateAddedUtc AND DateModifiedUtc (mutating
--     rows need both, unlike append-only YTDJRL which only has
--     DateAddedUtc).
--   - Cadence: daily full reload (volume ~1.84M as of initial load),
--     rather than the 4×/day cadence used by the small summary tables.
--
-- Source DDL from the AS/400: docs/YTDIST_DDL.sql.
-- ===========================================================================

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ---------------------------------------------------------------------------
-- dbo.YTDIST — Year-to-Date A/P Distribution (canonical vendor-invoice source)
-- Source: PFWF0125.YTDIST on the AS/400 (Intellidealer 6.0)
-- Natural PK from source: (DN_TID, DN_SEQ)
-- ---------------------------------------------------------------------------
CREATE TABLE dbo.YTDIST (
    DN_TID          DECIMAL(18,0)   NOT NULL,    -- Transaction id (PK part)
    DN_SEQ          NUMERIC(5,0)    NOT NULL,    -- Sequence within transaction (PK part)
    DN_RID          CHAR(1)         NOT NULL,    -- Record ID
    DN_CO           CHAR(2)         NOT NULL,    -- Company
    DN_VEN          CHAR(6)         NOT NULL,    -- Vendor code
    DN_DIV          CHAR(2)         NOT NULL,    -- Division
    DN_TC           CHAR(3)         NOT NULL,    -- Transaction code
    DN_VCH          CHAR(6)         NOT NULL,    -- Voucher number
    DN_NME          CHAR(25)        NOT NULL,    -- Vendor name (may be 'COMPUTER GENERATED $$$$VP' placeholder)
    DN_RR           CHAR(1)         NOT NULL,    -- Rapid Remittance, ADJ, REG
    DN_FILA         CHAR(6)         NOT NULL,    -- Filler
    DN_GRS          DECIMAL(11,2)   NOT NULL,    -- Gross amount (signed; rows per invoice net to zero)
    DN_ACC          CHAR(5)         NOT NULL,    -- GL account (distribution side)
    DN_DNU          CHAR(5)         NOT NULL,    -- Do Not Use (per source — see PGM CCA007)
    DN_CC           CHAR(3)         NOT NULL,    -- Cost center
    DN_FILB         CHAR(6)         NOT NULL,    -- Filler
    DN_CGC          CHAR(1)         NOT NULL,    -- Complete Goods Cost Code
    DN_CGT          CHAR(1)         NOT NULL,    -- Complete Goods Type
    DN_STA          CHAR(1)         NOT NULL,    -- Distribution status
    DN_ORD          CHAR(10)        NOT NULL,    -- Stock number
    DN_INV          CHAR(15)        NOT NULL,    -- Invoice number
    DNFILD          CHAR(20)        NOT NULL,    -- Filler (note: no underscore in source)
    DN_PO           CHAR(10)        NOT NULL,    -- PO number
    DN_POBR         CHAR(2)         NOT NULL,    -- PO branch
    DN_CER          NUMERIC(7,6)    NOT NULL,    -- Currency exchange rate
    DN_DTI          NUMERIC(8,0)    NOT NULL,    -- Invoice date YYYYMMDD
    DN_DTD          NUMERIC(8,0)    NOT NULL,    -- Distribution GL date YYYYMMDD
    DN_CUS          CHAR(10)        NOT NULL,    -- Customer number (rare on A/P)
    DN_UID          DECIMAL(18,0)   NOT NULL,    -- Update ID — UNUSABLE as watermark (99.4% zero per ETL analysis)
    DN_CHQ          CHAR(7)         NOT NULL,    -- Check number (empty = unpaid by check; may still be journal-cleared)
    DN_HDES         CHAR(40)        NOT NULL,    -- History description
    UPDATE_IDENT    DECIMAL(7,0)    NOT NULL,    -- IBM i row-version
    DateAddedUtc    DATETIME2(3)    NOT NULL CONSTRAINT DF_YTDIST_DateAddedUtc    DEFAULT SYSUTCDATETIME(),
    DateModifiedUtc DATETIME2(3)    NOT NULL CONSTRAINT DF_YTDIST_DateModifiedUtc DEFAULT SYSUTCDATETIME(),
    LastRunId       UNIQUEIDENTIFIER NULL,
    CONSTRAINT PK_YTDIST PRIMARY KEY CLUSTERED (DN_TID, DN_SEQ)
);
GO

-- ---------------------------------------------------------------------------
-- stg.YTDIST — transient staging; populated by ADF Copy, drained by
-- sp_Acct_Merge_YTDIST on each FULL_RELOAD run.
-- ---------------------------------------------------------------------------
CREATE TABLE stg.YTDIST (
    DN_TID          DECIMAL(18,0)   NULL,
    DN_SEQ          NUMERIC(5,0)    NULL,
    DN_RID          CHAR(1)         NULL,
    DN_CO           CHAR(2)         NULL,
    DN_VEN          CHAR(6)         NULL,
    DN_DIV          CHAR(2)         NULL,
    DN_TC           CHAR(3)         NULL,
    DN_VCH          CHAR(6)         NULL,
    DN_NME          CHAR(25)        NULL,
    DN_RR           CHAR(1)         NULL,
    DN_FILA         CHAR(6)         NULL,
    DN_GRS          DECIMAL(11,2)   NULL,
    DN_ACC          CHAR(5)         NULL,
    DN_DNU          CHAR(5)         NULL,
    DN_CC           CHAR(3)         NULL,
    DN_FILB         CHAR(6)         NULL,
    DN_CGC          CHAR(1)         NULL,
    DN_CGT          CHAR(1)         NULL,
    DN_STA          CHAR(1)         NULL,
    DN_ORD          CHAR(10)        NULL,
    DN_INV          CHAR(15)        NULL,
    DNFILD          CHAR(20)        NULL,
    DN_PO           CHAR(10)        NULL,
    DN_POBR         CHAR(2)         NULL,
    DN_CER          NUMERIC(7,6)    NULL,
    DN_DTI          NUMERIC(8,0)    NULL,
    DN_DTD          NUMERIC(8,0)    NULL,
    DN_CUS          CHAR(10)        NULL,
    DN_UID          DECIMAL(18,0)   NULL,
    DN_CHQ          CHAR(7)         NULL,
    DN_HDES         CHAR(40)        NULL,
    UPDATE_IDENT    DECIMAL(7,0)    NULL,
    LoadRunId       CHAR(36)        NULL,
    LoadedAt        CHAR(26)        NULL
);
GO

-- ---------------------------------------------------------------------------
-- sp_Acct_Merge_YTDIST — FULL_RELOAD with change-detection MERGE on natural PK.
-- Same shape as sp_Acct_Merge_GLCAL etc.; differs from sp_Acct_Insert_YTDJRL
-- (which is append-only because YTDJRL rows are immutable).
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_Acct_Merge_YTDIST
    @RunId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        DECLARE @RowsCopied INT = (SELECT COUNT(*) FROM stg.YTDIST WHERE LoadRunId = CONVERT(CHAR(36), @RunId));
        DECLARE @Inserted INT = 0, @Updated INT = 0;
        DECLARE @MergeActions TABLE (Action NVARCHAR(10));

        ;WITH src AS (SELECT * FROM stg.YTDIST WHERE LoadRunId = CONVERT(CHAR(36), @RunId))
        MERGE dbo.YTDIST AS tgt
        USING src ON tgt.DN_TID = src.DN_TID AND tgt.DN_SEQ = src.DN_SEQ
        WHEN MATCHED AND (
            tgt.DN_RID <> src.DN_RID OR tgt.DN_CO <> src.DN_CO OR tgt.DN_VEN <> src.DN_VEN OR
            tgt.DN_DIV <> src.DN_DIV OR tgt.DN_TC <> src.DN_TC OR tgt.DN_VCH <> src.DN_VCH OR
            tgt.DN_NME <> src.DN_NME OR tgt.DN_RR <> src.DN_RR OR tgt.DN_FILA <> src.DN_FILA OR
            tgt.DN_GRS <> src.DN_GRS OR tgt.DN_ACC <> src.DN_ACC OR tgt.DN_DNU <> src.DN_DNU OR
            tgt.DN_CC <> src.DN_CC OR tgt.DN_FILB <> src.DN_FILB OR tgt.DN_CGC <> src.DN_CGC OR
            tgt.DN_CGT <> src.DN_CGT OR tgt.DN_STA <> src.DN_STA OR tgt.DN_ORD <> src.DN_ORD OR
            tgt.DN_INV <> src.DN_INV OR tgt.DNFILD <> src.DNFILD OR tgt.DN_PO <> src.DN_PO OR
            tgt.DN_POBR <> src.DN_POBR OR tgt.DN_CER <> src.DN_CER OR tgt.DN_DTI <> src.DN_DTI OR
            tgt.DN_DTD <> src.DN_DTD OR tgt.DN_CUS <> src.DN_CUS OR tgt.DN_UID <> src.DN_UID OR
            tgt.DN_CHQ <> src.DN_CHQ OR tgt.DN_HDES <> src.DN_HDES OR tgt.UPDATE_IDENT <> src.UPDATE_IDENT
        ) THEN UPDATE SET
            tgt.DN_RID = src.DN_RID, tgt.DN_CO = src.DN_CO, tgt.DN_VEN = src.DN_VEN,
            tgt.DN_DIV = src.DN_DIV, tgt.DN_TC = src.DN_TC, tgt.DN_VCH = src.DN_VCH,
            tgt.DN_NME = src.DN_NME, tgt.DN_RR = src.DN_RR, tgt.DN_FILA = src.DN_FILA,
            tgt.DN_GRS = src.DN_GRS, tgt.DN_ACC = src.DN_ACC, tgt.DN_DNU = src.DN_DNU,
            tgt.DN_CC = src.DN_CC, tgt.DN_FILB = src.DN_FILB, tgt.DN_CGC = src.DN_CGC,
            tgt.DN_CGT = src.DN_CGT, tgt.DN_STA = src.DN_STA, tgt.DN_ORD = src.DN_ORD,
            tgt.DN_INV = src.DN_INV, tgt.DNFILD = src.DNFILD, tgt.DN_PO = src.DN_PO,
            tgt.DN_POBR = src.DN_POBR, tgt.DN_CER = src.DN_CER, tgt.DN_DTI = src.DN_DTI,
            tgt.DN_DTD = src.DN_DTD, tgt.DN_CUS = src.DN_CUS, tgt.DN_UID = src.DN_UID,
            tgt.DN_CHQ = src.DN_CHQ, tgt.DN_HDES = src.DN_HDES, tgt.UPDATE_IDENT = src.UPDATE_IDENT,
            tgt.DateModifiedUtc = SYSUTCDATETIME(), tgt.LastRunId = @RunId
        WHEN NOT MATCHED BY TARGET THEN INSERT (
            DN_TID, DN_SEQ, DN_RID, DN_CO, DN_VEN, DN_DIV,
            DN_TC, DN_VCH, DN_NME, DN_RR, DN_FILA, DN_GRS,
            DN_ACC, DN_DNU, DN_CC, DN_FILB, DN_CGC, DN_CGT,
            DN_STA, DN_ORD, DN_INV, DNFILD, DN_PO, DN_POBR,
            DN_CER, DN_DTI, DN_DTD, DN_CUS, DN_UID, DN_CHQ,
            DN_HDES, UPDATE_IDENT, DateAddedUtc, DateModifiedUtc, LastRunId
        ) VALUES (
            src.DN_TID, src.DN_SEQ, src.DN_RID, src.DN_CO, src.DN_VEN, src.DN_DIV,
            src.DN_TC, src.DN_VCH, src.DN_NME, src.DN_RR, src.DN_FILA, src.DN_GRS,
            src.DN_ACC, src.DN_DNU, src.DN_CC, src.DN_FILB, src.DN_CGC, src.DN_CGT,
            src.DN_STA, src.DN_ORD, src.DN_INV, src.DNFILD, src.DN_PO, src.DN_POBR,
            src.DN_CER, src.DN_DTI, src.DN_DTD, src.DN_CUS, src.DN_UID, src.DN_CHQ,
            src.DN_HDES, src.UPDATE_IDENT, SYSUTCDATETIME(), SYSUTCDATETIME(), @RunId
        )
        OUTPUT $action INTO @MergeActions;

        SELECT @Inserted = SUM(CASE WHEN Action='INSERT' THEN 1 ELSE 0 END),
               @Updated  = SUM(CASE WHEN Action='UPDATE' THEN 1 ELSE 0 END)
        FROM @MergeActions;

        UPDATE dbo.AcctLoadControl
        SET    RowsCopied   = @RowsCopied,
               RowsInserted = ISNULL(@Inserted, 0),
               RowsUpdated  = ISNULL(@Updated, 0)
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
-- Verification queries
-- ===========================================================================

-- Load history + freshness
--   SELECT TOP 5 StartedUtc, Status, RunKind, RowsCopied, RowsInserted, RowsUpdated
--     FROM dbo.AcctLoadControl WHERE TableName='YTDIST' ORDER BY StartedUtc DESC;

-- Vendor spend (excludes A/P liability clearing rows; includes inventory purchases)
--   SELECT TOP 20 RTRIM(DN_VEN) AS vendor,
--          MAX(LEFT(RTRIM(DN_NME),35)) AS name,
--          COUNT(DISTINCT DN_TID) AS invoices,
--          SUM(CASE WHEN DN_GRS>0 AND DN_ACC NOT LIKE '2%' THEN DN_GRS ELSE 0 END) AS spend
--   FROM dbo.YTDIST WHERE DN_DTI BETWEEN 20260101 AND 20260531
--   GROUP BY DN_VEN ORDER BY 4 DESC;
