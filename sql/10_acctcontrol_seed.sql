-- ===========================================================================
-- 10_acctcontrol_seed.sql
--
-- Final wiring step for the journal-line ETL extension:
--   1. ALTER dbo.sp_AcctStartRun to accept the five new TableName values.
--   2. Seed dbo.AcctSnapshotControl with one row per new table so the
--      snapshot procs can read their watermarks.
--
-- Run AFTER sql/07_journal_line_schema.sql, sql/08_journal_line_procedures.sql,
-- and sql/09_journal_line_snapshot.sql have all executed cleanly.
-- ===========================================================================

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ---------------------------------------------------------------------------
-- 1. Extend sp_AcctStartRun's allow-list.
--
-- The existing proc (sql/02_procedures.sql) throws if @TableName is not one of
-- the five summary tables. We extend the allow-list to include the five new
-- journal-line tables. Everything else in the proc is unchanged.
-- ---------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.sp_AcctStartRun
    @TableName      VARCHAR(30),
    @RunId          UNIQUEIDENTIFIER OUTPUT,
    @CredentialPair VARCHAR(4)       OUTPUT,
    @UserSecretName NVARCHAR(127)    OUTPUT,
    @PassSecretName NVARCHAR(127)    OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @TableName NOT IN (
        -- Original five summary tables:
        'ACCMAST','COACMAST','DEPTMAST','GLCAL','GLFIS',
        -- Journal-line sub-system tables added 2026-05-29:
        'CGIHIST','YTDIST','SUBLED','PARTHIST','INVHCC'
    )
        THROW 50002, 'TableName must be one of the 10 acctdata tables (ACCMAST/COACMAST/DEPTMAST/GLCAL/GLFIS or CGIHIST/YTDIST/SUBLED/PARTHIST/INVHCC)', 1;

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

    INSERT INTO dbo.AcctLoadControl (
        RunId, TableName, Status, CredentialPairUsed, UserSecretName, PassSecretName
    )
    VALUES (
        @RunId, @TableName, 'RUNNING', @CredentialPair, @UserSecretName, @PassSecretName
    );
END
GO

-- ---------------------------------------------------------------------------
-- 2. Seed AcctSnapshotControl with one row per new snapshotted table.
--
-- LastCapturedThroughUtc is set to SYSUTCDATETIME() at seed time so the FIRST
-- snapshot run skips any backfill — only new changes after this point will be
-- captured. If you want to backfill historical state, set the watermark to
-- something earlier (e.g. '2000-01-01'); the first run will then capture
-- every row whose LastSeenUtc falls in the range, which can be large for
-- PARTHIST.
-- ---------------------------------------------------------------------------
INSERT INTO dbo.AcctSnapshotControl (TableName, LastCapturedThroughUtc, LastSnapshotRunUtc, LastRowsCaptured)
SELECT v.TableName, SYSUTCDATETIME(), NULL, 0
FROM (VALUES ('CGIHIST'), ('YTDIST'), ('SUBLED'), ('PARTHIST'), ('INVHCC')) AS v(TableName)
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.AcctSnapshotControl c WHERE c.TableName = v.TableName
);
GO

-- ---------------------------------------------------------------------------
-- Verification queries — run these manually after deployment to confirm.
-- ---------------------------------------------------------------------------
-- Confirm all 10 tables are valid in sp_AcctStartRun:
--   DECLARE @r UNIQUEIDENTIFIER, @cp VARCHAR(4), @u NVARCHAR(127), @p NVARCHAR(127);
--   EXEC dbo.sp_AcctStartRun 'CGIHIST', @r OUTPUT, @cp OUTPUT, @u OUTPUT, @p OUTPUT;
--   SELECT @r AS RunId, @cp AS Pair, @u AS UserSecret, @p AS PassSecret;
--   -- Then clean up the test row:
--   DELETE FROM dbo.AcctLoadControl WHERE RunId = @r;

-- Confirm snapshot control rows exist:
--   SELECT * FROM dbo.AcctSnapshotControl ORDER BY TableName;
--   -- Should show 7 rows: GLCAL, GLFIS (pre-existing) + CGIHIST, YTDIST, SUBLED, PARTHIST, INVHCC (new)

-- Confirm tables exist with PKs + audit columns:
--   SELECT t.name AS TableName, c.name AS ColName, ty.name AS Type, c.max_length, c.is_nullable
--   FROM sys.tables t
--   INNER JOIN sys.columns c ON c.object_id = t.object_id
--   INNER JOIN sys.types ty ON ty.user_type_id = c.user_type_id
--   WHERE t.name IN ('CGIHIST','YTDIST','SUBLED','PARTHIST','INVHCC') AND SCHEMA_NAME(t.schema_id) = 'dbo'
--   ORDER BY t.name, c.column_id;
