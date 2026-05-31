-- ===========================================================================
-- 07_journal_line_schema.sql
--
-- Adds five Intellidealer sub-system history tables to the acctdata replica.
-- Together these carry the journal-line GL detail that the existing five
-- summary tables (ACCMAST/COACMAST/DEPTMAST/GLCAL/GLFIS) aggregate. Replicating
-- them unlocks: monthly-grain reporting inside unclosed periods, branch /
-- dept / brand decomposition of unclosed activity, JE-level audit trail,
-- unusual-JE detection, per-SKU parts margin (PARTHIST), per-customer A/R
-- history.
--
-- See docs/journal-line-etl-spec.md for the full spec, the rationale, and
-- the verification work (2026-05-29) that identified these five.
--
-- Tables added (in dbo + stg + snap parallels):
--   CGIHIST    Customer/Order GL distribution        (~536K rows on IDR1)
--   YTDIST     Vendor invoice distribution           (~1.07M rows on IDR1)
--   SUBLED     Sub-ledger / manual journal entries   (~6K rows on IDR1)
--   PARTHIST   Parts transactions (inventory GL)     (~1.87M rows on IDR1)
--   INVHCC     Invoice headers by cost center        (~137K rows on IDR1)
--
-- Pattern follows the existing five tables (sql/01_schema.sql):
--   dbo.<T>: source columns + FirstSeenUtc, LastSeenUtc, LastRunId
--   stg.<T>: source columns + LoadRunId, LoadedAt
--   PKs match source-side PKs from IBM i (verified against IDR1).
-- ===========================================================================

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ---------------------------------------------------------------------------
-- dbo.CGIHIST — Customer/Order GL distribution
-- Source PK: (CH_CO, CH_DIV, CH_ORD, CH_CGT, CH_CLS, CH_BDT, CH_INV, CH_SEQ)
-- ---------------------------------------------------------------------------
CREATE TABLE dbo.CGIHIST (
    CH_CO         NVARCHAR(2)    NOT NULL,
    CH_DIV        NVARCHAR(2)    NOT NULL,
    CH_ORD        NVARCHAR(10)   NOT NULL,
    CH_CGT        NVARCHAR(1)    NOT NULL,
    CH_CLS        NVARCHAR(1)    NOT NULL,
    CH_BDT        DECIMAL(8,0)   NOT NULL,   -- Posting date, YYYYMMDD
    CH_INV        NVARCHAR(6)    NOT NULL,
    CH_SEQ        DECIMAL(5,0)   NOT NULL,
    CH_CUS        NVARCHAR(10)   NULL,
    CH_FILA       NVARCHAR(25)   NULL,
    CH_AMT        DECIMAL(11,2)  NULL,        -- GL distribution amount
    CH_ACC        NVARCHAR(5)    NULL,        -- GL account
    CH_CC         NVARCHAR(3)    NULL,        -- Cost center
    CH_STA        NVARCHAR(1)    NULL,
    FILL1A        NVARCHAR(1)    NULL,
    CH_BR         NVARCHAR(2)    NULL,        -- Branch
    CH_HRS        DECIMAL(7,0)   NULL,
    CH_UID        DECIMAL(18,0)  NULL,        -- IBM i unique posting id
    CH_SYS        NVARCHAR(3)    NULL,        -- Source system code
    CH_TID        DECIMAL(18,0)  NULL,        -- Transaction id
    CH_NME        NVARCHAR(45)   NULL,
    UPDATE_IDENT  DECIMAL(7,0)   NULL,
    FirstSeenUtc  DATETIME2(3)   NOT NULL CONSTRAINT DF_CGIHIST_FirstSeenUtc DEFAULT SYSUTCDATETIME(),
    LastSeenUtc   DATETIME2(3)   NOT NULL CONSTRAINT DF_CGIHIST_LastSeenUtc  DEFAULT SYSUTCDATETIME(),
    LastRunId     UNIQUEIDENTIFIER NULL,
    CONSTRAINT PK_CGIHIST PRIMARY KEY CLUSTERED
        (CH_CO, CH_DIV, CH_ORD, CH_CGT, CH_CLS, CH_BDT, CH_INV, CH_SEQ)
);
CREATE INDEX IX_CGIHIST_LastSeen   ON dbo.CGIHIST(LastSeenUtc);
CREATE INDEX IX_CGIHIST_AcctDate   ON dbo.CGIHIST(CH_CO, CH_ACC, CH_BDT)
    INCLUDE (CH_DIV, CH_CC, CH_AMT);
