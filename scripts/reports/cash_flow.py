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
    bs_balance_through, fetch, fmt_money, make_doc, now_str,
    pnl_activity_through, themed_table, validate_branch, ytd_ni_through,
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


def balance(period: int | None, accts: list[str], branch: str | None, *,
            through: int | None = None) -> float:
    """Sum balance for given accounts at a date.

    through given (YYYYMMDD) → GLCAL last-closed + YTDJRL roll-forward.
    period given (YYYYMM) → GLCAL period-end snapshot.
    both None → live snapshot via COACMAST.CA_CUR.
    """
    branch = validate_branch(branch)
    if through is not None:
        from _common import last_closed_period_on_or_before
        anchor = last_closed_period_on_or_before(through)
        anchor_eom = anchor * 100 + 31
        branch_glcal = f"AND RIGHT(RTRIM(g.GB_GLC),2) = '{branch}'" if branch else ""
        branch_yj = f"AND RIGHT(RTRIM(y.YJ_CC),2) = '{branch}'" if branch else ""
        in_clause = ",".join("?" for _ in accts)
        _, rows = fetch(f"""
        SELECT
          ISNULL((SELECT SUM(g.GB_AMT) FROM dbo.GLCAL g
                  WHERE g.GB_DATE = {anchor} AND RTRIM(g.GB_GLA) IN ({in_clause})
                        {branch_glcal}), 0)
        + ISNULL((SELECT SUM(y.YJ_AMT) FROM dbo.YTDJRL y
                  WHERE y.YJ_DT > {anchor_eom} AND y.YJ_DT <= {through}
                        AND RTRIM(y.YJ_ACC) IN ({in_clause})
                        {branch_yj}), 0) AS bal
        """, tuple(accts) + tuple(accts))
        return float(rows[0][0] or 0)

    if period is None:
        where = [f"RTRIM(c.CA_ACC) IN ({','.join('?' for _ in accts)})"]
        if branch:
            where.append(f"RIGHT(RTRIM(c.CA_CC),2) = '{branch}'")
        _, rows = fetch(
            f"SELECT SUM(c.CA_CUR) FROM dbo.COACMAST c WHERE {' AND '.join(where)}",
            tuple(accts),
        )
        return float(rows[0][0] or 0)

    where = [f"g.GB_DATE = {period}", f"RTRIM(g.GB_GLA) IN ({','.join('?' for _ in accts)})"]
    if branch:
        where.append(f"RIGHT(RTRIM(g.GB_GLC),2) = '{branch}'")
    _, rows = fetch(
        f"SELECT SUM(g.GB_AMT) FROM dbo.GLCAL g WHERE {' AND '.join(where)}",
        tuple(accts),
    )
    return float(rows[0][0] or 0)


def yearly_activity(year: int, accts: list[str], branch: str | None, *, live: bool = False) -> float:
    """Sum P&L activity for the year. live=True pulls from CA_CUR (includes open periods)."""
    branch = validate_branch(branch)
    if live:
        where = [f"RTRIM(c.CA_ACC) IN ({','.join('?' for _ in accts)})"]
        if branch:
            where.append(f"RIGHT(RTRIM(c.CA_CC),2) = '{branch}'")
        _, rows = fetch(
            f"SELECT SUM(c.CA_CUR) FROM dbo.COACMAST c WHERE {' AND '.join(where)}",
            tuple(accts),
        )
        return float(rows[0][0] or 0)
    where = [f"g.GB_DATE BETWEEN {year*100+1} AND {year*100+12}",
             f"RTRIM(g.GB_GLA) IN ({','.join('?' for _ in accts)})"]
    if branch:
        where.append(f"RIGHT(RTRIM(g.GB_GLC),2) = '{branch}'")
    _, rows = fetch(
        f"SELECT SUM(g.GB_AMT) FROM dbo.GLCAL g WHERE {' AND '.join(where)}",
        tuple(accts),
    )
    return float(rows[0][0] or 0)


def ytd_ni(year: int, branch: str | None, *, live: bool = False) -> float:
    branch = validate_branch(branch)
    if live:
        where = ["am.ACTYP IN ('2','3')"]
        if branch:
            where.append(f"RIGHT(RTRIM(c.CA_CC),2) = '{branch}'")
        _, rows = fetch(f"""
            SELECT SUM(c.CA_CUR) FROM dbo.COACMAST c
            JOIN dbo.ACCMAST am ON RTRIM(am.ACACC) = RTRIM(c.CA_ACC)
            WHERE {' AND '.join(where)}
        """)
        return -float(rows[0][0] or 0)
    where = ["am.ACTYP IN ('2','3')", f"g.GB_DATE BETWEEN {year*100+1} AND {year*100+12}"]
    if branch:
        where.append(f"RIGHT(RTRIM(g.GB_GLC),2) = '{branch}'")
    _, rows = fetch(f"""
        SELECT SUM(g.GB_AMT) FROM dbo.GLCAL g
        JOIN dbo.ACCMAST am ON RTRIM(am.ACACC) = RTRIM(g.GB_GLA)
        WHERE {' AND '.join(where)}
    """)
    return -float(rows[0][0] or 0)


