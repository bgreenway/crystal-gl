-- ===========================================================================
-- 08_journal_line_procedures.sql
--
-- Merge procedures for the five journal-line sub-system tables added in
-- sql/07_journal_line_schema.sql. Same change-detection MERGE pattern used
-- by sp_Acct_Merge_GLCAL etc. in sql/02_procedures.sql.
--
-- Each proc:
--   1. Counts staging rows for the current RunId.
--   2. MERGE stg.<T> → dbo.<T>, only writing rows whose values actually differ.
--   3. Stamps LastSeenUtc + LastRunId on updates, FirstSeenUtc + LastSeenUtc
--      + LastRunId on inserts.
--   4. Updates dbo.AcctLoadControl with copied/inserted/updated counts.
--   5. On error: marks the run FAILED + writes ErrorMessage and re-throws.
--
-- These procs should be invoked by ADF after the per-table Copy lands rows
-- into stg.<T> with LoadRunId = the current run's RunId. See sql/10_*.sql
-- for the ALTER to sp_AcctStartRun that adds these table names to its
-- allow-list, and docs/journal-line-etl-spec.md for the ADF spec.
-- ===========================================================================

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ---------------------------------------------------------------------------
-- sp_Acct_Merge_CGIHIST   PK (CH_CO, CH_DIV, CH_ORD, CH_CGT, CH_CLS, CH_BDT, CH_INV, CH_SEQ)
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_Acct_Merge_CGIHIST
    @RunId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        DECLARE @RowsCopied INT = (SELECT COUNT(*) FROM stg.CGIHIST WHERE LoadRunId = CONVERT(CHAR(36), @RunId));
        DECLARE @Inserted INT = 0, @Updated INT = 0;
        DECLARE @MergeActions TABLE (Action NVARCHAR(10));

        ;WITH src AS (SELECT * FROM stg.CGIHIST WHERE LoadRunId = CONVERT(CHAR(36), @RunId))
        MERGE dbo.CGIHIST AS tgt
        USING src ON tgt.CH_CO = src.CH_CO AND tgt.CH_DIV = src.CH_DIV
                 AND tgt.CH_ORD = src.CH_ORD AND tgt.CH_CGT = src.CH_CGT
                 AND tgt.CH_CLS = src.CH_CLS AND tgt.CH_BDT = src.CH_BDT
                 AND tgt.CH_INV = src.CH_INV AND tgt.CH_SEQ = src.CH_SEQ
        WHEN MATCHED AND (
            ISNULL(tgt.CH_CUS,'')   <> ISNULL(src.CH_CUS,'')   OR
            ISNULL(tgt.CH_FILA,'')  <> ISNULL(src.CH_FILA,'')  OR
            ISNULL(tgt.CH_AMT,0)    <> ISNULL(src.CH_AMT,0)    OR
            ISNULL(tgt.CH_ACC,'')   <> ISNULL(src.CH_ACC,'')   OR
            ISNULL(tgt.CH_CC,'')    <> ISNULL(src.CH_CC,'')    OR
            ISNULL(tgt.CH_STA,'')   <> ISNULL(src.CH_STA,'')   OR
            ISNULL(tgt.FILL1A,'')   <> ISNULL(src.FILL1A,'')   OR
            ISNULL(tgt.CH_BR,'')    <> ISNULL(src.CH_BR,'')    OR
            ISNULL(tgt.CH_HRS,0)    <> ISNULL(src.CH_HRS,0)    OR
            ISNULL(tgt.CH_UID,0)    <> ISNULL(src.CH_UID,0)    OR
            ISNULL(tgt.CH_SYS,'')   <> ISNULL(src.CH_SYS,'')   OR
            ISNULL(tgt.CH_TID,0)    <> ISNULL(src.CH_TID,0)    OR
            ISNULL(tgt.CH_NME,'')   <> ISNULL(src.CH_NME,'')   OR
            ISNULL(tgt.UPDATE_IDENT,0) <> ISNULL(src.UPDATE_IDENT,0)
        ) THEN UPDATE SET
            tgt.CH_CUS = src.CH_CUS, tgt.CH_FILA = src.CH_FILA, tgt.CH_AMT = src.CH_AMT,
            tgt.CH_ACC = src.CH_ACC, tgt.CH_CC = src.CH_CC, tgt.CH_STA = src.CH_STA,
            tgt.FILL1A = src.FILL1A, tgt.CH_BR = src.CH_BR, tgt.CH_HRS = src.CH_HRS,
            tgt.CH_UID = src.CH_UID, tgt.CH_SYS = src.CH_SYS, tgt.CH_TID = src.CH_TID,
            tgt.CH_NME = src.CH_NME, tgt.UPDATE_IDENT = src.UPDATE_IDENT,
            tgt.LastSeenUtc = SYSUTCDATETIME(), tgt.LastRunId = @RunId
        WHEN NOT MATCHED BY TARGET THEN INSERT (
            CH_CO, CH_DIV, CH_ORD, CH_CGT, CH_CLS, CH_BDT, CH_INV, CH_SEQ,
            CH_CUS, CH_FILA, CH_AMT, CH_ACC, CH_CC, CH_STA, FILL1A,
            CH_BR, CH_HRS, CH_UID, CH_SYS, CH_TID, CH_NME, UPDATE_IDENT,
            FirstSeenUtc, LastSeenUtc, LastRunId
        ) VALUES (
            src.CH_CO, src.CH_DIV, src.CH_ORD, src.CH_CGT, src.CH_CLS, src.CH_BDT, src.CH_INV, src.CH_SEQ,
            src.CH_CUS, src.CH_FILA, src.CH_AMT, src.CH_ACC, src.CH_CC, src.CH_STA, src.FILL1A,
            src.CH_BR, src.CH_HRS, src.CH_UID, src.CH_SYS, src.CH_TID, src.CH_NME, src.UPDATE_IDENT,
            SYSUTCDATETIME(), SYSUTCDATETIME(), @RunId
        )
        OUTPUT $action INTO @MergeActions;

        SELECT @Inserted = SUM(CASE WHEN Action='INSERT' THEN 1 ELSE 0 END),
               @Updated  = SUM(CASE WHEN Action='UPDATE' THEN 1 ELSE 0 END)
        FROM @MergeActions;

        UPDATE dbo.AcctLoadControl
        SET RowsCopied = @RowsCopied, RowsInserted = ISNULL(@Inserted,0), RowsUpdated = ISNULL(@Updated,0)
        WHERE RunId = @RunId;
    END TRY
    BEGIN CATCH
        UPDATE dbo.AcctLoadControl
        SET Status='FAILED', EndedUtc=SYSUTCDATETIME(), ErrorMessage=ERROR_MESSAGE()
        WHERE RunId = @RunId;
        THROW;
    END CATCH
