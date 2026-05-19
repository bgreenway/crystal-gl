#!/usr/bin/env python3
"""
Crystal GL MCP Server

Read-only MCP tools over the Crystal GL data replicated to Azure SQL
(sqldb-acctdata-prod-eastus-001). See docs/data-model.md and
docs/mcp-server-spec.md in the Crystal repo.

Transport modes (env MCP_TRANSPORT):
  - stdio (default): for local Claude Code
  - http: streamable-HTTP server with bearer auth

DB config (env):
  GL_SQL_SERVER, GL_SQL_DATABASE, GL_SQL_TIMEOUT, GL_SQL_MAX_ROWS

HTTP auth (env, when MCP_TRANSPORT=http):
  MCP_BEARER_TOKEN  - required static token

DB auth: AAD via DefaultAzureCredential — Managed Identity in Azure,
developer credentials locally.
"""

import base64
import hashlib
import html
import json
import os
import re
import secrets
import struct
import time
from datetime import datetime, timezone
from typing import Any

import pyodbc
from azure.identity import DefaultAzureCredential
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import HTMLResponse, JSONResponse, RedirectResponse
from starlette.routing import Mount, Route

# ---- Config ----
SQL_SERVER = os.environ.get("GL_SQL_SERVER", "sql-prtsplan-prod-eastus-001.database.windows.net")
SQL_DATABASE = os.environ.get("GL_SQL_DATABASE", "sqldb-acctdata-prod-eastus-001")
SQL_TIMEOUT = int(os.environ.get("GL_SQL_TIMEOUT", "30"))
SQL_MAX_ROWS = int(os.environ.get("GL_SQL_MAX_ROWS", "10000"))

_default_allowed_hosts = (
    "127.0.0.1:*,localhost:*,[::1]:*,"
    "crystal-gl-mcp.azurewebsites.net,crystal-gl-mcp.azurewebsites.net:*"
)
ALLOWED_HOSTS = [
    h.strip() for h in os.environ.get("MCP_ALLOWED_HOSTS", _default_allowed_hosts).split(",") if h.strip()
]

mcp = FastMCP(
    "crystal-gl",
    transport_security=TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=ALLOWED_HOSTS,
    ),
)

# ---- DB layer ----
_credential: DefaultAzureCredential | None = None
_token_cache: dict[str, Any] = {"token_struct": None, "expires": 0.0}
_SQL_COPT_SS_ACCESS_TOKEN = 1256


def _get_token_struct() -> bytes:
    """Cached AAD token packed for pyodbc attrs_before."""
    global _credential
    now = time.time()
    if _token_cache["token_struct"] and now < _token_cache["expires"] - 60:
        return _token_cache["token_struct"]
    if _credential is None:
        _credential = DefaultAzureCredential()
    t = _credential.get_token("https://database.windows.net/.default")
    tb = t.token.encode("utf-16-le")
    _token_cache["token_struct"] = struct.pack(f"=i{len(tb)}s", len(tb), tb)
    _token_cache["expires"] = t.expires_on
    return _token_cache["token_struct"]


def _odbc_driver_name() -> str:
    """Pick the first available Microsoft ODBC driver."""
    for d in pyodbc.drivers():
        if "ODBC Driver 18 for SQL Server" in d:
            return d
    for d in pyodbc.drivers():
        if "ODBC Driver 17 for SQL Server" in d:
            return d
    raise RuntimeError(f"No Microsoft ODBC driver found. Installed drivers: {pyodbc.drivers()}")


def _conn():
    ts = _get_token_struct()
    drv = _odbc_driver_name()
    return pyodbc.connect(
        f"DRIVER={{{drv}}};"
        f"SERVER={SQL_SERVER};DATABASE={SQL_DATABASE};"
        f"Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30",
        attrs_before={_SQL_COPT_SS_ACCESS_TOKEN: ts},
        timeout=SQL_TIMEOUT,
    )


def _exec(sql: str, params: tuple = ()) -> dict:
    """Run a SELECT and return {'columns', 'rows', 'meta'} or {'error', 'message'}."""
    t0 = time.time()
    rows: list = []
    cols: list = []
    truncated = False
    try:
        conn = _conn()
        try:
            cur = conn.cursor()
            cur.execute("SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED")
            cur.execute(sql, params)
            if cur.description:
                cols = [c[0] for c in cur.description]
                for i, r in enumerate(cur.fetchall()):
                    if i >= SQL_MAX_ROWS:
                        truncated = True
                        break
                    rows.append(tuple(r))
        finally:
            conn.close()
    except Exception as e:
        return {"error": True, "message": f"{type(e).__name__}: {e}"}
    return {
        "columns": cols,
        "rows": rows,
        "meta": {
            "row_count": len(rows),
            "truncated": truncated,
            "query_ms": int((time.time() - t0) * 1000),
            "as_of": datetime.now(timezone.utc).isoformat(),
        },
    }


