# Omega changelog

Agents: call `get_context`, then `get_changelog` after updating Omega. Reconnect the Folio MCP connection to discover new tool schemas. The same tools are available through `omega call TOOL` with JSON on stdin. Changes below describe the app version that bundles this file; uninstalled source changes do not add tools to a running older app.

## 1.3.16 — Table calculations (2026-10-20)

- Table cells can hold formulas. Omega shows their calculated values; click a result to edit its formula, or use **ƒx** in the table toolbar. Formula source remains in Markdown, Git history and live edits. Calculated values are never written over formulas.
- Reference cells (`B2`), rectangular ranges (`B2:C8`), named rows and columns, and other Markdown pages across folders or open notebooks. Results refresh after edits and poll referenced sources every two seconds while the page is open. Row 1 is the header, so the first data row is row 2.
- Decimal arithmetic with 40 significant digits, percentages, comparisons, `SUM`, `AVERAGE`, `MIN`, `MAX`, `COUNT`, `ROUND`, `ABS`, `IF`, and `SUMPRODUCT`. `ROUND` uses half-up rounding and supports 0–12 decimal places. This is a bounded calculation engine, not full Excel compatibility.
- Clear `#REF!`, `#CYCLE!`, `#VALUE!`, `#DIV/0!`, `#NUM!`, `#NAME!`, `#ARGS!`, `#SYNTAX!`, and `#LIMIT!` results. Missing/ambiguous references and non-numeric inputs never silently become zero.
- New read-only agent tools: `read_tables`, `evaluate_formula`, `get_changelog`. `get_context` advertises them; generated project instructions tell agents to check the changelog after updates.
- Releases now require a versioned changelog entry before packaging. The changelog is bundled with the app and available to agents without opening a note.

### Formula syntax and examples

Store a formula as inline code inside a Markdown table cell so Markdown does not interpret operators as formatting:

```markdown
## Pricing

| Item | Quantity | Unit price | Total |
| --- | ---: | ---: | ---: |
| API | 3 | 0.10 | `=ROUND(B2*C2, 2)` |
| Storage | 2 | 12.50 | `=ROUND(B3*C3, 2)` |
| Total | | | `=SUM(D2:D3)` |
```

Local calculations:

- `=ROUND(SUM(D2:D3)*(1+18%), 2)` — total with 18% tax.
- `=IF(B2>0, D2/B2, 0)` — only evaluates the selected branch.
- `=SUMPRODUCT(B2:B3, C2:C3)` — quantities × prices, then summed.

Cross-page lookups (paths are relative to the page containing that formula; use ordinary paths with spaces, not URL encoding):

- `=CELL("../Rates.md", "Pricing", "API", "Unit price")*B2`
- `=CELL("../Rates.md", 1, "C2")`
- `=SUM(RANGE("../Rates.md", "Pricing", "C2:C8"))`
- `=SUM(COLUMN("../Rates.md", "Pricing", "Unit price"))`
- `=SUM(ROW("../Forecast.md", "Monthly costs", "Hosting"))`
- `=CELL("", "Pricing", "API", "Unit price")` — another table in this page.

`CELL(page, table, address)` or `CELL(page, table, row, column)` reads one cell. `RANGE(page, table, addresses)` reads a rectangle. `COLUMN(page, table, column)` excludes the header row. `ROW(page, table, row)` excludes the first column (the row label). Select tables by their unique immediately preceding heading or 1-based table number; rows by their first-column label or 1-based row number; columns by header or 1-based column number. Duplicate names return an error. Named references survive row/column reordering; numeric/A1 references remain positional and do **not** rewrite themselves on insert/delete/move. Renaming or moving pages/headings/labels requires updating formula references.

Only top-level Markdown tables are calculation sources. A page must have a table to supply the evaluation context. All dependencies must be in currently open notebooks; no network, scripts, hidden paths or symlinks. Explicit paths can cross folder boundaries and open notebooks; folder-wide wildcard aggregation is not supported. A source snapshot is read once per calculation; returned revisions identify the values used.

Numbers use a dot decimal separator. Commas are accepted only as 3-digit thousands groups. `$`, `€`, `£`, `₹`, `¥` prefixes are treated as numeric formatting, **not currency conversion**; do not mix currencies without an explicit exchange-rate cell. Percent values divide by 100. Aggregates skip empty cells but reject other text (including `COUNT`); direct empty-cell arithmetic errors. Results are numeric strings, not currency-formatted strings. Limits: 4,096 formula characters, 64 dependency/nesting levels, 10,000 cells/100 tables per page, 32 pages/8 MB per calculation, 2 MB per page and 100,000 operations. A limit produces an error rather than a partial total.

### Agent examples

Discover tables, then read only the table and rows needed:

```json
{"path":"/absolute/open/notebook/Plans/Quote.md"}
```

Pass that to `read_tables`; then use `table:"Pricing"` (or `"1"`), `offset:1`, `limit:30` for cells. Offsets include the header row. Follow `next_offset`; missing `next_offset`/null means the end.

```json
{"path":"/absolute/open/notebook/Plans/Quote.md","table":"Pricing","formula":"=ROUND(SUM(D2:D8)*1.18,2)"}
```

Pass that to `evaluate_formula`. Check `error` before using a result. `value` is an exact decimal string at the engine’s precision; `source_revisions` records all loaded note revisions. To save a formula, first `read_note`, then `update_note` with the exact page revision. Preserve inline-code formula source, do not paste the displayed result over it. Formula evaluation itself never changes files.

## 1.3.15 — Agent work queues (2026-10-18)

- Multiple completion statuses (for example Merged and Done) consistently drive progress and dependency readiness.
- Renewable claim leases, default 30 minutes, and a Recoverable queue for expired claims. Legacy claims remain manual until renewed.
- Human/agent audience filtering; YOU/HUMAN labels default to human work unless explicitly overridden.
- `omega ready`, `omega list`, `omega show`, `omega call`, and the terminal-command installer in Settings → Assistants.
- Clear missing task-revision errors. Claims remain coordinated through one designated Mac, not distributed Git locks.

## 1.3.14 — Independent task updates (2026-10-18)

- Compact mutation receipts, per-task revisions, atomic batches up to 100 tasks, P0–P4 priority and filtered/paginated queues.
- Existing worktree execution remains with Claude/Codex. Omega stores coordination and handoff records.

Earlier releases: https://github.com/MHASK/Omega/releases