GO

-- ---------------------------------------------------------------------------
-- dbo.YTDIST — Vendor invoice GL distribution (A/P side)
-- Source PK: (DN_TID, DN_SEQ)
-- ---------------------------------------------------------------------------
CREATE TABLE dbo.YTDIST (
    DN_TID        DECIMAL(18,0)  NOT NULL,    -- Transaction id (PK)
    DN_SEQ        DECIMAL(5,0)   NOT NULL,    -- Sequence within transaction
    DN_RID        NVARCHAR(1)    NULL,
    DN_CO         NVARCHAR(2)    NULL,
    DN_VEN        NVARCHAR(6)    NULL,        -- Vendor code
    DN_DIV        NVARCHAR(2)    NULL,
    DN_TC         NVARCHAR(3)    NULL,
    DN_VCH        NVARCHAR(6)    NULL,        -- Voucher number
    DN_NME        NVARCHAR(25)   NULL,        -- Vendor name
    DN_RR         NVARCHAR(1)    NULL,
    DN_FILA       NVARCHAR(6)    NULL,
    DN_GRS        DECIMAL(11,2)  NULL,        -- Gross amount
    DN_ACC        NVARCHAR(5)    NULL,        -- GL account
    DN_DNU        NVARCHAR(5)    NULL,
    DN_CC         NVARCHAR(3)    NULL,        -- Cost center
    DN_FILB       NVARCHAR(6)    NULL,
    DN_CGC        NVARCHAR(1)    NULL,
    DN_CGT        NVARCHAR(1)    NULL,
    DN_STA        NVARCHAR(1)    NULL,
    DN_ORD        NVARCHAR(10)   NULL,
    DN_INV        NVARCHAR(15)   NULL,        -- Invoice number
    DNFILD        NVARCHAR(20)   NULL,
    DN_PO         NVARCHAR(10)   NULL,        -- PO number
    DN_POBR       NVARCHAR(2)    NULL,
    DN_CER        DECIMAL(7,6)   NULL,
    DN_DTI        DECIMAL(8,0)   NULL,        -- Invoice date, YYYYMMDD
    DN_DTD        DECIMAL(8,0)   NULL,        -- Due date, YYYYMMDD
    DN_CUS        NVARCHAR(10)   NULL,
    DN_UID        DECIMAL(18,0)  NULL,
    DN_CHQ        NVARCHAR(7)    NULL,        -- Check number
    DN_HDES       NVARCHAR(40)   NULL,
    UPDATE_IDENT  DECIMAL(7,0)   NULL,
    FirstSeenUtc  DATETIME2(3)   NOT NULL CONSTRAINT DF_YTDIST_FirstSeenUtc DEFAULT SYSUTCDATETIME(),
    LastSeenUtc   DATETIME2(3)   NOT NULL CONSTRAINT DF_YTDIST_LastSeenUtc  DEFAULT SYSUTCDATETIME(),
    LastRunId     UNIQUEIDENTIFIER NULL,
    CONSTRAINT PK_YTDIST PRIMARY KEY CLUSTERED (DN_TID, DN_SEQ)
);
CREATE INDEX IX_YTDIST_LastSeen ON dbo.YTDIST(LastSeenUtc);
CREATE INDEX IX_YTDIST_AcctDate ON dbo.YTDIST(DN_CO, DN_ACC, DN_DTI)
    INCLUDE (DN_DIV, DN_CC, DN_GRS);
CREATE INDEX IX_YTDIST_Vendor   ON dbo.YTDIST(DN_VEN, DN_DTI);
GO

