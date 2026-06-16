#!/usr/bin/env python3
"""Crystal Tractor — Consolidated Income Statement.

Replicates the v2 CFO-approved IS layout: revenue/COGS in matched 4-way
sub-sections (Equipment / Parts / Service-Labor / Other), Variable Expense
(Sales Commission) broken out, D&A pulled into its own section, EBITDA
subtotal, then Operating / Fixed / Interest / Other Income sections.

Examples:
    python scripts/reports/income_statement.py
    python scripts/reports/income_statement.py --year 2025
    python scripts/reports/income_statement.py --year 2025 --branch 01
    python scripts/reports/income_statement.py --period 202604
"""
from __future__ import annotations

import argparse
from datetime import date
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.units import inch
from reportlab.platypus import Paragraph, Spacer, TableStyle

from _common import (
    BAND_GRAY, BODY, BRAND_BLUE, H1, H2, LINE_GRAY, SMALL, SUB,
    fetch, fmt_money, make_doc, now_str, pnl_activity_through, themed_table,
    validate_branch,
)

# CFO-approved v2 section structure. Each section: list of (account, name).
# Accounts not listed fall into "Other Operating Expense" or "Other Income"
# based on their ACTYP. Section ORDER below is the rendering order.

SECTIONS_IS = [
    # ----- REVENUE -----
    ("Equipment Sales",  "revenue",  ["31001","32000","32010","32011","32012","32014","32020",
                                       "32060","32070","32080","32100","32200","32400","32500","32550","32700","32720","32800","32840",
                                       # Contra-revenue items moved out of Equipment COGS per CFO 2.4:
                                       "42210","42005","42212"]),
    ("Parts Sales",      "revenue",  ["33000","33010","33020","33030","33100","33110","33120","33130","33220"]),
    ("Service / Labor Sales", "revenue", ["34000","34200","34300"]),
    ("Other Revenue / Discounts", "revenue", ["39000"]),
    # ----- COGS -----
    ("Equipment COGS",   "cogs",     ["41000","41001","42000","42001","42002","42003","42004",
                                       "42006","42007","42010","42011","42012","42013","42014","42050","42060","42070","42080","42100","42200"]),
    ("Parts COGS",       "cogs",     ["43000","43010","43020","43030","43100","43110","43120","43130","43200","43220"]),
    ("Service / Labor COGS", "cogs", ["44000","44200","44300","44500"]),
    ("Other COGS",       "cogs",     ["48900","49000"]),
    # ----- VARIABLE EXPENSE -----
    ("Variable Expense (Sales Commission)", "opex", ["51910"]),
    # ----- PERSONNEL -----
    ("Personnel",        "opex",     ["51900","51920","51960","51970","51980","51990"]),
    # ----- OPERATING (with CFO reclassifications 2.9, 2.10) -----
    ("Operating",        "opex",     ["52000","53000","53500","54000","54500","56000","57000","58000",
                                       "58100","58400","58500","58600","58700","58800","58900","59000"]),
    # ----- FIXED -----
    ("Fixed",            "opex",     ["59010","59020"]),
    # ----- D&A -----
    ("D&A",              "dna",      ["55100","55300","55400"]),
    # ----- INTEREST EXPENSE -----
    ("Interest Expense", "interest", ["58200","58290","59100"]),
    # ----- OTHER INCOME / EXPENSE -----
    ("Other Income",     "other_inc", ["61500","62000","71300","71200","71500"]),
    ("Other Expense",    "other_exp", ["63000","64000"]),
]

# Build account → section lookup
ACCT_TO_SECTION: dict[str, str] = {}
for sec_name, _kind, accts in SECTIONS_IS:
    for a in accts:
        ACCT_TO_SECTION[a] = sec_name


