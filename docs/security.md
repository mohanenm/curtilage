# Security model

What curtilage trusts, what it doesn't, who might attack it, and how each attack is met. Report problems privately, as [SECURITY.md](../SECURITY.md) explains.

## What it does that matters

- **Downloads** public map data over HTTPS: Geofabrik's region index and shapefiles, Overture's catalogue and file index, and, when opted in, Microsoft's footprint tiles.
- **Runs the DuckDB CLI**, an external program, with SQL it builds. DuckDB reads Parquet files (local, in a bucket, or Overture's) and installs its `spatial` and `httpfs` extensions.
- **Parses untrusted input**: your pin files, and all map data.
- **Writes** GeoJSON, CSV, KML and an HTML preview, files under `--out`, and a cache folder of built regions.

## Trust boundaries

| Input | Trusted? | How it's handled |
|---|---|---|
| Your Ruby calls | The caller is trusted, the values are checked | Unknown options raise; numeric options are range-checked; pins are checked before use in SQL. |
| Pin files (CSV, GeoJSON) | No | Capped at 50 MB and 100,000 pins; fields and ids at 10,000 characters, rows at 1,000 columns, JSON nesting at 20, all enforced while reading; must be UTF-8 without NUL bytes; CSV parsed by a strict quoted-field reader; every pin checked as finite plain decimals in range. |
| Map data (Geofabrik, Overture, Microsoft, your own catalogue files) | No | At most 20,000 features per pin and 5,000 vertices per ring; empty, self-intersecting or invalid geometry dropped; names and ids escaped in every output; DuckDB output capped at 200 MB; values from map data never become SQL. |
| The DuckDB binary (`CURTILAGE_DUCKDB`, or `duckdb` on the `PATH`) | **Yes**: trusted configuration | It runs with your user's rights. Point it only at a DuckDB you installed. `curtilage doctor` shows which one runs. |
| DuckDB's extensions | Through DuckDB's signature checks | Installed from DuckDB's repository on first use. The gem never turns signature checks off or allows unsigned extensions. |
| `setup_sql:` (lookup option) | **Yes** | Passed to DuckDB as written, for statements such as `CREATE SECRET`. Never fill it from untrusted input. |
| Environment variables (`CURTILAGE_*`) and `Curtilage.configure` | **Yes**: configuration | Values that reach SQL are quoted (`DuckDB.quote`) or converted to numbers first. |
| Catalogue folders and bucket URLs | The location is configuration; the files are map data | Paths and URLs are quoted in SQL; what they contain is treated like any map data. |
| The cache folder | Only if nobody else can write to it | DuckDB reads its Parquet files and the gem trusts its metadata, so whoever can write to it can feed both. |
| Upstream hosts | No | HTTPS with certificate checks, to a fixed list of hosts; no redirects followed; sizes capped while streaming. |

## Who might attack, and the defences

**A poisoned map-data file** (vandalised OSM data, a compromised mirror or bucket). Oversized and invalid geometry is dropped and counts are capped, so a file can't exhaust memory through the gem's own parsing; text from map data is escaped wherever it's written; nothing from map data is placed into SQL (Overture file links are accepted only from Overture's own bucket, and quoted). What's left: bugs in DuckDB or its extensions when reading a crafted Parquet file or shapefile, and wrong but plausible geometry, which validation, flags and review are there to catch.

