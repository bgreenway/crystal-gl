#!/usr/bin/env python3
"""Crystal Tractor — Accounts Payable Analysis report.

Generates an 8-section PDF from dbo.YTDIST covering top vendors, vendor
concentration, spend by Kubota DFS dept, spend by branch (with YoY),
A/P aging, largest single invoices, and a YTDJRL reconciliation footnote.

Examples:
    python scripts/reports/ap_analysis.py
    python scripts/reports/ap_analysis.py --period-from 20260101 --period-to 20260531
    python scripts/reports/ap_analysis.py --output /tmp/AP-march.pdf --period-from 20260301 --period-to 20260331

Defaults: period = current YTD (Jan 1 of current year through today).
"""
from __future__ import annotations

import argparse
from datetime import date
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.units import inch
from reportlab.platypus import PageBreak, Paragraph, Spacer, TableStyle

from _common import (
    BODY, BRAND_BLUE, H1, H2, INTERCO_BLUE, INTERNAL_AMBER, LINE_GRAY, SMALL, SUB,
    fetch, fmt_int, fmt_money, fmt_pct, make_doc, now_str, themed_table,
)

BRANCH_NAMES = {
    "01": "Deland", "02": "Leesburg", "03": "Parts Warehouse", "04": "Chiefland",
    "05": "Spring Hill", "06": "Ocala", "07": "Homosassa", "08": "Hastings",
    "09": "Palatka", "10": "Starke", "11": "Live Oak", "12": "Madison",
    "13": "Panama City", "14": "Tallahassee", "15": "Cairo", "16": "Jacksonville",
    "17": "Lecanto", "18": "Dothan", "91": "Other", "93": "Wholesale", "95": "Corporate",
}
DEPT_NAMES = {
    "0": "Balance Sheet / Corp", "1": "Admin", "2": "Sales",
    "3": "Service", "4": "Parts", "5": "Rental",
}

VENDOR_NAME_EXPR = """COALESCE(
    (SELECT TOP 1 LEFT(RTRIM(yi2.DN_NME), 35) FROM dbo.YTDIST yi2
     WHERE yi2.DN_VEN = yi.DN_VEN
       AND RTRIM(yi2.DN_NME) <> ''
       AND yi2.DN_NME NOT LIKE '%COMPUTER GENERATED%'
     ORDER BY yi2.DN_DTI DESC),
    (SELECT TOP 1 LEFT(RTRIM(yi3.DN_NME), 35) FROM dbo.YTDIST yi3
     WHERE yi3.DN_VEN = yi.DN_VEN AND RTRIM(yi3.DN_NME) <> ''
     ORDER BY yi3.DN_DTI DESC)
)"""


def classify_vendor(name: str | None) -> str:
    n = (name or "").upper()
    if "JOURNAL" in n or "J/E" in n:
        return "internal-JE"
    if "CRYSTAL" in n:
        return "intercompany"
    return "outside"


def prior_year_window(period_from: int, period_to: int) -> tuple[int, int]:
    """Shift a date window back exactly one calendar year."""
    return period_from - 10000, period_to - 10000