-- ---------------------------------------------------------------------------
-- dbo.SUBLED — Sub-ledger / manual journal entries
-- Source PK: (SL_CO, SL_ACC, SL_CC, SL_DIV, SL_SEQ)
-- ---------------------------------------------------------------------------
CREATE TABLE dbo.SUBLED (
    SL_CO         NVARCHAR(2)    NOT NULL,
    SL_ACC        NVARCHAR(5)    NOT NULL,    -- GL account
    SL_CC         NVARCHAR(3)    NOT NULL,    -- Cost center
    SL_DIV        NVARCHAR(2)    NOT NULL,
    SL_SEQ        DECIMAL(6,0)   NOT NULL,    -- Sequence within (Co,Acc,CC,Div)
    SL_STA        NVARCHAR(1)    NULL,
    SL_CUS        NVARCHAR(10)   NULL,
    SL_FILB       NVARCHAR(6)    NULL,
    SL_DES        NVARCHAR(40)   NULL,        -- Description / memo
    SL_IA         DECIMAL(11,2)  NULL,        -- Invoice amount
    SL_RA         DECIMAL(11,2)  NULL,        -- Remaining amount
    SL_DTI        DECIMAL(8,0)   NULL,        -- Transaction date, YYYYMMDD
    SL_DTR        DECIMAL(8,0)   NULL,        -- Reference date, YYYYMMDD
    SL_CRN        NVARCHAR(8)    NULL,
    SL_BL         NVARCHAR(1)    NULL,
    SL_UID        DECIMAL(18,0)  NULL,
    SL_SYS        NVARCHAR(3)    NULL,        -- Source system code (002, 005=WO, 012=BankRec, etc.)
    SL_TID        DECIMAL(18,0)  NULL,
    SL_ORD        NVARCHAR(15)   NULL,        -- Order / batch reference
    SL_FILA       NVARCHAR(6)    NULL,
    SL_NME        NVARCHAR(45)   NULL,        -- Customer / counterparty name
    UPDATE_IDENT  DECIMAL(7,0)   NULL,
    FirstSeenUtc  DATETIME2(3)   NOT NULL CONSTRAINT DF_SUBLED_FirstSeenUtc DEFAULT SYSUTCDATETIME(),
    LastSeenUtc   DATETIME2(3)   NOT NULL CONSTRAINT DF_SUBLED_LastSeenUtc  DEFAULT SYSUTCDATETIME(),
    LastRunId     UNIQUEIDENTIFIER NULL,
    CONSTRAINT PK_SUBLED PRIMARY KEY CLUSTERED (SL_CO, SL_ACC, SL_CC, SL_DIV, SL_SEQ)
);
CREATE INDEX IX_SUBLED_LastSeen ON dbo.SUBLED(LastSeenUtc);
CREATE INDEX IX_SUBLED_Date     ON dbo.SUBLED(SL_DTI) INCLUDE (SL_CO, SL_ACC, SL_CC, SL_IA);
CREATE INDEX IX_SUBLED_Sys      ON dbo.SUBLED(SL_SYS, SL_DTI);
GO