END
GO

-- ---------------------------------------------------------------------------
-- sp_Acct_Merge_YTDIST   PK (DN_TID, DN_SEQ)
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
            ISNULL(tgt.DN_RID,'')    <> ISNULL(src.DN_RID,'')    OR
            ISNULL(tgt.DN_CO,'')     <> ISNULL(src.DN_CO,'')     OR
            ISNULL(tgt.DN_VEN,'')    <> ISNULL(src.DN_VEN,'')    OR
            ISNULL(tgt.DN_DIV,'')    <> ISNULL(src.DN_DIV,'')    OR
            ISNULL(tgt.DN_TC,'')     <> ISNULL(src.DN_TC,'')     OR
            ISNULL(tgt.DN_VCH,'')    <> ISNULL(src.DN_VCH,'')    OR
            ISNULL(tgt.DN_NME,'')    <> ISNULL(src.DN_NME,'')    OR
            ISNULL(tgt.DN_RR,'')     <> ISNULL(src.DN_RR,'')     OR
            ISNULL(tgt.DN_FILA,'')   <> ISNULL(src.DN_FILA,'')   OR
            ISNULL(tgt.DN_GRS,0)     <> ISNULL(src.DN_GRS,0)     OR
            ISNULL(tgt.DN_ACC,'')    <> ISNULL(src.DN_ACC,'')    OR
            ISNULL(tgt.DN_DNU,'')    <> ISNULL(src.DN_DNU,'')    OR
            ISNULL(tgt.DN_CC,'')     <> ISNULL(src.DN_CC,'')     OR
            ISNULL(tgt.DN_FILB,'')   <> ISNULL(src.DN_FILB,'')   OR
            ISNULL(tgt.DN_CGC,'')    <> ISNULL(src.DN_CGC,'')    OR
            ISNULL(tgt.DN_CGT,'')    <> ISNULL(src.DN_CGT,'')    OR
            ISNULL(tgt.DN_STA,'')    <> ISNULL(src.DN_STA,'')    OR
            ISNULL(tgt.DN_ORD,'')    <> ISNULL(src.DN_ORD,'')    OR
            ISNULL(tgt.DN_INV,'')    <> ISNULL(src.DN_INV,'')    OR
            ISNULL(tgt.DNFILD,'')    <> ISNULL(src.DNFILD,'')    OR
            ISNULL(tgt.DN_PO,'')     <> ISNULL(src.DN_PO,'')     OR
            ISNULL(tgt.DN_POBR,'')   <> ISNULL(src.DN_POBR,'')   OR
            ISNULL(tgt.DN_CER,0)     <> ISNULL(src.DN_CER,0)     OR
            ISNULL(tgt.DN_DTI,0)     <> ISNULL(src.DN_DTI,0)     OR
            ISNULL(tgt.DN_DTD,0)     <> ISNULL(src.DN_DTD,0)     OR
            ISNULL(tgt.DN_CUS,'')    <> ISNULL(src.DN_CUS,'')    OR
            ISNULL(tgt.DN_UID,0)     <> ISNULL(src.DN_UID,0)     OR
            ISNULL(tgt.DN_CHQ,'')    <> ISNULL(src.DN_CHQ,'')    OR
            ISNULL(tgt.DN_HDES,'')   <> ISNULL(src.DN_HDES,'')   OR
            ISNULL(tgt.UPDATE_IDENT,0) <> ISNULL(src.UPDATE_IDENT,0)
        ) THEN UPDATE SET
            tgt.DN_RID=src.DN_RID, tgt.DN_CO=src.DN_CO, tgt.DN_VEN=src.DN_VEN,
            tgt.DN_DIV=src.DN_DIV, tgt.DN_TC=src.DN_TC, tgt.DN_VCH=src.DN_VCH,
            tgt.DN_NME=src.DN_NME, tgt.DN_RR=src.DN_RR, tgt.DN_FILA=src.DN_FILA,
            tgt.DN_GRS=src.DN_GRS, tgt.DN_ACC=src.DN_ACC, tgt.DN_DNU=src.DN_DNU,
            tgt.DN_CC=src.DN_CC, tgt.DN_FILB=src.DN_FILB, tgt.DN_CGC=src.DN_CGC,
            tgt.DN_CGT=src.DN_CGT, tgt.DN_STA=src.DN_STA, tgt.DN_ORD=src.DN_ORD,
            tgt.DN_INV=src.DN_INV, tgt.DNFILD=src.DNFILD, tgt.DN_PO=src.DN_PO,
            tgt.DN_POBR=src.DN_POBR, tgt.DN_CER=src.DN_CER, tgt.DN_DTI=src.DN_DTI,
            tgt.DN_DTD=src.DN_DTD, tgt.DN_CUS=src.DN_CUS, tgt.DN_UID=src.DN_UID,
            tgt.DN_CHQ=src.DN_CHQ, tgt.DN_HDES=src.DN_HDES, tgt.UPDATE_IDENT=src.UPDATE_IDENT,
            tgt.LastSeenUtc = SYSUTCDATETIME(), tgt.LastRunId = @RunId
        WHEN NOT MATCHED BY TARGET THEN INSERT (
            DN_RID, DN_CO, DN_VEN, DN_DIV, DN_TC, DN_VCH, DN_NME, DN_RR, DN_FILA,
            DN_GRS, DN_ACC, DN_DNU, DN_CC, DN_FILB, DN_CGC, DN_CGT, DN_STA,
            DN_ORD, DN_INV, DNFILD, DN_PO, DN_POBR, DN_CER, DN_DTI, DN_DTD,
            DN_CUS, DN_TID, DN_SEQ, DN_UID, DN_CHQ, DN_HDES, UPDATE_IDENT,
            FirstSeenUtc, LastSeenUtc, LastRunId
        ) VALUES (
            src.DN_RID, src.DN_CO, src.DN_VEN, src.DN_DIV, src.DN_TC, src.DN_VCH, src.DN_NME, src.DN_RR, src.DN_FILA,
            src.DN_GRS, src.DN_ACC, src.DN_DNU, src.DN_CC, src.DN_FILB, src.DN_CGC, src.DN_CGT, src.DN_STA,
            src.DN_ORD, src.DN_INV, src.DNFILD, src.DN_PO, src.DN_POBR, src.DN_CER, src.DN_DTI, src.DN_DTD,
            src.DN_CUS, src.DN_TID, src.DN_SEQ, src.DN_UID, src.DN_CHQ, src.DN_HDES, src.UPDATE_IDENT,
            SYSUTCDATETIME(), SYSUTCDATETIME(), @RunId
        )
        OUTPUT $action INTO @MergeActions;

        SELECT @Inserted = SUM(CASE WHEN Action='INSERT' THEN 1 ELSE 0 END),
               @Updated  = SUM(CASE WHEN Action='UPDATE' THEN 1 ELSE 0 END)
        FROM @MergeActions;

        UPDATE dbo.AcctLoadControl
        SET RowsCopied = @RowsCopied, RowsInserted = ISNULL(@Inserted,0), RowsUpdated = ISNULL(@Updated,0)
        WHERE RunId = @RunId;
    END TRY
    BEGIN CATCH
        UPDATE dbo.AcctLoadControl
        SET Status='FAILED', EndedUtc=SYSUTCDATETIME(), ErrorMessage=ERROR_MESSAGE()
        WHERE RunId = @RunId;
        THROW;
    END CATCH
