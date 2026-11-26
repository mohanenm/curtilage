# Agent instructions

For coding agents working on curtilage. Read [CONTRIBUTING.md](CONTRIBUTING.md) first; this adds what an agent needs on top of it.

## Commands

- `bundle exec rake`: tests (Minitest), then RuboCop. Must pass before every commit.
- `bundle exec rake benchmark`, then `rake "benchmark:compare[OLD,NEW]"`: before and after any change to the rules ([benchmark/README.md](benchmark/README.md)).
- `bundle exec exe/curtilage doctor` (`--json`, `--network`, `--verify DIR`): checks DuckDB and its extensions.

## Conventions

- Coordinates are `[lng, lat]`; rings are closed. Geometry is plain Ruby (a flat projection round the pin, well under a metre at premises scale): don't add a geometry gem without a reason. No runtime gem dependencies; DuckDB through its CLI.
- Every polygon goes through `Curtilage::Validation.check`; the store zone sits inside the premises.
- Rule-based only. ML footprints are an opt-in data flavour (`buildings:`).
- Map data and input are untrusted: cap sizes and vertex counts, drop invalid geometry, never build SQL from map values.
- Keep [README.md](README.md) and [docs/reference.md](docs/reference.md) in step with the code; CHANGELOG under Unreleased, **Breaking** for API changes.
- New behaviour goes behind an option, off by default. An option that doesn't earn its place on the benchmark is removed.
- Judge rule changes on imagery and the benchmark's labelled points, not only on IoU.

## Simplicity

- Before writing code: does it need to exist? Is it already here? Does Ruby's standard library or DuckDB do it? Can it be one line? Otherwise write the minimum that works, with a small test if it has logic.
- No options "in case", no abstraction before the third use; extend existing steps rather than adding parallel ones.
- Comments explain why, not what.

## Benchmark

- Held-out sites never tune anything: they're scored only in a release check, totals only, and sealed labels never change. The rules are in [benchmark/README.md](benchmark/README.md).

## Voice (README, docs, commits, pull requests)

- Say what changed and how it was checked, with numbers. Plain words, short sentences.
- No names, no internal decisions or open questions, no hype.
- Commit messages are short and imperative, one logical change each.
- No AI attribution: no Co-Authored-By, "Generated with" or session links.

## Never commit or send

- Real or private site locations, customer data, credentials. Tests use made-up coordinates or well-known public places.
- `data/`, OSM files, Parquet output, `notes/`, `CLAUDE.local.md`, personal settings (`.claude/settings.local.json`).
- Network: public map-data hosts (Geofabrik, Overture Maps, Microsoft footprints when opted in) and DuckDB's extension repositories (core; community only for the opt-in `h3` extension). Never send site locations anywhere else.
- Benchmark tooling only, never the gem or its commands, and for the public benchmark sites only: USGS imagery (`imagery.nationalmap.gov`, `basemap.nationalmap.gov`) for the labelling page, the gallery's snapshots and the spot-check (`LABEL_IMAGERY=off` loads none; off by default for a private benchmark folder), and the state parcel services listed in `benchmark/parcels.rb`.
- Benchmark tooling only, for the regional check: DC GIS (`maps2.dcgis.dc.gov`), whole layers only, never per-site queries (`benchmark/regional.rb`).

## Git

- Stage files by path (never `git add -A`, `git add .` or `commit -a`); check `git diff --cached --stat` first. Don't push unless asked. Other sessions may share the folder: run `git status` first.