-- ---------------------------------------------------------------------------
-- dbo.PARTHIST — Parts inventory transactions
-- Source PK: (PH_CO, PH_PRT, PH_DIV, PH_BR, PH_DTR, PH_TMR, PH_PO, PH_SEQ)
-- ---------------------------------------------------------------------------
CREATE TABLE dbo.PARTHIST (
    PH_CO         NVARCHAR(2)    NOT NULL,
    PH_PRT        NVARCHAR(30)   NOT NULL,    -- Part number
    PH_DIV        NVARCHAR(2)    NOT NULL,
    PH_BR         NVARCHAR(2)    NOT NULL,    -- Branch
    PH_DTR        DECIMAL(8,0)   NOT NULL,    -- Transaction date, YYYYMMDD
    PH_TMR        DECIMAL(6,0)   NOT NULL,    -- Transaction time, HHMMSS
    PH_PO         NVARCHAR(10)   NOT NULL,    -- PO / reference number
    PH_SEQ        DECIMAL(7,0)   NOT NULL,    -- Sequence
    PH_STA        NVARCHAR(1)    NULL,
    PH_TID        DECIMAL(18,0)  NULL,
    PH_UID        DECIMAL(18,0)  NULL,
    PH_QTR        DECIMAL(5,0)   NULL,        -- Quantity
    PH_NET        DECIMAL(9,2)   NULL,        -- Net amount
    PH_VEN        NVARCHAR(6)    NULL,
    PH_OST        NVARCHAR(1)    NULL,
    PH_PPK        DECIMAL(5,0)   NULL,
    PH_TYP        NVARCHAR(2)    NULL,        -- Transaction type
    PH_GLIC       NVARCHAR(3)    NULL,        -- Inventory GL cost center
    PH_GLIA       NVARCHAR(5)    NULL,        -- Inventory GL account
    PH_IAC        NVARCHAR(3)    NULL,        -- Inventory accrual cost center
    PH_IAA        NVARCHAR(5)    NULL,        -- Inventory accrual account
    PH_INV        NVARCHAR(6)    NULL,
    PH_QRE        DECIMAL(5,0)   NULL,
    PH_FIL1       NVARCHAR(9)    NULL,
    UPDATE_IDENT  DECIMAL(7,0)   NULL,
    FirstSeenUtc  DATETIME2(3)   NOT NULL CONSTRAINT DF_PARTHIST_FirstSeenUtc DEFAULT SYSUTCDATETIME(),
    LastSeenUtc   DATETIME2(3)   NOT NULL CONSTRAINT DF_PARTHIST_LastSeenUtc  DEFAULT SYSUTCDATETIME(),
    LastRunId     UNIQUEIDENTIFIER NULL,
    CONSTRAINT PK_PARTHIST PRIMARY KEY CLUSTERED
        (PH_CO, PH_PRT, PH_DIV, PH_BR, PH_DTR, PH_TMR, PH_PO, PH_SEQ)
);
CREATE INDEX IX_PARTHIST_LastSeen ON dbo.PARTHIST(LastSeenUtc);
CREATE INDEX IX_PARTHIST_GLAcct   ON dbo.PARTHIST(PH_CO, PH_GLIA, PH_DTR)
    INCLUDE (PH_DIV, PH_GLIC, PH_NET, PH_QTR);
CREATE INDEX IX_PARTHIST_Date     ON dbo.PARTHIST(PH_DTR) INCLUDE (PH_CO, PH_PRT, PH_NET);
GO

-- ---------------------------------------------------------------------------
-- dbo.INVHCC — Invoice header by cost center
-- Source PK: (EB_TID)
-- ---------------------------------------------------------------------------
CREATE TABLE dbo.INVHCC (
    EB_TID        DECIMAL(18,0)  NOT NULL,    -- Transaction id (PK)
    EB_CO         NVARCHAR(2)    NULL,
    EB_DIV        NVARCHAR(2)    NULL,
    EB_BR         NVARCHAR(2)    NULL,
    EB_SYS        NVARCHAR(3)    NULL,
    EB_ORD        NVARCHAR(10)   NULL,
    EB_CRDN       NVARCHAR(25)   NULL,
    EB_EXP        DECIMAL(6,0)   NULL,
    EB_AUTH       NVARCHAR(11)   NULL,
    EB_MER        NVARCHAR(20)   NULL,
    EB_PROM       NVARCHAR(4)    NULL,
    EB_INVD       NVARCHAR(1)    NULL,
    EB_AGC        NVARCHAR(1)    NULL,
    EB_MAN        NVARCHAR(1)    NULL,
    EB_AAMT       DECIMAL(11,2)  NULL,        -- Auth amount
    EB_GLA        NVARCHAR(5)    NULL,        -- GL account
    EB_GLC        NVARCHAR(3)    NULL,        -- GL cost center
    EB_DTT        DECIMAL(8,0)   NULL,        -- Transaction date, YYYYMMDD
    EB_CUS        NVARCHAR(10)   NULL,
    EB_IAMT       DECIMAL(11,2)  NULL,        -- Invoice amount
    EB_REF        NVARCHAR(10)   NULL,
    EB_DC1        DECIMAL(6,0)   NULL,
    EB_DC2        DECIMAL(6,0)   NULL,
    EB_RQID       NVARCHAR(50)   NULL,
    EB_STID       NVARCHAR(64)   NULL,
    EB_MRID       NVARCHAR(64)   NULL,
    EB_TMID       NVARCHAR(64)   NULL,
    EB_PDES       NVARCHAR(100)  NULL,
    UPDATE_IDENT  DECIMAL(7,0)   NULL,
    FirstSeenUtc  DATETIME2(3)   NOT NULL CONSTRAINT DF_INVHCC_FirstSeenUtc DEFAULT SYSUTCDATETIME(),
    LastSeenUtc   DATETIME2(3)   NOT NULL CONSTRAINT DF_INVHCC_LastSeenUtc  DEFAULT SYSUTCDATETIME(),
    LastRunId     UNIQUEIDENTIFIER NULL,
    CONSTRAINT PK_INVHCC PRIMARY KEY CLUSTERED (EB_TID)
);
CREATE INDEX IX_INVHCC_LastSeen ON dbo.INVHCC(LastSeenUtc);
CREATE INDEX IX_INVHCC_GLAcct   ON dbo.INVHCC(EB_CO, EB_GLA, EB_DTT)
    INCLUDE (EB_DIV, EB_GLC, EB_IAMT, EB_AAMT);
