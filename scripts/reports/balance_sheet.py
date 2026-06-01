#!/usr/bin/env python3
"""Crystal Tractor — Consolidated Balance Sheet.

CFO v2 layout: Cash split into Cash/AR/Other-Current/Intercompany,
PP&E paired with accumulated depreciation, Reserves as its own section,
Related Party Loans (renamed from Notes Payable Other), Intercompany
Liabilities (new section with 24900 CDK System Clearing).

Examples:
    python scripts/reports/balance_sheet.py
    python scripts/reports/balance_sheet.py --period 202512
    python scripts/reports/balance_sheet.py --period 202512 --branch 14
"""
from __future__ import annotations

import argparse
from pathlib import Path

from reportlab.lib.units import inch
from reportlab.platypus import Paragraph, Spacer, TableStyle
from reportlab.lib import colors

from _common import (
    BAND_GRAY, BRAND_BLUE, H1, H2, SMALL, SUB,
    fetch, fmt_money, make_doc, now_str, themed_table,
)

SECTIONS_BS = [
    # ===== ASSETS =====
    ("Cash & Equivalents",       "asset",  ["10100","10110","10113","10114","10140","10150","10151","10160","10170"]),
    ("Accounts Receivable",      "asset",  ["10200","10204","10210","10224","10230","10241","10242","10245","10246"]),
    ("Other Current Assets",     "asset",  ["10301","10311","10400","10401","10402"]),
    ("Intercompany",             "asset",  ["10180","10182"]),
    ("Inventory — Wholegoods",   "asset",  ["12000","12007"]),
    ("Inventory — Parts",        "asset",  ["13000","13900"]),
    ("Work-in-Process",          "asset",  ["14000","14100","14200"]),
    ("Reserves",                 "asset",  ["12100","13010"]),
    ("Property, Plant & Equipment (net)", "asset",
        ["15100","15103","15110","15120","15200","15300","15400","15600","15700","15800","15950","15000","15050",
         "16100","16103","16110","16120","16200","16300","16400","16600","16700","16800","16950"]),
    ("Intangibles & Other",      "asset",  ["17250","17260","17400","17800","17801"]),
    ("Other Assets",             "asset",  ["10205","18000","19000","20150"]),
    # ===== LIABILITIES =====
    ("Floorplan",                "liab",   ["20350"]),
    ("Accounts Payable & Taxes", "liab",   ["20100","20200","20201","20300","20500","20600"]),
    ("Accrued Expenses & Reserves","liab", ["21002","21010","21015","21016","21020","21100","21112","21200","21201","21300"]),
    ("Other Current Liabilities","liab",   ["22000","22110"]),
    ("Related Party Loans",      "liab",   ["24050","24060","24070"]),
    ("Intercompany Liabilities", "liab",   ["24900"]),
    ("Notes Payable — Long-term","liab",   ["25610","25700","25800"]),
    # ===== EQUITY =====
    ("Equity",                   "equity", ["27500","27530","27531","27532","27533","27550","27551","27552","28000","29000"]),
]

ACCT_TO_SECTION_BS: dict[str, str] = {}
for sec, _, accts in SECTIONS_BS:
    for a in accts:
        ACCT_TO_SECTION_BS[a] = sec


def fetch_bs_balances(period: int, branch: str | None):
    """GLCAL.GB_AMT for BS accounts is a running balance — pick the row for the period."""
    where = ["am.ACTYP = '1'", f"g.GB_DATE = {period}"]
    if branch:
        where.append(f"RIGHT(RTRIM(g.GB_GLC),2) = '{branch}'")
    _, rows = fetch(f"""
    SELECT RTRIM(g.GB_GLA) AS acct,
           LEFT(RTRIM(am.ACNME), 40) AS name,
           SUM(g.GB_AMT) AS bal
    FROM dbo.GLCAL g
    JOIN dbo.ACCMAST am ON RTRIM(am.ACACC) = RTRIM(g.GB_GLA)
    WHERE {' AND '.join(where)}
    GROUP BY g.GB_GLA, am.ACNME
    HAVING SUM(g.GB_AMT) <> 0
    """)
    return rows


