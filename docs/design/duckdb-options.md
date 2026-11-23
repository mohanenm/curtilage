# DuckDB: how users get it

Status: analysis for a decision. curtilage needs DuckDB for every data path (building regions, reading built files, reading Overture). Today the user installs the DuckDB CLI (1.4 LTS or 2.0) and the gem runs it as a separate process.

## Options

### a. The `duckdb` Ruby gem as an optional backend

Use the native bindings when the gem is installed, the CLI otherwise.

- **What users gain:** no process per query (each lookup now pays ~85 ms for starting the CLI and parsing JSON), so single-pin API calls get faster. That's the main win.
- **What it doesn't remove:** the bindings compile against DuckDB's C library, which the user must still install (and a C compiler), so setup gets heavier, not lighter. Its version has to match the library's.
- **Extensions and remote reads:** they're SQL (`INSTALL`/`LOAD`, `read_parquet` on `s3://`), so they'd work the same way.
- **Security and robustness:** DuckDB would run inside the host app. Today a stuck or runaway query is a separate process the gem can time out and kill (Phase 4); in-process, a crash or memory blow-up takes the host down, and timeouts become cooperative.
- **Platforms and maintenance:** native builds on macOS and Linux (glibc and musl need checking), Windows uncertain; a second code path to test against every DuckDB release; releases trail DuckDB's.
- **Docker:** the image would need build tools in its build stage, nothing in the final image.
- *Not verified here (no gem installs in this environment): exact platform support, extension loading through the bindings, and the gem's release cadence. Check before building.*

**Effort:** 2-3 days plus ongoing testing. **Risk:** medium.

### b. `curtilage doctor --install`

Downloads a known DuckDB CLI release for the OS and chip from DuckDB's GitHub releases into the cache folder, checks it against a SHA256 pinned in the gem, and uses it whenever `CURTILAGE_DUCKDB` isn't set and no `duckdb` is on the `PATH`.

- **What users gain:** Ruby is the only thing to install; the DuckDB version is one the gem was tested with.
- **Security:** the binary runs with the user's rights, so the pinned checksum is what makes it trustworthy (a compromised release or mirror fails the check). Nothing runs that wasn't checked.
- **Network:** a new host for the gem: `github.com`, which redirects downloads to `objects.githubusercontent.com`. The download code allows no redirects today, so this needs the redirect allowed to that one host. Explicit command only, never automatic on first run.
- **Maintenance:** a checksum table per supported version and platform (linux amd64/arm64, macOS universal; Windows if supported), updated with each DuckDB release; a CI job that runs the installer on Linux and macOS.
- **Docker:** no change (the image already ships a checked DuckDB).
- **Size:** about 20-40 MB per platform, in the user's cache folder.

**Effort:** about a day. **Risk:** low, given the pinned checksums.

### c. A range of DuckDB versions

Already true in practice: 1.4.4 and 2.0.1 are both tested end to end, and the gem adapts to the differences it found (extension folder setting, `s3_region`, lambda syntax, geometry storage, agent mode).

- **Proposal:** support 1.4.x (LTS) and 2.0.x; `doctor` warns, without failing, on anything else; a weekly CI job runs the DuckDB-dependent tests against the newest release without blocking pull requests, so a break shows up before users hit it.
- **Effort:** small (being done in this phase). **Risk:** low.

## Recommendation

1. **c now** (this phase): the supported range, doctor's warning and the weekly job.
2. **b next**, as an explicit `doctor --install` with pinned checksums, once you approve the GitHub hosts.
3. **a later, if at all**: only if single-pin API speed matters more than isolation, and then as an optional backend next to the CLI, never instead of it.

## Decisions needed

1. Build `doctor --install` (b), allowing downloads from `github.com` and its `objects.githubusercontent.com` redirect, for the gem's users?
2. Defer the Ruby bindings (a)?