END
GO

-- ---------------------------------------------------------------------------
-- sp_Acct_Merge_SUBLED   PK (SL_CO, SL_ACC, SL_CC, SL_DIV, SL_SEQ)
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_Acct_Merge_SUBLED
    @RunId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        DECLARE @RowsCopied INT = (SELECT COUNT(*) FROM stg.SUBLED WHERE LoadRunId = CONVERT(CHAR(36), @RunId));
        DECLARE @Inserted INT = 0, @Updated INT = 0;
        DECLARE @MergeActions TABLE (Action NVARCHAR(10));

        ;WITH src AS (SELECT * FROM stg.SUBLED WHERE LoadRunId = CONVERT(CHAR(36), @RunId))
        MERGE dbo.SUBLED AS tgt
        USING src ON tgt.SL_CO=src.SL_CO AND tgt.SL_ACC=src.SL_ACC
                 AND tgt.SL_CC=src.SL_CC AND tgt.SL_DIV=src.SL_DIV
                 AND tgt.SL_SEQ=src.SL_SEQ
        WHEN MATCHED AND (
            ISNULL(tgt.SL_STA,'')    <> ISNULL(src.SL_STA,'')    OR
            ISNULL(tgt.SL_CUS,'')    <> ISNULL(src.SL_CUS,'')    OR
            ISNULL(tgt.SL_FILB,'')   <> ISNULL(src.SL_FILB,'')   OR
            ISNULL(tgt.SL_DES,'')    <> ISNULL(src.SL_DES,'')    OR
            ISNULL(tgt.SL_IA,0)      <> ISNULL(src.SL_IA,0)      OR
            ISNULL(tgt.SL_RA,0)      <> ISNULL(src.SL_RA,0)      OR
            ISNULL(tgt.SL_DTI,0)     <> ISNULL(src.SL_DTI,0)     OR
            ISNULL(tgt.SL_DTR,0)     <> ISNULL(src.SL_DTR,0)     OR
            ISNULL(tgt.SL_CRN,'')    <> ISNULL(src.SL_CRN,'')    OR
            ISNULL(tgt.SL_BL,'')     <> ISNULL(src.SL_BL,'')     OR
            ISNULL(tgt.SL_UID,0)     <> ISNULL(src.SL_UID,0)     OR
            ISNULL(tgt.SL_SYS,'')    <> ISNULL(src.SL_SYS,'')    OR
            ISNULL(tgt.SL_TID,0)     <> ISNULL(src.SL_TID,0)     OR
            ISNULL(tgt.SL_ORD,'')    <> ISNULL(src.SL_ORD,'')    OR
            ISNULL(tgt.SL_FILA,'')   <> ISNULL(src.SL_FILA,'')   OR
            ISNULL(tgt.SL_NME,'')    <> ISNULL(src.SL_NME,'')    OR
            ISNULL(tgt.UPDATE_IDENT,0) <> ISNULL(src.UPDATE_IDENT,0)
        ) THEN UPDATE SET
            tgt.SL_STA=src.SL_STA, tgt.SL_CUS=src.SL_CUS, tgt.SL_FILB=src.SL_FILB,
            tgt.SL_DES=src.SL_DES, tgt.SL_IA=src.SL_IA, tgt.SL_RA=src.SL_RA,
            tgt.SL_DTI=src.SL_DTI, tgt.SL_DTR=src.SL_DTR, tgt.SL_CRN=src.SL_CRN,
            tgt.SL_BL=src.SL_BL, tgt.SL_UID=src.SL_UID, tgt.SL_SYS=src.SL_SYS,
            tgt.SL_TID=src.SL_TID, tgt.SL_ORD=src.SL_ORD, tgt.SL_FILA=src.SL_FILA,
            tgt.SL_NME=src.SL_NME, tgt.UPDATE_IDENT=src.UPDATE_IDENT,
            tgt.LastSeenUtc = SYSUTCDATETIME(), tgt.LastRunId = @RunId
        WHEN NOT MATCHED BY TARGET THEN INSERT (
            SL_STA, SL_CO, SL_ACC, SL_CC, SL_DIV, SL_SEQ,
            SL_CUS, SL_FILB, SL_DES, SL_IA, SL_RA, SL_DTI, SL_DTR, SL_CRN,
            SL_BL, SL_UID, SL_SYS, SL_TID, SL_ORD, SL_FILA, SL_NME, UPDATE_IDENT,
            FirstSeenUtc, LastSeenUtc, LastRunId
        ) VALUES (
            src.SL_STA, src.SL_CO, src.SL_ACC, src.SL_CC, src.SL_DIV, src.SL_SEQ,
            src.SL_CUS, src.SL_FILB, src.SL_DES, src.SL_IA, src.SL_RA, src.SL_DTI, src.SL_DTR, src.SL_CRN,
            src.SL_BL, src.SL_UID, src.SL_SYS, src.SL_TID, src.SL_ORD, src.SL_FILA, src.SL_NME, src.UPDATE_IDENT,
            SYSUTCDATETIME(), SYSUTCDATETIME(), @RunId
        )
        OUTPUT $action INTO @MergeActions;

        SELECT @Inserted = SUM(CASE WHEN Action='INSERT' THEN 1 ELSE 0 END),
               @Updated  = SUM(CASE WHEN Action='UPDATE' THEN 1 ELSE 0 END)
        FROM @MergeActions;

        UPDATE dbo.AcctLoadControl
        SET RowsCopied=@RowsCopied, RowsInserted=ISNULL(@Inserted,0), RowsUpdated=ISNULL(@Updated,0)
        WHERE RunId = @RunId;
    END TRY
    BEGIN CATCH
        UPDATE dbo.AcctLoadControl
        SET Status='FAILED', EndedUtc=SYSUTCDATETIME(), ErrorMessage=ERROR_MESSAGE()
        WHERE RunId = @RunId;
        THROW;
    END CATCH
