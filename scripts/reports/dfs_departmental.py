#!/usr/bin/env python3
"""Crystal Tractor — Kubota DFS Departmental P&L.

7-column layout: Sales / Service / Parts / Rental / Total Fixed / Admin / Consolidated.
Per CFO v2: Variable Expense (Sales Commission) broken out, D&A pulled into
its own line, EBITDA subtotal added.

Examples:
    python scripts/reports/dfs_departmental.py
    python scripts/reports/dfs_departmental.py --year 2025
"""
from __future__ import annotations

import argparse
from datetime import date
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.units import inch
from reportlab.platypus import Paragraph, Spacer, TableStyle

from _common import (
    BAND_GRAY, BRAND_BLUE, H1, SMALL, SUB, fetch, fmt_money, make_doc, now_str, themed_table,
)

# Dept = CC leading digit. v2 columns:
#   Sales = 2xx, Service = 3xx, Parts = 4xx, Rental = 5xx, Admin = 1xx, Corp = 0xx
DEPTS = [("Sales", "2"), ("Service", "3"), ("Parts", "4"), ("Rental", "5"), ("Admin", "1")]


def fetch_dept_pnl(year: int | None):
    """Return dict[dept_digit][line_name] = amount (in $).

    year=None or current year → live via COACMAST.CA_CUR (includes open periods).
    year given (historical) → GLCAL full-year aggregate.
    """
    from datetime import date as _d
    use_live = year is None or year == _d.today().year

    SECTIONS = {
        "Revenue":         "am.ACTYP = '2' AND LEFT(RTRIM(am.ACACC),1) IN ('3') AND am.ACACC NOT IN ('42210','42005','42212')",
        "COGS":            "am.ACTYP = '2' AND LEFT(RTRIM(am.ACACC),1) = '4' AND am.ACACC NOT IN ('42210','42005','42212')",
        "Variable Exp":    "am.ACTYP = '3' AND RTRIM(am.ACACC) = '51910'",
        "Personnel Exp":   "am.ACTYP = '3' AND LEFT(RTRIM(am.ACACC),2) = '51' AND RTRIM(am.ACACC) NOT IN ('51910')",
        "Operating Exp":   "am.ACTYP = '3' AND LEFT(RTRIM(am.ACACC),2) IN ('52','53','54','56','57','58') AND RTRIM(am.ACACC) NOT IN ('58200','58290','58310','55100','55300','55400')",
        "Fixed Exp":       "am.ACTYP = '3' AND LEFT(RTRIM(am.ACACC),3) = '590'",
        "D&A":             "am.ACTYP = '3' AND RTRIM(am.ACACC) IN ('55100','55300','55400')",
        "Interest Exp":    "am.ACTYP = '3' AND RTRIM(am.ACACC) IN ('58200','58290','59100')",
        "Other Inc/Exp":   "am.ACTYP IN ('2','3') AND LEFT(RTRIM(am.ACACC),1) IN ('6','7')",
    }
    data: dict[str, dict[str, float]] = {d: {} for _, d in DEPTS}
    data["consolidated"] = {}

    for line, where in SECTIONS.items():
        if use_live:
            sql = f"""
            SELECT LEFT(RTRIM(c.CA_CC),1) AS dept, SUM(c.CA_CUR) AS s
            FROM dbo.COACMAST c
            JOIN dbo.ACCMAST am ON RTRIM(am.ACACC) = RTRIM(c.CA_ACC)
            WHERE LEN(RTRIM(c.CA_CC)) >= 3 AND ({where})
            GROUP BY LEFT(RTRIM(c.CA_CC),1)
            """
        else:
            sql = f"""
            SELECT LEFT(RTRIM(g.GB_GLC),1) AS dept, SUM(g.GB_AMT) AS s
            FROM dbo.GLCAL g
            JOIN dbo.ACCMAST am ON RTRIM(am.ACACC) = RTRIM(g.GB_GLA)
            WHERE g.GB_DATE BETWEEN {year*100+1} AND {year*100+12}
              AND LEN(RTRIM(g.GB_GLC)) >= 3
              AND ({where})
            GROUP BY LEFT(RTRIM(g.GB_GLC),1)
            """
        _, rows = fetch(sql)
        for dept, s in rows:
            amt = float(s or 0)
            # Revenue stored negative; expense positive — both flip on display
            amt = -amt
            data.setdefault(dept, {})[line] = amt
            data["consolidated"][line] = data["consolidated"].get(line, 0) + amt

    return data