def fetch_pnl_amounts(year: int | None, period: int | None, through: int | None, branch: str | None):
    """Sum P&L activity; group by (account, name).

    Source dispatch:
      - through given (YYYYMMDD): YTDJRL year-start through that date
      - period given (YYYYMM): GLCAL single-month
      - year given (and != current): GLCAL annual
      - else (default): COACMAST.CA_CUR — live YTD current year
    """
    from datetime import date as _d
    branch = validate_branch(branch)
    if through is not None:
        return pnl_activity_through(through, branch, group_by_cc_digit=False)
    use_live = (period is None and (year is None or year == _d.today().year))

    if use_live:
        where = ["am.ACTYP IN ('2','3')"]
        if branch:
            where.append(f"RIGHT(RTRIM(c.CA_CC),2) = '{branch}'")
        _, rows = fetch(f"""
        SELECT RTRIM(c.CA_ACC) AS acct,
               LEFT(RTRIM(am.ACNME), 40) AS name,
               SUM(c.CA_CUR) AS amt
        FROM dbo.COACMAST c
        JOIN dbo.ACCMAST am ON RTRIM(am.ACACC) = RTRIM(c.CA_ACC)
        WHERE {' AND '.join(where)}
        GROUP BY c.CA_ACC, am.ACNME
        HAVING SUM(c.CA_CUR) <> 0
        """)
        return rows

    where = ["am.ACTYP IN ('2','3')"]
    if period is not None:
        where.append(f"g.GB_DATE = {period}")
    else:
        where.append(f"g.GB_DATE BETWEEN {year*100 + 1} AND {year*100 + 12}")
    if branch:
        where.append(f"RIGHT(RTRIM(g.GB_GLC),2) = '{branch}'")

    _, rows = fetch(f"""
    SELECT RTRIM(g.GB_GLA) AS acct,
           LEFT(RTRIM(am.ACNME), 40) AS name,
           SUM(g.GB_AMT) AS amt
    FROM dbo.GLCAL g
    JOIN dbo.ACCMAST am ON RTRIM(am.ACACC) = RTRIM(g.GB_GLA)
    WHERE {' AND '.join(where)}
    GROUP BY g.GB_GLA, am.ACNME
    HAVING SUM(g.GB_AMT) <> 0
    """)
    return rows


def categorize(rows):
    """Group rows into sections. Returns {section_name: [(acct, name, signed_amount)]}.

    GLCAL.GB_AMT convention: revenue accounts are negative, expense positive.
    For display we flip signs: revenue shown positive, expense shown negative.
    """
    sections: dict[str, list[tuple[str, str, float]]] = {sec: [] for sec, _, _ in SECTIONS_IS}
    other_revenue: list = []
    other_expense: list = []
    for acct, name, amt in rows:
        amt = float(amt)
        sec = ACCT_TO_SECTION.get(acct)
        if sec is None:
            # Fallback: revenue if acct starts with 3, expense otherwise
            if acct.startswith("3"):
                other_revenue.append((acct, name, -amt))  # flip sign for revenue
            else:
                other_expense.append((acct, name, -amt))  # expense shown negative
        else:
            # For display: revenue/COGS/expense all conventionally shown with
            # revenue positive, costs/expenses negative.
            kind = next(k for sn, k, _ in SECTIONS_IS if sn == sec)
            if kind == "revenue":
                sections[sec].append((acct, name, -amt))   # neg in DB → positive display
            else:
                sections[sec].append((acct, name, -amt))   # pos in DB → negative display
    if other_revenue:
        sections.setdefault("Other Revenue / Discounts", []).extend(other_revenue)
    if other_expense:
        sections.setdefault("Other Expense", []).extend(other_expense)
    return sections