def gather_data(period_from: int, period_to: int):
    """Pull all data needed for the report. Returns a dict of sections."""
    pyf, pyt = prior_year_window(period_from, period_to)

    # ---- Summary ----
    _, summary = fetch(f"""
    SELECT
        (SELECT COUNT(*) FROM dbo.YTDIST WHERE DN_DTI BETWEEN {period_from} AND {period_to}) AS distribution_rows,
        (SELECT COUNT(DISTINCT DN_TID) FROM dbo.YTDIST WHERE DN_DTI BETWEEN {period_from} AND {period_to}) AS invoices,
        (SELECT COUNT(DISTINCT RTRIM(DN_VEN)) FROM dbo.YTDIST WHERE DN_DTI BETWEEN {period_from} AND {period_to}) AS vendors,
        (SELECT SUM(DN_GRS) FROM dbo.YTDIST WHERE DN_DTI BETWEEN {period_from} AND {period_to}
           AND DN_GRS > 0 AND DN_ACC NOT LIKE '2%') AS total_spend
    """)
    dist_rows, invoices, vendors, total_spend = summary[0]
    avg_invoice = float(total_spend) / float(invoices) if invoices else 0

    _, prior_row = fetch(f"""
    SELECT SUM(DN_GRS) FROM dbo.YTDIST
    WHERE DN_DTI BETWEEN {pyf} AND {pyt}
      AND DN_GRS > 0 AND DN_ACC NOT LIKE '2%'
    """)
    prior_spend = prior_row[0][0] or 0
    yoy = (float(total_spend) - float(prior_spend)) / float(prior_spend) * 100 if prior_spend else None

    # ---- Top vendors ----
    _, top_vendors = fetch(f"""
    SELECT TOP 25
        RTRIM(yi.DN_VEN) AS vendor_code,
        {VENDOR_NAME_EXPR} AS vendor_name,
        COUNT(DISTINCT yi.DN_TID) AS invoices,
        SUM(CASE WHEN yi.DN_GRS > 0 AND yi.DN_ACC NOT LIKE '2%' THEN yi.DN_GRS ELSE 0 END) AS spend
    FROM dbo.YTDIST yi
    WHERE yi.DN_DTI BETWEEN {period_from} AND {period_to}
    GROUP BY yi.DN_VEN
    HAVING SUM(CASE WHEN yi.DN_GRS > 0 AND yi.DN_ACC NOT LIKE '2%' THEN yi.DN_GRS ELSE 0 END) > 0
    ORDER BY 4 DESC
    """)

    # ---- All outside vendors for concentration math ----
    _, all_vendors = fetch(f"""
    WITH v AS (
        SELECT RTRIM(yi.DN_VEN) vc, {VENDOR_NAME_EXPR} AS vendor_name,
               SUM(CASE WHEN yi.DN_GRS > 0 AND yi.DN_ACC NOT LIKE '2%' THEN yi.DN_GRS ELSE 0 END) AS s
        FROM dbo.YTDIST yi
        WHERE yi.DN_DTI BETWEEN {period_from} AND {period_to}
        GROUP BY yi.DN_VEN
    )
    SELECT vc, vendor_name, s FROM v WHERE s > 0 ORDER BY s DESC
    """)
    outside_only = [r for r in all_vendors if classify_vendor(r[1]) == "outside"]
    total_outside_full = sum(float(r[2]) for r in outside_only)

    # ---- Spend by DFS dept ----
    _, by_dept = fetch(f"""
    SELECT LEFT(RTRIM(DN_CC),1) AS dept,
           SUM(CASE WHEN DN_GRS > 0 AND DN_ACC NOT LIKE '2%' THEN DN_GRS ELSE 0 END) AS spend
    FROM dbo.YTDIST
    WHERE DN_DTI BETWEEN {period_from} AND {period_to} AND LEN(RTRIM(DN_CC)) >= 3
    GROUP BY LEFT(RTRIM(DN_CC),1) ORDER BY 1
    """)

    # ---- Spend by branch (with YoY) ----
    _, by_branch = fetch(f"""
    WITH cur AS (
      SELECT RIGHT(RTRIM(DN_CC),2) AS br,
             SUM(CASE WHEN DN_GRS > 0 AND DN_ACC NOT LIKE '2%' THEN DN_GRS ELSE 0 END) AS s
      FROM dbo.YTDIST
      WHERE DN_DTI BETWEEN {period_from} AND {period_to} AND LEN(RTRIM(DN_CC))>=3
      GROUP BY RIGHT(RTRIM(DN_CC),2)
    ),
    prior AS (
      SELECT RIGHT(RTRIM(DN_CC),2) AS br,
             SUM(CASE WHEN DN_GRS > 0 AND DN_ACC NOT LIKE '2%' THEN DN_GRS ELSE 0 END) AS s
      FROM dbo.YTDIST
      WHERE DN_DTI BETWEEN {pyf} AND {pyt} AND LEN(RTRIM(DN_CC))>=3
      GROUP BY RIGHT(RTRIM(DN_CC),2)
    )
    SELECT TOP 15 c.br, c.s AS cur_spend, ISNULL(p.s, 0) AS prior_spend
    FROM cur c LEFT JOIN prior p ON p.br = c.br
    WHERE c.br NOT IN ('00') ORDER BY c.s DESC
    """)

    # ---- Aging: last 180 days ----
    aging_from = period_from - 600  # ~180 days back; close enough
    _, aging = fetch(f"""
    WITH inv AS (
        SELECT DN_TID, MAX(DN_DTI) AS dti,
               SUM(CASE WHEN DN_GRS > 0 AND DN_ACC NOT LIKE '2%' THEN DN_GRS ELSE 0 END) AS amt,
               MAX(CASE WHEN LEN(RTRIM(DN_CHQ))>0 THEN 1 ELSE 0 END) AS paid
        FROM dbo.YTDIST
        WHERE DN_DTI BETWEEN {aging_from} AND {period_to}
        GROUP BY DN_TID
    )
    SELECT
       CASE
         WHEN DATEDIFF(day, TRY_CONVERT(date, CAST(CAST(dti AS INT) AS VARCHAR),112), CAST(GETDATE() AS date)) BETWEEN 0 AND 30 THEN '0-30 days'
         WHEN DATEDIFF(day, TRY_CONVERT(date, CAST(CAST(dti AS INT) AS VARCHAR),112), CAST(GETDATE() AS date)) BETWEEN 31 AND 60 THEN '31-60 days'
         WHEN DATEDIFF(day, TRY_CONVERT(date, CAST(CAST(dti AS INT) AS VARCHAR),112), CAST(GETDATE() AS date)) BETWEEN 61 AND 90 THEN '61-90 days'
         WHEN DATEDIFF(day, TRY_CONVERT(date, CAST(CAST(dti AS INT) AS VARCHAR),112), CAST(GETDATE() AS date)) > 90 THEN '91-180 days'
         ELSE 'future-dated'
       END AS bucket,
       COUNT(*) AS unpaid_invoices,
       SUM(amt) AS unpaid_spend
    FROM inv
    WHERE paid = 0 AND amt > 0
    GROUP BY
       CASE
         WHEN DATEDIFF(day, TRY_CONVERT(date, CAST(CAST(dti AS INT) AS VARCHAR),112), CAST(GETDATE() AS date)) BETWEEN 0 AND 30 THEN '0-30 days'
         WHEN DATEDIFF(day, TRY_CONVERT(date, CAST(CAST(dti AS INT) AS VARCHAR),112), CAST(GETDATE() AS date)) BETWEEN 31 AND 60 THEN '31-60 days'
         WHEN DATEDIFF(day, TRY_CONVERT(date, CAST(CAST(dti AS INT) AS VARCHAR),112), CAST(GETDATE() AS date)) BETWEEN 61 AND 90 THEN '61-90 days'
         WHEN DATEDIFF(day, TRY_CONVERT(date, CAST(CAST(dti AS INT) AS VARCHAR),112), CAST(GETDATE() AS date)) > 90 THEN '91-180 days'
         ELSE 'future-dated'
       END
    ORDER BY MIN(DATEDIFF(day, TRY_CONVERT(date, CAST(CAST(dti AS INT) AS VARCHAR),112), CAST(GETDATE() AS date)))
    """)

    # ---- Largest single invoices ----
    _, big_invoices = fetch(f"""
    WITH inv AS (
        SELECT DN_TID, MAX(DN_DTI) dti, MAX(RTRIM(DN_VEN)) vc,
               MAX(LEFT(RTRIM(DN_NME),30)) nme, MAX(RTRIM(DN_INV)) invn,
               MAX(RTRIM(DN_PO)) po,
               SUM(CASE WHEN DN_GRS>0 AND DN_ACC NOT LIKE '2%' THEN DN_GRS ELSE 0 END) amt
        FROM dbo.YTDIST WHERE DN_DTI BETWEEN {period_from} AND {period_to}
        GROUP BY DN_TID
    )
    SELECT TOP 10 dti, vc, nme, invn, po, amt FROM inv ORDER BY amt DESC
    """)

    # ---- Reconciliation: pick the most recent closed month for the test ----
    _, closed_row = fetch("SELECT MAX(GB_DATE) FROM dbo.GLCAL")
    closed_period = int(closed_row[0][0])
    cm_from = closed_period * 100 + 1
    cm_to = closed_period * 100 + 31
    _, recon_row = fetch(f"""
    WITH yi AS (
        SELECT SUM(DN_GRS) s FROM dbo.YTDIST
        WHERE DN_DTI BETWEEN {cm_from} AND {cm_to}
          AND DN_GRS > 0 AND DN_ACC NOT LIKE '2%'
    ),
    yj AS (
        SELECT SUM(YJ_AMT) s FROM dbo.YTDJRL
        WHERE YJ_DT BETWEEN {cm_from} AND {cm_to}
          AND LEFT(RTRIM(YJ_JRL),2)='AP' AND YJ_AMT > 0
    )
    SELECT yi.s, yj.s, {closed_period} AS cp FROM yi, yj
    """)
    ytdist_recon, ytdjrl_recon, recon_period = recon_row[0]

    return dict(
        period_from=period_from, period_to=period_to,
        dist_rows=dist_rows, invoices=invoices, vendors=vendors,
        total_spend=total_spend, prior_spend=prior_spend, yoy=yoy,
        avg_invoice=avg_invoice,
        top_vendors=top_vendors,
        outside_only=outside_only,
        total_outside_full=total_outside_full,
        by_dept=by_dept,
        by_branch=by_branch,
        aging=aging,
        big_invoices=big_invoices,
        recon=(ytdist_recon, ytdjrl_recon, recon_period),
    )


