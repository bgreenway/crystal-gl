#!/usr/bin/env python3
"""Crystal Tractor — Consolidated Cash Flow Statement (Indirect Method).

Per CFO v2 feedback: no auto "(Gain) on sale" adjustment (manual only),
Retained Earnings line labeled "Distributions or Δ in equity (excl. NI)",
financing-section lines labeled net-of-all-activity, reconciliation
residual called out as DISCUSS-level open item.

Examples:
    python scripts/reports/cash_flow.py
    python scripts/reports/cash_flow.py --year 2025
    python scripts/reports/cash_flow.py --year 2025 --branch 01
"""
from __future__ import annotations

import argparse
from datetime import date
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.units import inch
from reportlab.platypus import Paragraph, Spacer, TableStyle

from _common import (
    BAND_GRAY, BRAND_BLUE, H1, H2, SMALL, SUB,
    fetch, fmt_money, make_doc, now_str, themed_table,
)

# BS account groups for working-capital change calculations
WC_GROUPS = [
    ("Inventory — Wholegoods",   ["12000", "12007"]),
    ("Inventory — Parts",        ["13000", "13900"]),
    ("Work-in-Process",          ["14000", "14100", "14200"]),
    ("Accounts Receivable",      ["10200", "10204", "10210", "10241", "10242", "10245", "10246", "10230"]),
    ("Other Current Assets",     ["10301", "10311", "10400", "10401", "10402", "10224", "10205"]),
    ("Prepaid Expenses",         ["10301"]),
    ("Accounts Payable & Taxes", ["20100", "20200", "20300", "20500", "20600"]),
    ("Accrued Expenses",         ["21002", "21010", "21015", "21016", "21020", "21100", "21112", "21200", "21300"]),
    ("Customer Deposits / Reserves", ["12100", "13010"]),
]

INVESTING_GROUPS = [
    ("Property, Plant & Equipment",
        ["15100","15103","15110","15120","15200","15300","15400","15600","15700","15800","15950","15000","15050",
         "16100","16103","16110","16120","16200","16300","16400","16600","16700","16800","16950"]),
    ("Intangibles & Goodwill", ["17250", "17260", "17400"]),
]

FINANCING_GROUPS = [
    ("Notes Payable — Long-term", ["25610", "25700", "25800"]),
    ("Intercompany Transfers",    ["10180", "10182"]),
    ("Floorplan Payable",         ["20350"]),
    ("Related Party Loans",       ["24050", "24060", "24070"]),
    ("Intercompany Liabilities",  ["24900"]),
    ("Paid-In Capital / Stock",   ["27500"]),
    ("Other Equity",              ["27530", "27532"]),
    ("Distributions / Δ Equity (excl. NI)", ["27531", "27533", "27550", "27551", "27552"]),
]

DA_ACCTS = ["55100", "55300", "55400"]
CASH_ACCTS = ["10100", "10110", "10113", "10114", "10140", "10150", "10151", "10160", "10170"]


def balance(period: int, accts: list[str], branch: str | None) -> float:
    """Sum GB_AMT for given accounts at period-end (BS running balance)."""
    where = [f"g.GB_DATE = {period}", f"RTRIM(g.GB_GLA) IN ({','.join('?' for _ in accts)})"]
    if branch:
        where.append(f"RIGHT(RTRIM(g.GB_GLC),2) = '{branch}'")
    _, rows = fetch(
        f"SELECT SUM(g.GB_AMT) FROM dbo.GLCAL g WHERE {' AND '.join(where)}",
        tuple(accts),
    )
    return float(rows[0][0] or 0)


def yearly_activity(year: int, accts: list[str], branch: str | None) -> float:
    """Sum GB_AMT across all months of year for P&L accounts."""
    where = [f"g.GB_DATE BETWEEN {year*100+1} AND {year*100+12}",
             f"RTRIM(g.GB_GLA) IN ({','.join('?' for _ in accts)})"]
    if branch:
        where.append(f"RIGHT(RTRIM(g.GB_GLC),2) = '{branch}'")
    _, rows = fetch(
        f"SELECT SUM(g.GB_AMT) FROM dbo.GLCAL g WHERE {' AND '.join(where)}",
        tuple(accts),
    )
    return float(rows[0][0] or 0)