def _result_to_text(result: dict, extra_meta: dict | None = None, max_chars: int = 18000) -> str:
    if result.get("error"):
        return json.dumps(result, default=str, indent=2)
    cols = result["columns"]
    data = [dict(zip(cols, r)) for r in result["rows"]]
    out = {"data": data, "meta": result["meta"]}
    if extra_meta:
        out["meta"].update(extra_meta)
    s = json.dumps(out, default=str, indent=2)
    if len(s) > max_chars:
        s = s[:max_chars] + f"\n... [truncated; {len(s) - max_chars} more chars]"
    return s


# ---- Period parsing ----
_PERIOD_RX = re.compile(r"^(?:(\d{4})-?(\d{2})(?:-\d{2})?|(\d{6}))$")


def _parse_period(p: Any) -> int:
    """Accept 'YYYY-MM', 'YYYY-MM-DD', 'YYYYMM', or int — return CCYYMM int."""
    if isinstance(p, int):
        if 190001 <= p <= 209912 and 1 <= (p % 100) <= 12:
            return p
        raise ValueError(f"period int out of range: {p}")
    s = str(p).strip()
    m = _PERIOD_RX.match(s)
    if not m:
        raise ValueError(f"period must be 'YYYY-MM', 'YYYY-MM-DD', or 'YYYYMM', got {s!r}")
    if m.group(3):
        v = int(m.group(3))
    else:
        v = int(m.group(1)) * 100 + int(m.group(2))
    if not (190001 <= v <= 209912 and 1 <= (v % 100) <= 12):
        raise ValueError(f"period out of range: {v}")
    return v


# =============================================================================
# Reporting tools
# =============================================================================

@mcp.tool()
async def income_statement(
    period: str,
    company: str | None = None,
    division: str | None = None,
    branch: str | None = None,
    detail: str = "summary",
) -> str:
    """Return a P&L for the given period from v_IncomeStatementLines.

    Args:
        period: 'YYYY-MM', 'YYYY-MM-DD', or 'YYYYMM' (e.g. '2025-04' or 202504)
        company: optional 2-char company code (e.g. '01')
        division: optional 2-char division code
        branch: optional branch code
        detail: 'summary' (one row per Section) or 'by_account'
    """
    try:
        per = _parse_period(period)
    except ValueError as e:
        return json.dumps({"error": True, "message": str(e)})

    where = ["Period = ?"]
    params: list = [per]
    if company:
        where.append("Company = ?")
        params.append(company.strip().zfill(2))
    if division:
        where.append("Division = ?")
        params.append(division.strip().zfill(2))
    if branch:
        where.append("Branch = ?")
        params.append(branch.strip())
    where_sql = " AND ".join(where)

    if detail == "summary":
        sql = f"""
            SELECT Section, SectionOrder,
                   COUNT(*) AS Lines,
                   SUM(NetIncomeImpact) AS NetIncomeImpact
            FROM dbo.v_IncomeStatementLines
            WHERE {where_sql}
            GROUP BY Section, SectionOrder
            ORDER BY SectionOrder
        """
    elif detail == "by_account":
        sql = f"""
            SELECT Section, SectionOrder, AccountNumber, AccountName,
                   Company, Division, Branch,
                   SUM(NetIncomeImpact) AS NetIncomeImpact,
                   SUM(Amount) AS Amount
            FROM dbo.v_IncomeStatementLines
            WHERE {where_sql}
            GROUP BY Section, SectionOrder, AccountNumber, AccountName, Company, Division, Branch
            ORDER BY SectionOrder, AccountNumber
        """
    else:
        return json.dumps({"error": True, "message": f"detail must be 'summary' or 'by_account', got {detail!r}"})

    r = _exec(sql, tuple(params))
    if r.get("error"):
        return json.dumps(r, default=str)
    total = sum((row[r["columns"].index("NetIncomeImpact")] or 0) for row in r["rows"])
    return _result_to_text(
        r,
        extra_meta={
            "period": per,
            "total_net_income": float(total),
            "filters": {"company": company, "division": division, "branch": branch},
        },
    )


