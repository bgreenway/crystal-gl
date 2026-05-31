-- ===========================================================================
-- 09_journal_line_snapshot.sql
--
-- Snapshot tables + capture procedures for the five journal-line sub-system
-- tables. Same sparse change-capture pattern as snap.GLCAL / snap.GLFIS in
-- sql/06_snapshot_schema.sql.
--
-- For each table, snapshot rows where LastSeenUtc moved between the prior
-- watermark and now. These captures are valuable for journal-line data
-- because they preserve:
--   - Late-posted adjustments to closed periods (when CGIHIST/YTDIST rows
--     get re-stated after first appearance)
--   - The historical view at any past date for audit / dispute resolution
--   - Drift in SUBLED entries that can post and then get re-coded
--
-- Volume note: PARTHIST is large (~2M rows growing); steady-state snapshots
-- should capture only the few rows that change per ETL cycle. If captures
-- get heavy, consider a date-window guard (capture only PH_DTR >= dateadd…).
-- The procs below do NOT impose such a guard yet — add one later if needed.
-- ===========================================================================

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ---------------------------------------------------------------------------
-- snap.CGIHIST
-- ---------------------------------------------------------------------------
CREATE TABLE snap.CGIHIST (
    SnapshotDate          DATE             NOT NULL,
    CH_CO                 NVARCHAR(2)      NOT NULL,
    CH_DIV                NVARCHAR(2)      NOT NULL,
    CH_ORD                NVARCHAR(10)     NOT NULL,
    CH_CGT                NVARCHAR(1)      NOT NULL,
    CH_CLS                NVARCHAR(1)      NOT NULL,
    CH_BDT                DECIMAL(8,0)     NOT NULL,
    CH_INV                NVARCHAR(6)      NOT NULL,
    CH_SEQ                DECIMAL(5,0)     NOT NULL,
    CH_CUS                NVARCHAR(10)     NULL,
    CH_FILA               NVARCHAR(25)     NULL,
    CH_AMT                DECIMAL(11,2)    NULL,
    CH_ACC                NVARCHAR(5)      NULL,
    CH_CC                 NVARCHAR(3)      NULL,
    CH_STA                NVARCHAR(1)      NULL,
    FILL1A                NVARCHAR(1)      NULL,
    CH_BR                 NVARCHAR(2)      NULL,
    CH_HRS                DECIMAL(7,0)     NULL,
    CH_UID                DECIMAL(18,0)    NULL,
    CH_SYS                NVARCHAR(3)      NULL,
    CH_TID                DECIMAL(18,0)    NULL,
    CH_NME                NVARCHAR(45)     NULL,
    UPDATE_IDENT          DECIMAL(7,0)     NULL,
    ChangeKind            CHAR(1)          NOT NULL,
    SourceFirstSeenUtc    DATETIME2(3)     NOT NULL,
    SourceLastSeenUtc     DATETIME2(3)     NOT NULL,
    SourceRunId           UNIQUEIDENTIFIER NULL,
    SnapshotCapturedUtc   DATETIME2(3)     NOT NULL CONSTRAINT DF_snap_CGIHIST_Captured DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_snap_CGIHIST PRIMARY KEY CLUSTERED
        (SnapshotDate, CH_CO, CH_DIV, CH_ORD, CH_CGT, CH_CLS, CH_BDT, CH_INV, CH_SEQ),
    CONSTRAINT CK_snap_CGIHIST_ChangeKind CHECK (ChangeKind IN ('I','U'))
);
GO