def fetch_ytd_ni(year: int, branch: str | None) -> float:
    """Year-to-date Net Income — used to roll into RE if 2025 hasn't closed."""
    where = ["am.ACTYP IN ('2','3')", f"g.GB_DATE BETWEEN {year*100+1} AND {year*100+12}"]
    if branch:
        where.append(f"RIGHT(RTRIM(g.GB_GLC),2) = '{branch}'")
    _, rows = fetch(f"""
    SELECT SUM(g.GB_AMT) FROM dbo.GLCAL g
    JOIN dbo.ACCMAST am ON RTRIM(am.ACACC) = RTRIM(g.GB_GLA)
    WHERE {' AND '.join(where)}
    """)
    return -float(rows[0][0] or 0)  # flip sign: net income


def categorize(rows):
    """Assign each (acct, name, amt) to exactly one section. Unknown accounts
    fall through to one of: Other Assets / Other Current Liabilities / Equity
    based on account-number prefix."""
    sections: dict[str, list[tuple[str, str, float]]] = {sec: [] for sec, _, _ in SECTIONS_BS}
    for acct, name, amt in rows:
        amt_f = float(amt)
        sec = ACCT_TO_SECTION_BS.get(acct)
        if sec is not None:
            sections[sec].append((acct, name, amt_f))
            continue
        # Catchall — note the order matters: equity (27/28/29) must be checked
        # BEFORE the broader "starts with 2" liability bucket.
        if acct.startswith(("27", "28", "29")):
            sections.setdefault("Equity", []).append((acct, name, amt_f))
        elif acct.startswith("2"):
            sections.setdefault("Other Current Liabilities", []).append((acct, name, amt_f))
        else:  # 1xxxx — assets
            sections.setdefault("Other Assets", []).append((acct, name, amt_f))
    return sections