def build_pdf(year: int | None, period: int | None, through: int | None,
              branch: str | None, sections: dict, output_path: str) -> str:
    doc = make_doc(output_path, title="Crystal Tractor — Income Statement")
    elements: list = []
    from datetime import date as _d
    is_live = through is None and period is None and (year is None or year == _d.today().year)
    if through is not None:
        s = str(through)
        label = f"YTD {s[:4]} through {s[:4]}-{s[4:6]}-{s[6:]} (YTDJRL)"
        source_label = "dbo.YTDJRL (per-day journal-line postings)"
    elif period is not None:
        label = f"Period {str(period)[:4]}-{str(period)[4:]}"
        source_label = "dbo.GLCAL"
    elif is_live:
        label = f"YTD {_d.today().year} (live, through latest source update)"
        source_label = "dbo.COACMAST.CA_CUR (live)"
    else:
        label = f"Fiscal Year {year}"
        source_label = "dbo.GLCAL"
    branch_label = f" · Branch {branch}" if branch else " · Consolidated"
    elements += [
        Paragraph("Crystal Tractor — Consolidated Income Statement", H1),
        Paragraph(f"{label}{branch_label}", SUB),
        Paragraph(f"Generated {now_str()} · Source: {source_label}", SMALL),
        Spacer(1, 0.15 * inch),
    ]

    # Render each section with its line items and subtotal.
    # Track running subtotals for EBITDA / Operating Income / Net Income.
    rev_total = cogs_total = variable_total = personnel_total = 0.0
    operating_total = fixed_total = dna_total = interest_total = 0.0
    other_inc_total = other_exp_total = 0.0

    def render_section(sec_name: str, lines, total_label: str, total_value: float, bold_total: bool = True):
        if not lines:
            return
        rows = [[sec_name, "", ""]]  # section header
        for acct, name, amt in sorted(lines, key=lambda r: -abs(r[2])):
            rows.append([f"  {acct}", name, fmt_money(amt)])
        rows.append([f"  {total_label}", "", fmt_money(total_value)])
        t = themed_table(rows, [0.9*inch, 4.0*inch, 1.2*inch], right_align_cols=[2],
                         has_header=False, font_size=9)
        t.setStyle(TableStyle([
            ("FONTNAME",   (0, 0), (-1, 0), "Helvetica-Bold"),
            ("BACKGROUND", (0, 0), (-1, 0), BRAND_BLUE),
            ("TEXTCOLOR",  (0, 0), (-1, 0), colors.white),
            ("FONTNAME",   (0, -1), (-1, -1), "Helvetica-Bold"),
            ("LINEABOVE",  (0, -1), (-1, -1), 0.5, BRAND_BLUE),
            ("BACKGROUND", (0, -1), (-1, -1), BAND_GRAY),
        ]))
        elements.append(t)
        elements.append(Spacer(1, 0.04*inch))

    for sec_name, kind, _ in SECTIONS_IS:
        lines = sections.get(sec_name, [])
        section_total = sum(l[2] for l in lines)
        if kind == "revenue":
            rev_total += section_total
        elif kind == "cogs":
            cogs_total += section_total
        elif kind == "opex":
            if "Sales Commission" in sec_name:
                variable_total += section_total
            elif sec_name == "Personnel":
                personnel_total += section_total
            elif sec_name == "Fixed":
                fixed_total += section_total
            else:
                operating_total += section_total
        elif kind == "dna":
            dna_total += section_total
        elif kind == "interest":
            interest_total += section_total
        elif kind == "other_inc":
            other_inc_total += section_total
        elif kind == "other_exp":
            other_exp_total += section_total
        if lines:
            render_section(sec_name, lines, f"Total {sec_name}", section_total)
        # After Revenue: insert Gross Profit subtotal once
        if sec_name == "Other Revenue / Discounts":
            elements.append(themed_table(
                [["Total Revenue", "", fmt_money(rev_total)]],
                [4.9*inch, 0.1*inch, 1.2*inch], right_align_cols=[2], has_header=False, font_size=10,
            ))
            elements.append(Spacer(1, 0.05*inch))
        if sec_name == "Other COGS":
            gp = rev_total + cogs_total  # cogs is negative
            elements.append(themed_table(
                [["Gross Profit", "", fmt_money(gp)]],
                [4.9*inch, 0.1*inch, 1.2*inch], right_align_cols=[2], has_header=False, font_size=11,
            ))
            elements.append(Spacer(1, 0.05*inch))
        # After Fixed: insert Operating Income before D&A (EBITDA)
        if sec_name == "Fixed":
            ebitda = rev_total + cogs_total + variable_total + personnel_total + operating_total + fixed_total
            t = themed_table(
                [["EBITDA (before D&A)", "", fmt_money(ebitda)]],
                [4.9*inch, 0.1*inch, 1.2*inch], right_align_cols=[2], has_header=False, font_size=11,
            )
            t.setStyle(TableStyle([
                ("BACKGROUND", (0, 0), (-1, -1), BRAND_BLUE),
                ("TEXTCOLOR",  (0, 0), (-1, -1), colors.white),
                ("FONTNAME",   (0, 0), (-1, -1), "Helvetica-Bold"),
            ]))
            elements.append(t)
            elements.append(Spacer(1, 0.05*inch))
        # After D&A: Operating Income
        if sec_name == "D&A":
            oi = rev_total + cogs_total + variable_total + personnel_total + operating_total + fixed_total + dna_total
            elements.append(themed_table(
                [["Operating Income", "", fmt_money(oi)]],
                [4.9*inch, 0.1*inch, 1.2*inch], right_align_cols=[2], has_header=False, font_size=11,
            ))
            elements.append(Spacer(1, 0.05*inch))

    # Net Income
    ni = (rev_total + cogs_total + variable_total + personnel_total + operating_total
          + fixed_total + dna_total + interest_total + other_inc_total + other_exp_total)
    t = themed_table(
        [["Net Income", "", fmt_money(ni)]],
        [4.9*inch, 0.1*inch, 1.2*inch], right_align_cols=[2], has_header=False, font_size=12,
    )
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), BRAND_BLUE),
        ("TEXTCOLOR",  (0, 0), (-1, -1), colors.white),
        ("FONTNAME",   (0, 0), (-1, -1), "Helvetica-Bold"),
        ("BOX",        (0, 0), (-1, -1), 1, BRAND_BLUE),
    ]))
    elements.append(Spacer(1, 0.1*inch))
    elements.append(t)

    elements.append(Spacer(1, 0.15*inch))
    elements.append(Paragraph(
        "Source: dbo.GLCAL · ACCMAST classification with CFO v2 section overlay (Variable Expense broken out; "
        "D&A pulled into its own section; contra-revenue items moved from Equipment COGS to Equipment Sales; "
        "Operating reclassifications per CFO feedback 2026-05-28). Accounts not in the section map fall into Other.",
        SMALL))

    doc.build(elements)
    return output_path


