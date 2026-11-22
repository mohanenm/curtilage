# curtilage

*Curtilage: the land immediately around a building, such as its yard, drive and lot.*

Generates a site's **premises polygon** (the building plus its customer-facing lot) and a **store zone** (the building's own outline) from free map data, so nobody has to draw them by hand.

**Status:** 0.2.0. The rules were tuned on 20 real store sites, then tested on sites they had never seen: 51 across the US, Brazil and Hungary, and 164 mostly in the western US. On the 164, 96% got a valid polygon; nearly all the misses were buildings absent from OpenStreetMap. Results were reviewed against hand-drawn premises and by eye on aerial imagery. The API may still change before 1.0.

## Quick start

1. Install the gem (`gem "curtilage"` in your Gemfile, once published) and the [DuckDB CLI](https://duckdb.org/docs/installation/) 1.4. Check with `curtilage doctor`; DuckDB's extensions install themselves.
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

Or from the shell: `curtilage generate --pin -80.0,35.0`.

That's all the setup: map data is fetched as needed. Everything else (batches, Overture instead of Geofabrik, caching, styles, every option and flag) is in the [reference](docs/reference.md).

## How it works

1. **Data.** Buildings, parking lots, roads and railways from OpenStreetMap, picked automatically (`source: :auto`, the default):
   - **Scattered pins: Overture Maps, read in place.** The same OpenStreetMap data from Overture's public release, read straight from their storage: about 5-10 s per area, nothing downloaded.
   - **Many pins in one region, or a region already cached: a Geofabrik build.** The gem downloads only the layers it needs from that region's shapefiles and builds a compact Parquet file, 1-5 minutes per US state, then answers instantly.
   - Or force one: `source: :geofabrik` (the host only ever learns the region, never the area) or `source: :overture`. Or use your own prebuilt files (`curtilage build`), local or in a bucket.
2. **Generate.** Start from the building at the pin and grow its rectangle 30 m toward its lot, then:
   - stop at public roads, half a typical road width short of the centreline (by road class) but at least 3 m out from the building, following each road's direction; and at railways;
   - take in the site's mapped parking (a lot shared with a few buildings is claimed whole; a shopping-centre lot is split by nearest building), parking garages, canopies, and driveways to the street;
   - stop 3 m short of neighbouring buildings, or halfway when the site is behind a house (its back yard);
   - fall back to the building's rectangle plus a margin if that fails validation.
   Every result explains each step and carries review flags.
3. **Validate.** Reject or flag polygons that are unsafe to use: pin outside, unclosed, self-intersecting, swapped coordinates, too far from the pin, an implausible size. The store zone always sits inside the premises.

It's rule-based: no machine learning in the method. Coordinates are `[lng, lat]` throughout, as in GeoJSON.

## Usage

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
- Check an existing polygon: `Curtilage::Audit.check(pin, ring, features)` returns `:ok`, `:review` (with reasons) or `:invalid`.

### Flags

| Flag | Meaning |
|---|---|
| `near_houses` | The lot borders a home: check where the yard or property line is |
| `large_building` | Building over 5,000 m2: may be shared by several tenants |
| `small_building` | Building under 50 m2: may be a kiosk or canopy rather than the store |
| `building_not_under_pin` | No building under the pin; the nearest one within 30 m was used |
| `store_may_be_unit` | Store zone is a building over 1,500 m2: the store may be one unit of it |
| `shopping_centre` | `scope: :centre` mapped the whole centre |
| `fallback` | The main method failed validation; the building rectangle was used |
| `partial_data` | Part of the area around the pin is in a region that isn't built |
| `ml_footprint` | Built on a machine-learned footprint, not an OSM building |
| `no_data` | No map data covers the pin |

### Speed

- Generate: about 100 ms per site (median; a few hundred ms in dense blocks).
- Prebuilt files: about 85 ms per lookup through the DuckDB CLI; one call serves many pins.
- Overture (the default for scattered pins): about 5-10 s per area; pins within a few km of each other share it. A test batch of 51 sites in 17 regions across three continents took 4 minutes from a cold start.
- Geofabrik builds (the default once 10+ pins share a region): 1-5 minutes per US state the first time (Texas, the largest tested, about 4.5 minutes and under 650 MB of memory), then as above. Downloads use `curl` when it's installed, and `data: { parallel_builds: 2 }` builds two regions at once on machines with the memory.

## Known limitations

Rules on open map data go a long way, but some sites need a person. These are the patterns seen in testing, and what helps:

- **The building isn't in OpenStreetMap** (about 3-8% of sites tested). Nothing is generated. Opting in to machine-learned footprints (`buildings: :osm_filled`) usually fills the gap.
- **A store that's one unit of a long or large building** (storefronts in urban blocks, strip malls). The premises cover the whole building and its lot, often several times too big. Flagged `store_may_be_unit` or `large_building`; `preset: :tight` or `preset: :centre` may suit these better.
- **Sites spread over several buildings** (compounds, campuses). The premises cover the building at the pin only, so they come out too small.
- **Dense rowhouse blocks.** Cuts toward many close neighbours can leave a thin sliver.
- **`near_houses` is noisy in dense urban areas,** where almost every site borders homes. It's more meaningful in suburbs.
- **The polygon is always convex,** so entrance notches and L-shaped lots are approximated.

## Building footprints: OSM, or OSM plus machine-learned

By default all buildings come from OpenStreetMap. Where OSM is missing buildings, you can opt in to [Microsoft's Global ML Building Footprints](https://github.com/microsoft/GlobalMLBuildingFootprints) (ODbL, like OSM): build with `--ml-footprints microsoft` (or `ml_footprints: "microsoft"`), then generate with `buildings: :osm_filled` or `:ml`. With `source: :overture`, Overture's non-OSM buildings play the same role. Results built on one carry the `ml_footprint` flag.

## Network access

The gem only talks to public map-data hosts, and only when it needs data: Geofabrik (region index and extracts), Overture Maps (file index and data), Microsoft's footprint files (opt-in), and your own bucket if you point it at one. Reading Overture by area tells its host roughly which few-km areas you read (never the pin or what it's for); Geofabrik builds only reveal the region. Use `source: :geofabrik` if that matters to you. Nothing else is sent anywhere.

## Layout

| Path | What |
|---|---|
| `lib/curtilage.rb` | Entry points: `generate`, `generate_many`, presets |
| `lib/curtilage/generator.rb` | Methods, the fallback chain, road and neighbour trims, flags |
| `lib/curtilage/generator_lot.rb` | Which parking, garages, canopies and driveways are the site's |
| `lib/curtilage/generator_store.rb` | The store zone |
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
| `exe/curtilage` | `curtilage generate`, `build` and `doctor` |
| `docs/reference.md` | Every option, setting, flag and command |
| `sql/build_from_shapefiles.sql` | DuckDB query: shapefiles to a features Parquet file |
| `test/` | Tests, using made-up coordinates only |

## Development

```sh
bin/setup
bundle exec rake        # tests and RuboCop
```

The gem itself is plain Ruby with no runtime gem dependencies. Getting data needs the [DuckDB](https://duckdb.org/) CLI (1.4 LTS); its `spatial` and `httpfs` extensions install themselves on first use. Point `CURTILAGE_DUCKDB` and `CURTILAGE_EXTENSIONS` at them if they aren't in the default places (`curtilage doctor` checks). `unzip` is only needed if a server can't serve byte ranges.

## Data and licensing

- Map data © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright), available under the [ODbL](https://opendatacommons.org/licenses/odbl/). Show this attribution wherever generated premises are displayed; results carry it (`to_geojson`).
- With `source: :overture`: also © Overture Maps Foundation. With ML footprints: also Microsoft Global ML Building Footprints (ODbL).
- Downloaded files and built Parquet files are OSM-derived data. They're never committed to this repository (see `.gitignore`).
- This repository must never contain real site locations, client data or credentials. Tests and examples use made-up coordinates.
- The code is MIT-licensed (see `LICENSE.txt`). The map data keeps its own licence (ODbL).
- Security issues: see `SECURITY.md` (report privately through GitHub).
