# Core features (Phase 6): design notes

Short notes on each Phase 6 feature: what it adds, the choices made and why. The reference documents the result.

## 6.1 Reproducibility and provenance

Each result carries `provenance`: gem version, data source and release, every option after defaults, and `features_sha256`, a hash of the map data it was made from.

- **Release.** For Overture it's the release name, settled once per call so every result in a batch names the same one. For Geofabrik builds and catalogues it's each region's extract dates, from the build's metadata. Microsoft footprints publish no dates, so the build's date stands in.
- **The hash** covers every input feature in a canonical form (keys sorted and stringified, lines sorted), so it doesn't depend on the order DuckDB returns rows or on how a caller writes keys. Same hash, version and options means same inputs.
- **No timestamps** in results or outputs. A `generated_at` would make every run differ; callers who want one add it themselves.
- **`precision:`** (default 7, about 1 cm) rounds coordinates before validation, so the polygon that was checked is the one written.
- **Order.** The rules used to depend on the order features arrived in (neighbour cuts were applied in input order), and DuckDB doesn't promise row order. See the decision below.

## 6.2 Confidence score

`Result#confidence`, 0 to 1, with `confidence_factors` listing every factor. Each unmet factor takes its weight off 1 (floor 0). A penalty sum rather than a normalised average, so one serious problem (a fallback, 0.30) counts fully whatever else is fine, and an invalid result (weight 1.0) is always 0.

- **Factors** come only from what the result already knows (flags, details, validation), so the score explains itself and adds no new rules.
- **No data age.** "Data fresh" was suggested, but scoring by today's date makes the same inputs score differently over time, which breaks 6.1. The release is in `provenance` for anyone who wants to age-filter.
- **Weights are judgement**, set before measuring. They may only be calibrated on the public benchmark (no tuning on private data), and its reference polygons aren't drawn yet.
- **First measurement** (private held-out set, aggregate only, weights not tuned to it): the 17 lowest-confidence sites (bottom 10%) hold all 5 invalid results and have mean IoU 0.25 against 0.49 for the rest; 10 of the 31 sites under IoU 0.3 land there. Among valid results the ranking is weak (Spearman 0.14 against IoU), and IoU against hand-drawn polygons, which are tighter than the goal, is itself a weak measure. So: good at surfacing the clearly bad, not yet at ordering the rest. Calibrate on the benchmark and on review outcomes (accept / nudge / redraw).
- **`--min-confidence N`** leaves results below N out of the output (exit 1, count on stderr), giving a file of results to save unattended while the rest go to review. The preview sorts by confidence instead of filtering, as it's for review.

## 6.3 Machine-readable explanation

`Result#steps`: one record per line of the explanation, same order, with `text` equal to the line. Keeping them one-to-one means a tool can show either and nothing is said in one but not the other; the notes and steps are written by the same call (`Log#note` takes the structured fields), so they can't drift apart.

- **Fields:** `step`, `text`, and when they apply `rule`, `features`, `distance_m`, `area_before_m2`, `area_after_m2`, `flag`. Absent rather than null, to keep lines short.
- **`rule`** is an option name where an option set the distance (`grow_m`, `parking_reach_m`, ...), so a reviewer can see which knob to turn; otherwise a short rule name (`road_class_half_width`, `clearance`, `halfway`).
- **Areas** are the premises in whole square metres, recorded only where a step changes the polygon. A road trimmed along several stretches is one step whose area after is the final one.
- One explanation line was added (`add_lot`, with its areas): before, adding the lot changed the polygon without a line saying so.
- Step names are documented; new ones may appear in minor versions, so readers should treat unknown names as plain notes.

## 6.4 Layered zones

Approach ⊇ premises ⊇ store zone and pickup zone, all derived from the premises, so the nesting holds by construction (checked on every held-out site at precisions 7 and 5).

- **Off by default** (`approach_m:`, `pickup_m:` nil): they add features to every site's GeoJSON, which would surprise existing readers. The CLI flags take an optional distance (`--approach` alone is 150 m).
- **Approach:** the existing rounded buffer, simplified only by dropping corners that keep every premises corner inside: still a superset, at most 16 corners for geofence limits.
- **Pickup has no data to stand on.** The brief asked for designated pickup or curbside parking where OSM maps it. Geofabrik's free shapefiles reduce parking to areas and driveways to `service`; our Overture read keeps only parking polygons; entrances aren't in either. So the zone is always estimated: the largest piece of mapped parking within `pickup_m` of the building's rectangle, kept inside the premises with the store zone's margin. No guess without mapped parking. Mapped pickup bays would need a richer extract (full `.osm.pbf`) and are left for later.
- **Validation:** zones get the shape checks (`Validation.shape_errors`), not the premises size limits (a 150 m approach zone is far over the premises area cap).
- Held-out set: approach on all 159 valid sites; pickup on 103 (65%), median about 1,480 m².