@mcp.tool()
async def pnl_by_section(
    period_start: str,
    period_end: str | None = None,
    company: str | None = None,
    division: str | None = None,
) -> str:
    """P&L by Section across one period or a range.

    Faster than `income_statement` when you only want section totals or
    you want a multi-month aggregate.
    """
    try:
        ps = _parse_period(period_start)
        pe = _parse_period(period_end) if period_end else ps
    except ValueError as e:
        return json.dumps({"error": True, "message": str(e)})
    if pe < ps:
        return json.dumps({"error": True, "message": "period_end must be >= period_start"})

    where = ["Period BETWEEN ? AND ?"]
    params: list = [ps, pe]
    if company:
        where.append("Company = ?")
        params.append(company.strip().zfill(2))
    if division:
        where.append("Division = ?")
        params.append(division.strip().zfill(2))

    sql = f"""
        SELECT Section, SectionOrder,
               COUNT(*) AS Lines,
               SUM(NetIncomeImpact) AS NetIncomeImpact
        FROM dbo.v_IncomeStatementLines
        WHERE {' AND '.join(where)}
        GROUP BY Section, SectionOrder
        ORDER BY SectionOrder
    """
    return _result_to_text(
        _exec(sql, tuple(params)),
        extra_meta={"period_start": ps, "period_end": pe},
    )


@mcp.tool()
async def trial_balance(
    period: str,
    company: str | None = None,
    division: str | None = None,
    include_zero: bool = False,
) -> str:
    """Trial balance for one period — every account with its balance.

    Args:
        period: 'YYYY-MM' or YYYYMM
        company / division: optional filters
        include_zero: include zero-amount rows (default False)
    """
    try:
        per = _parse_period(period)
    except ValueError as e:
        return json.dumps({"error": True, "message": str(e)})

    where = ["g.GB_DATE = ?"]
    params: list = [per]
    if company:
        where.append("g.GB_CO = ?")
        params.append(company.strip().zfill(2))
    if division:
        where.append("g.GB_DIV = ?")
        params.append(division.strip().zfill(2))
    if not include_zero:
        where.append("g.GB_AMT <> 0")

    sql = f"""
        SELECT g.GB_CO AS Company, g.GB_DIV AS Division, g.GB_GLC AS CostCtr,
               g.GB_GLA AS Account, RTRIM(a.ACNME) AS AccountName,
               c.CA_GLFA AS Alias, a.ACTYP AS AccountType, g.GB_AMT AS Amount
        FROM dbo.GLCAL g
        LEFT JOIN dbo.ACCMAST a ON a.ACCO = g.GB_CO AND a.ACACC = g.GB_GLA
        LEFT JOIN dbo.COACMAST c ON c.CA_CO = g.GB_CO AND c.CA_DIV = g.GB_DIV
                                AND c.CA_ACC = g.GB_GLA AND c.CA_CC = g.GB_GLC
        WHERE {' AND '.join(where)}
        ORDER BY g.GB_CO, g.GB_GLA, g.GB_GLC
    """
    r = _exec(sql, tuple(params))
    if r.get("error"):
        return json.dumps(r, default=str)
    total = sum((row[r["columns"].index("Amount")] or 0) for row in r["rows"])
    return _result_to_text(r, extra_meta={"period": per, "total": float(total)})


@mcp.tool()
async def account_search(
    query: str,
    company: str | None = None,
    limit: int = 25,
) -> str:
    """Find accounts by partial name or number.

    Args:
        query: search string (matches account number prefix and name LIKE)
        company: optional 2-char company filter
        limit: max rows (default 25, max 100)
    """
    limit = max(1, min(int(limit), 100))
    where = []
    params: list = []
    q = query.strip()
    if q:
        where.append("(a.ACACC LIKE ? OR a.ACNME LIKE ?)")
        params.append(f"{q}%")
        params.append(f"%{q}%")
    if company:
        where.append("a.ACCO = ?")
        params.append(company.strip().zfill(2))
    wsql = (" WHERE " + " AND ".join(where)) if where else ""
    sql = f"""
        SELECT TOP {limit}
            a.ACCO AS Company, a.ACACC AS Account, RTRIM(a.ACNME) AS AccountName,
            a.ACTYP AS AccountType, a.ACSTA AS Status
        FROM dbo.ACCMAST a
        {wsql}
        ORDER BY a.ACCO, a.ACACC
    """
    return _result_to_text(_exec(sql, tuple(params)), extra_meta={"query": q})