END
GO

-- ---------------------------------------------------------------------------
-- sp_Acct_Merge_PARTHIST   PK (PH_CO, PH_PRT, PH_DIV, PH_BR, PH_DTR, PH_TMR, PH_PO, PH_SEQ)
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_Acct_Merge_PARTHIST
    @RunId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        DECLARE @RowsCopied INT = (SELECT COUNT(*) FROM stg.PARTHIST WHERE LoadRunId = CONVERT(CHAR(36), @RunId));
        DECLARE @Inserted INT = 0, @Updated INT = 0;
        DECLARE @MergeActions TABLE (Action NVARCHAR(10));

        ;WITH src AS (SELECT * FROM stg.PARTHIST WHERE LoadRunId = CONVERT(CHAR(36), @RunId))
        MERGE dbo.PARTHIST AS tgt
        USING src ON tgt.PH_CO=src.PH_CO AND tgt.PH_PRT=src.PH_PRT
                 AND tgt.PH_DIV=src.PH_DIV AND tgt.PH_BR=src.PH_BR
                 AND tgt.PH_DTR=src.PH_DTR AND tgt.PH_TMR=src.PH_TMR
                 AND tgt.PH_PO=src.PH_PO AND tgt.PH_SEQ=src.PH_SEQ
        WHEN MATCHED AND (
            ISNULL(tgt.PH_STA,'')    <> ISNULL(src.PH_STA,'')    OR
            ISNULL(tgt.PH_TID,0)     <> ISNULL(src.PH_TID,0)     OR
            ISNULL(tgt.PH_UID,0)     <> ISNULL(src.PH_UID,0)     OR
            ISNULL(tgt.PH_QTR,0)     <> ISNULL(src.PH_QTR,0)     OR
            ISNULL(tgt.PH_NET,0)     <> ISNULL(src.PH_NET,0)     OR
            ISNULL(tgt.PH_VEN,'')    <> ISNULL(src.PH_VEN,'')    OR
            ISNULL(tgt.PH_OST,'')    <> ISNULL(src.PH_OST,'')    OR
            ISNULL(tgt.PH_PPK,0)     <> ISNULL(src.PH_PPK,0)     OR
            ISNULL(tgt.PH_TYP,'')    <> ISNULL(src.PH_TYP,'')    OR
            ISNULL(tgt.PH_GLIC,'')   <> ISNULL(src.PH_GLIC,'')   OR
            ISNULL(tgt.PH_GLIA,'')   <> ISNULL(src.PH_GLIA,'')   OR
            ISNULL(tgt.PH_IAC,'')    <> ISNULL(src.PH_IAC,'')    OR
            ISNULL(tgt.PH_IAA,'')    <> ISNULL(src.PH_IAA,'')    OR
            ISNULL(tgt.PH_INV,'')    <> ISNULL(src.PH_INV,'')    OR
            ISNULL(tgt.PH_QRE,0)     <> ISNULL(src.PH_QRE,0)     OR
            ISNULL(tgt.PH_FIL1,'')   <> ISNULL(src.PH_FIL1,'')   OR
            ISNULL(tgt.UPDATE_IDENT,0) <> ISNULL(src.UPDATE_IDENT,0)
        ) THEN UPDATE SET
            tgt.PH_STA=src.PH_STA, tgt.PH_TID=src.PH_TID, tgt.PH_UID=src.PH_UID,
            tgt.PH_QTR=src.PH_QTR, tgt.PH_NET=src.PH_NET, tgt.PH_VEN=src.PH_VEN,
            tgt.PH_OST=src.PH_OST, tgt.PH_PPK=src.PH_PPK, tgt.PH_TYP=src.PH_TYP,
            tgt.PH_GLIC=src.PH_GLIC, tgt.PH_GLIA=src.PH_GLIA, tgt.PH_IAC=src.PH_IAC,
            tgt.PH_IAA=src.PH_IAA, tgt.PH_INV=src.PH_INV, tgt.PH_QRE=src.PH_QRE,
            tgt.PH_FIL1=src.PH_FIL1, tgt.UPDATE_IDENT=src.UPDATE_IDENT,
            tgt.LastSeenUtc = SYSUTCDATETIME(), tgt.LastRunId = @RunId
        WHEN NOT MATCHED BY TARGET THEN INSERT (
            PH_STA, PH_CO, PH_PRT, PH_DIV, PH_BR, PH_DTR, PH_TMR, PH_PO, PH_SEQ,
            PH_TID, PH_UID, PH_QTR, PH_NET, PH_VEN, PH_OST, PH_PPK, PH_TYP,
            PH_GLIC, PH_GLIA, PH_IAC, PH_IAA, PH_INV, PH_QRE, PH_FIL1, UPDATE_IDENT,
            FirstSeenUtc, LastSeenUtc, LastRunId
        ) VALUES (
            src.PH_STA, src.PH_CO, src.PH_PRT, src.PH_DIV, src.PH_BR, src.PH_DTR, src.PH_TMR, src.PH_PO, src.PH_SEQ,
            src.PH_TID, src.PH_UID, src.PH_QTR, src.PH_NET, src.PH_VEN, src.PH_OST, src.PH_PPK, src.PH_TYP,
            src.PH_GLIC, src.PH_GLIA, src.PH_IAC, src.PH_IAA, src.PH_INV, src.PH_QRE, src.PH_FIL1, src.UPDATE_IDENT,
            SYSUTCDATETIME(), SYSUTCDATETIME(), @RunId
        )
        OUTPUT $action INTO @MergeActions;

        SELECT @Inserted = SUM(CASE WHEN Action='INSERT' THEN 1 ELSE 0 END),
               @Updated  = SUM(CASE WHEN Action='UPDATE' THEN 1 ELSE 0 END)
        FROM @MergeActions;

        UPDATE dbo.AcctLoadControl
        SET RowsCopied=@RowsCopied, RowsInserted=ISNULL(@Inserted,0), RowsUpdated=ISNULL(@Updated,0)
        WHERE RunId = @RunId;
    END TRY
    BEGIN CATCH
        UPDATE dbo.AcctLoadControl
        SET Status='FAILED', EndedUtc=SYSUTCDATETIME(), ErrorMessage=ERROR_MESSAGE()
        WHERE RunId = @RunId;
        THROW;
    END CATCH