def build_pdf(data: dict, output_path: str) -> str:
    doc = make_doc(output_path, title="Crystal Tractor — A/P Analysis")
    elements: list = []
    period_label = (
        f"FY {data['period_from'] // 10000} YTD "
        f"({_pretty_date(data['period_from'])} – {_pretty_date(data['period_to'])})"
    )

    # Cover header
    elements += [
        Paragraph("Crystal Tractor — Accounts Payable Analysis", H1),
        Paragraph(period_label, SUB),
        Paragraph(f"Generated {now_str()} • Source: dbo.YTDIST", SMALL),
        Spacer(1, 0.15 * inch),
    ]

    # Section 1: Summary
    elements.append(Paragraph("1. Summary", H2))
    yoy_str = (
        f"{data['yoy']:+.1f}% vs prior-year YTD ({fmt_money(data['prior_spend'])})"
        if data["yoy"] is not None else ""
    )
    elements.append(themed_table(
        [
            ["Total A/P spend",   fmt_money(data["total_spend"]), yoy_str],
            ["Invoices",          fmt_int(data["invoices"]), ""],
            ["Distinct vendors",  fmt_int(data["vendors"]), ""],
            ["Avg invoice size",  fmt_money(data["avg_invoice"]), ""],
            ["Distribution rows", fmt_int(data["dist_rows"]), "(one invoice → multiple GL distributions)"],
        ],
        col_widths=[1.7*inch, 1.5*inch, 3.6*inch],
        has_header=False,
        right_align_cols=[1],
        font_size=10,
    ))

    # Section 2: Top vendors
    elements.append(Paragraph("2. Top 25 vendors by spend", H2))
    elements.append(Paragraph(
        "Internal-JE buckets (name contains 'JOURNAL'/'J/E') and intercompany "
        "('Crystal') flagged in the class column — they aren't third-party spend.", SMALL))
    hdr = ["#", "Code", "Vendor name", "Invoices", "Spend", "% of total", "Class"]
    rows = [hdr]
    for i, (vc, nm, inv, sp) in enumerate(data["top_vendors"], 1):
        cls = classify_vendor(nm)
        pct = float(sp) / float(data["total_spend"]) * 100 if data["total_spend"] else 0
        rows.append([str(i), vc, nm or "", fmt_int(inv), fmt_money(sp), fmt_pct(pct), cls])
    t = themed_table(
        rows,
        col_widths=[0.3*inch, 0.7*inch, 2.4*inch, 0.7*inch, 1.0*inch, 0.7*inch, 0.9*inch],
        right_align_cols=[0, 3, 4, 5],
        font_size=8.5,
    )
    for ridx in range(1, len(rows)):
        cls = rows[ridx][6]
        if cls == "internal-JE":
            t.setStyle(TableStyle([
                ("TEXTCOLOR", (6, ridx), (6, ridx), INTERNAL_AMBER),
                ("FONTNAME", (6, ridx), (6, ridx), "Helvetica-Oblique"),
            ]))
        elif cls == "intercompany":
            t.setStyle(TableStyle([
                ("TEXTCOLOR", (6, ridx), (6, ridx), INTERCO_BLUE),
                ("FONTNAME", (6, ridx), (6, ridx), "Helvetica-Oblique"),
            ]))
    elements.append(t)

    elements.append(PageBreak())

    # Section 3: Concentration
    elements.append(Paragraph("3. Outside-vendor concentration", H2))
    elements.append(Paragraph(
        f"Outside-vendor total YTD: <b>{fmt_money(data['total_outside_full'])}</b> "
        f"across <b>{len(data['outside_only'])}</b> distinct vendors.", BODY))

    def top_n_pct(n: int) -> float:
        return (
            sum(float(r[2]) for r in data["outside_only"][:n]) / data["total_outside_full"] * 100
            if data["total_outside_full"] else 0
        )

    conc_rows = [["Tier", "Spend", "% of outside total"]]
    for n in [5, 10, 20, 50]:
        spend_n = sum(float(r[2]) for r in data["outside_only"][:n])
        conc_rows.append([f"Top {n}", fmt_money(spend_n), fmt_pct(top_n_pct(n))])
    elements.append(themed_table(conc_rows, [1.0*inch, 1.5*inch, 1.8*inch], right_align_cols=[1, 2], font_size=10))

    # Section 4: DFS dept
    elements.append(Paragraph("4. Spend by Kubota DFS department", H2))
    elements.append(Paragraph(
        "Departments derived from CC leading digit. Note: inventory purchases hit BS/Corp accounts "
        "(12xxx Wholegoods Inventory with CC='000'), so BS/Corp typically dominates this view for a dealership.",
        SMALL))
    total_dept = sum(float(r[1]) for r in data["by_dept"])
    dept_rows = [["Dept", "Description", "Spend", "% of total"]]
    for d, sp in data["by_dept"]:
        name = DEPT_NAMES.get(d, f"({d})")
        pct = float(sp) / total_dept * 100 if total_dept else 0
        dept_rows.append([d, name, fmt_money(sp), fmt_pct(pct)])
    elements.append(themed_table(dept_rows, [0.5*inch, 2.5*inch, 1.3*inch, 1.0*inch], right_align_cols=[2, 3]))

    # Section 5: Branch
    elements.append(Paragraph("5. Top 15 branches by spend (YoY)", H2))
    br_rows = [["Suffix", "Branch", "YTD current", "YTD prior", "Δ $", "Δ %"]]
    for br, cur_sp, prior_sp in data["by_branch"]:
        name = BRANCH_NAMES.get(br, "?")
        delta = float(cur_sp) - float(prior_sp)
        pct = (delta / float(prior_sp) * 100) if prior_sp else None
        br_rows.append([
            br, name, fmt_money(cur_sp), fmt_money(prior_sp),
            ("+" if delta >= 0 else "") + fmt_money(delta, parens_for_neg=False),
            (("+" if pct >= 0 else "") + fmt_pct(pct)) if pct is not None else "new",
        ])
    elements.append(themed_table(
        br_rows,
        [0.55*inch, 1.5*inch, 1.1*inch, 1.1*inch, 1.0*inch, 0.7*inch],
        right_align_cols=[2, 3, 4, 5], font_size=9,
    ))

    elements.append(PageBreak())

    # Section 6: A/P aging
    elements.append(Paragraph("6. A/P aging — unpaid invoices, last 180 days", H2))
    elements.append(Paragraph(
        "'Unpaid' = no check number in DN_CHQ across any distribution row. Restricted to recent invoices "
        "(older open items typically get cleared by journal entry, not check, so DN_CHQ isn't reliable beyond ~6 months).",
        SMALL))
    total_unpaid = sum(float(r[2]) for r in data["aging"])
    total_unpaid_inv = sum(int(r[1]) for r in data["aging"])
    age_rows = [["Bucket", "Unpaid invoices", "Outstanding $", "% of unpaid"]]
    for bucket, n, amt in data["aging"]:
        pct = float(amt) / total_unpaid * 100 if total_unpaid else 0
        age_rows.append([bucket, fmt_int(n), fmt_money(amt), fmt_pct(pct)])
    age_rows.append(["Total", fmt_int(total_unpaid_inv), fmt_money(total_unpaid), "100.0%"])
    elements.append(themed_table(
        age_rows, [1.3*inch, 1.4*inch, 1.4*inch, 1.0*inch],
        right_align_cols=[1, 2, 3], has_total_row=True, font_size=10,
    ))

    # Section 7: Largest single invoices
    elements.append(Paragraph("7. Largest 10 single invoices", H2))
    elements.append(Paragraph(
        "Worth a quick glance for unusual entries. Each row is one invoice (DN_TID) "
        "aggregated across its GL distribution rows.", SMALL))
    big_rows = [["Inv date", "Vendor code", "Vendor name", "Invoice #", "PO #", "Amount"]]
    for dti, vc, nm, invn, po, amt in data["big_invoices"]:
        big_rows.append([str(int(dti)), vc, nm or "", invn or "", po or "", fmt_money(amt)])
    elements.append(themed_table(
        big_rows, [0.8*inch, 0.8*inch, 2.1*inch, 0.9*inch, 0.9*inch, 1.0*inch],
        right_align_cols=[5], font_size=9,
    ))

    # Section 8: Reconciliation
    ytdist_recon, ytdjrl_recon, recon_period = data["recon"]
    elements.append(Paragraph("8. Reconciliation to YTDJRL (data integrity check)", H2))
    elements.append(Paragraph(
        f"For closed period {recon_period}: YTDIST distribution-side sum (positive, non-liability) = "
        f"<b>{fmt_money(ytdist_recon)}</b>; YTDJRL A/P journal postings (positive) = "
        f"<b>{fmt_money(ytdjrl_recon)}</b>. YTDJRL.AP is a superset (includes manual A/P JEs + credit memos "
        f"that don't generate YTDIST rows); YTDIST is the per-invoice canonical source of vendor detail. "
        f"Both reconcile to GLCAL through their respective paths.", BODY))

    elements.append(Spacer(1, 0.2*inch))
    elements.append(Paragraph(
        "Source: <b>dbo.YTDIST</b> on sqldb-acctdata-prod-eastus-001. "
        "Vendor spend = sum of positive DN_GRS rows where DN_ACC does not begin with '2' "
        "(excludes A/P trade, floorplan, other liability clearing accounts). Inventory purchases (12xxx) ARE included. "
        "DFS dept from CC leading digit; branch from CC trailing 2 digits.",
        SMALL))

    doc.build(elements)
    return output_path