@mcp.tool()
async def account_activity(
    account: str,
    company: str | None = None,
    division: str | None = None,
    cost_center: str | None = None,
    from_period: str | None = None,
    to_period: str | None = None,
) -> str:
    """Every period an account had non-zero amount, with summary stats.

    Args:
        account: account number (e.g. '10100')
        company / division / cost_center: optional filters
        from_period / to_period: optional inclusive bounds
    """
    where = ["g.GB_GLA = ?", "g.GB_AMT <> 0"]
    params: list = [account.strip().zfill(5)]
    if company:
        where.append("g.GB_CO = ?")
        params.append(company.strip().zfill(2))
    if division:
        where.append("g.GB_DIV = ?")
        params.append(division.strip().zfill(2))
    if cost_center:
        where.append("g.GB_GLC = ?")
        params.append(cost_center.strip().zfill(3))
    try:
        if from_period:
            where.append("g.GB_DATE >= ?")
            params.append(_parse_period(from_period))
        if to_period:
            where.append("g.GB_DATE <= ?")
            params.append(_parse_period(to_period))
    except ValueError as e:
        return json.dumps({"error": True, "message": str(e)})

    sql = f"""
        SELECT g.GB_CO AS Company, g.GB_DIV AS Division, g.GB_GLC AS CostCtr,
               g.GB_GLA AS Account, g.GB_DATE AS Period, g.GB_AMT AS Amount
        FROM dbo.GLCAL g
        WHERE {' AND '.join(where)}
        ORDER BY g.GB_DATE, g.GB_CO, g.GB_DIV, g.GB_GLC
    """
    r = _exec(sql, tuple(params))
    if r.get("error"):
        return json.dumps(r, default=str)

    meta_extra: dict = {}
    if r["rows"]:
        amt_idx = r["columns"].index("Amount")
        per_idx = r["columns"].index("Period")
        amts = [row[amt_idx] for row in r["rows"]]
        meta_extra = {
            "first_period": r["rows"][0][per_idx],
            "last_period": r["rows"][-1][per_idx],
            "count": len(amts),
            "total": float(sum(amts)),
            "mean": float(sum(amts) / len(amts)),
            "min": float(min(amts)),
            "max": float(max(amts)),
        }
    else:
        meta_extra = {"count": 0}
    return _result_to_text(r, extra_meta=meta_extra)


@mcp.tool()
async def monthly_trend(
    account: str,
    company: str | None = None,
    division: str | None = None,
    from_period: str | None = None,
    to_period: str | None = None,
) -> str:
    """Time series for one account, summed across all matching dimensions per period."""
    where = ["g.GB_GLA = ?"]
    params: list = [account.strip().zfill(5)]
    if company:
        where.append("g.GB_CO = ?")
        params.append(company.strip().zfill(2))
    if division:
        where.append("g.GB_DIV = ?")
        params.append(division.strip().zfill(2))
    try:
        if from_period:
            where.append("g.GB_DATE >= ?")
            params.append(_parse_period(from_period))
        if to_period:
            where.append("g.GB_DATE <= ?")
            params.append(_parse_period(to_period))
    except ValueError as e:
        return json.dumps({"error": True, "message": str(e)})

    sql = f"""
        SELECT g.GB_DATE AS Period, SUM(g.GB_AMT) AS Amount
        FROM dbo.GLCAL g
        WHERE {' AND '.join(where)}
        GROUP BY g.GB_DATE
        ORDER BY g.GB_DATE
    """
    r = _exec(sql, tuple(params))
    if r.get("error"):
        return json.dumps(r, default=str)

    meta_extra: dict = {}
    if r["rows"]:
        amts = [row[1] for row in r["rows"]]
        meta_extra = {
            "count": len(amts),
            "total": float(sum(amts)),
            "mean": float(sum(amts) / len(amts)),
            "min": float(min(amts)),
            "max": float(max(amts)),
            "latest_period": r["rows"][-1][0],
            "latest_amount": float(r["rows"][-1][1]),
        }
    else:
        meta_extra = {"count": 0}
    return _result_to_text(r, extra_meta=meta_extra)


@mcp.tool()
async def alias_rollup(
    period: str,
    alias: str | None = None,
    company: str | None = None,
    division: str | None = None,
) -> str:
    """Roll up accounts by COACMAST.CA_GLFA alias.

    Matches the spreadsheet "Alias Account" column. If alias is supplied,
    returns the contributing accounts; otherwise returns all aliases for the period.
    """
    try:
        per = _parse_period(period)
    except ValueError as e:
        return json.dumps({"error": True, "message": str(e)})

    where = ["g.GB_DATE = ?"]
    params: list = [per]
    if company:
        where.append("g.GB_CO = ?")
        params.append(company.strip().zfill(2))
    if division:
        where.append("g.GB_DIV = ?")
        params.append(division.strip().zfill(2))

    if alias:
        where.append("c.CA_GLFA = ?")
        params.append(alias.strip())
        sql = f"""
            SELECT c.CA_GLFA AS Alias, g.GB_CO AS Company, g.GB_DIV AS Division,
                   g.GB_GLC AS CostCtr, g.GB_GLA AS Account,
                   RTRIM(a.ACNME) AS AccountName, g.GB_AMT AS Amount
            FROM dbo.GLCAL g
            JOIN dbo.COACMAST c ON c.CA_CO=g.GB_CO AND c.CA_DIV=g.GB_DIV
                              AND c.CA_ACC=g.GB_GLA AND c.CA_CC=g.GB_GLC
            LEFT JOIN dbo.ACCMAST a ON a.ACCO=g.GB_CO AND a.ACACC=g.GB_GLA
            WHERE {' AND '.join(where)}
            ORDER BY ABS(g.GB_AMT) DESC
        """
    else:
        where.append("c.CA_GLFA <> ''")
        sql = f"""
            SELECT c.CA_GLFA AS Alias,
                   COUNT(*) AS Lines,
                   SUM(g.GB_AMT) AS Amount
            FROM dbo.GLCAL g
            JOIN dbo.COACMAST c ON c.CA_CO=g.GB_CO AND c.CA_DIV=g.GB_DIV
                              AND c.CA_ACC=g.GB_GLA AND c.CA_CC=g.GB_GLC
            WHERE {' AND '.join(where)}
            GROUP BY c.CA_GLFA
            ORDER BY ABS(SUM(g.GB_AMT)) DESC
        """
    return _result_to_text(_exec(sql, tuple(params)), extra_meta={"period": per})