def main():
    ap = argparse.ArgumentParser(description="Crystal Tractor Income Statement")
    ap.add_argument("--year", type=int, default=None,
                    help="Fiscal year (default: current year, served live via COACMAST.CA_CUR)")
    ap.add_argument("--period", type=int, default=None, help="Single period YYYYMM (uses GLCAL)")
    ap.add_argument("--through", type=int, default=None,
                    help="YTD through a specific date YYYYMMDD via YTDJRL roll-forward")
    ap.add_argument("--branch", type=str, default=None, help="2-digit branch suffix; default consolidated")
    ap.add_argument("--output", type=str, default=None)
    args = ap.parse_args()
    if sum(x is not None for x in (args.year, args.period, args.through)) > 1:
        ap.error("--year / --period / --through are mutually exclusive")

    rows = fetch_pnl_amounts(args.year, args.period, args.through, args.branch)
    sections = categorize(rows)
    if args.output is None:
        if args.through:
            tag = f"through-{args.through}"
        elif args.period:
            tag = str(args.period)
        elif args.year:
            tag = str(args.year)
        else:
            tag = f"YTD-{date.today().isoformat()}"
        if args.branch:
            tag += f"-br{args.branch}"
        out = Path.home() / "Downloads" / f"Crystal-IS-{tag}.pdf"
    else:
        out = Path(args.output)
    path = build_pdf(args.year, args.period, args.through, args.branch, sections, str(out))
    print(f"Wrote: {path}")


if __name__ == "__main__":
    main()