GO

-- ===========================================================================
-- Staging tables (stg.*) — transient ETL workspace, populated by ADF Copy,
-- consumed by sp_Acct_Merge_<T>. No FirstSeen/LastSeen — they get stamped
-- in dbo.* during the merge.
-- ===========================================================================

CREATE TABLE stg.CGIHIST (
    CH_CO NVARCHAR(2) NULL, CH_DIV NVARCHAR(2) NULL, CH_ORD NVARCHAR(10) NULL,
    CH_CGT NVARCHAR(1) NULL, CH_CLS NVARCHAR(1) NULL, CH_BDT DECIMAL(8,0) NULL,
    CH_INV NVARCHAR(6) NULL, CH_SEQ DECIMAL(5,0) NULL, CH_CUS NVARCHAR(10) NULL,
    CH_FILA NVARCHAR(25) NULL, CH_AMT DECIMAL(11,2) NULL, CH_ACC NVARCHAR(5) NULL,
    CH_CC NVARCHAR(3) NULL, CH_STA NVARCHAR(1) NULL, FILL1A NVARCHAR(1) NULL,
    CH_BR NVARCHAR(2) NULL, CH_HRS DECIMAL(7,0) NULL, CH_UID DECIMAL(18,0) NULL,
    CH_SYS NVARCHAR(3) NULL, CH_TID DECIMAL(18,0) NULL, CH_NME NVARCHAR(45) NULL,
    UPDATE_IDENT DECIMAL(7,0) NULL,
    LoadRunId CHAR(36) NULL, LoadedAt CHAR(26) NULL
);
GO

CREATE TABLE stg.YTDIST (
    DN_RID NVARCHAR(1) NULL, DN_CO NVARCHAR(2) NULL, DN_VEN NVARCHAR(6) NULL,
    DN_DIV NVARCHAR(2) NULL, DN_TC NVARCHAR(3) NULL, DN_VCH NVARCHAR(6) NULL,
    DN_NME NVARCHAR(25) NULL, DN_RR NVARCHAR(1) NULL, DN_FILA NVARCHAR(6) NULL,
    DN_GRS DECIMAL(11,2) NULL, DN_ACC NVARCHAR(5) NULL, DN_DNU NVARCHAR(5) NULL,
    DN_CC NVARCHAR(3) NULL, DN_FILB NVARCHAR(6) NULL, DN_CGC NVARCHAR(1) NULL,
    DN_CGT NVARCHAR(1) NULL, DN_STA NVARCHAR(1) NULL, DN_ORD NVARCHAR(10) NULL,
    DN_INV NVARCHAR(15) NULL, DNFILD NVARCHAR(20) NULL, DN_PO NVARCHAR(10) NULL,
    DN_POBR NVARCHAR(2) NULL, DN_CER DECIMAL(7,6) NULL, DN_DTI DECIMAL(8,0) NULL,
    DN_DTD DECIMAL(8,0) NULL, DN_CUS NVARCHAR(10) NULL,
    DN_TID DECIMAL(18,0) NULL, DN_SEQ DECIMAL(5,0) NULL,
    DN_UID DECIMAL(18,0) NULL, DN_CHQ NVARCHAR(7) NULL, DN_HDES NVARCHAR(40) NULL,
    UPDATE_IDENT DECIMAL(7,0) NULL,
    LoadRunId CHAR(36) NULL, LoadedAt CHAR(26) NULL
);
GO