# =============================================================================
# Operational tools
# =============================================================================

@mcp.tool()
async def period_coverage(company: str | None = None) -> str:
    """Period coverage in GLCAL — min, max, count, plus the 12 most recent periods."""
    where: list = []
    params: list = []
    if company:
        where.append("GB_CO = ?")
        params.append(company.strip().zfill(2))
    wsql = (" WHERE " + " AND ".join(where)) if where else ""

    r1 = _exec(
        f"""SELECT MIN(GB_DATE) AS MinPeriod, MAX(GB_DATE) AS MaxPeriod,
                  COUNT(DISTINCT GB_DATE) AS DistinctPeriods, COUNT(*) AS TotalRows
            FROM dbo.GLCAL{wsql}""",
        tuple(params),
    )
    if r1.get("error"):
        return json.dumps(r1, default=str)
    r2 = _exec(
        f"""SELECT TOP 12 GB_DATE AS Period, COUNT(*) AS Rows
            FROM dbo.GLCAL{wsql}
            GROUP BY GB_DATE ORDER BY GB_DATE DESC""",
        tuple(params),
    )
    out = {
        "summary": dict(zip(r1["columns"], r1["rows"][0])) if r1["rows"] else {},
        "recent_periods": [dict(zip(r2["columns"], row)) for row in r2.get("rows", [])],
        "meta": r1["meta"],
    }
    return json.dumps(out, default=str, indent=2)


@mcp.tool()
async def load_status() -> str:
    """Most recent successful ETL load per table (dbo.AcctLoadControl)."""
    sql = """
        WITH last_complete AS (
            SELECT TableName, MAX(EndedUtc) AS LastSuccessUtc
            FROM dbo.AcctLoadControl
            WHERE Status='COMPLETE'
            GROUP BY TableName
        )
        SELECT lc.TableName,
               lc.LastSuccessUtc,
               DATEDIFF(SECOND, lc.LastSuccessUtc, SYSUTCDATETIME()) AS SecondsSinceSuccess,
               lc2.Status AS LastAttemptStatus,
               lc2.RowsCopied AS LastSuccessRowsCopied,
               lc2.ErrorMessage AS LastErrorMessage
        FROM last_complete lc
        LEFT JOIN dbo.AcctLoadControl lc2
            ON lc2.TableName = lc.TableName AND lc2.EndedUtc = lc.LastSuccessUtc
        ORDER BY lc.TableName
    """
    return _result_to_text(_exec(sql))


# =============================================================================
# Escape hatch
# =============================================================================

_SQL_FORBIDDEN = re.compile(
    r"\b(insert|update|delete|merge|drop|alter|create|truncate|exec|execute|grant|revoke)\b",
    re.IGNORECASE,
)
_SQL_FORBIDDEN_PREFIX = re.compile(r"\b(xp_|sp_)\w+", re.IGNORECASE)
_SQL_ALLOWED_START = re.compile(r"^\s*(--[^\n]*\n|\s)*(select|with)\b", re.IGNORECASE)


def _strip_strings_and_comments(sql: str) -> str:
    out = re.sub(r"--[^\n]*", "", sql)
    out = re.sub(r"/\*.*?\*/", "", out, flags=re.DOTALL)
    out = re.sub(r"'(?:[^']|'')*'", "''", out)
    return out