def build_pdf(period: int, branch: str | None, sections: dict, ytd_ni: float, output_path: str) -> str:
    doc = make_doc(output_path, title="Crystal Tractor — Balance Sheet")
    elements: list = []
    period_label = f"As of {str(period)[:4]}-{str(period)[4:]} period-end"
    branch_label = f" · Branch {branch}" if branch else " · Consolidated (all entities, divisions, branches)"
    elements += [
        Paragraph("Crystal Tractor — Consolidated Balance Sheet", H1),
        Paragraph(f"{period_label}{branch_label}", SUB),
        Paragraph(f"Generated {now_str()} · Source: dbo.GLCAL (BS-account running balances)", SMALL),
        Spacer(1, 0.15 * inch),
    ]

    asset_total = liab_total = equity_total = 0.0  # all stored in GLCAL sign convention (L,E negative)

    def render_section(sec_name, lines, total_label, total_value, flip_for_display=False):
        if not lines:
            return
        rows = [[sec_name, "", ""]]
        for acct, name, amt in sorted(lines, key=lambda r: -abs(r[2])):
            disp = -amt if flip_for_display else amt
            rows.append([f"  {acct}", name, fmt_money(disp)])
        disp_total = -total_value if flip_for_display else total_value
        rows.append([f"  {total_label}", "", fmt_money(disp_total)])
        t = themed_table(rows, [0.9*inch, 4.0*inch, 1.2*inch], right_align_cols=[2],
                         has_header=False, font_size=9)
        t.setStyle(TableStyle([
            ("FONTNAME",   (0, 0), (-1, 0), "Helvetica-Bold"),
            ("BACKGROUND", (0, 0), (-1, 0), BRAND_BLUE),
            ("TEXTCOLOR",  (0, 0), (-1, 0), colors.white),
            ("FONTNAME",   (0, -1), (-1, -1), "Helvetica-Bold"),
            ("BACKGROUND", (0, -1), (-1, -1), BAND_GRAY),
        ]))
        elements.append(t)
        elements.append(Spacer(1, 0.04*inch))

    # ASSETS
    elements.append(Paragraph("ASSETS", H2))
    for sec_name, kind, _ in SECTIONS_BS:
        if kind != "asset":
            continue
        lines = sections.get(sec_name, [])
        sec_total = sum(l[2] for l in lines)
        asset_total += sec_total
        render_section(sec_name, lines, f"Total {sec_name}", sec_total)
    elements.append(themed_table(
        [["TOTAL ASSETS", "", fmt_money(asset_total)]],
        [4.9*inch, 0.1*inch, 1.2*inch], right_align_cols=[2], has_header=False, font_size=11,
    ))

    # LIABILITIES (flip signs for display — GLCAL stores as credit balances)
    elements.append(Spacer(1, 0.1*inch))
    elements.append(Paragraph("LIABILITIES", H2))
    for sec_name, kind, _ in SECTIONS_BS:
        if kind != "liab":
            continue
        lines = sections.get(sec_name, [])
        sec_total = sum(l[2] for l in lines)
        liab_total += sec_total
        render_section(sec_name, lines, f"Total {sec_name}", sec_total, flip_for_display=True)
    elements.append(themed_table(
        [["TOTAL LIABILITIES", "", fmt_money(-liab_total)]],
        [4.9*inch, 0.1*inch, 1.2*inch], right_align_cols=[2], has_header=False, font_size=11,
    ))

    # EQUITY (with NI roll-in if needed) — also flip for display
    elements.append(Spacer(1, 0.1*inch))
    elements.append(Paragraph("EQUITY", H2))
    for sec_name, kind, _ in SECTIONS_BS:
        if kind != "equity":
            continue
        lines = sections.get(sec_name, [])
        sec_total = sum(l[2] for l in lines)
        equity_total += sec_total
        render_section(sec_name, lines, f"Total {sec_name}", sec_total, flip_for_display=True)

    # If YTD NI hasn't closed to RE, add it explicitly
    # Pre-close residual = A + L + E in GLCAL sign convention. Add NI (positive)
    # which translates to crediting equity (so equity_total -= ytd_ni in raw sign).
    year = period // 100
    pre_close_residual = asset_total + liab_total + equity_total
    if abs(pre_close_residual) > 1000:
        elements.append(Paragraph(
            f"<b>Net Income {year} (not yet closed to Retained Earnings):</b> {fmt_money(ytd_ni)} — added to Equity for balance.",
            SMALL))
        equity_total -= ytd_ni

    elements.append(themed_table(
        [["TOTAL EQUITY", "", fmt_money(-equity_total)]],
        [4.9*inch, 0.1*inch, 1.2*inch], right_align_cols=[2], has_header=False, font_size=11,
    ))
    elements.append(Spacer(1, 0.1*inch))

    # A = L + E balance check (raw GLCAL signs: should sum to ~0)
    balance = asset_total + liab_total + equity_total
    bal_t = themed_table(
        [["A = L + E balance check", "", fmt_money(balance)]],
        [4.9*inch, 0.1*inch, 1.2*inch], right_align_cols=[2], has_header=False, font_size=10,
    )
    bal_t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), BRAND_BLUE),
        ("TEXTCOLOR",  (0, 0), (-1, -1), colors.white),
        ("FONTNAME",   (0, 0), (-1, -1), "Helvetica-Bold"),
    ]))
    elements.append(bal_t)

    elements.append(Spacer(1, 0.15*inch))
    elements.append(Paragraph(
        "Source: dbo.GLCAL · BS accounts (ACTYP='1') carry period-end running balances; "
        "current-year NI rolled into Equity if year-end close hasn't posted to RE on the source. "
        "v2 CFO section overlay applied (Cash split 4 ways; Reserves pulled into own section; Intercompany Liabilities new; "
        "PP&E grouped with accumulated depreciation). Accounts not in the section map fall through to nearest catchall.",
        SMALL))

    doc.build(elements)
    return output_path


def main():
    ap = argparse.ArgumentParser(description="Crystal Tractor Balance Sheet")
    # Default: most recent closed period in GLCAL
    ap.add_argument("--period", type=int, default=None, help="Period YYYYMM (default: most recent closed)")
    ap.add_argument("--branch", type=str, default=None)
    ap.add_argument("--output", type=str, default=None)
    args = ap.parse_args()

    if args.period is None:
        _, row = fetch("SELECT MAX(GB_DATE) FROM dbo.GLCAL")
        args.period = int(row[0][0])

    rows = fetch_bs_balances(args.period, args.branch)
    sections = categorize(rows)
    year = args.period // 100
    ytd_ni = fetch_ytd_ni(year, args.branch)
    if args.output is None:
        tag = str(args.period)
        if args.branch:
            tag += f"-br{args.branch}"
        out = Path.home() / "Downloads" / f"Crystal-BS-{tag}.pdf"
    else:
        out = Path(args.output)
    path = build_pdf(args.period, args.branch, sections, ytd_ni, str(out))
    print(f"Wrote: {path}")


if __name__ == "__main__":
    main()
