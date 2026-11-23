# Security

## Reporting a vulnerability

Please report security issues privately through GitHub: on this repository, open the **Security** tab and choose **Report a vulnerability**. Don't open a public issue for them.

Include what you found, how to reproduce it (with made-up or public locations, never private site data), and the version you used.

You should get an acknowledgement within 7 days. Confirmed issues are fixed in a new release, usually within 30 days, and disclosed in a GitHub security advisory and the changelog once the fix is out; you'll be credited unless you'd rather not be.

## Supported versions

curtilage is pre-1.0: fixes go into the latest release only. Upgrade to get them.

## Threat model

[docs/security.md](docs/security.md) says what the gem trusts and doesn't, who might attack it, and the defences.

## Scope

In scope:

- The gem's code and the `curtilage` command, including how it runs external programs (the DuckDB CLI, and `curl` when installed) and builds the SQL it gives DuckDB.
- Downloads of map data (Geofabrik, Overture's catalogue, opt-in Microsoft footprints): host allow-list, size caps, archive handling, the cache folder.
- Parsing untrusted input: pin files and map data.
- Outputs: the HTML preview, CSV, KML, GeoJSON and files written with `--out`.
- The repository's Docker image and CI workflows.
- `curtilage serve`, once it exists.

Out of scope: vulnerabilities in DuckDB or its extensions themselves (report them to [DuckDB](https://github.com/duckdb/duckdb/security)); the accuracy of OpenStreetMap or Overture data; and anything that needs control of your configuration (`CURTILAGE_DUCKDB`, `setup_sql:`), which is trusted by design.