END
GO

-- ---------------------------------------------------------------------------
-- sp_Acct_Merge_INVHCC   PK (EB_TID)
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_Acct_Merge_INVHCC
    @RunId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        DECLARE @RowsCopied INT = (SELECT COUNT(*) FROM stg.INVHCC WHERE LoadRunId = CONVERT(CHAR(36), @RunId));
        DECLARE @Inserted INT = 0, @Updated INT = 0;
        DECLARE @MergeActions TABLE (Action NVARCHAR(10));

        ;WITH src AS (SELECT * FROM stg.INVHCC WHERE LoadRunId = CONVERT(CHAR(36), @RunId))
        MERGE dbo.INVHCC AS tgt
        USING src ON tgt.EB_TID = src.EB_TID
        WHEN MATCHED AND (
            ISNULL(tgt.EB_CO,'')    <> ISNULL(src.EB_CO,'')    OR
            ISNULL(tgt.EB_DIV,'')   <> ISNULL(src.EB_DIV,'')   OR
            ISNULL(tgt.EB_BR,'')    <> ISNULL(src.EB_BR,'')    OR
            ISNULL(tgt.EB_SYS,'')   <> ISNULL(src.EB_SYS,'')   OR
            ISNULL(tgt.EB_ORD,'')   <> ISNULL(src.EB_ORD,'')   OR
            ISNULL(tgt.EB_CRDN,'')  <> ISNULL(src.EB_CRDN,'')  OR
            ISNULL(tgt.EB_EXP,0)    <> ISNULL(src.EB_EXP,0)    OR
            ISNULL(tgt.EB_AUTH,'')  <> ISNULL(src.EB_AUTH,'')  OR
            ISNULL(tgt.EB_MER,'')   <> ISNULL(src.EB_MER,'')   OR
            ISNULL(tgt.EB_PROM,'')  <> ISNULL(src.EB_PROM,'')  OR
            ISNULL(tgt.EB_INVD,'')  <> ISNULL(src.EB_INVD,'')  OR
            ISNULL(tgt.EB_AGC,'')   <> ISNULL(src.EB_AGC,'')   OR
            ISNULL(tgt.EB_MAN,'')   <> ISNULL(src.EB_MAN,'')   OR
            ISNULL(tgt.EB_AAMT,0)   <> ISNULL(src.EB_AAMT,0)   OR
            ISNULL(tgt.EB_GLA,'')   <> ISNULL(src.EB_GLA,'')   OR
            ISNULL(tgt.EB_GLC,'')   <> ISNULL(src.EB_GLC,'')   OR
            ISNULL(tgt.EB_DTT,0)    <> ISNULL(src.EB_DTT,0)    OR
            ISNULL(tgt.EB_CUS,'')   <> ISNULL(src.EB_CUS,'')   OR
            ISNULL(tgt.EB_IAMT,0)   <> ISNULL(src.EB_IAMT,0)   OR
            ISNULL(tgt.EB_REF,'')   <> ISNULL(src.EB_REF,'')   OR
            ISNULL(tgt.EB_DC1,0)    <> ISNULL(src.EB_DC1,0)    OR
            ISNULL(tgt.EB_DC2,0)    <> ISNULL(src.EB_DC2,0)    OR
            ISNULL(tgt.EB_RQID,'')  <> ISNULL(src.EB_RQID,'')  OR
            ISNULL(tgt.EB_STID,'')  <> ISNULL(src.EB_STID,'')  OR
            ISNULL(tgt.EB_MRID,'')  <> ISNULL(src.EB_MRID,'')  OR
            ISNULL(tgt.EB_TMID,'')  <> ISNULL(src.EB_TMID,'')  OR
            ISNULL(tgt.EB_PDES,'')  <> ISNULL(src.EB_PDES,'')  OR
            ISNULL(tgt.UPDATE_IDENT,0) <> ISNULL(src.UPDATE_IDENT,0)
        ) THEN UPDATE SET
            tgt.EB_CO=src.EB_CO, tgt.EB_DIV=src.EB_DIV, tgt.EB_BR=src.EB_BR,
            tgt.EB_SYS=src.EB_SYS, tgt.EB_ORD=src.EB_ORD, tgt.EB_CRDN=src.EB_CRDN,
            tgt.EB_EXP=src.EB_EXP, tgt.EB_AUTH=src.EB_AUTH, tgt.EB_MER=src.EB_MER,
            tgt.EB_PROM=src.EB_PROM, tgt.EB_INVD=src.EB_INVD, tgt.EB_AGC=src.EB_AGC,
            tgt.EB_MAN=src.EB_MAN, tgt.EB_AAMT=src.EB_AAMT, tgt.EB_GLA=src.EB_GLA,
            tgt.EB_GLC=src.EB_GLC, tgt.EB_DTT=src.EB_DTT, tgt.EB_CUS=src.EB_CUS,
            tgt.EB_IAMT=src.EB_IAMT, tgt.EB_REF=src.EB_REF, tgt.EB_DC1=src.EB_DC1,
            tgt.EB_DC2=src.EB_DC2, tgt.EB_RQID=src.EB_RQID, tgt.EB_STID=src.EB_STID,
            tgt.EB_MRID=src.EB_MRID, tgt.EB_TMID=src.EB_TMID, tgt.EB_PDES=src.EB_PDES,
            tgt.UPDATE_IDENT=src.UPDATE_IDENT,
            tgt.LastSeenUtc = SYSUTCDATETIME(), tgt.LastRunId = @RunId
        WHEN NOT MATCHED BY TARGET THEN INSERT (
            EB_TID, EB_CO, EB_DIV, EB_BR, EB_SYS, EB_ORD, EB_CRDN, EB_EXP,
            EB_AUTH, EB_MER, EB_PROM, EB_INVD, EB_AGC, EB_MAN, EB_AAMT, EB_GLA,
            EB_GLC, EB_DTT, EB_CUS, EB_IAMT, EB_REF, EB_DC1, EB_DC2, EB_RQID,
            EB_STID, EB_MRID, EB_TMID, EB_PDES, UPDATE_IDENT,
            FirstSeenUtc, LastSeenUtc, LastRunId
        ) VALUES (
            src.EB_TID, src.EB_CO, src.EB_DIV, src.EB_BR, src.EB_SYS, src.EB_ORD, src.EB_CRDN, src.EB_EXP,
            src.EB_AUTH, src.EB_MER, src.EB_PROM, src.EB_INVD, src.EB_AGC, src.EB_MAN, src.EB_AAMT, src.EB_GLA,
            src.EB_GLC, src.EB_DTT, src.EB_CUS, src.EB_IAMT, src.EB_REF, src.EB_DC1, src.EB_DC2, src.EB_RQID,
            src.EB_STID, src.EB_MRID, src.EB_TMID, src.EB_PDES, src.UPDATE_IDENT,
            SYSUTCDATETIME(), SYSUTCDATETIME(), @RunId
        )
        OUTPUT $action INTO @MergeActions;

        SELECT @Inserted = SUM(CASE WHEN Action='INSERT' THEN 1 ELSE 0 END),
               @Updated  = SUM(CASE WHEN Action='UPDATE' THEN 1 ELSE 0 END)
        FROM @MergeActions;

        UPDATE dbo.AcctLoadControl
        SET RowsCopied=@RowsCopied, RowsInserted=ISNULL(@Inserted,0), RowsUpdated=ISNULL(@Updated,0)
        WHERE RunId = @RunId;
    END TRY
    BEGIN CATCH
        UPDATE dbo.AcctLoadControl
        SET Status='FAILED', EndedUtc=SYSUTCDATETIME(), ErrorMessage=ERROR_MESSAGE()
        WHERE RunId = @RunId;
        THROW;
    END CATCH
END
GO