**A malicious input file** (a pin list from someone else). Size, pin-count and nesting caps; a strict CSV reader; pins must be numbers in range. Outputs are made safe for where they're opened: CSV cells a spreadsheet would run as a formula get a leading `'`, the preview escapes all text, KML escapes all text, and GeoJSON is written by a JSON library.

**A shared cache on a multi-user machine.** Another user who can write to the cache folder could replace a built region with a crafted one. Keep the cache in a folder only you can write to (see the gaps below).

**A compromised upstream release.** Downloads go only to the listed hosts over HTTPS. Geofabrik publishes no checksums, so a build checks each file's zip CRC, which catches corruption but not deliberate tampering. The DuckDB binary and its extensions come from DuckDB: install DuckDB from a source you trust.

**Hostile configuration** (environment variables, `setup_sql:`, the DuckDB path). Configuration is trusted by design: whoever sets it already controls what runs. It's documented here so nobody fills it from untrusted input.

**The HTTP server** (`curtilage serve`, planned). Not built yet. When it is: it will bind to `127.0.0.1` by default, support an optional bearer token, cap body size, pins, time and concurrency, and never log pins unless asked.

## Defences in the code

- **Pins**: every entry point goes through `Validation.pin`: two finite plain decimal numbers, in range.
- **SQL**: text values go through `DuckDB.quote`, which also refuses line breaks and NUL bytes (the DuckDB CLI treats a line starting with `.` as its own command); numbers through `Float()`/`Integer()`; pins through `Validation.pin`; `memory_limit` must match a size pattern and `threads` must be 1 to 64. `test/sql_safety_test.rb` pushes crafted values through each path into SQL.
- **DuckDB runs** (`DuckDB.capture`): each in its own process group, stopped with everything it started after a timeout (600 s for lookups, 3600 s for builds); output read as it arrives and DuckDB stopped once it passes the cap; lookups and Overture reads capped at 1 GB of memory; error messages stripped of the query excerpt DuckDB quotes, which can hold the box around a pin.
- **Commands**: every external program (DuckDB, `curl`, `unzip`, `git` in the benchmark) runs through `Open3`, `system` or `IO.popen` with an argument list, never a shell string.
- **Downloads** (`Download`): only `ALLOWED_HOSTS`; HTTPS only (`curl --proto =https`); no redirects followed; size capped while streaming; written to a `.part` file and renamed only when complete; transient failures retried three times.
- **Zip extraction** (`ZipRange`): only plain file names (no folders, so nothing can be written outside the target, and no symlinks are created); at most 1,000 entries; compressed size capped; inflated size must match the header; CRC-32 checked.
- **Atomic writes**: the cached region index, each region's metadata and the command line's `--out` files are written to a temporary name and renamed; an unreadable cached index is fetched again. `--out` refuses a symbolic link at the target.
- **Errors**: everything raised on purpose is a `Curtilage::Error`, or an `ArgumentError` for bad input.
- **Output**: the preview escapes all text, drops Unicode direction controls from it, and carries a Content-Security-Policy that allows only its own inline style and script (by hash) and no loads at all, so a missed escape can't run script. CSV cells a spreadsheet would run as a formula (a leading `=`, `+`, `-`, `@`, `|` or `%`, full-width forms, after any whitespace) get a leading `'`, in every column; KML escapes all text; GeoJSON is written by a JSON library.
- **Fuzz tests** (`test/fuzz_test.rb`, plain Ruby, fixed seed): the CSV and GeoJSON readers, map-data parsing, geometry on degenerate input (repeated, lined-up and coincident points), validation, and generation near the poles and the antimeridian. `FUZZ_ITERATIONS=5000` runs a longer pass.
- **Docker**: the image runs as a non-root user.

## Known gaps

Being worked on; this list shrinks as they're fixed.

- The cache folder is created with default permissions and isn't checked for other writers; cached files have no recorded checksums; downloaded files' SHA256 isn't recorded.
- Zip extraction doesn't cap the total uncompressed size or the compression ratio.
- There's no offline mode that guarantees no network use.
- A site that raises during generation aborts its whole batch; there's no cap on pins per call.
- CI actions aren't pinned to commit SHAs; the Docker image downloads DuckDB without a checksum and isn't pinned to a base-image digest.

## Out of scope

The accuracy of OpenStreetMap or Overture data; whether a generated polygon matches the real property line (results are proposals for review); and denial of service by giving the gem a large but legitimate workload on your own machine.