def build_pdf(year: int | None, through: int | None, branch: str | None, output_path: str) -> str:
    from datetime import date as _d
    branch = validate_branch(branch)
    if through is not None:
        eff_year = through // 10000
        eoy_period = None
        boy_period = (eff_year - 1) * 100 + 12
        is_live = False
        s = str(through)
        period_label = f"YTD {eff_year} through {s[:4]}-{s[4:6]}-{s[6:]} (YTDJRL roll-forward)"
        source_label = f"BOY: dbo.GLCAL {eff_year-1}-12 · EOY: dbo.GLCAL last-closed + dbo.YTDJRL through {through}"
    else:
        is_live = year is None or year == _d.today().year
        eff_year = _d.today().year if is_live else year
        eoy_period = None if is_live else eff_year * 100 + 12
        boy_period = (eff_year - 1) * 100 + 12
        period_label = (f"YTD {eff_year} (live, BOY {eff_year-1}-12 from GLCAL → EOY live from CA_CUR)"
                        if is_live else f"Fiscal Year {eff_year}")
        source_label = ("BOY: dbo.GLCAL · EOY: dbo.COACMAST.CA_CUR (live)"
                        if is_live else "dbo.GLCAL (closed periods)")

    doc = make_doc(output_path, title="Crystal Tractor — Cash Flow")
    elements: list = []
    branch_label = f" · Branch {branch}" if branch else " · Consolidated"
    elements += [
        Paragraph("Crystal Tractor — Consolidated Statement of Cash Flows", H1),
        Paragraph(f"{period_label} · Indirect Method{branch_label}", SUB),
        Paragraph(f"Generated {now_str()} · Source: {source_label}", SMALL),
        Spacer(1, 0.15 * inch),
    ]

    # NI + D&A: through → YTDJRL year-start to through date; else live/yearly logic
    if through is not None:
        ni = ytd_ni_through(through, branch)
        # D&A via YTDJRL
        da = -balance(None, DA_ACCTS, branch, through=through) + balance(boy_period, DA_ACCTS, branch)
        # Actually for D&A as expense activity, easier: sum YTDJRL DA postings year-to-through
        _, rows = fetch(f"""
        SELECT ISNULL(SUM(y.YJ_AMT), 0) FROM dbo.YTDJRL y
        WHERE RTRIM(y.YJ_ACC) IN ({','.join('?' for _ in DA_ACCTS)})
          AND y.YJ_DT BETWEEN {eff_year*10000+101} AND {through}
          {f"AND RIGHT(RTRIM(y.YJ_CC),2) = '{branch}'" if branch else ''}
        """, tuple(DA_ACCTS))
        da = -float(rows[0][0] or 0)  # expense in YTDJRL is positive → add-back negate
    else:
        ni = ytd_ni(eff_year, branch, live=is_live)
        da = -yearly_activity(eff_year, DA_ACCTS, branch, live=is_live)

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
        eoy = balance(eoy_period, accts, branch, through=through)
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
        delta = balance(eoy_period, accts, branch, through=through) - balance(boy_period, accts, branch)
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
        delta = balance(eoy_period, accts, branch, through=through) - balance(boy_period, accts, branch)
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
    end_cash = balance(eoy_period, CASH_ACCTS, branch, through=through)
    actual_change = end_cash - begin_cash
    residual = actual_change - net_per_cf

    if through is not None:
        s = str(through)
        end_label = f"{s[:4]}-{s[4:6]}-{s[6:]} (YTDJRL roll-forward)"
    elif is_live:
        end_label = "today (live CA_CUR)"
    else:
        end_label = f"{eff_year}-12"
    rec_rows = [
        ["NET CHANGE IN CASH (per cash flow)", fmt_money(net_per_cf)],
        [f"  Beginning Cash ({eff_year-1}-12)", fmt_money(begin_cash)],
        [f"  Ending Cash ({end_label})", fmt_money(end_cash)],
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
    ap.add_argument("--year", type=int, default=None,
                    help="Fiscal year (default: current year, EOY served live via COACMAST.CA_CUR)")
    ap.add_argument("--through", type=int, default=None,
                    help="YTD through YYYYMMDD via YTDJRL roll-forward")
    ap.add_argument("--branch", type=str, default=None)
    ap.add_argument("--output", type=str, default=None)
    args = ap.parse_args()
    if args.year and args.through:
        ap.error("--year and --through are mutually exclusive")
    if args.output is None:
        if args.through:
            tag = f"through-{args.through}"
        elif args.year:
            tag = str(args.year)
        else:
            tag = f"YTD-{date.today().isoformat()}"
        if args.branch:
            tag += f"-br{args.branch}"
        out = Path.home() / "Downloads" / f"Crystal-Cash-Flow-{tag}.pdf"
    else:
        out = Path(args.output)
    path = build_pdf(args.year, args.through, args.branch, str(out))
    print(f"Wrote: {path}")


if __name__ == "__main__":
    main()