@mcp.tool()
async def query_sql(sql: str, limit: int = 100) -> str:
    """Run an ad-hoc read-only SELECT against the GL replica.

    PREFER curated tools (income_statement, trial_balance, monthly_trend, etc.)
    when they apply — faster, safer, richer output. Use this only for novel
    questions no curated tool fits.

    Tables (schema: dbo):
      ACCMAST, COACMAST, DEPTMAST, GLCAL, GLFIS,
      AcctLoadControl, v_IncomeStatementLines (view).

    Args:
        sql: a single SELECT or WITH...SELECT statement
        limit: row cap (default 100, max 10000); TOP injected for plain SELECTs
    """
    limit = max(1, min(int(limit), 10000))
    s = sql.strip().rstrip(";")
    if ";" in s:
        return json.dumps({"error": True, "message": "Only single statements allowed (no ';' chaining)."})
    if not _SQL_ALLOWED_START.match(s):
        return json.dumps({"error": True, "message": "Statement must start with SELECT or WITH."})
    scrubbed = _strip_strings_and_comments(s)
    m = _SQL_FORBIDDEN.search(scrubbed)
    if m:
        return json.dumps({"error": True, "message": f"Forbidden keyword in SQL: {m.group(0)!r}"})
    m2 = _SQL_FORBIDDEN_PREFIX.search(scrubbed)
    if m2:
        return json.dumps({"error": True, "message": f"Forbidden identifier in SQL: {m2.group(0)!r}"})

    if s.lstrip().lower().startswith("select") and not re.match(r"^\s*select\s+top\s+", s, re.IGNORECASE):
        s = re.sub(r"^(\s*select)\b", lambda mm: f"{mm.group(1)} TOP {limit}", s, count=1, flags=re.IGNORECASE)

    return _result_to_text(_exec(s), extra_meta={"sql_executed": s})


# =============================================================================
# OAuth 2.0 (PKCE + DCR) for claude.ai
# =============================================================================
# Implements RFC 8414 authorization-server metadata, RFC 7591 dynamic client
# registration, authorization-code grant with PKCE (RFC 7636), and JWT bearer
# access tokens. Single-tenant: one shared OAUTH_PASSCODE.

_auth_codes: dict[str, dict] = {}
_clients: dict[str, dict] = {}
_AUTH_CODE_TTL = 600
_ACCESS_TOKEN_TTL = 7 * 24 * 3600
_JWT_ALGO = "HS256"


def _resolve_public_url() -> str:
    base = os.environ.get("MCP_PUBLIC_URL", "").rstrip("/")
    return base or "https://crystal-gl-mcp.azurewebsites.net"


def _jwt_secret() -> str:
    s = os.environ.get("MCP_JWT_SECRET") or os.environ.get("MCP_BEARER_TOKEN") or ""
    if not s:
        raise RuntimeError("MCP_JWT_SECRET (or MCP_BEARER_TOKEN as fallback) must be set for HTTP mode.")
    return s


def _make_access_token(sub: str, client_id: str) -> str:
    import jwt as pyjwt
    now = int(time.time())
    payload = {
        "iss": _resolve_public_url(),
        "aud": _resolve_public_url(),
        "sub": sub,
        "client_id": client_id,
        "iat": now,
        "exp": now + _ACCESS_TOKEN_TTL,
        "scope": "mcp",
    }
    return pyjwt.encode(payload, _jwt_secret(), algorithm=_JWT_ALGO)


def _verify_access_token(token: str) -> dict | None:
    import jwt as pyjwt
    try:
        return pyjwt.decode(token, _jwt_secret(), algorithms=[_JWT_ALGO], audience=_resolve_public_url())
    except Exception:
        return None


def _verify_pkce(code_verifier: str, code_challenge: str, method: str) -> bool:
    if not code_challenge:
        return True
    if method == "S256":
        digest = hashlib.sha256(code_verifier.encode()).digest()
        expected = base64.urlsafe_b64encode(digest).decode().rstrip("=")
        return secrets.compare_digest(expected, code_challenge)
    if method == "plain":
        return secrets.compare_digest(code_verifier, code_challenge)
    return False


def _cleanup_codes():
    now = time.time()
    for c in [c for c, r in _auth_codes.items() if r["exp"] < now]:
        _auth_codes.pop(c, None)


async def oauth_authorization_server_metadata(_request):
    base = _resolve_public_url()
    return JSONResponse({
        "issuer": base,
        "authorization_endpoint": f"{base}/authorize",
        "token_endpoint": f"{base}/token",
        "registration_endpoint": f"{base}/register",
        "response_types_supported": ["code"],
        "grant_types_supported": ["authorization_code"],
        "code_challenge_methods_supported": ["S256", "plain"],
        "token_endpoint_auth_methods_supported": ["none"],
        "scopes_supported": ["mcp"],
    })


async def oauth_protected_resource_metadata(_request):
    base = _resolve_public_url()
    return JSONResponse({
        "resource": f"{base}/mcp",
        "authorization_servers": [base],
        "scopes_supported": ["mcp"],
        "bearer_methods_supported": ["header"],
    })