-- ---------------------------------------------------------------------------
-- snap.YTDIST
-- ---------------------------------------------------------------------------
CREATE TABLE snap.YTDIST (
    SnapshotDate          DATE             NOT NULL,
    DN_TID                DECIMAL(18,0)    NOT NULL,
    DN_SEQ                DECIMAL(5,0)     NOT NULL,
    DN_RID                NVARCHAR(1)      NULL,
    DN_CO                 NVARCHAR(2)      NULL,
    DN_VEN                NVARCHAR(6)      NULL,
    DN_DIV                NVARCHAR(2)      NULL,
    DN_TC                 NVARCHAR(3)      NULL,
    DN_VCH                NVARCHAR(6)      NULL,
    DN_NME                NVARCHAR(25)     NULL,
    DN_RR                 NVARCHAR(1)      NULL,
    DN_FILA               NVARCHAR(6)      NULL,
    DN_GRS                DECIMAL(11,2)    NULL,
    DN_ACC                NVARCHAR(5)      NULL,
    DN_DNU                NVARCHAR(5)      NULL,
    DN_CC                 NVARCHAR(3)      NULL,
    DN_FILB               NVARCHAR(6)      NULL,
    DN_CGC                NVARCHAR(1)      NULL,
    DN_CGT                NVARCHAR(1)      NULL,
    DN_STA                NVARCHAR(1)      NULL,
    DN_ORD                NVARCHAR(10)     NULL,
    DN_INV                NVARCHAR(15)     NULL,
    DNFILD                NVARCHAR(20)     NULL,
    DN_PO                 NVARCHAR(10)     NULL,
    DN_POBR               NVARCHAR(2)      NULL,
    DN_CER                DECIMAL(7,6)     NULL,
    DN_DTI                DECIMAL(8,0)     NULL,
    DN_DTD                DECIMAL(8,0)     NULL,
    DN_CUS                NVARCHAR(10)     NULL,
    DN_UID                DECIMAL(18,0)    NULL,
    DN_CHQ                NVARCHAR(7)      NULL,
    DN_HDES               NVARCHAR(40)     NULL,
    UPDATE_IDENT          DECIMAL(7,0)     NULL,
    ChangeKind            CHAR(1)          NOT NULL,
    SourceFirstSeenUtc    DATETIME2(3)     NOT NULL,
    SourceLastSeenUtc     DATETIME2(3)     NOT NULL,
    SourceRunId           UNIQUEIDENTIFIER NULL,
    SnapshotCapturedUtc   DATETIME2(3)     NOT NULL CONSTRAINT DF_snap_YTDIST_Captured DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_snap_YTDIST PRIMARY KEY CLUSTERED (SnapshotDate, DN_TID, DN_SEQ),
    CONSTRAINT CK_snap_YTDIST_ChangeKind CHECK (ChangeKind IN ('I','U'))
);
GO

-- ---------------------------------------------------------------------------
-- snap.SUBLED
-- ---------------------------------------------------------------------------
CREATE TABLE snap.SUBLED (
    SnapshotDate          DATE             NOT NULL,
    SL_CO                 NVARCHAR(2)      NOT NULL,
    SL_ACC                NVARCHAR(5)      NOT NULL,
    SL_CC                 NVARCHAR(3)      NOT NULL,
    SL_DIV                NVARCHAR(2)      NOT NULL,
    SL_SEQ                DECIMAL(6,0)     NOT NULL,
    SL_STA                NVARCHAR(1)      NULL,
    SL_CUS                NVARCHAR(10)     NULL,
    SL_FILB               NVARCHAR(6)      NULL,
    SL_DES                NVARCHAR(40)     NULL,
    SL_IA                 DECIMAL(11,2)    NULL,
    SL_RA                 DECIMAL(11,2)    NULL,
    SL_DTI                DECIMAL(8,0)     NULL,
    SL_DTR                DECIMAL(8,0)     NULL,
    SL_CRN                NVARCHAR(8)      NULL,
    SL_BL                 NVARCHAR(1)      NULL,
    SL_UID                DECIMAL(18,0)    NULL,
    SL_SYS                NVARCHAR(3)      NULL,
    SL_TID                DECIMAL(18,0)    NULL,
    SL_ORD                NVARCHAR(15)     NULL,
    SL_FILA               NVARCHAR(6)      NULL,
    SL_NME                NVARCHAR(45)     NULL,
    UPDATE_IDENT          DECIMAL(7,0)     NULL,
    ChangeKind            CHAR(1)          NOT NULL,
    SourceFirstSeenUtc    DATETIME2(3)     NOT NULL,
    SourceLastSeenUtc     DATETIME2(3)     NOT NULL,
    SourceRunId           UNIQUEIDENTIFIER NULL,
    SnapshotCapturedUtc   DATETIME2(3)     NOT NULL CONSTRAINT DF_snap_SUBLED_Captured DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_snap_SUBLED PRIMARY KEY CLUSTERED
        (SnapshotDate, SL_CO, SL_ACC, SL_CC, SL_DIV, SL_SEQ),
    CONSTRAINT CK_snap_SUBLED_ChangeKind CHECK (ChangeKind IN ('I','U'))
);
GO

