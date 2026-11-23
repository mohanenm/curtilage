# Method limits (review phase 7)

What was tried against the built-in limits of the rules, how it was judged, and what was decided. Every change is an option, off by default; no default changed.

## How changes were judged

- **The public benchmark's labelled points** (`benchmark/LABELS.md`): nine Delaware sites labelled by kind, one labeller, hand-placed points only so far. Scored in the default view: the share of "in" points caught, of "out" points taken in, and per kind. At the 0.4.0 rules: 44% caught, 0.8% taken in, entrances missed at 8 of 9 sites.
- **A private held-out set** of 164 real sites, aggregate numbers only, never used for tuning: IoU against hand-drawn polygons that hug the building more tightly than the goal, so a weak guide that penalises anything larger.
- Nine sites can't separate variants that differ by a few points, so constants were chosen on principle and on how shapes look, not tuned to the labels.

## Non-convex shapes (7.1)

Premises were always convex. `Curtilage::Grid` (half-metre to two-metre cells: union, difference, closing, Voronoi splits, one simple outline) plus exact ring checks (`Geometry.overlap_area`, `ring_inside?`, `simplify_around`) now let any step produce a non-convex shape, and everything that reads premises (store and pickup zones, details, Audit, Diff, `Result#buffered`, the benchmark) handles one. A raster was chosen over an exact polygon boolean: it has none of the degenerate cases (shared edges, touching corners, holes), outlines are within a cell, and every guarantee is then checked exactly on the outline. It's under the fuzz tests (1,000 random scenes pass).

A general `shape: :concave` mode wasn't added. The labels show premises rarely overreach (0.8% of "out" points), so a mode to cut L-shaped overreach has nothing to measure against yet. Revisit when the benchmark has `l_shaped_lot` sites. Non-convex output comes from `entrances: :all` and `parcels:` today.

## Entrances: `entrances: :all`

Follows mapped service roads from the lot to every place they meet a public road (up to 250 m) and adds an 8 m corridor along each, up to the kerb, kept off roads, railways and neighbours. A walk may run at most 30 m alongside a street (within 30 m of one), so a frontage road serving the whole block isn't followed to its far end. Closing gaps between corridors and the lot was tried and dropped: no measured gain, slower, and it reached into neighbours' lots.

- Labels: entrances 5 → 12 of 24; "in" caught 44% → 48%; "out" taken in unchanged.
- Held-out: 157 of 164 sites change (typically 3-5 entrances, area +33% median); IoU 0.466 → 0.377 against the tight hand-drawn polygons; about 0.3 s a site against 0.06 s.
- Not a default: much larger premises, and a corridor along a long shared access road may belong to the whole block.

## Road widths (7.2)

Overture's `width_rules` gives a width for 117 of 111,782 public road segments in Delaware (0.1%) and 69 of 37,085 in Washington DC (0.2%), median 7 m; it has no lane counts. Geofabrik's free shapefiles carry neither. OSM's `width` and `lanes` tags would mean reading each region's `.osm.pbf` as well: a second, much larger download per region (hundreds of MB for a large state, against the few layers range-downloaded today) and a new parser path. The labels give no reason to pay that: no labelled public-road point is taken in. Nothing was built. Each road trim already records the offset used (`distance_m`) and why (`rule`: `road_class_half_width`, `clearance` or `road_offset_m`).

## Buildings missing from OSM (7.3)

`buildings: :osm_or_ml` uses machine-learned footprints only when no OSM building is under or within 30 m of the pin; every other site is exactly as with `:osm`. On the held-out set: 2 of the 5 sites with no OSM building get valid premises (IoU 0.23 and 0.65, flagged `ml_footprint`); the other 3 have no footprint either. The benchmark has no site missing from OSM. **Whether `:auto` should use it by default is an open decision**: it needs footprints in the data (a build with `--ml-footprints microsoft`, or Overture's non-OSM buildings).

## Shared lots (7.4)

- `lot_split: :voronoi` keeps the part of a shared lot nearer the site's walls than any other building's (two distance transforms on a Grid). Labels: "in" caught 44% → 45%, nothing more taken in. Held-out: mean IoU 0.466 → 0.469, IoU ≥ 0.7 on 18 sites, from 16. About 30 ms slower.
- Splitting along aisles and weighting by entrances weren't built: the labels show the split isn't the main loss. Of 126 missed parking points, 51 have no mapped parking under them (45 at one unmapped fuel forecourt), 31 lie past the 60 m reach, 22 are nearer another building's wall (the labeller judged by doors, which aren't mapped), 13 fall outside the squared-up lot and 11 sit on parking never claimed.
- Internal roads tagged as public streets (a centre's ring road) were tried as "roads through the site's own parking don't bound it" and dropped: in the benchmark's centre they run between parking polygons, not through them.

## Property lines (7.5)

`parcels:` (GeoJSON or GeoParquet, local or at a URL, or `"parcel"` features) clips the premises to the parcel holding most of the building, keeping the site's mapped parking where it runs 100 m2 or more past it (flag `beyond_parcel`). Nothing is fetched on its own; the caller answers for the data's licence.

## Multi-tenant buildings (7.6)

`unit_m:` makes a large building's store zone the slice that wide along its frontage round the pin (flag `unit_estimated`). Neither source maps units, entrances or address points; Overture's addresses theme could place address points along a frontage, a possible next step. The benchmark can't score store zones yet.

## Next

- More labelled sites, across regions, before any of these becomes a default; then calibrate confidence and named profiles on them.
- Unmapped forecourts and parking (the largest single loss), multi-building sites, and centres' internal streets.