CREATE TABLE stg.SUBLED (
    SL_STA NVARCHAR(1) NULL, SL_CO NVARCHAR(2) NULL, SL_ACC NVARCHAR(5) NULL,
    SL_CC NVARCHAR(3) NULL, SL_DIV NVARCHAR(2) NULL, SL_SEQ DECIMAL(6,0) NULL,
    SL_CUS NVARCHAR(10) NULL, SL_FILB NVARCHAR(6) NULL, SL_DES NVARCHAR(40) NULL,
    SL_IA DECIMAL(11,2) NULL, SL_RA DECIMAL(11,2) NULL, SL_DTI DECIMAL(8,0) NULL,
    SL_DTR DECIMAL(8,0) NULL, SL_CRN NVARCHAR(8) NULL, SL_BL NVARCHAR(1) NULL,
    SL_UID DECIMAL(18,0) NULL, SL_SYS NVARCHAR(3) NULL, SL_TID DECIMAL(18,0) NULL,
    SL_ORD NVARCHAR(15) NULL, SL_FILA NVARCHAR(6) NULL, SL_NME NVARCHAR(45) NULL,
    UPDATE_IDENT DECIMAL(7,0) NULL,
    LoadRunId CHAR(36) NULL, LoadedAt CHAR(26) NULL
);
GO

CREATE TABLE stg.PARTHIST (
    PH_STA NVARCHAR(1) NULL, PH_CO NVARCHAR(2) NULL, PH_PRT NVARCHAR(30) NULL,
    PH_DIV NVARCHAR(2) NULL, PH_BR NVARCHAR(2) NULL, PH_DTR DECIMAL(8,0) NULL,
    PH_TMR DECIMAL(6,0) NULL, PH_PO NVARCHAR(10) NULL, PH_SEQ DECIMAL(7,0) NULL,
    PH_TID DECIMAL(18,0) NULL, PH_UID DECIMAL(18,0) NULL, PH_QTR DECIMAL(5,0) NULL,
    PH_NET DECIMAL(9,2) NULL, PH_VEN NVARCHAR(6) NULL, PH_OST NVARCHAR(1) NULL,
    PH_PPK DECIMAL(5,0) NULL, PH_TYP NVARCHAR(2) NULL, PH_GLIC NVARCHAR(3) NULL,
    PH_GLIA NVARCHAR(5) NULL, PH_IAC NVARCHAR(3) NULL, PH_IAA NVARCHAR(5) NULL,
    PH_INV NVARCHAR(6) NULL, PH_QRE DECIMAL(5,0) NULL, PH_FIL1 NVARCHAR(9) NULL,
    UPDATE_IDENT DECIMAL(7,0) NULL,
    LoadRunId CHAR(36) NULL, LoadedAt CHAR(26) NULL
);
GO

CREATE TABLE stg.INVHCC (
    EB_TID DECIMAL(18,0) NULL, EB_CO NVARCHAR(2) NULL, EB_DIV NVARCHAR(2) NULL,
    EB_BR NVARCHAR(2) NULL, EB_SYS NVARCHAR(3) NULL, EB_ORD NVARCHAR(10) NULL,
    EB_CRDN NVARCHAR(25) NULL, EB_EXP DECIMAL(6,0) NULL, EB_AUTH NVARCHAR(11) NULL,
    EB_MER NVARCHAR(20) NULL, EB_PROM NVARCHAR(4) NULL, EB_INVD NVARCHAR(1) NULL,
    EB_AGC NVARCHAR(1) NULL, EB_MAN NVARCHAR(1) NULL, EB_AAMT DECIMAL(11,2) NULL,
    EB_GLA NVARCHAR(5) NULL, EB_GLC NVARCHAR(3) NULL, EB_DTT DECIMAL(8,0) NULL,
    EB_CUS NVARCHAR(10) NULL, EB_IAMT DECIMAL(11,2) NULL, EB_REF NVARCHAR(10) NULL,
    EB_DC1 DECIMAL(6,0) NULL, EB_DC2 DECIMAL(6,0) NULL, EB_RQID NVARCHAR(50) NULL,
    EB_STID NVARCHAR(64) NULL, EB_MRID NVARCHAR(64) NULL, EB_TMID NVARCHAR(64) NULL,
    EB_PDES NVARCHAR(100) NULL,
    UPDATE_IDENT DECIMAL(7,0) NULL,
    LoadRunId CHAR(36) NULL, LoadedAt CHAR(26) NULL
);
GO