-- ---------------------------------------------------------------------------
-- snap.PARTHIST  (large; consider date-window guard if captures get heavy)
-- ---------------------------------------------------------------------------
CREATE TABLE snap.PARTHIST (
    SnapshotDate          DATE             NOT NULL,
    PH_CO                 NVARCHAR(2)      NOT NULL,
    PH_PRT                NVARCHAR(30)     NOT NULL,
    PH_DIV                NVARCHAR(2)      NOT NULL,
    PH_BR                 NVARCHAR(2)      NOT NULL,
    PH_DTR                DECIMAL(8,0)     NOT NULL,
    PH_TMR                DECIMAL(6,0)     NOT NULL,
    PH_PO                 NVARCHAR(10)     NOT NULL,
    PH_SEQ                DECIMAL(7,0)     NOT NULL,
    PH_STA                NVARCHAR(1)      NULL,
    PH_TID                DECIMAL(18,0)    NULL,
    PH_UID                DECIMAL(18,0)    NULL,
    PH_QTR                DECIMAL(5,0)     NULL,
    PH_NET                DECIMAL(9,2)     NULL,
    PH_VEN                NVARCHAR(6)      NULL,
    PH_OST                NVARCHAR(1)      NULL,
    PH_PPK                DECIMAL(5,0)     NULL,
    PH_TYP                NVARCHAR(2)      NULL,
    PH_GLIC               NVARCHAR(3)      NULL,
    PH_GLIA               NVARCHAR(5)      NULL,
    PH_IAC                NVARCHAR(3)      NULL,
    PH_IAA                NVARCHAR(5)      NULL,
    PH_INV                NVARCHAR(6)      NULL,
    PH_QRE                DECIMAL(5,0)     NULL,
    PH_FIL1               NVARCHAR(9)      NULL,
    UPDATE_IDENT          DECIMAL(7,0)     NULL,
    ChangeKind            CHAR(1)          NOT NULL,
    SourceFirstSeenUtc    DATETIME2(3)     NOT NULL,
    SourceLastSeenUtc     DATETIME2(3)     NOT NULL,
    SourceRunId           UNIQUEIDENTIFIER NULL,
    SnapshotCapturedUtc   DATETIME2(3)     NOT NULL CONSTRAINT DF_snap_PARTHIST_Captured DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_snap_PARTHIST PRIMARY KEY CLUSTERED
        (SnapshotDate, PH_CO, PH_PRT, PH_DIV, PH_BR, PH_DTR, PH_TMR, PH_PO, PH_SEQ),
    CONSTRAINT CK_snap_PARTHIST_ChangeKind CHECK (ChangeKind IN ('I','U'))
);
GO

-- ---------------------------------------------------------------------------
-- snap.INVHCC
-- ---------------------------------------------------------------------------
CREATE TABLE snap.INVHCC (
    SnapshotDate          DATE             NOT NULL,
    EB_TID                DECIMAL(18,0)    NOT NULL,
    EB_CO                 NVARCHAR(2)      NULL,
    EB_DIV                NVARCHAR(2)      NULL,
    EB_BR                 NVARCHAR(2)      NULL,
    EB_SYS                NVARCHAR(3)      NULL,
    EB_ORD                NVARCHAR(10)     NULL,
    EB_CRDN               NVARCHAR(25)     NULL,
    EB_EXP                DECIMAL(6,0)     NULL,
    EB_AUTH               NVARCHAR(11)     NULL,
    EB_MER                NVARCHAR(20)     NULL,
    EB_PROM               NVARCHAR(4)      NULL,
    EB_INVD               NVARCHAR(1)      NULL,
    EB_AGC                NVARCHAR(1)      NULL,
    EB_MAN                NVARCHAR(1)      NULL,
    EB_AAMT               DECIMAL(11,2)    NULL,
    EB_GLA                NVARCHAR(5)      NULL,
    EB_GLC                NVARCHAR(3)      NULL,
    EB_DTT                DECIMAL(8,0)     NULL,
    EB_CUS                NVARCHAR(10)     NULL,
    EB_IAMT               DECIMAL(11,2)    NULL,
    EB_REF                NVARCHAR(10)     NULL,
    EB_DC1                DECIMAL(6,0)     NULL,
    EB_DC2                DECIMAL(6,0)     NULL,
    EB_RQID               NVARCHAR(50)     NULL,
    EB_STID               NVARCHAR(64)     NULL,
    EB_MRID               NVARCHAR(64)     NULL,
    EB_TMID               NVARCHAR(64)     NULL,
    EB_PDES               NVARCHAR(100)    NULL,
    UPDATE_IDENT          DECIMAL(7,0)     NULL,
    ChangeKind            CHAR(1)          NOT NULL,
    SourceFirstSeenUtc    DATETIME2(3)     NOT NULL,
    SourceLastSeenUtc     DATETIME2(3)     NOT NULL,
    SourceRunId           UNIQUEIDENTIFIER NULL,
    SnapshotCapturedUtc   DATETIME2(3)     NOT NULL CONSTRAINT DF_snap_INVHCC_Captured DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_snap_INVHCC PRIMARY KEY CLUSTERED (SnapshotDate, EB_TID),
    CONSTRAINT CK_snap_INVHCC_ChangeKind CHECK (ChangeKind IN ('I','U'))
);
GO

