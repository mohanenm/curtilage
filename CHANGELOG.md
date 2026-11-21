# Changelog

## [Unreleased]

First release, not yet published. What it does:

### Premises
- Grows the building's rectangle 30 m toward its lot, trims at public roads and railways, and claims the site's parking; falls back to the building rectangle plus a margin when that fails validation. Every result has a step-by-step explanation.
- Roads: stops half a typical road width short of the centreline (by road class), but always at least 3 m out from the building (`building_clearance_m`). Cuts follow each road's fitted direction beside the site, nearest road first, snapped square to the building within 5 degrees. Roads and railways in tunnels or on bridges are ignored.
- Railways at ground level bound the premises like roads.
- Neighbours: stops 3 m short of a neighbouring building, square to the building (halfway when the gap is narrower). Homes (typed in OSM, or untyped small buildings in a row) get the halfway split when the site is behind them (their back yard, judged by which way they face their street).
- Lot: mapped parking within 20 m of the building is the site's, up to the kerb and at most 60 m out. A lot shared with one or two other buildings is claimed whole (split halfway only with homes); a shopping-centre lot (three or more buildings) is split by nearest building. Parking garages, carports and canopies next to the building count as lot, and driveways linking the lot to a public road are taken in up to the kerb.
- When the pin isn't on a building, the nearest real building within 30 m is used, not a tiny canopy next to it.
- Presets: `:whole_lot` (default), `:tight` (building plus a small margin) and `:centre` (a store on a shared lot gets the whole shopping centre, flagged `shopping_centre`).

### Store zone
- `result.store_ring` is the building's OSM outline (any shape, at most 20 corners, never self-crossing), always inside the premises: the premises take in the whole building and the outline is clipped 5 cm inside them. `store_zone: false` turns it off.

### Flags and validation
- Flags, checked against reviewed sites: `near_houses`, `large_building` (over 5,000 m2), `small_building` (under 50 m2), `building_not_under_pin`, `store_may_be_unit` (over 1,500 m2), `shopping_centre`, `fallback`, `ml_footprint`, `no_data`.
- `Validation.check` errors on missing, unclosed, self-intersecting or swapped rings, a pin outside, vertices too far away, too many vertices, or an area over 100,000 m2; warns on small, large or off-centre polygons.
- `Audit.check` scores an existing polygon (crosses a road, covers a neighbour, differs from what would be generated).

### Data
- On demand: `generate_many(pins)` finds each pin's region in Geofabrik's index (worldwide), builds only those regions into a temporary folder or `cache_dir:` (reused for a month, locked so concurrent jobs build once) and cleans up.
- `source: :overture`: reads features in place from Overture Maps' latest release, using its file index and sharing reads between nearby pins.
- `curtilage build REGION`: any US state or Geofabrik region path; downloads only the layers it uses with HTTP range requests (CRC-checked, full-file fallback), reads every part of split layers and multi-part regions (California), keeps building types, and builds with DuckDB capped at 400 MB and 1 thread. Writes `<region>.json` metadata beside the Parquet file.
- `Catalogue`, batch lookups (`Lookup.features_many`), Parquet read from `s3://`, `gs://` or `https://`.
- Optional machine-learned building footprints (Microsoft, ODbL): `--ml-footprints microsoft`, then `buildings: :osm_filled` or `:ml`. OSM only is the default.
- Map data is treated as untrusted: size and vertex caps, invalid geometry dropped and counted.

### Interface
- `Curtilage.generate`, `Curtilage.generate_many`, `Result#to_geojson` (with attribution; `include_store: true` for both shapes), and the `curtilage build` / `curtilage generate` commands.
- MIT licence.
