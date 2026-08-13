# CodeGraph Reader

A small, dependency-light **Clarion 12** desktop tool for browsing the
`*.codegraph.db` SQLite databases produced by the Clarion Assistant CodeGraph
indexer. Point it at any `.codegraph.db` and explore the symbols and
relationships of an entire Clarion solution without leaving Windows.

It is **hand-coded Clarion** — no dictionary, no AppGen, no ABC templates — a
single source file (`CodeGraphReader.clw`) that talks to SQLite directly through
`sqlite3.dll` using the SQLite C API (no ODBC driver, no DSN, no Clarion SQLite
file driver).

## Features

Three tabs feed one shared result grid whose columns and headers rebuild
themselves from each query at run time:

- **Analyses** — canned queries: all procedures & functions, all classes, class
  hierarchy, orphaned procedures, *Who calls X*, *What X calls*, and **all
  relationships (readable)** — the raw `from_id`/`to_id` numbers JOINed back to
  their symbol names.
- **Browse** — dump any table in the database.
- **SQL** — run any free-form read-only `SELECT`.

**Grid navigation:**

- **Double-click a result row** → opens that row's `file_path` at its
  `line_number` in **VS Code** (`code -g "file:line"`). Works on any result that
  carries `file_path`/`line_number` columns.
- **Double-click a column header** → sorts by that column; double-click again
  toggles ascending/descending (the sorted header shows a `^` / `v` arrow).
- **Drag a column border** → resize. The status bar flags when there are more
  columns than fit in the current view.

## Requirements

- **Clarion 12** (32-bit) to build.
- `sqlite3.dll` (32-bit) and `sqlite3.lib` — **both bundled in this repo**.
  - `sqlite3.dll` is the stock public-domain SQLite 3 amalgamation build.
  - `sqlite3.lib` is a Clarion import library generated from that DLL with
    Clarion's **LibMaker** (`LibMaker.exe sqlite3.dll`). The source links it via
    `PRAGMA('link(sqlite3.lib)')`.
- *(optional)* **VS Code** — on `PATH` (its `code` command) or installed per-user
  — enables the double-click-to-open-source feature. Without it the tool still
  browses and queries fine; only the jump-to-source is unavailable.

## Build

From a PowerShell prompt (put `C:\Clarion12\bin` first on `PATH`):

```powershell
& 'C:\Windows\Microsoft.NET\Framework\v4.0.30319\MSBuild.exe' `
    CodeGraphReader.cwproj `
    /p:ClarionBinPath=C:\Clarion12\bin `
    /p:Configuration=Debug /p:Platform=Win32 /t:Build
```

Then run `CodeGraphReader.exe`. Keep `sqlite3.dll` next to the EXE.

## Usage

1. Click **Open Database…** and pick any `*.codegraph.db` file.
2. Use the **Analyses**, **Browse**, or **SQL** tab to query it.
3. Results land in the grid; the status bar reports row/column counts.
4. Double-click a row to open its source in VS Code; double-click a column
   header to sort; drag a column border to resize.

## The `.codegraph.db` schema (reference)

| Table | Key columns |
|-------|-------------|
| `symbols` | `name, type, file_path, line_number, params, return_type, parent_name, scope` |
| `relationships` | `from_id, to_id, type` (calls / do / inherits / implements / references) |
| `projects` | `name, cwproj_path, sln_path` |
| `index_metadata` | `key, value` (e.g. `lib_paths_hash`, `last_indexed`) |

## Notes

- On launch, if any `*.codegraph.db` file is present in the program's working
  directory the tool opens the first one automatically; otherwise it prompts you
  to **Open Database…**. No paths are hard-coded.
- The header of `CodeGraphReader.clw` carries a full **VERSION HISTORY
  (v1.0.0–v1.0.4)** and documents several hard-won ClaRUN 12.0.0.14000 gotchas
  baked into the code (CSTRING null-termination, the `@sN` 255-character picture
  cap, and displaying a variable in a `STRING` control).

## License

The CodeGraph Reader source is released under the [MIT License](LICENSE).
The bundled SQLite (`sqlite3.dll`) is in the **public domain** — see
<https://www.sqlite.org/copyright.html>.
