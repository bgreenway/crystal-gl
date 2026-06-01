"""Shared utilities for Crystal GL report generators.

Each report script in this directory:
- imports `conn`, `fetch`, `fmt_*` from here for DB access + formatting
- imports the style constants (H1, H2, SUB, BODY, SMALL, COLORS) for consistent PDF look
- imports `themed_table` for the standard table style

Database access uses Azure AD via DefaultAzureCredential (works locally with
`az login`, also works inside Azure with Managed Identity).
"""
from __future__ import annotations

import os
import struct
import sys
from datetime import datetime
from typing import Any

import pyodbc
from azure.identity import DefaultAzureCredential
from reportlab.lib import colors
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.platypus import Table, TableStyle

# ---- DB layer --------------------------------------------------------------
SQL_SERVER = os.environ.get("GL_SQL_SERVER", "sql-prtsplan-prod-eastus-001.database.windows.net")
SQL_DATABASE = os.environ.get("GL_SQL_DATABASE", "sqldb-acctdata-prod-eastus-001")
SQL_TIMEOUT = int(os.environ.get("GL_SQL_TIMEOUT", "60"))
_SQL_COPT_SS_ACCESS_TOKEN = 1256

_conn_cache: pyodbc.Connection | None = None


def conn() -> pyodbc.Connection:
    """Process-cached pyodbc connection using AAD token."""
    global _conn_cache
    if _conn_cache is not None:
        return _conn_cache
    tok = DefaultAzureCredential().get_token("https://database.windows.net/.default").token.encode("utf-16-le")
    tokstruct = struct.pack(f"<I{len(tok)}s", len(tok), tok)
    _conn_cache = pyodbc.connect(
        f"Driver={{ODBC Driver 18 for SQL Server}};Server={SQL_SERVER};Database={SQL_DATABASE};Encrypt=yes;",
        attrs_before={_SQL_COPT_SS_ACCESS_TOKEN: tokstruct},
        timeout=SQL_TIMEOUT,
    )
    return _conn_cache


def fetch(sql: str, params: tuple = ()) -> tuple[list[str], list[tuple]]:
    """Execute SQL, return (column_names, rows)."""
    cur = conn().cursor()
    cur.execute(sql, params) if params else cur.execute(sql)
    if cur.description is None:
        return [], []
    cols = [c[0] for c in cur.description]
    return cols, cur.fetchall()


# ---- Formatting helpers ----------------------------------------------------
def fmt_money(v: Any, parens_for_neg: bool = True, decimals: int = 0) -> str:
    if v is None:
        return ""
    v = float(v)
    if decimals == 0:
        s = f"${abs(v):,.0f}"
    else:
        s = f"${abs(v):,.{decimals}f}"
    if v < 0 and parens_for_neg:
        return f"({s})"
    if v < 0:
        return f"-{s}"
    return s


def fmt_pct(v: Any, decimals: int = 1) -> str:
    if v is None:
        return ""
    return f"{float(v):.{decimals}f}%"


def fmt_int(v: Any) -> str:
    if v is None:
        return ""
    return f"{int(v):,}"


def fmt_period(p: int | str) -> str:
    """202602 -> 'Feb 2026'; 2025 -> '2025'."""
    s = str(p)
    if len(s) == 6:
        year, month = int(s[:4]), int(s[4:])
        return f"{['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'][month-1]} {year}"
    return s


# ---- PDF styling -----------------------------------------------------------
BRAND_BLUE = colors.HexColor("#1f3864")
LIGHT_GRAY = colors.HexColor("#5a5a5a")
BAND_GRAY = colors.HexColor("#f4f6fa")
LINE_GRAY = colors.HexColor("#d0d0d0")
INTERNAL_AMBER = colors.HexColor("#a86a00")
INTERCO_BLUE = colors.HexColor("#0070c0")