def ytd_ni(year: int, branch: str | None) -> float:
    where = ["am.ACTYP IN ('2','3')", f"g.GB_DATE BETWEEN {year*100+1} AND {year*100+12}"]
    if branch:
        where.append(f"RIGHT(RTRIM(g.GB_GLC),2) = '{branch}'")
    _, rows = fetch(f"""
        SELECT SUM(g.GB_AMT) FROM dbo.GLCAL g
        JOIN dbo.ACCMAST am ON RTRIM(am.ACACC) = RTRIM(g.GB_GLA)
        WHERE {' AND '.join(where)}
    """)
    return -float(rows[0][0] or 0)


def build_pdf(year: int, branch: str | None, output_path: str) -> str:
    eoy_period = year * 100 + 12
    boy_period = (year - 1) * 100 + 12

    doc = make_doc(output_path, title="Crystal Tractor — Cash Flow")
    elements: list = []
    branch_label = f" · Branch {branch}" if branch else " · Consolidated"
    elements += [
        Paragraph("Crystal Tractor — Consolidated Statement of Cash Flows", H1),
        Paragraph(f"Fiscal Year {year} · Indirect Method{branch_label}", SUB),
        Paragraph(f"Generated {now_str()} · Source: dbo.GLCAL", SMALL),
        Spacer(1, 0.15 * inch),
    ]

    ni = ytd_ni(year, branch)
    da = -yearly_activity(year, DA_ACCTS, branch)  # expense → positive cash add-back

    # OPERATING
    elements.append(Paragraph("CASH FROM OPERATING ACTIVITIES", H2))
    op_rows = [
        ["Net Income", fmt_money(ni)],
        ["Adjustments to reconcile NI to cash from ops:", ""],
        ["  Depreciation & Amortization (non-cash)", fmt_money(da)],
        ["Changes in Working Capital:", ""],
    ]
    op_total = ni + da
    for label, accts in WC_GROUPS:
        boy = balance(boy_period, accts, branch)
        eoy = balance(eoy_period, accts, branch)
        # For assets (positive balances): increase = cash use (negative)
        # For liabs (negative balances): increase in abs = cash source (positive)
        # Use signed delta with sign convention: delta of GLCAL balance
        # Assets: delta in (raw signed) = positive if asset grew → cash use → flip sign
        # Liabs: delta in raw = negative if liab grew → cash source → flip sign
        # Net effect: cash impact = -delta (works for both since raw signs encode direction)
        delta = eoy - boy
        cash_impact = -delta
        op_rows.append([f"  {label}", fmt_money(cash_impact)])
        op_total += cash_impact
    op_rows.append(["Cash from Operating Activities", fmt_money(op_total)])

    t = themed_table(op_rows, [4.5*inch, 1.5*inch], right_align_cols=[1],
                     has_header=False, font_size=9.5)
    t.setStyle(TableStyle([
        ("FONTNAME", (0, -1), (-1, -1), "Helvetica-Bold"),
        ("LINEABOVE", (0, -1), (-1, -1), 0.5, BRAND_BLUE),
        ("BACKGROUND", (0, -1), (-1, -1), BAND_GRAY),
    ]))
    elements.append(t)

    # INVESTING
    elements.append(Spacer(1, 0.1*inch))
    elements.append(Paragraph("CASH FROM INVESTING ACTIVITIES", H2))
    inv_rows = []
    inv_total = 0.0
    for label, accts in INVESTING_GROUPS:
        delta = balance(eoy_period, accts, branch) - balance(boy_period, accts, branch)
        cash_impact = -delta
        inv_rows.append([f"  {label}", fmt_money(cash_impact)])
        inv_total += cash_impact
    inv_rows.append(["Cash used in Investing", fmt_money(inv_total)])
    t = themed_table(inv_rows, [4.5*inch, 1.5*inch], right_align_cols=[1],
                     has_header=False, font_size=9.5)
    t.setStyle(TableStyle([
        ("FONTNAME", (0, -1), (-1, -1), "Helvetica-Bold"),
        ("LINEABOVE", (0, -1), (-1, -1), 0.5, BRAND_BLUE),
        ("BACKGROUND", (0, -1), (-1, -1), BAND_GRAY),
    ]))
    elements.append(t)

    # FINANCING
    elements.append(Spacer(1, 0.1*inch))
    elements.append(Paragraph("CASH FROM FINANCING ACTIVITIES", H2))
    fin_rows = []
    fin_total = 0.0
    for label, accts in FINANCING_GROUPS:
        delta = balance(eoy_period, accts, branch) - balance(boy_period, accts, branch)
        cash_impact = -delta
        fin_rows.append([f"  {label} (net of all activity)", fmt_money(cash_impact)])
        fin_total += cash_impact
    fin_rows.append(["Cash from Financing", fmt_money(fin_total)])
    t = themed_table(fin_rows, [4.5*inch, 1.5*inch], right_align_cols=[1],
                     has_header=False, font_size=9.5)
    t.setStyle(TableStyle([
        ("FONTNAME", (0, -1), (-1, -1), "Helvetica-Bold"),
        ("LINEABOVE", (0, -1), (-1, -1), 0.5, BRAND_BLUE),
        ("BACKGROUND", (0, -1), (-1, -1), BAND_GRAY),
    ]))
    elements.append(t)

    # RECONCILIATION
    elements.append(Spacer(1, 0.15*inch))
    net_per_cf = op_total + inv_total + fin_total
    begin_cash = balance(boy_period, CASH_ACCTS, branch)
    end_cash = balance(eoy_period, CASH_ACCTS, branch)
    actual_change = end_cash - begin_cash
    residual = actual_change - net_per_cf

    rec_rows = [
        ["NET CHANGE IN CASH (per cash flow)", fmt_money(net_per_cf)],
        [f"  Beginning Cash ({year-1}-12)", fmt_money(begin_cash)],
        [f"  Ending Cash ({year}-12)", fmt_money(end_cash)],
        ["  Actual Δ Cash from balance sheet", fmt_money(actual_change)],
        ["  Reconciliation residual (DISCUSS)", fmt_money(residual)],
    ]
    t = themed_table(rec_rows, [4.5*inch, 1.5*inch], right_align_cols=[1],
                     has_header=False, font_size=10)
    t.setStyle(TableStyle([
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ("BACKGROUND", (0, 0), (-1, 0), BRAND_BLUE),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
    ]))
    elements.append(t)

    elements.append(Spacer(1, 0.15*inch))
    elements.append(Paragraph(
        f"Per CFO v2 feedback: Gain/loss on sale of assets removed from this report (manual reconciliation only). "
        f"Financing-section lines presented as net-of-all-activity. Retained Earnings line shown net of {year} NI "
        f"(NI is in Operating). DISCUSS: any reconciliation residual reflects intercompany-transfer sign convention "
        f"and partial year-end close — see docs/cfo-feedback-2026-05-28.md action 3.4.",
        SMALL))

    doc.build(elements)
    return output_path


def main():
    ap = argparse.ArgumentParser(description="Crystal Tractor Cash Flow Statement")
    ap.add_argument("--year", type=int, default=date.today().year - 1)
    ap.add_argument("--branch", type=str, default=None)
    ap.add_argument("--output", type=str, default=None)
    args = ap.parse_args()
    if args.output is None:
        tag = str(args.year) + (f"-br{args.branch}" if args.branch else "")
        out = Path.home() / "Downloads" / f"Crystal-Cash-Flow-{tag}.pdf"
    else:
        out = Path(args.output)
    path = build_pdf(args.year, args.branch, str(out))
    print(f"Wrote: {path}")


if __name__ == "__main__":
    main()