-- ===========================================================================
-- Snapshot procedures — one per table, all following the sp_Acct_Snapshot_GLCAL
-- watermark-driven pattern. Each:
--   1. Reads LastCapturedThroughUtc from dbo.AcctSnapshotControl.
--   2. Sets NewHighWaterUtc = now.
--   3. Finds rows in dbo.<T> where LastSeenUtc > prior AND <= new high water.
--   4. MERGEs into snap.<T> keyed by (SnapshotDate, PK). Same-day collisions
--      update; ChangeKind = 'I' if FirstSeenUtc > prior, else 'U'.
--   5. Advances watermark + writes LastRowsCaptured.
-- SnapshotDate is Eastern Time today, matching sp_Acct_Snapshot_GLCAL.
-- ===========================================================================

CREATE OR ALTER PROCEDURE dbo.sp_Acct_Snapshot_CGIHIST
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @LastCapturedThroughUtc DATETIME2(3);
    DECLARE @NewHighWaterUtc        DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @SnapshotDate           DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Eastern Standard Time' AS DATE);

    SELECT @LastCapturedThroughUtc = LastCapturedThroughUtc
    FROM dbo.AcctSnapshotControl WHERE TableName = 'CGIHIST';

    IF @LastCapturedThroughUtc IS NULL
        THROW 50030, 'sp_Acct_Snapshot_CGIHIST: AcctSnapshotControl row for CGIHIST missing; run sql/10_acctcontrol_seed.sql', 1;

    BEGIN TRY
        BEGIN TRAN;
        ;WITH chg AS (
            SELECT d.*, ChangeKind = CASE WHEN d.FirstSeenUtc > @LastCapturedThroughUtc THEN 'I' ELSE 'U' END
            FROM dbo.CGIHIST d
            WHERE d.LastSeenUtc > @LastCapturedThroughUtc AND d.LastSeenUtc <= @NewHighWaterUtc
        )
        MERGE snap.CGIHIST AS tgt
        USING chg AS src ON tgt.SnapshotDate=@SnapshotDate
            AND tgt.CH_CO=src.CH_CO AND tgt.CH_DIV=src.CH_DIV
            AND tgt.CH_ORD=src.CH_ORD AND tgt.CH_CGT=src.CH_CGT
            AND tgt.CH_CLS=src.CH_CLS AND tgt.CH_BDT=src.CH_BDT
            AND tgt.CH_INV=src.CH_INV AND tgt.CH_SEQ=src.CH_SEQ
        WHEN MATCHED THEN UPDATE SET
            tgt.CH_CUS=src.CH_CUS, tgt.CH_FILA=src.CH_FILA, tgt.CH_AMT=src.CH_AMT,
            tgt.CH_ACC=src.CH_ACC, tgt.CH_CC=src.CH_CC, tgt.CH_STA=src.CH_STA,
            tgt.FILL1A=src.FILL1A, tgt.CH_BR=src.CH_BR, tgt.CH_HRS=src.CH_HRS,
            tgt.CH_UID=src.CH_UID, tgt.CH_SYS=src.CH_SYS, tgt.CH_TID=src.CH_TID,
            tgt.CH_NME=src.CH_NME, tgt.UPDATE_IDENT=src.UPDATE_IDENT,
            tgt.ChangeKind=src.ChangeKind,
            tgt.SourceFirstSeenUtc=src.FirstSeenUtc, tgt.SourceLastSeenUtc=src.LastSeenUtc,
            tgt.SourceRunId=src.LastRunId, tgt.SnapshotCapturedUtc=SYSUTCDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT (
            SnapshotDate, CH_CO, CH_DIV, CH_ORD, CH_CGT, CH_CLS, CH_BDT, CH_INV, CH_SEQ,
            CH_CUS, CH_FILA, CH_AMT, CH_ACC, CH_CC, CH_STA, FILL1A, CH_BR, CH_HRS,
            CH_UID, CH_SYS, CH_TID, CH_NME, UPDATE_IDENT,
            ChangeKind, SourceFirstSeenUtc, SourceLastSeenUtc, SourceRunId
        ) VALUES (
            @SnapshotDate, src.CH_CO, src.CH_DIV, src.CH_ORD, src.CH_CGT, src.CH_CLS, src.CH_BDT, src.CH_INV, src.CH_SEQ,
            src.CH_CUS, src.CH_FILA, src.CH_AMT, src.CH_ACC, src.CH_CC, src.CH_STA, src.FILL1A, src.CH_BR, src.CH_HRS,
            src.CH_UID, src.CH_SYS, src.CH_TID, src.CH_NME, src.UPDATE_IDENT,
            src.ChangeKind, src.FirstSeenUtc, src.LastSeenUtc, src.LastRunId
        );

        DECLARE @Captured INT = @@ROWCOUNT;
        UPDATE dbo.AcctSnapshotControl
        SET LastCapturedThroughUtc=@NewHighWaterUtc, LastSnapshotRunUtc=SYSUTCDATETIME(), LastRowsCaptured=@Captured
        WHERE TableName='CGIHIST';
        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_Acct_Snapshot_YTDIST
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @LastCapturedThroughUtc DATETIME2(3);
    DECLARE @NewHighWaterUtc        DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @SnapshotDate           DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Eastern Standard Time' AS DATE);

    SELECT @LastCapturedThroughUtc = LastCapturedThroughUtc
    FROM dbo.AcctSnapshotControl WHERE TableName = 'YTDIST';

    IF @LastCapturedThroughUtc IS NULL
        THROW 50031, 'sp_Acct_Snapshot_YTDIST: AcctSnapshotControl row for YTDIST missing; run sql/10_acctcontrol_seed.sql', 1;

    BEGIN TRY
        BEGIN TRAN;
        ;WITH chg AS (
            SELECT d.*, ChangeKind = CASE WHEN d.FirstSeenUtc > @LastCapturedThroughUtc THEN 'I' ELSE 'U' END
            FROM dbo.YTDIST d
            WHERE d.LastSeenUtc > @LastCapturedThroughUtc AND d.LastSeenUtc <= @NewHighWaterUtc
        )
        MERGE snap.YTDIST AS tgt
        USING chg AS src ON tgt.SnapshotDate=@SnapshotDate
            AND tgt.DN_TID=src.DN_TID AND tgt.DN_SEQ=src.DN_SEQ
        WHEN MATCHED THEN UPDATE SET
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
            tgt.ChangeKind=src.ChangeKind,
            tgt.SourceFirstSeenUtc=src.FirstSeenUtc, tgt.SourceLastSeenUtc=src.LastSeenUtc,
            tgt.SourceRunId=src.LastRunId, tgt.SnapshotCapturedUtc=SYSUTCDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT (
            SnapshotDate, DN_TID, DN_SEQ, DN_RID, DN_CO, DN_VEN, DN_DIV, DN_TC,
            DN_VCH, DN_NME, DN_RR, DN_FILA, DN_GRS, DN_ACC, DN_DNU, DN_CC,
            DN_FILB, DN_CGC, DN_CGT, DN_STA, DN_ORD, DN_INV, DNFILD, DN_PO,
            DN_POBR, DN_CER, DN_DTI, DN_DTD, DN_CUS, DN_UID, DN_CHQ, DN_HDES,
            UPDATE_IDENT, ChangeKind, SourceFirstSeenUtc, SourceLastSeenUtc, SourceRunId
        ) VALUES (
            @SnapshotDate, src.DN_TID, src.DN_SEQ, src.DN_RID, src.DN_CO, src.DN_VEN, src.DN_DIV, src.DN_TC,
            src.DN_VCH, src.DN_NME, src.DN_RR, src.DN_FILA, src.DN_GRS, src.DN_ACC, src.DN_DNU, src.DN_CC,
            src.DN_FILB, src.DN_CGC, src.DN_CGT, src.DN_STA, src.DN_ORD, src.DN_INV, src.DNFILD, src.DN_PO,
            src.DN_POBR, src.DN_CER, src.DN_DTI, src.DN_DTD, src.DN_CUS, src.DN_UID, src.DN_CHQ, src.DN_HDES,
            src.UPDATE_IDENT, src.ChangeKind, src.FirstSeenUtc, src.LastSeenUtc, src.LastRunId
        );

        DECLARE @Captured INT = @@ROWCOUNT;
        UPDATE dbo.AcctSnapshotControl
        SET LastCapturedThroughUtc=@NewHighWaterUtc, LastSnapshotRunUtc=SYSUTCDATETIME(), LastRowsCaptured=@Captured
        WHERE TableName='YTDIST';
        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_Acct_Snapshot_SUBLED
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @LastCapturedThroughUtc DATETIME2(3);
    DECLARE @NewHighWaterUtc        DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @SnapshotDate           DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Eastern Standard Time' AS DATE);

    SELECT @LastCapturedThroughUtc = LastCapturedThroughUtc
    FROM dbo.AcctSnapshotControl WHERE TableName = 'SUBLED';

    IF @LastCapturedThroughUtc IS NULL
        THROW 50032, 'sp_Acct_Snapshot_SUBLED: AcctSnapshotControl row for SUBLED missing; run sql/10_acctcontrol_seed.sql', 1;

    BEGIN TRY
        BEGIN TRAN;
        ;WITH chg AS (
            SELECT d.*, ChangeKind = CASE WHEN d.FirstSeenUtc > @LastCapturedThroughUtc THEN 'I' ELSE 'U' END
            FROM dbo.SUBLED d
            WHERE d.LastSeenUtc > @LastCapturedThroughUtc AND d.LastSeenUtc <= @NewHighWaterUtc
        )
        MERGE snap.SUBLED AS tgt
        USING chg AS src ON tgt.SnapshotDate=@SnapshotDate
            AND tgt.SL_CO=src.SL_CO AND tgt.SL_ACC=src.SL_ACC
            AND tgt.SL_CC=src.SL_CC AND tgt.SL_DIV=src.SL_DIV
            AND tgt.SL_SEQ=src.SL_SEQ
        WHEN MATCHED THEN UPDATE SET
            tgt.SL_STA=src.SL_STA, tgt.SL_CUS=src.SL_CUS, tgt.SL_FILB=src.SL_FILB,
            tgt.SL_DES=src.SL_DES, tgt.SL_IA=src.SL_IA, tgt.SL_RA=src.SL_RA,
            tgt.SL_DTI=src.SL_DTI, tgt.SL_DTR=src.SL_DTR, tgt.SL_CRN=src.SL_CRN,
            tgt.SL_BL=src.SL_BL, tgt.SL_UID=src.SL_UID, tgt.SL_SYS=src.SL_SYS,
            tgt.SL_TID=src.SL_TID, tgt.SL_ORD=src.SL_ORD, tgt.SL_FILA=src.SL_FILA,
            tgt.SL_NME=src.SL_NME, tgt.UPDATE_IDENT=src.UPDATE_IDENT,
            tgt.ChangeKind=src.ChangeKind,
            tgt.SourceFirstSeenUtc=src.FirstSeenUtc, tgt.SourceLastSeenUtc=src.LastSeenUtc,
            tgt.SourceRunId=src.LastRunId, tgt.SnapshotCapturedUtc=SYSUTCDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT (
            SnapshotDate, SL_CO, SL_ACC, SL_CC, SL_DIV, SL_SEQ, SL_STA, SL_CUS, SL_FILB,
            SL_DES, SL_IA, SL_RA, SL_DTI, SL_DTR, SL_CRN, SL_BL, SL_UID, SL_SYS,
            SL_TID, SL_ORD, SL_FILA, SL_NME, UPDATE_IDENT,
            ChangeKind, SourceFirstSeenUtc, SourceLastSeenUtc, SourceRunId
        ) VALUES (
            @SnapshotDate, src.SL_CO, src.SL_ACC, src.SL_CC, src.SL_DIV, src.SL_SEQ, src.SL_STA, src.SL_CUS, src.SL_FILB,
            src.SL_DES, src.SL_IA, src.SL_RA, src.SL_DTI, src.SL_DTR, src.SL_CRN, src.SL_BL, src.SL_UID, src.SL_SYS,
            src.SL_TID, src.SL_ORD, src.SL_FILA, src.SL_NME, src.UPDATE_IDENT,
            src.ChangeKind, src.FirstSeenUtc, src.LastSeenUtc, src.LastRunId
        );

        DECLARE @Captured INT = @@ROWCOUNT;
        UPDATE dbo.AcctSnapshotControl
        SET LastCapturedThroughUtc=@NewHighWaterUtc, LastSnapshotRunUtc=SYSUTCDATETIME(), LastRowsCaptured=@Captured
        WHERE TableName='SUBLED';
        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_Acct_Snapshot_PARTHIST
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @LastCapturedThroughUtc DATETIME2(3);
    DECLARE @NewHighWaterUtc        DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @SnapshotDate           DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Eastern Standard Time' AS DATE);

    SELECT @LastCapturedThroughUtc = LastCapturedThroughUtc
    FROM dbo.AcctSnapshotControl WHERE TableName = 'PARTHIST';

    IF @LastCapturedThroughUtc IS NULL
        THROW 50033, 'sp_Acct_Snapshot_PARTHIST: AcctSnapshotControl row for PARTHIST missing; run sql/10_acctcontrol_seed.sql', 1;

    BEGIN TRY
        BEGIN TRAN;
        ;WITH chg AS (
            SELECT d.*, ChangeKind = CASE WHEN d.FirstSeenUtc > @LastCapturedThroughUtc THEN 'I' ELSE 'U' END
            FROM dbo.PARTHIST d
            WHERE d.LastSeenUtc > @LastCapturedThroughUtc AND d.LastSeenUtc <= @NewHighWaterUtc
        )
        MERGE snap.PARTHIST AS tgt
        USING chg AS src ON tgt.SnapshotDate=@SnapshotDate
            AND tgt.PH_CO=src.PH_CO AND tgt.PH_PRT=src.PH_PRT
            AND tgt.PH_DIV=src.PH_DIV AND tgt.PH_BR=src.PH_BR
            AND tgt.PH_DTR=src.PH_DTR AND tgt.PH_TMR=src.PH_TMR
            AND tgt.PH_PO=src.PH_PO AND tgt.PH_SEQ=src.PH_SEQ
        WHEN MATCHED THEN UPDATE SET
            tgt.PH_STA=src.PH_STA, tgt.PH_TID=src.PH_TID, tgt.PH_UID=src.PH_UID,
            tgt.PH_QTR=src.PH_QTR, tgt.PH_NET=src.PH_NET, tgt.PH_VEN=src.PH_VEN,
            tgt.PH_OST=src.PH_OST, tgt.PH_PPK=src.PH_PPK, tgt.PH_TYP=src.PH_TYP,
            tgt.PH_GLIC=src.PH_GLIC, tgt.PH_GLIA=src.PH_GLIA, tgt.PH_IAC=src.PH_IAC,
            tgt.PH_IAA=src.PH_IAA, tgt.PH_INV=src.PH_INV, tgt.PH_QRE=src.PH_QRE,
            tgt.PH_FIL1=src.PH_FIL1, tgt.UPDATE_IDENT=src.UPDATE_IDENT,
            tgt.ChangeKind=src.ChangeKind,
            tgt.SourceFirstSeenUtc=src.FirstSeenUtc, tgt.SourceLastSeenUtc=src.LastSeenUtc,
            tgt.SourceRunId=src.LastRunId, tgt.SnapshotCapturedUtc=SYSUTCDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT (
            SnapshotDate, PH_CO, PH_PRT, PH_DIV, PH_BR, PH_DTR, PH_TMR, PH_PO, PH_SEQ,
            PH_STA, PH_TID, PH_UID, PH_QTR, PH_NET, PH_VEN, PH_OST, PH_PPK, PH_TYP,
            PH_GLIC, PH_GLIA, PH_IAC, PH_IAA, PH_INV, PH_QRE, PH_FIL1, UPDATE_IDENT,
            ChangeKind, SourceFirstSeenUtc, SourceLastSeenUtc, SourceRunId
        ) VALUES (
            @SnapshotDate, src.PH_CO, src.PH_PRT, src.PH_DIV, src.PH_BR, src.PH_DTR, src.PH_TMR, src.PH_PO, src.PH_SEQ,
            src.PH_STA, src.PH_TID, src.PH_UID, src.PH_QTR, src.PH_NET, src.PH_VEN, src.PH_OST, src.PH_PPK, src.PH_TYP,
            src.PH_GLIC, src.PH_GLIA, src.PH_IAC, src.PH_IAA, src.PH_INV, src.PH_QRE, src.PH_FIL1, src.UPDATE_IDENT,
            src.ChangeKind, src.FirstSeenUtc, src.LastSeenUtc, src.LastRunId
        );

        DECLARE @Captured INT = @@ROWCOUNT;
        UPDATE dbo.AcctSnapshotControl
        SET LastCapturedThroughUtc=@NewHighWaterUtc, LastSnapshotRunUtc=SYSUTCDATETIME(), LastRowsCaptured=@Captured
        WHERE TableName='PARTHIST';
        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_Acct_Snapshot_INVHCC
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @LastCapturedThroughUtc DATETIME2(3);
    DECLARE @NewHighWaterUtc        DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @SnapshotDate           DATE = CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'Eastern Standard Time' AS DATE);

    SELECT @LastCapturedThroughUtc = LastCapturedThroughUtc
    FROM dbo.AcctSnapshotControl WHERE TableName = 'INVHCC';

    IF @LastCapturedThroughUtc IS NULL
        THROW 50034, 'sp_Acct_Snapshot_INVHCC: AcctSnapshotControl row for INVHCC missing; run sql/10_acctcontrol_seed.sql', 1;

    BEGIN TRY
        BEGIN TRAN;
        ;WITH chg AS (
            SELECT d.*, ChangeKind = CASE WHEN d.FirstSeenUtc > @LastCapturedThroughUtc THEN 'I' ELSE 'U' END
            FROM dbo.INVHCC d
            WHERE d.LastSeenUtc > @LastCapturedThroughUtc AND d.LastSeenUtc <= @NewHighWaterUtc
        )
        MERGE snap.INVHCC AS tgt
        USING chg AS src ON tgt.SnapshotDate=@SnapshotDate AND tgt.EB_TID=src.EB_TID
        WHEN MATCHED THEN UPDATE SET
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
            tgt.ChangeKind=src.ChangeKind,
            tgt.SourceFirstSeenUtc=src.FirstSeenUtc, tgt.SourceLastSeenUtc=src.LastSeenUtc,
            tgt.SourceRunId=src.LastRunId, tgt.SnapshotCapturedUtc=SYSUTCDATETIME()
        WHEN NOT MATCHED BY TARGET THEN INSERT (
            SnapshotDate, EB_TID, EB_CO, EB_DIV, EB_BR, EB_SYS, EB_ORD, EB_CRDN, EB_EXP,
            EB_AUTH, EB_MER, EB_PROM, EB_INVD, EB_AGC, EB_MAN, EB_AAMT, EB_GLA,
            EB_GLC, EB_DTT, EB_CUS, EB_IAMT, EB_REF, EB_DC1, EB_DC2, EB_RQID,
            EB_STID, EB_MRID, EB_TMID, EB_PDES, UPDATE_IDENT,
            ChangeKind, SourceFirstSeenUtc, SourceLastSeenUtc, SourceRunId
        ) VALUES (
            @SnapshotDate, src.EB_TID, src.EB_CO, src.EB_DIV, src.EB_BR, src.EB_SYS, src.EB_ORD, src.EB_CRDN, src.EB_EXP,
            src.EB_AUTH, src.EB_MER, src.EB_PROM, src.EB_INVD, src.EB_AGC, src.EB_MAN, src.EB_AAMT, src.EB_GLA,
            src.EB_GLC, src.EB_DTT, src.EB_CUS, src.EB_IAMT, src.EB_REF, src.EB_DC1, src.EB_DC2, src.EB_RQID,
            src.EB_STID, src.EB_MRID, src.EB_TMID, src.EB_PDES, src.UPDATE_IDENT,
            src.ChangeKind, src.FirstSeenUtc, src.LastSeenUtc, src.LastRunId
        );

        DECLARE @Captured INT = @@ROWCOUNT;
        UPDATE dbo.AcctSnapshotControl
        SET LastCapturedThroughUtc=@NewHighWaterUtc, LastSnapshotRunUtc=SYSUTCDATETIME(), LastRowsCaptured=@Captured
        WHERE TableName='INVHCC';
        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH
END
GO