_styles = getSampleStyleSheet()
H1 = ParagraphStyle("H1", parent=_styles["Heading1"], fontSize=18, leading=22, spaceAfter=4, textColor=BRAND_BLUE)
H2 = ParagraphStyle("H2", parent=_styles["Heading2"], fontSize=13, leading=16, spaceBefore=10, spaceAfter=4, textColor=BRAND_BLUE)
SUB = ParagraphStyle("Sub", parent=_styles["Normal"], fontSize=9, textColor=LIGHT_GRAY, spaceAfter=8)
BODY = ParagraphStyle("Body", parent=_styles["Normal"], fontSize=10, leading=13)
SMALL = ParagraphStyle("Small", parent=_styles["Normal"], fontSize=8, leading=10, textColor=LIGHT_GRAY)
LABEL = ParagraphStyle("Label", parent=_styles["Normal"], fontSize=10, leading=13, fontName="Helvetica-Bold")


def themed_table(
    rows: list[list[Any]],
    col_widths: list[float],
    *,
    right_align_cols: list[int] | None = None,
    has_header: bool = True,
    has_total_row: bool = False,
    font_size: float = 9.5,
) -> Table:
    """Standard branded table with header row + zebra striping + optional total row."""
    t = Table(rows, colWidths=col_widths)
    cmds = [
        ("FONTSIZE",      (0, 0), (-1, -1), font_size),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
        ("TOPPADDING",    (0, 0), (-1, -1), 3),
        ("GRID",          (0, 0), (-1, -1), 0.25, LINE_GRAY),
    ]
    if has_header:
        cmds += [
            ("FONTNAME",   (0, 0), (-1, 0), "Helvetica-Bold"),
            ("BACKGROUND", (0, 0), (-1, 0), BRAND_BLUE),
            ("TEXTCOLOR",  (0, 0), (-1, 0), colors.white),
        ]
    if right_align_cols:
        for c in right_align_cols:
            cmds.append(("ALIGN", (c, 0), (c, -1), "RIGHT"))
    body_start = 1 if has_header else 0
    body_end = -2 if has_total_row else -1
    cmds.append(("ROWBACKGROUNDS", (0, body_start), (-1, body_end), [colors.white, BAND_GRAY]))
    if has_total_row:
        cmds += [
            ("FONTNAME",  (0, -1), (-1, -1), "Helvetica-Bold"),
            ("LINEABOVE", (0, -1), (-1, -1), 1, BRAND_BLUE),
        ]
    t.setStyle(TableStyle(cmds))
    return t


# ---- Period helpers --------------------------------------------------------
def period_to_yyyymm(p: int | str) -> int:
    """Accept 202602 or '202602' → 202602."""
    return int(p)


def period_to_date_range(yyyymm: int) -> tuple[int, int]:
    """202602 -> (20260201, 20260229). Uses end-of-month detection."""
    year, month = yyyymm // 100, yyyymm % 100
    start = yyyymm * 100 + 1
    # crude end-of-month
    if month == 12:
        next_month_first = (year + 1) * 100 * 100 + 101
    else:
        next_month_first = year * 10000 + (month + 1) * 100 + 1
    # last day of month = next_month_first - 1 in calendar terms, simpler: just use 31
    last_day = {1:31,2:29 if year%4==0 else 28,3:31,4:30,5:31,6:30,7:31,8:31,9:30,10:31,11:30,12:31}[month]
    end = yyyymm * 100 + last_day
    return start, end


# ---- Doc factory -----------------------------------------------------------
def make_doc(output_path: str, title: str = "Crystal Tractor"):
    """Standard SimpleDocTemplate for Crystal reports."""
    from reportlab.lib.units import inch
    from reportlab.platypus import SimpleDocTemplate
    return SimpleDocTemplate(
        output_path, pagesize=letter,
        leftMargin=0.6 * inch, rightMargin=0.6 * inch,
        topMargin=0.5 * inch, bottomMargin=0.5 * inch,
        title=title, author="Crystal GL Reports",
    )


def now_str() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M")