def build_pdf(year: int | None, data: dict, output_path: str) -> str:
    doc = make_doc(output_path, title="Crystal Tractor — Kubota DFS Departmental")
    elements: list = []
    from datetime import date as _d
    is_live = year is None or year == _d.today().year
    period_label = (f"YTD {_d.today().year} (live, through latest source update)"
                    if is_live else f"Fiscal Year {year}")
    source_label = "dbo.COACMAST.CA_CUR (live)" if is_live else "dbo.GLCAL"
    elements += [
        Paragraph("Crystal Tractor — Kubota DFS Departmental P&L", H1),
        Paragraph(f"{period_label} · Amounts in $K · Dept from CC leading digit", SUB),
        Paragraph(f"Generated {now_str()} · Source: {source_label}", SMALL),
        Spacer(1, 0.2 * inch),
    ]

    def k(v):
        return f"({abs(v)/1000:,.0f}K)" if v < 0 else f"{v/1000:,.0f}K" if v != 0 else "—"

    # Build the 7-column table
    headers = ["", "Sales", "Service", "Parts", "Rental", "Total Fixed", "Admin", "Consolidated"]
    rows = [headers]

    line_order = [
        ("Revenue",        "Revenue",         False),
        ("COGS",           "COGS",            True),
        ("Gross Profit",   None,              False),  # computed
        ("Variable Exp",   "Variable Exp",    False),
        ("Personnel Exp",  "Personnel Exp",   False),
        ("Operating Exp",  "Operating Exp",   False),
        ("Fixed Exp",      "Fixed Exp",       False),
        ("Total OpEx",     None,              False),  # computed
        ("EBITDA",         None,              True),   # computed, bold
        ("D&A",            "D&A",             False),
        ("Operating Income", None,            False),
        ("Interest Exp",   "Interest Exp",    False),
        ("Other Inc/Exp",  "Other Inc/Exp",   False),
        ("Net Income",     None,              True),
    ]
    # Total Fixed column = Service + Parts + Rental
    def col_val(dept_dig, line_name):
        return data.get(dept_dig, {}).get(line_name, 0)

    for label, src, _bold in line_order:
        rowvals = [label]
        if label == "Gross Profit":
            for _, dept in DEPTS:
                gp = col_val(dept, "Revenue") + col_val(dept, "COGS")
                rowvals.append(k(gp))
            total_fixed = sum(col_val(d, "Revenue") + col_val(d, "COGS") for _, d in DEPTS if d in ("3","4","5"))
            rowvals.insert(5, k(total_fixed))  # Total Fixed
            cons = col_val("consolidated", "Revenue") + col_val("consolidated", "COGS")
            rowvals.append(k(cons))
        elif label == "Total OpEx":
            for _, dept in DEPTS:
                opex = sum(col_val(dept, n) for n in ["Variable Exp","Personnel Exp","Operating Exp","Fixed Exp"])
                rowvals.append(k(opex))
            total_fixed = sum(sum(col_val(d, n) for n in ["Variable Exp","Personnel Exp","Operating Exp","Fixed Exp"]) for _, d in DEPTS if d in ("3","4","5"))
            rowvals.insert(5, k(total_fixed))
            cons = sum(col_val("consolidated", n) for n in ["Variable Exp","Personnel Exp","Operating Exp","Fixed Exp"])
            rowvals.append(k(cons))
        elif label == "EBITDA":
            for _, dept in DEPTS:
                e = (col_val(dept, "Revenue") + col_val(dept, "COGS")
                     + sum(col_val(dept, n) for n in ["Variable Exp","Personnel Exp","Operating Exp","Fixed Exp"]))
                rowvals.append(k(e))
            total_fixed = sum((col_val(d, "Revenue") + col_val(d, "COGS")
                               + sum(col_val(d, n) for n in ["Variable Exp","Personnel Exp","Operating Exp","Fixed Exp"]))
                              for _, d in DEPTS if d in ("3","4","5"))
            rowvals.insert(5, k(total_fixed))
            cons = (col_val("consolidated", "Revenue") + col_val("consolidated", "COGS")
                    + sum(col_val("consolidated", n) for n in ["Variable Exp","Personnel Exp","Operating Exp","Fixed Exp"]))
            rowvals.append(k(cons))
        elif label == "Operating Income":
            for _, dept in DEPTS:
                oi = (col_val(dept, "Revenue") + col_val(dept, "COGS")
                      + sum(col_val(dept, n) for n in ["Variable Exp","Personnel Exp","Operating Exp","Fixed Exp"])
                      + col_val(dept, "D&A"))
                rowvals.append(k(oi))
            total_fixed = sum((col_val(d, "Revenue") + col_val(d, "COGS")
                               + sum(col_val(d, n) for n in ["Variable Exp","Personnel Exp","Operating Exp","Fixed Exp"])
                               + col_val(d, "D&A")) for _, d in DEPTS if d in ("3","4","5"))
            rowvals.insert(5, k(total_fixed))
            cons = (col_val("consolidated", "Revenue") + col_val("consolidated", "COGS")
                    + sum(col_val("consolidated", n) for n in ["Variable Exp","Personnel Exp","Operating Exp","Fixed Exp"])
                    + col_val("consolidated", "D&A"))
            rowvals.append(k(cons))
        elif label == "Net Income":
            for _, dept in DEPTS:
                ni = (col_val(dept, "Revenue") + col_val(dept, "COGS")
                      + sum(col_val(dept, n) for n in ["Variable Exp","Personnel Exp","Operating Exp","Fixed Exp"])
                      + col_val(dept, "D&A") + col_val(dept, "Interest Exp") + col_val(dept, "Other Inc/Exp"))
                rowvals.append(k(ni))
            total_fixed = sum((col_val(d, "Revenue") + col_val(d, "COGS")
                               + sum(col_val(d, n) for n in ["Variable Exp","Personnel Exp","Operating Exp","Fixed Exp"])
                               + col_val(d, "D&A") + col_val(d, "Interest Exp") + col_val(d, "Other Inc/Exp"))
                              for _, d in DEPTS if d in ("3","4","5"))
            rowvals.insert(5, k(total_fixed))
            cons = (col_val("consolidated", "Revenue") + col_val("consolidated", "COGS")
                    + sum(col_val("consolidated", n) for n in ["Variable Exp","Personnel Exp","Operating Exp","Fixed Exp"])
                    + col_val("consolidated", "D&A") + col_val("consolidated", "Interest Exp") + col_val("consolidated", "Other Inc/Exp"))
            rowvals.append(k(cons))
        else:
            for _, dept in DEPTS:
                rowvals.append(k(col_val(dept, src)))
            total_fixed = sum(col_val(d, src) for _, d in DEPTS if d in ("3","4","5"))
            rowvals.insert(5, k(total_fixed))
            rowvals.append(k(col_val("consolidated", src)))
        rows.append(rowvals)

    t = themed_table(rows,
                     [1.3*inch, 0.7*inch, 0.7*inch, 0.7*inch, 0.7*inch, 0.8*inch, 0.7*inch, 0.9*inch],
                     right_align_cols=[1, 2, 3, 4, 5, 6, 7], font_size=9)
    # Bold EBITDA + NI rows
    for ridx, (label, _, bold) in enumerate(line_order, 1):
        if bold or label in ("Gross Profit", "Operating Income"):
            t.setStyle(TableStyle([
                ("FONTNAME", (0, ridx), (-1, ridx), "Helvetica-Bold"),
                ("BACKGROUND", (0, ridx), (-1, ridx), BAND_GRAY),
            ]))
        if label == "EBITDA":
            t.setStyle(TableStyle([
                ("BACKGROUND", (0, ridx), (-1, ridx), BRAND_BLUE),
                ("TEXTCOLOR", (0, ridx), (-1, ridx), colors.white),
            ]))
    elements.append(t)

    elements.append(Spacer(1, 0.2 * inch))
    elements.append(Paragraph(
        "Dept derived from cost-center leading digit: 2xx=Sales · 3xx=Service · 4xx=Parts · 5xx=Rental · 1xx=Admin · 0xx=Corp. "
        "Total Fixed = Service + Parts + Rental. Variable Expense = acct 51910 (Sales Commission). "
        "D&A = 55100/55300/55400. Source: dbo.GLCAL.",
        SMALL))
    doc.build(elements)
    return output_path


def main():
    ap = argparse.ArgumentParser(description="Crystal Tractor Kubota DFS Departmental P&L")
    ap.add_argument("--year", type=int, default=None,
                    help="Fiscal year (default: current year, live via COACMAST.CA_CUR)")
    ap.add_argument("--output", type=str, default=None)
    args = ap.parse_args()
    if args.output is None:
        tag = str(args.year) if args.year else f"YTD-{date.today().isoformat()}"
        out = Path.home() / "Downloads" / f"Crystal-IS-Kubota-DFS-{tag}.pdf"
    else:
        out = Path(args.output)
    data = fetch_dept_pnl(args.year)
    path = build_pdf(args.year, data, str(out))
    print(f"Wrote: {path}")


if __name__ == "__main__":
    main()
