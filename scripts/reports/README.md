# Crystal GL — Report Generators

Five parameterizable PDF report generators backed by the `dbo.GLCAL` / `dbo.YTDIST` replica. Each script:
- Takes period / branch flags via `argparse`
- Writes to `~/Downloads/Crystal-*.pdf` by default (override with `--output`)
- Uses Azure AD via `DefaultAzureCredential` for DB auth (works with `az login` locally)
- Shares connection + PDF styling via [`_common.py`](_common.py)

| Script | What it produces | Key flags |
|---|---|---|
| [`ap_analysis.py`](ap_analysis.py) | A/P spend, top vendors, concentration, dept/branch breakdown, aging, biggest invoices, YTDJRL recon | `--period-from YYYYMMDD --period-to YYYYMMDD` |
| [`income_statement.py`](income_statement.py) | Consolidated P&L with CFO v2 sections (Variable Exp, D&A broken out, EBITDA subtotal) | `--year YYYY` or `--period YYYYMM`; `--branch NN` |
| [`balance_sheet.py`](balance_sheet.py) | BS with CFO v2 layout (Cash split 4 ways, Reserves section, Intercompany Liab) | `--period YYYYMM`; `--branch NN` |
| [`cash_flow.py`](cash_flow.py) | Indirect-method SCF: Operating / Investing / Financing + reconciliation residual | `--year YYYY`; `--branch NN` |
| [`dfs_departmental.py`](dfs_departmental.py) | 7-column Kubota DFS departmental P&L (Sales/Service/Parts/Rental/Admin/Consolidated) | `--year YYYY` |

## Quick start

```sh
az login                                 # one-time, refreshes for 30 days
cd scripts/reports
python ap_analysis.py                    # YTD current year
python income_statement.py --year 2025
python balance_sheet.py --period 202512
python cash_flow.py --year 2025
python dfs_departmental.py --year 2025
```

Each writes the PDF path to stdout when done.

## Common flags

- `--branch NN` — restrict to a single branch by CC suffix (`01`=Deland, `14`=Tallahassee, etc. — see [docs/data-model.md](../../docs/data-model.md))
- `--period YYYYMM` (where supported) — single month instead of year
- `--output /path/to/file.pdf` — custom output path

## Programmatic / MCP access

The [`MCP/server.py`](../../MCP/server.py) crystal-gl MCP server exposes the same reports as tools that return structured data (not PDFs — see "Why no PDF over MCP" below):

| MCP tool | Equivalent script |
|---|---|
| `income_statement(period, ...)` | `income_statement.py` (already existed; uses view-side sectioning) |
| `ap_analysis(period_from, period_to)` | `ap_analysis.py` |
| `balance_sheet_v2(period, branch)` | `balance_sheet.py` |
| `cash_flow(year, branch)` | `cash_flow.py` |
| `dfs_departmental(year)` | `dfs_departmental.py` |

## Section maps — caveat

The CFO's v2 restructure (2026-05-28 markups, see [docs/cfo-feedback-2026-05-28.md](../../docs/cfo-feedback-2026-05-28.md)) hand-encodes account-to-section maps in each script (`SECTIONS_*` constants). These are best-effort matches to the v2 PDFs Steven approved; **bottom-line totals (Net Income, Total Assets) match v2 to the dollar**, but individual section subtotals can drift if Crystal's chart of accounts adds new accounts that don't fall into the hardcoded buckets.

**To fix drift:** add the new account number to the appropriate `SECTIONS_*` list in the relevant script. Accounts not in any list fall through to "Other" buckets at the bottom of their statement.

## Why no PDF over MCP

MCP tools return text to the conversation. A typical PDF is 10-100KB binary → 15-150K tokens if encoded — would saturate context. Reasonable patterns:

- **Local Claude Code** with this repo cloned: run the CLI scripts directly
- **MCP-only access** (e.g. claude.ai web): use the MCP tools for numbers/section subtotals, generate the PDF separately

If a PDF-via-MCP transport is ever wanted, the cleanest path is publishing to Azure Blob Storage with a SAS URL — out of scope for this commit.

## Dependencies

All in [`../../MCP/requirements.txt`](../../MCP/requirements.txt) (shared venv):
- `pyodbc>=5.1.0` + ODBC Driver 18 for SQL Server
- `azure-identity>=1.15.0`
- `reportlab>=4.0` (PDF generation)