## 6.5 Entrances, staging point and drive-through

What the data allows today:

- **Driveway entrances: yes.** The rules already found where driveways taken into the premises meet a public road (`access_points`). Each now also records the street (name, class, id) and the driveway's id: `details[:entrances]` and `Result#entrances`. The points are unchanged (checked on the held-out set).
- **Staging point: estimated.** "Parking nearest the main entrance" needs the main entrance, which isn't mapped in our data, so it's the pickup zone's point nearest the building, made only with a pickup zone.
- **Building entrances and drive-through lanes: no.** Geofabrik's free shapefiles drop `entrance=*` and `service=*`; Overture's buildings have no entrances and its road subclasses (`link`, `sidewalk`, `crosswalk`, `parking_aisle`, `driveway`, `alley`, `cycle_crossing`) have no drive-through. Getting them means reading full OSM data (`.osm.pbf`, same host, much bigger files, a second build path) or waiting for Overture. Decision pending.

## 6.6 Fixing pins and finding places

- **Pin quality** on every result: `on_building`, `on_road` (within half a public road's width of its centreline, the same width the road trims use), `near_building` (within `building_max_distance_m`) or `far`, with the distance to the nearest building. On road beats near building: a geocoder's street pin is the case to catch.
- **Snapping** (`snap_m:`, off by default because it moves the pin and so changes results). A pin on the street matters more than it looks: the premises always hold the pin with 5 m clearance, so a street pin stops the road trim and drags the premises into the road. Snapping moves the pin 1 m inside the nearest building (the same choice as `building_max_distance_m`: real buildings before kiosks) and shifts the map data to the new pin rather than re-reading it: a flat shift, exact to well under a metre at these distances, and it works on `Features` passed in. Flag `pin_moved`; `pin_quality.moved_from` keeps the pin as given; confidence counts it as not on the building.
- Held-out set: 154 of 164 pins are on a building, 4 near one, 1 on a road, 5 far. Snapping at 30 m moves 5 and leaves validity and IoU as they were: this set's pins are good; geocoded pins are where it pays.
- **By name, brand or place id, and pins from Overture places:** not built yet (see the open question in the phase notes).

## 8.2 A stable CLI contract

(Pulled ahead of Phase 8 because the provenance and NDJSON schema go together.)

- `--format ndjson`: one GeoJSON Feature per line (GeoJSONSeq without the record separator), so GDAL, QGIS, tippecanoe and DuckDB read it directly and any language can parse it line by line. The store zone is a geometry in `properties.store`. Schema: `docs/schema/site-v1.json`.
- NDJSON in: each line `{"id","lng","lat"}`, `{"id","pin":[lng,lat]}` or a GeoJSON Point Feature; `--in -` reads standard input.
- Exit codes: 0 ok, 1 some sites failed, 2 bad input or usage, 3 missing dependency (DuckDB or extensions), 4 data unavailable (downloads, Overture, offline mode), 70 an unexpected error. The CLI maps by class, never by message: `ArgumentError` is 2, `Curtilage::DependencyError` 3, any other `Curtilage::Error` 4. A crash gets 70 rather than Ruby's default 1, so 1 always means "output written, some sites failed". A separate `DataUnavailable` class was left out: every other gem error already is one.
- Logs go to standard error only; `--quiet` keeps errors only and `--log-format json` writes one JSON object per line.

### Decision: making results independent of input order

Shuffling the input changed the polygon on 32 of 164 real sites, nearly all through the order of neighbour cuts (each cut works on what the ones before it left). Chosen (2026-11-23):

- **Nearest neighbour first** (ties by id): the closest building bounds the lot most, so it's cut first. Only the buildings a cut considers are sorted, which keeps generation as fast as before.
- **The input is sorted** into one canonical order before the rules run, covering the rest (one road case) and making the 20,000-feature cap take the same features every time.

On the private held-out set this gives the same answer for every input order. Mean IoU went from 0.469 to 0.466; today's 0.469 came from one lucky order, and random orders gave 0.464-0.466. Slanted road edges went from 7 sites to 8.