async def register_client(request):
    try:
        body = await request.json()
    except Exception:
        body = {}
    client_id = secrets.token_urlsafe(16)
    _clients[client_id] = body
    return JSONResponse({
        "client_id": client_id,
        "client_id_issued_at": int(time.time()),
        "redirect_uris": body.get("redirect_uris", []),
        "token_endpoint_auth_method": "none",
        "grant_types": ["authorization_code"],
        "response_types": ["code"],
        "scope": "mcp",
        **({k: body[k] for k in ("client_name", "client_uri", "logo_uri") if k in body}),
    }, status_code=201)


_LOGIN_PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Crystal GL — Authorize</title>
<style>
  body {{ font-family: system-ui, sans-serif; max-width: 420px; margin: 60px auto; padding: 24px; }}
  h1 {{ font-size: 18px; margin-bottom: 4px; }}
  p  {{ color: #555; font-size: 14px; }}
  label {{ display: block; margin-top: 16px; font-size: 13px; color: #333; }}
  input[type=password] {{ width: 100%; padding: 10px; font-size: 16px; border: 1px solid #ccc; border-radius: 6px; box-sizing: border-box; }}
  button {{ margin-top: 16px; width: 100%; padding: 10px; font-size: 15px; background: #1f6feb; color: white; border: 0; border-radius: 6px; cursor: pointer; }}
  .err {{ color: #c00; font-size: 13px; margin-top: 12px; }}
  .meta {{ color: #777; font-size: 12px; margin-top: 20px; }}
</style></head><body>
<h1>Authorize Crystal GL</h1>
<p>Requested by <code>{client}</code>. Enter the passcode to grant access.</p>
{err}
<form method="post" action="/authorize">
  <input type="hidden" name="client_id"             value="{client_id}">
  <input type="hidden" name="redirect_uri"          value="{redirect_uri}">
  <input type="hidden" name="state"                 value="{state}">
  <input type="hidden" name="code_challenge"        value="{code_challenge}">
  <input type="hidden" name="code_challenge_method" value="{code_challenge_method}">
  <input type="hidden" name="scope"                 value="{scope}">
  <label>Passcode<input name="passcode" type="password" autofocus required></label>
  <button type="submit">Authorize</button>
</form>
<div class="meta">Crystal GL MCP &middot; single-tenant passcode auth</div>
</body></html>"""


async def authorize(request):
    if request.method == "GET":
        params = request.query_params
        client_id = params.get("client_id", "")
        redirect_uri = params.get("redirect_uri", "")
        if not redirect_uri:
            return HTMLResponse("Missing redirect_uri", status_code=400)
        ctx = {
            "client": html.escape(_clients.get(client_id, {}).get("client_name", client_id or "unknown")),
            "client_id": html.escape(client_id),
            "redirect_uri": html.escape(redirect_uri),
            "state": html.escape(params.get("state", "")),
            "code_challenge": html.escape(params.get("code_challenge", "")),
            "code_challenge_method": html.escape(params.get("code_challenge_method", "S256")),
            "scope": html.escape(params.get("scope", "mcp")),
            "err": "",
        }
        return HTMLResponse(_LOGIN_PAGE.format(**ctx))

    form = await request.form()
    expected = os.environ.get("OAUTH_PASSCODE", "")
    if not expected:
        return HTMLResponse("Server misconfigured: OAUTH_PASSCODE not set", status_code=500)
    if not secrets.compare_digest(str(form.get("passcode", "")), expected):
        ctx = {
            "client": html.escape(form.get("client_id") or "unknown"),
            "client_id": html.escape(form.get("client_id", "")),
            "redirect_uri": html.escape(form.get("redirect_uri", "")),
            "state": html.escape(form.get("state", "")),
            "code_challenge": html.escape(form.get("code_challenge", "")),
            "code_challenge_method": html.escape(form.get("code_challenge_method", "S256")),
            "scope": html.escape(form.get("scope", "mcp")),
            "err": '<div class="err">Invalid passcode.</div>',
        }
        return HTMLResponse(_LOGIN_PAGE.format(**ctx), status_code=401)

    _cleanup_codes()
    code = secrets.token_urlsafe(32)
    _auth_codes[code] = {
        "client_id": form.get("client_id", ""),
        "redirect_uri": form.get("redirect_uri", ""),
        "code_challenge": form.get("code_challenge", ""),
        "code_challenge_method": form.get("code_challenge_method", "S256"),
        "exp": time.time() + _AUTH_CODE_TTL,
        "sub": "user",
        "scope": form.get("scope", "mcp"),
    }
    redirect_uri = form.get("redirect_uri") or ""
    state = form.get("state", "")
    sep = "&" if "?" in redirect_uri else "?"
    location = f"{redirect_uri}{sep}code={code}"
    if state:
        location += f"&state={state}"
    return RedirectResponse(location, status_code=302)


async def token_endpoint(request):
    form = await request.form()
    if form.get("grant_type") != "authorization_code":
        return JSONResponse({"error": "unsupported_grant_type"}, status_code=400)
    code = form.get("code", "")
    _cleanup_codes()
    record = _auth_codes.pop(code, None)
    if not record:
        return JSONResponse({"error": "invalid_grant", "error_description": "code expired or unknown"}, status_code=400)
    if record["exp"] < time.time():
        return JSONResponse({"error": "invalid_grant", "error_description": "code expired"}, status_code=400)
    if record["redirect_uri"] and record["redirect_uri"] != form.get("redirect_uri"):
        return JSONResponse({"error": "invalid_grant", "error_description": "redirect_uri mismatch"}, status_code=400)
    if not _verify_pkce(form.get("code_verifier", ""), record["code_challenge"], record["code_challenge_method"]):
        return JSONResponse({"error": "invalid_grant", "error_description": "PKCE failed"}, status_code=400)
    return JSONResponse({
        "access_token": _make_access_token(sub=record["sub"], client_id=record["client_id"]),
        "token_type": "Bearer",
        "expires_in": _ACCESS_TOKEN_TTL,
        "scope": record["scope"],
    })


# =============================================================================
# HTTP transport
# =============================================================================

def _build_http_app():
    auth_mode = os.environ.get("MCP_AUTH_MODE", "both").lower()
    if auth_mode not in ("bearer", "oauth", "both"):
        raise RuntimeError(f"Invalid MCP_AUTH_MODE: {auth_mode!r}")
    static_bearer = os.environ.get("MCP_BEARER_TOKEN")
    if auth_mode in ("bearer", "both") and not static_bearer:
        raise RuntimeError("MCP_BEARER_TOKEN required for bearer/both auth modes.")
    if auth_mode in ("oauth", "both") and not os.environ.get("OAUTH_PASSCODE"):
        raise RuntimeError("OAUTH_PASSCODE required for oauth/both auth modes.")

    base = _resolve_public_url()
    www_authenticate = f'Bearer resource_metadata="{base}/.well-known/oauth-protected-resource"'

    PUBLIC_PATHS = {
        "/healthz",
        "/.well-known/oauth-authorization-server",
        "/.well-known/oauth-protected-resource",
        "/authorize",
        "/token",
        "/register",
    }

    class AuthMiddleware(BaseHTTPMiddleware):
        async def dispatch(self, request, call_next):
            if request.url.path in PUBLIC_PATHS:
                return await call_next(request)
            auth = request.headers.get("authorization", "")
            if not auth.lower().startswith("bearer "):
                return JSONResponse({"error": "unauthorized"}, status_code=401,
                                    headers={"WWW-Authenticate": www_authenticate})
            token = auth.split(None, 1)[1].strip()
            if auth_mode in ("bearer", "both") and static_bearer:
                if secrets.compare_digest(token, static_bearer):
                    return await call_next(request)
            if auth_mode in ("oauth", "both"):
                if _verify_access_token(token):
                    return await call_next(request)
            return JSONResponse({"error": "unauthorized"}, status_code=401,
                                headers={"WWW-Authenticate": www_authenticate})

    inner_app = mcp.streamable_http_app()

    async def healthz(_request):
        try:
            r = _exec("SELECT 1 AS ok")
            db_ok = not r.get("error")
            err = r.get("message") if not db_ok else None
        except Exception as e:
            db_ok = False
            err = str(e)
        body = {"status": "ok" if db_ok else "degraded", "db": "ok" if db_ok else "error"}
        if err:
            body["db_error"] = err
        return JSONResponse(body, status_code=200 if db_ok else 503)

    routes = [
        Route("/healthz", healthz, methods=["GET"]),
        Route("/.well-known/oauth-authorization-server", oauth_authorization_server_metadata, methods=["GET"]),
        Route("/.well-known/oauth-protected-resource", oauth_protected_resource_metadata, methods=["GET"]),
        Route("/register", register_client, methods=["POST"]),
        Route("/authorize", authorize, methods=["GET", "POST"]),
        Route("/token", token_endpoint, methods=["POST"]),
        Mount("/", app=inner_app),
    ]
    return Starlette(
        middleware=[Middleware(AuthMiddleware)],
        routes=routes,
        lifespan=inner_app.router.lifespan_context,
    )


app = _build_http_app() if os.environ.get("MCP_TRANSPORT") == "http" else None


if __name__ == "__main__":
    transport = os.environ.get("MCP_TRANSPORT", "stdio").lower()
    if transport == "stdio":
        mcp.run()
    elif transport == "http":
        import uvicorn
        host = os.environ.get("MCP_HOST", "0.0.0.0")
        port = int(os.environ.get("MCP_PORT", "8000"))
        uvicorn.run(app, host=host, port=port, log_level="info")
    else:
        raise SystemExit(f"Unknown MCP_TRANSPORT: {transport!r}")