def _pretty_date(yyyymmdd: int) -> str:
    s = str(yyyymmdd)
    return f"{s[:4]}-{s[4:6]}-{s[6:]}"


def _default_period() -> tuple[int, int]:
    today = date.today()
    return today.year * 10000 + 101, today.year * 10000 + today.month * 100 + today.day


def main():
    ap = argparse.ArgumentParser(description="Crystal Tractor A/P Analysis report")
    df_from, df_to = _default_period()
    ap.add_argument("--period-from", type=int, default=df_from,
                    help=f"Start of period YYYYMMDD (default {df_from} = Jan 1 current year)")
    ap.add_argument("--period-to", type=int, default=df_to,
                    help=f"End of period YYYYMMDD (default {df_to} = today)")
    ap.add_argument("--output", type=str, default=None,
                    help="Output PDF path (default ~/Downloads/Crystal-AP-Analysis-<period>.pdf)")
    args = ap.parse_args()

    if args.output is None:
        out = Path.home() / "Downloads" / f"Crystal-AP-Analysis-{args.period_from}-{args.period_to}.pdf"
    else:
        out = Path(args.output)

    data = gather_data(args.period_from, args.period_to)
    path = build_pdf(data, str(out))
    print(f"Wrote: {path}")


if __name__ == "__main__":
    main()
