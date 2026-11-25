# curtilage

[![Gem Version](https://badge.fury.io/rb/curtilage.svg)](https://badge.fury.io/rb/curtilage)

**Free, explainable premises polygons and geofences for any store, from OpenStreetMap.**

*Curtilage: the land immediately around a building, such as its yard, drive and lot.*

Give it a pin; it gives back the site's **premises polygon** (the building plus its customer-facing lot, up to the kerb) and a **store zone** (the building's own outline), with review flags, a confidence score and a plain-words explanation of every step. Map data is fetched as needed, so nobody has to draw polygons by hand or host anything.

## Try it

The pin below is a public store from the [benchmark](benchmark/sites.geojson). With Docker (it builds the image from this repository, a few minutes the first time):

```sh
docker build -t curtilage https://github.com/mohanenm/curtilage.git && docker run --rm curtilage generate --pin -75.71809,39.46075
```

Ruby (`gem install curtilage`, plus the [DuckDB CLI](https://duckdb.org/docs/installation/)):

```ruby
require "curtilage"
result = Curtilage.premises([-75.71809, 39.46075])   # [lng, lat]
result.ring          # [[lng, lat], ...]
result.explanation   # each step, in words
```

Any other language, through the HTTP API (`curtilage serve`, or `docker run --rm -p 127.0.0.1:8754:8754 curtilage serve --host 0.0.0.0`):

```sh
curl -s localhost:8754/premises -d '{"pins": [[-75.71809, 39.46075]]}'
```

```python
import json, urllib.request
body = json.dumps({"pins": [[-75.71809, 39.46075]]}).encode()
sites = json.load(urllib.request.urlopen("http://127.0.0.1:8754/premises", body))   # a GeoJSON FeatureCollection
```

## Who it's for

- **Geofencing and pickup:** know when a customer arrives on site, not just near it; optional approach and pickup zones ([geofence server](docs/recipes/geofence-server.md), [platforms](docs/recipes/geofence-platforms.md), [mobile circles](docs/recipes/mobile-circles.md)).
- **Delivery:** a drop-off area per address that stops at the street ([Rails background job](docs/recipes/rails.md)).
- **Location analytics:** count visits inside the lot rather than within a radius ([DuckDB](docs/recipes/duckdb.md), [GeoPandas](docs/recipes/geopandas.md), [PostGIS](docs/recipes/postgis.md)).
- **Site selection:** parking area, street frontage and driveway entrances for every candidate site, e.g. all pharmacies in a state from `curtilage places` ([QGIS](docs/recipes/qgis.md)).
- **Research:** a documented, rule-based method you can rerun and cite, with a public [benchmark](benchmark/README.md).
- **OpenStreetMap mapping:** a task list of stores whose building is missing from the map ([Giving back](#giving-back-to-openstreetmap)).

## How it compares

Scored on the public benchmark's labelled points (default view): the share of points that should be inside that are, and of points that should stay out (roads, neighbours' buildings and lots, homes) that are taken in anyway. Three groups of sites: 24 held-out sites (two sets, of 16 and 8) in states that had no tuning sites when they were labelled, labelled blind and scored only in a release check; 7 validation sites, labelled before their results were seen; and 25 labelled sites used for tuning. The held-out numbers are the fair comparison; the tuning ones flatter curtilage. Simple alternatives were scored the same way; paid datasets and hand-drawing weren't.

| | Cost | Coverage | Held-out sites, 24 (in caught / out taken) | Validation sites, 7 | Tuning sites, 25 | Explainability | Licence of the polygons | Effort |
|---|---|---|---|---|---|---|---|---|
| Drawing by hand | Staff time, minutes per site | Anywhere with imagery | The yardstick, but people draw it differently | | | Whatever the drawer notes | Yours, if the imagery's terms allow tracing | High, every site and every change |
| Circle around the pin | Free | Everywhere | 50 m: 80% / 23%; 75 m: 94% / 51% | 50 m: 47% / 12%; 75 m: 76% / 30% | 50 m: 62% / 33%; 75 m: 81% / 54% | None needed | Yours | None |
| Building outline only | Free (OSM, or ML footprints) | Wherever the building is mapped | Not measured | 4% / 6% | 5% / 4% (23 sites) | Simple | ODbL (OSM) | Low |
| Tax parcel (the property line) | Free in some states and counties, paid elsewhere | Where the county's parcels are published | Not measured (no parcel service in the benchmark for those states) | 63% / 7% (6 of 7 sites have one) | 63% / 14% (the 23 sites with one) | A legal boundary, not the customer-facing lot | Varies by county | Collecting and keeping each county's data |
| Paid POI polygon datasets | A licence fee | The vendor's place list | Not measured | | | Usually opaque | Proprietary, with use limits | Low, if your places are in the list |
| curtilage | Free | Wherever OSM has the building (Overture or Geofabrik) | 80% / 6.8% (set of 16: 77% / 7.8%; set of 8: 87% / 4.6%) | 47% / 14.5% | 73% / 6.0% | Every step, flags, confidence | ODbL (share-alike when you publish a database of them) | Low; review the flagged sites |

On the 24 held-out sites curtilage catches as much of the lot as a 50 m circle (80%) and takes in less than a third as much that should stay out (6.8% against 23%). The set of 8 was drawn to keep pins that are off the business, but all 8 of its pins landed within 15 m of the business's building, so it says little about misplaced pins. Where it loses: on the validation sites, which hold the hardest cases (a pin in the road, a 28,000 m2 building, large shared buildings), a 50 m circle scores about the same and a published tax parcel does better. curtilage starts from the building at the pin, so a pin off the business costs it more than it costs a circle; three held-out sites whose map point was off the business, or whose business couldn't be seen on the imagery, were replaced while labelling, before any result was seen, so the held-out numbers likely understate that cost. All the sets are small. It also still stops short of some lots (deep lots, lots running past a neighbour, shared lots split by guesswork) and gives nothing where no building is mapped at all. Its polygons are ODbL, which a paid dataset's aren't.

**Status:** 0.9, rule-based; the API may change before 1.0. The [public benchmark](benchmark/README.md) has 66 public sites in 32 states, each labelled with points saying what is physically there, in three groups: 35 sites the rules were tuned on (25 of them labelled); 7 validation sites, labelled before their results were seen and scored with every run; and 24 held-out sites in 24 further states (Michigan and Missouri have since gained tuning sites), in two sets (16 and 8), labelled blind and scored only before a release, totals only. Default view, share of what should be in that is caught / of what should stay out that is taken in: tuning 73% / 6.0%, validation 47% / 14.5%, held-out 80% / 6.8% (77% / 7.8% and 87% / 4.6% for the two sets). Counting only what every use case agrees on (the site's building, own parking, drive-through, forecourt and entrances in; roads, neighbours, homes out): 90% / 1.3%, 60% / 8.9%, 85% / 3.6%. The validation sites include the hardest cases in the benchmark (a pin in the road, a 28,000 m2 building, large shared buildings); the held-out sets hold few pins that are off the business, so they likely understate what a misplaced pin costs. All the sets are small. Results are good where the pin is on or beside the right building, and poorer where the building is large or shared. The options added in 0.8 (`parcel_mode: :grow`, `shared_checks`) are experimental and off by default: `shared_checks` makes confidence track errors on the tuning sites, but only slightly on the set of 16 held-out sites (rank correlation -0.41, against -0.36 without).

Where you have tax parcels: on the tuning and validation sites, adding the parking and service roads inside the site's parcels (`parcel_mode: :grow`) catches more of the lot (71% → 73% on the 23 tuning sites with parcels, 47% → 63% validation) for a little more taken in (6.5% → 6.8%, 14.5% → 16.7%). Clipping to the parcel (the default when parcels are given) takes in less (5.2%, 8.7%) but misses more of the lot (64%, 47%), because parcels stop short of the kerb and a store's lot often crosses them. A parcel on its own scores 63% / 14% on tuning and 73% / 8.1% on the 6 validation sites that have one. The parcel modes aren't measured on the held-out sites: their states have no parcel service in the benchmark. Anyone can rerun all of it (`rake benchmark`, `rake benchmark:parcel_modes`). On private sets of real sites that can't be published:

- On 164 sites the rules had never seen, 159 (97%) got a polygon that passed the gem's own validation (pin inside, closed, no self-intersection, plausible size). Nearly all five misses were buildings missing from OpenStreetMap. Passing validation means usable, not necessarily right.
- Against hand-drawn premises for those sites, the median overlap (IoU) was 0.48. Hand-drawn polygons often hug the building more tightly than the whole lot this gem aims for, so IoU undersells generous but correct results.
- The 20 sites used to tune the rules were also reviewed by eye on aerial imagery, which is a subjective check. An earlier version gave similar validity on 51 sites in the US, Brazil and Hungary (47 of 51).

## Quick start

1. Install the gem (`gem install curtilage`, or `gem "curtilage"` in your Gemfile; Ruby 3.2 or newer) and the [DuckDB CLI](https://duckdb.org/docs/installation/), 1.4 LTS or 2.0 (`brew install duckdb` gives 2.0). Check with `curtilage doctor`; DuckDB's extensions install themselves.
2. Ask for premises:

```ruby
require "curtilage"

result = Curtilage.premises([-80.0, 35.0])   # [lng, lat]
result.ok?          # true when it passed validation
result.ring         # the premises polygon, [[lng, lat], ...]
result.store_ring   # the building's outline, inside the premises
result.flags        # anything a person should check, e.g. [:near_houses]
result.to_geojson   # ready to draw or save, with the attribution to show
```

Or from the shell:

```sh
curtilage generate --pin -80.0,35.0                     # one pin: GeoJSON to the screen
curtilage generate --in sites.csv --out premises.csv    # a file of pins in; CSV, GeoJSON, NDJSON or KML out
curtilage preview --in sites.csv                        # a page with a map of each site, to check by eye
```

`sites.csv` needs `lng` and `lat` columns; an `id` column is carried through to the output:

```csv
id,lng,lat
store-1,-80.0,35.0
store-2,-80.1,35.2
```

That's all the setup: map data is fetched as needed. No Ruby? Use [Docker](#docker). Everything else (every option, flag and command) is in the [reference](docs/reference.md).

## Data licence

The code is MIT-licensed; the polygons are not. Every result is derived from [OpenStreetMap](https://www.openstreetmap.org/copyright) data, which is available under the [Open Database License (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/1-0/):

- **Credit OpenStreetMap wherever results are shown or shared**, and make clear the data is under the ODbL ([OSMF attribution guidelines](https://osmfoundation.org/wiki/Licence/Attribution_Guidelines)). Every output carries what to credit: `attribution` in GeoJSON properties and in CSV, the KML description, the preview page.
- **Storing or publishing many results** can make a *derivative database*. If you use one publicly, the ODbL asks you to offer it under the ODbL too (section 4.4).
- **A map image or similar *produced work*** made from results needs a notice that it contains data from OpenStreetMap under the ODbL (section 4.3); the image itself doesn't have to be ODbL.
- Overture data is also credited to the Overture Maps Foundation, and Overture's non-OSM buildings to their source, when a result could use them. Microsoft's footprints are under [CDLA Permissive 2.0](https://cdla.dev/permissive-2-0/).
- The OSMF [community guidelines](https://osmfoundation.org/wiki/Licence/Community_Guidelines) cover the common cases (produced works, what counts as substantial, collective databases, geocoding). This section is a summary, not legal advice.

## How it works

1. **Data.** Buildings, parking lots, roads and railways from OpenStreetMap, picked automatically (`source: :auto`, the default):
   - **Scattered pins: Overture Maps, read in place.** The same OpenStreetMap data from Overture's public release, read straight from their storage: about 5-10 s per area, nothing downloaded.
   - **Many pins in one region, or a region already cached: a Geofabrik build.** The gem downloads only the layers it needs from that region's shapefiles and builds a compact Parquet file, 1-5 minutes per US state, then answers instantly.
   - Or force one: `source: :geofabrik` (the host only ever learns the region, never the area) or `source: :overture`. Or use your own prebuilt files (`curtilage build`), local or in a bucket.
2. **Generate.** Start from the building at the pin (a pin on a fuel or drive-through canopy means the shop beside it) and grow its rectangle 30 m toward its lot, then:
   - stop at public roads, half a typical road width short of the centreline (by road class, measured on the benchmark's labels) but at least 3 m out from the building, following each road's direction; and at railways;
   - take in the site's mapped parking (a lot shared with a few buildings is claimed whole; a shopping-centre lot the site fronts is split by nearest building, flagged `shared_lot`), parking garages, canopies, and driveways to the street; where a lot is mapped only as service roads (aisles and driveways), a strip either side of them stands in for it;
   - stop 3 m short of neighbouring buildings, or halfway when the site is behind a house (its back yard), and at the edge of another business's mapped lot;
   - fall back to the building's rectangle plus a margin if that fails validation.
   Every result explains each step and carries review flags.
3. **Validate.** Reject or flag polygons that are unsafe to use: pin outside, unclosed, self-intersecting, swapped coordinates, too far from the pin, an implausible size. The store zone always sits inside the premises.

It's rule-based: no machine learning in the method. Coordinates are `[lng, lat]` throughout, as in GeoJSON.

## Usage

### In Ruby

```ruby
pins = [[-80.0, 35.0], [-80.1, 35.2]]
results = Curtilage.generate_many(pins)                       # data picked automatically (Overture or Geofabrik)
results = Curtilage.generate_many(pins, source: :geofabrik)   # always build regions: most private, slower
results = Curtilage.generate_many(pins, preset: :centre)      # whole shopping centre where on a shared lot

Curtilage.configure do |c|                                    # once, instead of options on every call
  c.cache_dir = "/var/cache/curtilage"                        # reuse on-demand builds for a month
end
```

- Styles: `preset: :whole_lot` (default), `:tight` (building plus a small margin) or `:centre`. `store_zone: false` skips the store zone. Every rule's distance is an option ([reference](docs/reference.md#generation-options)).
- Built ahead of time, for instant lookups: `curtilage build tennessee`, then `generate_many(pins, catalogue: Curtilage::Catalogue.from_dir("."))`. Files can also live in a bucket (`s3://`, `gs://`, `https://`).
- Just the building at a pin: `Curtilage.building_at(pin)`.
- No pin list? `curtilage places --region virginia --category pharmacy` (or `--brand`) lists matching places from Overture Maps as pins to generate from (`Curtilage.places` in Ruby). Each row names its sources and licences.
- Big sites (a big-box store's lot can pass 100,000 m2, where validation stops by default): raise the limits, e.g. `validation: { max_area_m2: 200_000, max_area_error_m2: 300_000 }` ([reference](docs/reference.md#validation-limits)).
- Fix the few bad sites once: `--corrections fixed.geojson` (your edited output, matched by id) uses your polygons instead of generating them, marked manual. After a data refresh, `curtilage diff last.ndjson new.ndjson` lists only the sites whose premises changed enough to look at again.
- Check a polygon someone already drew: `Curtilage::Audit.check(pin, ring, features)` returns `:ok`, `:review` (with reasons) or `:invalid`.

### What each result holds

| | |
|---|---|
| `ok?` | It passed validation. Never save one that isn't. |
| `ring` / `store_ring` | The premises and the store zone, `[[lng, lat], ...]` closed. |
| `flags` | Reasons a person should look first ([below](#flags)). |
| `pin_quality` | Where the pin was given: `on_building`, `on_road`, `near_building` or `far`, and how far from the nearest building. With `snap_m: 30`, a pin off any building is moved onto the nearest one (flag `pin_moved`). |
| `confidence` | 0 to 1, from documented rules (fallback used, pin off the building, no mapped parking, ...), to decide which sites to review first ([reference](docs/reference.md#confidence)). |
| `explanation` | Each step, in plain words. |
| `details` | The building (id, name, type, area, outline), mapped parking inside the premises and an estimate of spaces, street frontage, and where driveways meet the street. Rough, like the map data. |
| `candidates` | With `candidates: 3`, other premises an ambiguous site could have (another building near the pin, the whole shopping centre, a tighter shape), each with its own confidence and flags. |
| `approach_ring`, `pickup_ring` | Optional zones for arrival detection (`approach_m: 150`, `pickup_m: 25`): the premises grown for "customer is near", and the parking right by the store (estimated). Nested with the premises ([reference](docs/reference.md#zones)). |
| `buffered(15)` | The premises grown 15 m (rounded corners), e.g. for a geofence with a margin; negative shrinks. |
| `to_geojson`, `to_wkt` | Ready to draw or store. GeoJSON carries everything above and the attribution to show. |
| `attribution` | What to credit wherever the result is shown ([Data licence](#data-licence)). |

### Files

`curtilage generate --in FILE --out FILE` reads pins from a CSV (as above), a GeoJSON file of points or NDJSON (one site per line; `--in -` reads standard input), and writes:

- **CSV** (`.csv`): one row per pin with its id, `ok`, flags, the details, the polygons as WKT and the attribution. Opens in any spreadsheet.
- **GeoJSON** (`.geojson`): one FeatureCollection, the premises and store zone of each pin, with the id in each feature's properties.
- **NDJSON** (`.ndjson`, or `--format ndjson`): one GeoJSON Feature per site per line, with a [versioned schema](docs/schema/site-v1.json). For scripts in any language, and for GDAL, QGIS or DuckDB.
- **KML** (`.kml`): for Google Earth, with the attribution in its description.
- **GeoParquet** (`.parquet`), **GeoPackage** (`.gpkg`) and **FlatGeobuf** (`.fgb`), with `--out`: for analytics, QGIS and web maps. Written through DuckDB, one row a site with the premises as the geometry, the store zone as WKT, and the flags, confidence, attribution and provenance as columns. FlatGeobuf holds only the sites with premises.

From Ruby, `Curtilage::Formats` does the same ([reference](docs/reference.md#files-curtilageformats)).

### Recipes

PostGIS, geofences on your own server, circles for mobile geofences, geofence platforms, QGIS, DuckDB, GeoPandas and Rails: [docs/recipes](docs/recipes/README.md), each with made-up data.

### HTTP API

`curtilage serve` runs a small HTTP API on this machine (127.0.0.1:8754): `POST /premises` with `{"pins": [[-80.0, 35.0]]}` answers GeoJSON (or NDJSON), for apps in any language. Set `CURTILAGE_SERVE_TOKEN` to require a bearer token; requests, pins and time are capped, and pins are never logged. Put a reverse proxy in front for TLS. Details and the OpenAPI spec: [reference](docs/reference.md#http-server-curtilage-serve).

### Checking results by eye

`curtilage preview --in sites.csv` writes `curtilage-preview.html`: a card per site with a map drawn from the map data the premises were made from. Each map shows:

- the premises (green), the store zone (outline) and the pin;
- the site's building (darker) and its neighbours, mapped parking, public roads (hover for the name), service roads and driveways, and railways;
- where driveways meet the street (blue dots), and with `--buffer 15` the premises grown 15 m (dashed);
- a 50 m scale bar; each map is 240 m across, north up.

Under each map: the flags (hover for what they mean), the building and premises areas, parking and an estimate of spaces, street frontage, the number of entrances, and "How it was made", the step-by-step explanation. Invalid results say why.

For examples, the [gallery](https://mohanenm.github.io/curtilage/gallery/) is this page, drawn over public-domain USGS aerial snapshots, for the public benchmark sites (all but the held-out ones), with each site's category and what its labels say it got wrong, failures included. It is rebuilt with `rake benchmark:gallery`.

At the top, a count of sites that are ok, flagged or unusable, and controls to show only some (sites that need a look, invalid ones, or those with a given flag) and to sort them (input order, needs a look first, lowest confidence first, id, or premises size).

![The preview page: two of six public benchmark sites, each drawn with its premises, store zone, parking, roads and driveway entrances](https://raw.githubusercontent.com/mohanenm/curtilage/main/docs/preview.png)

*Randomly chosen locations, not real sites. Map data © OpenStreetMap contributors.*

The page loads nothing from the internet (no map tiles, scripts or fonts), so opening it reveals no locations. It does contain the coordinates, so share it only as you would them. From Ruby: `Curtilage::Preview.html(Curtilage.generate_many(pins, keep_features: true))`.

### Docker

The repository's `Dockerfile` packages the gem with DuckDB and its extensions, for machines without Ruby:

```sh
docker build -t curtilage .
docker run --rm -v "$PWD:/work" -v curtilage-cache:/cache curtilage generate --in sites.csv --out premises.csv
```

The current folder is mounted at `/work`, so file names are relative to it. The `curtilage-cache` volume keeps on-demand builds for a month.

### Flags

| Flag | Meaning |
|---|---|
| `near_houses` | The lot borders a home: check where the yard or property line is |
| `large_building` | Building over 5,000 m2: may be shared by several tenants |
| `small_building` | Building under 50 m2: may be a kiosk or canopy rather than the store |
| `building_not_under_pin` | No building under the pin; the nearest one within 30 m was used |
| `pin_moved` | The pin wasn't on a building and was moved onto the nearest one (`snap_m:`): check it's the right one |
| `store_may_be_unit` | Store zone is a building over 1,500 m2: the store may be one unit of it |
| `shopping_centre` | `scope: :centre` mapped the whole centre |
| `large_centre` | `scope: :centre`, but the centre is over `centre_max_m2`: the premises are the site's own share |
| `shared_lot` | The lot is shared with other buildings and was split by nearest building: where it really divides isn't in the map |
| `fallback` | The main method failed validation; the building rectangle was used |
| `partial_data` | Part of the area around the pin is in a region that isn't built |
| `ml_footprint` | Built on a machine-learned footprint, not an OSM building |
| `unit_estimated` | The store zone is an estimated unit of a large building (`unit_m:`): check it |
| `beyond_parcel` | The site's parking runs past the building's parcel (parcels supplied): check the property line |
| `shared_parcel` | `parcel_mode: :grow`: the building's parcel also holds other businesses, so it was only a limit |
| `no_data` | No map data covers the pin |
| `error` | Generating this site raised an error (see its explanation); the rest of the batch went on |

### Speed

- Generate: about 30 ms per site (median on the public benchmark's commercial sites), up to about a second for a large shopping centre.
- Big batches: 10,000 made-up pins in one state took under 2.5 minutes from a prebuilt file on a laptop (about 70 sites a second), with Ruby under 650 MB however long the batch. `curtilage generate` works in chunks of 500, shows progress on a terminal, streams NDJSON and CSV, and `--resume` carries on an interrupted run.
- Prebuilt files: about 2 ms a pin in batches (one DuckDB call serves 500 pins); about 85 ms for a single lookup, mostly starting DuckDB.
- Overture (the default for scattered pins): about 5-10 s per area; pins within a few km of each other share it. A test batch of 51 sites in 17 regions across three continents took 4 minutes from a cold start; the 164 (143 pins read from Geofabrik builds, 21 from Overture) took under 6.
- Geofabrik builds (the default once 10+ pins share a region): 1-5 minutes per US state the first time (Texas, the largest tested, about 4.5 minutes and under 650 MB of memory), then as above. Downloads use `curl` when it's installed, and `data: { parallel_builds: 2 }` builds two regions at once on machines with the memory.

## Known limitations

**Results are proposals for review, not survey-grade property lines.** They're built from open map data by fixed rules, so they're only as good as what's mapped near the site, and a person should check them before they're used for anything that matters. These are the patterns seen in testing, the flag that marks each, and what helps:

**Where results are usually good:** a pin on or within about 30 m of the business's own building, with its own lot. On 24 held-out sites in states that had no tuning sites when they were labelled, the default caught 80% of what should be in and took in 6.8% of what should stay out.

**What to check by hand first:** results flagged `store_may_be_unit`, `large_building`, `shared_lot`, `building_not_under_pin`, `fallback` or `ml_footprint`, and the lowest-confidence results. Large shared buildings and lots shared with other stores are where results are weakest.

| What goes wrong | Flag | What helps |
|---|---|---|
| **The building isn't in OpenStreetMap** (about 3-8% of sites tested): nothing is generated. | (no premises) | Sites read from Overture (the default for scattered pins) fall back to its machine-learned footprints for those sites, flagged `ml_footprint`. Elsewhere, `buildings: :osm_or_ml` with a build made `--ml-footprints microsoft`; on a private test set it rescued 2 of 5. |
| **Premises fall short of the whole lot**, more than they overreach: mostly parking shared with other stores, where the map doesn't say how the lot divides (on the benchmark's tuning sites, nearly all lot points missed beyond 60 m of the building are shared parking), and a lot that runs past a neighbouring building (the cut that keeps the premises off the neighbour runs straight across the lot beyond it). | `shared_lot` | `parcel_mode: :grow` with parcels you supply; `neighbour_cut: :notch` cuts round the neighbour instead; `entrances: :all` follows mapped driveways to every entrance. All experimental, off by default; each caught more of the lot on the benchmark's tuning and validation sites, for a little more taken in. |
| **Fields and open land behind a building:** the premises grow 30 m from the building, and nothing in the map data marks where a field or tree line starts. | | `grow_m` smaller, or a correction. |
| **A store that's one unit of a large building** (strip malls, urban blocks): the store zone is the whole building, the premises its whole lot. | `store_may_be_unit`, `large_building` | `unit_m: 15` estimates the unit round the pin (flag `unit_estimated`); `preset: :tight`, or `scope: :centre` for the whole centre. |
| **Shopping centres.** A shared lot is split by nearest building, but where it really divides between properties isn't in the map; a centre's internal roads tagged as public streets (ring roads, "Plaza" streets) cut a store off from its car park; a building at an angle to its lot gets an oversized rectangle. | `shared_lot`, `store_may_be_unit` | `parcels:` (property lines you supply), `scope: :centre`, `candidates: 3`. Internal roads mapped as public streets have no fix yet. |
| **Sites spread over several buildings** (compounds, campuses): only the building at the pin counts as the site, so premises come out too small. (A pin on a fuel canopy is handled: the shop beside it is the site.) | `small_building` | `candidates: 3`, or a correction. |
| **Property lines aren't known.** Premises follow roads, railways and neighbours, not legal boundaries. | `near_houses` | `parcels:` clips to property lines you supply (flag `beyond_parcel` where the site's parking runs past them); `parcel_mode: :grow` also takes in the parking inside them. |
| **Road widths are typical figures by road class**, measured on the benchmark's labels: no free source maps each road's width (Overture gives one for about 0.1-0.2% of roads), so a wide road can still take a strip of kerbside lot, or a narrow one leave a strip out. | | `road_offset_m` for a fixed offset. |
| **Default premises are convex.** An L-shaped site gets a diagonal edge that can cross a neighbour's corner. | | `neighbour_cut: :notch`, `entrances: :all` and `parcels:` can give non-convex premises. |
| **Dense rowhouse blocks:** cuts toward many close neighbours can leave a thin sliver; `near_houses` fires almost everywhere in dense areas. | `near_houses` | |
| **Sites within about 100 m of the antimeridian** (180° longitude: parts of Fiji, Chukotka, the Aleutians) get no polygon: premises can't cross that line. | (no premises) | |

## Building footprints: OSM, or OSM plus machine-learned

By default all buildings come from OpenStreetMap. Where OSM is missing buildings, you can opt in to [Microsoft's Global ML Building Footprints](https://github.com/microsoft/GlobalMLBuildingFootprints) (CDLA Permissive 2.0): build with `--ml-footprints microsoft` (or `ml_footprints: "microsoft"`), then generate with `buildings: :osm_or_ml` (only where OSM has no building near the pin), `:osm_filled` or `:ml`. With Overture reads (`source: :overture`, and `:auto` for scattered pins), Overture's non-OSM buildings play the same role and are used by default where OSM has no building near the pin (`buildings: :osm_or_ml`; pass `buildings: :osm` to turn that off). Results built on one carry the `ml_footprint` flag, and their attribution credits the footprints' source.

## Giving back to OpenStreetMap

Most sites that get no premises are buildings missing from OpenStreetMap. `curtilage missing-buildings` lists them as a task list for mappers, so the fix goes into the map for everyone:

```sh
curtilage missing-buildings --in sites.csv --out missing.geojson               # GeoJSON points
curtilage missing-buildings --in sites.csv --maproulette --out missing.jsonl   # for a MapRoulette challenge
```

Each task is a point with what to do, and whether a machine-learned footprint lies nearby (something to trace). Your site ids stay out unless you pass `--with-ids`. Map from imagery you're allowed to use (the [OSM editors](https://wiki.openstreetmap.org/wiki/Editors) offer some) and follow the [OSM guidelines](https://wiki.openstreetmap.org/wiki/How_We_Map).

**Don't publish a private site list.** Points with no names still say where your sites are: a list of a client's stores, or of sites you're scouting, can be confidential. Map them yourself, or share them only where you're allowed to.

## Privacy

Pins never leave the machine as coordinates: they aren't put in any URL or request, and appear only in your own outputs and local error messages. What hosts can learn depends on the data source:

| When | Host | What it learns |
|---|---|---|
| Geofabrik build (`source: :geofabrik`, or `:auto` where 10+ pins share a region or it's cached) | `download.geofabrik.de` | Which region(s) you build, from the region index and the region's file. Not where in the region. |
| Overture read (`source: :overture`, or `:auto` for scattered pins) | `stac.overturemaps.org` | Which Overture release you use. Nothing about the pins. |
| `curtilage places` / `Curtilage.places` | Overture's storage, and Geofabrik for `--region` | The box or region you search, and Geofabrik's region index is downloaded. No pins are involved. |
| | Overture's storage (Amazon S3, `overturemaps-us-west-2`) | Which files and parts of files are read: roughly where each pin is, to within a few km. |
| Your own built files (`catalogue:`, `parquet:`) on disk | none | Nothing. |
| ... in your bucket (`s3://`, `gs://`, `https://`) | your bucket's host | The parts of files read: roughly where each pin is. |
| Microsoft footprints in a build (opt-in) | Microsoft's footprint host | Which tiles cover the region you build. |
| First run, or `curtilage doctor` | DuckDB's extension repository | That you install the `spatial` and `httpfs` extensions, and your DuckDB version and platform. |
| `--h3` / `Curtilage::H3` (opt-in) | DuckDB's community extension repository | That you install the community `h3` extension, and your DuckDB version and platform. |

- **For a sensitive list of locations, use `source: :geofabrik`** (or `CURTILAGE_SOURCE=geofabrik`): hosts then learn only which regions you build. `:auto` reads scattered pins from Overture.
- The gem's own downloads go only to Geofabrik, Overture's catalogue and Microsoft's footprint host, and anything else is refused. DuckDB reads Overture's storage, your bucket and its extension repository itself.
- If a DuckDB query fails, its error message can quote part of the query, including the coordinates of the box around a pin. That stays on your machine unless your app forwards errors to an outside service.
- To guarantee nothing leaves the machine, set `CURTILAGE_OFFLINE=1` and use prebuilt files or a cache: downloads, extension installs and Overture or bucket reads are then refused.
- The benchmark's labelling page (repository tooling, not the gem) loads public-domain imagery from USGS (`imagery.nationalmap.gov`, `basemap.nationalmap.gov`), which learns the area of each site you label; build it with `LABEL_IMAGERY=off` to load nothing, the default for a private benchmark folder. `rake benchmark:parcels` sends the public benchmark sites' locations to the state parcel services, and `rake benchmark:gallery` fetches one USGS snapshot per public site (the published gallery then loads nothing). None of these run during generation.
- The preview page loads nothing from the internet. Building the Docker image fetches DuckDB from its GitHub releases and its extensions from DuckDB's repository.

## Layout

| Path | What |
|---|---|
| `lib/curtilage.rb` | Entry points: `generate`, `generate_many`, presets |
| `lib/curtilage/generator.rb` | Methods, the fallback chain, road and neighbour trims, flags |
| `lib/curtilage/generator_lot.rb` | Which parking, garages, canopies and driveways are the site's |
| `lib/curtilage/generator_store.rb` | The store zone |
| `lib/curtilage/generator_details.rb` | Facts about the site: parking, frontage, entrances |
| `lib/curtilage/result.rb` | What generation returns: GeoJSON, WKT, buffering |
| `lib/curtilage/formats.rb` | Pins in from CSV, GeoJSON or NDJSON; results out as GeoJSON, NDJSON, CSV or KML |
| `lib/curtilage/preview.rb` | The HTML review page |
| `lib/curtilage/features.rb` | Parses nearby map features (untrusted) and projects them to metres |
| `lib/curtilage/geometry.rb` | Plain-Ruby planar geometry |
| `lib/curtilage/validation.rb` | Checks a polygon against its pin |
| `lib/curtilage/audit.rb` | Checks an existing polygon against the map and the generated one |
| `lib/curtilage/auto_data.rb` | Builds the regions pins need on demand, into a temporary or cache folder |
| `lib/curtilage/regions.rb` | Geofabrik's region index: which region a pin is in |
| `lib/curtilage/build.rb` | Builds a region's features Parquet file from Geofabrik shapefiles |
| `lib/curtilage/zip_range.rb` | Downloads only the needed files from a remote zip |
| `lib/curtilage/catalogue.rb` | Finds the built region file(s) covering a pin |
| `lib/curtilage/lookup.rb` | Reads the features around pins from Parquet files |
| `lib/curtilage/overture.rb` | Reads features in place from Overture Maps |
| `lib/curtilage/footprints.rb` | Optional machine-learned footprints (Microsoft) |
| `lib/curtilage/download.rb` | HTTPS downloads from allowed hosts, with size caps |
| `lib/curtilage/config.rb` | Shared settings (`Curtilage.configure`, environment variables) |
| `lib/curtilage/duckdb.rb` | Runs the DuckDB CLI |
| `lib/curtilage/error.rb` | `Curtilage::Error`, the base of every error the gem raises |
| `exe/curtilage` | `curtilage generate`, `preview`, `places`, `diff`, `build`, `doctor`, `serve` and `missing-buildings` |
| `lib/curtilage/server.rb` | The HTTP API (`curtilage serve`) |
| `Dockerfile` | The gem with DuckDB, ready to run |
| `docs/reference.md` | Every option, setting, flag and command |
| `sql/build_from_shapefiles.sql` | DuckDB query: shapefiles to a features Parquet file |
| `test/` | Tests, using made-up coordinates only |
| `benchmark/` | The public benchmark: sites, hand-drawn references, the runner ([how to run it](benchmark/README.md)) |

## Development

```sh
bin/setup
bundle exec rake        # tests and RuboCop
bundle exec rake benchmark   # the public benchmark (see benchmark/README.md)
```

No Ruby gem dependencies. Getting data needs the [DuckDB](https://duckdb.org/) CLI (1.4 LTS or 2.0 are tested; `curtilage doctor` checks it and says how to install it); its `spatial` and `httpfs` extensions install themselves on first use. Point `CURTILAGE_DUCKDB` and `CURTILAGE_EXTENSIONS` at them if they aren't in the default places (`curtilage doctor` checks). Nothing else is needed: `curl` is used when it's installed, as a faster download path.

## Versioning

- The public API is what [docs/reference.md](docs/reference.md) documents: the Ruby methods and their options, result fields, flags, errors, the command line with its flags and exit codes, the NDJSON schema ([docs/schema/site-v1.json](docs/schema/site-v1.json)) and the HTTP API ([docs/openapi.yaml](docs/openapi.yaml)). Anything not listed there is internal and may change at any time.
- Until 1.0, a minor release (0.x) may change the public API. Every such change is listed under **Breaking** in [CHANGELOG.md](CHANGELOG.md), with how to update. Patch releases don't change it.
- Rule improvements can change the polygons a release produces; the changelog says when they do.

**Road to 1.0.** 1.0 promises the public API stays compatible until 2.0. Before then:

- The public API unchanged across at least two minor releases.
- Every held-out benchmark site labelled, and its results published with each release.
- A fix rate checked on real use: how many generated sites a reviewer had to correct.
- The data licence notes reviewed.
- Release signing and provenance for the gem and the Docker image.

## This repository

- The code is MIT-licensed (see `LICENSE.txt`); results keep the map data's licence ([Data licence](#data-licence)).
- Downloaded files and built Parquet files are OSM-derived data. They're never committed to this repository (see `.gitignore`).
- This repository must never contain real site locations, private data or credentials. Tests and examples use made-up coordinates.
- Security issues: see [SECURITY.md](SECURITY.md) (report privately through GitHub); the threat model is in [docs/security.md](docs/security.md).
- Contributing: [CONTRIBUTING.md](CONTRIBUTING.md) (setup, tests, the benchmark, how to report a bad polygon); [code of conduct](CODE_OF_CONDUCT.md); [governance](GOVERNANCE.md).
