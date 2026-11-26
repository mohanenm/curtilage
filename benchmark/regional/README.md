# Regional check: official planimetric data

An automated check that scores curtilage against official, survey-grade polygons (roads, driveways, parking lots, sidewalks, buildings, parcels) across many real sites in one region. It complements the labelled benchmark ([../README.md](../README.md)); it doesn't replace it. It measures pavement and buildings, not who a piece of ground belongs to.

Raw layers are never committed: the repository holds only the download code and this table. Downloads go to `data/regional/` (gitignored).

## Sources

Checked 2026-11-25 from each publisher's own pages. Check again before any other use.

| Jurisdiction | Publisher | Layers | Capture | Terms as published | What may be published |
|---|---|---|---|---|---|
| Washington DC | DC Office of the Chief Technology Officer (DC GIS), opendata.dc.gov | Planimetrics 2023: Roads (`FEATURECODE`: road, alley, paved drive, parking lot, medians, intersections), Sidewalks, Building Footprints; Common Ownership Lots (parcels, Department of Buildings) | 2023 planimetrics (published 2026-02-20); lots regenerated weekly | CC BY 4.0 | Results with attribution ("DC GIS, CC BY 4.0"), including illustrated sites |
| Denver, CO | DRCOG Regional Planimetric Data Project (Denver Regional Council of Governments); City and County of Denver open data (parcels) | 2024 planimetrics: Paved Parking, Polygon Driveways, Edge of Pavement Polygons (corridors and medians), Polygon Sidewalks, Building Roofprints (`Bldg_Type`, including Garage/Shed and Parking Structure); Denver parcels (`ODC_PROP_PARCELS_A`) | 2024 DRAPP imagery (updated every two years since 2014) | DRCOG: CC BY 3.0 ("credit the DRCOG Regional Data Catalog"); Denver's open data catalog: CC BY 3.0 | Results with attribution |
| Connecticut (six towns: Hartford, Waterbury, Norwalk, Danbury, Milford, Manchester) | State of Connecticut, Office of Policy and Management, CT GIS Office (impervious data by Ecopia AI, checked by Dewberry) | 2023 Impervious Surface (`CateTitle`: building, driveway, parking, road, sidewalk, pavement, bridge, ...); State Parcel Layer 2023 | 2023 imagery (impervious published 2026-02-01); parcels from 2022-2023 data | No licence named; the impervious metadata says "Use limitations: None", "Terms and fees: None"; parcels: no terms found | Aggregate numbers only |
| Fairfax County | Fairfax County DIT GIS Division | Driveways and Parking Lots (`TYPE`: paved/unpaved parking lot, paved/unpaved private road, driveways), buildings, roads, parcels | Driveways and parking: updated 2024 from 2022-2023 orthophotos | "Copyright by Fairfax County. Except as provided herein, all rights are reserved." Reproduction granted "for internal or personal use"; redistribution and derived works not addressed | Not clear: aggregate numbers at most, after asking |
| Arlington County | Arlington County GIS | Planimetric layers and parcels on the county's ArcGIS hub (list not readable without a browser) | Not confirmed | No open licence found. The county website's terms bar distributing or creating derivative works "without the written permission" of the county; the hub's per-dataset licence field couldn't be read | Nothing until the terms are confirmed |
| City of Alexandria | City of Alexandria GIS Division | Buildings, parcels, roads named; parking lots not confirmed | Updated twice a year | Disclaimer only ("provided as is"); no licence found | Nothing until the terms are confirmed |

## Capture rules that affect scoring

- **DC:** "If a driveway is less than 200 feet and leads to a parking lot, the entire paved area is captured as Parking Lot"; longer drives are Paved Drive. Small parking areas off a public alley in the middle of a block aren't captured as parking. Roads don't overlap sidewalks. No minimum feature size is stated.
- **Fairfax:** driveways and parking lots outside the right of way, up to the edge of pavement, paved and unpaved.
- **Denver (DRCOG):** parking lots of 400 sq ft or more, "the entrance into the lot is included"; driveways are paved public and private polygons, and a sidewalk meeting a driveway apron takes precedence; paved road polygons take precedence over sidewalks; roofprints of 48 sq ft or more and over 5 ft high.
- **Connecticut:** machine-extracted from 2023 imagery with quality control, not hand-traced. Parking is a paved surface with visible parking lanes over 500 sq ft; a driveway runs from the edge of the curb to the structure (a sidewalk over it takes priority); roads include curbs; "pavement" is any other paved surface (mapped to `paved`, counted with parking and driveways).

## OpenStreetMap imports from the same sources

Where OSM data was imported from the same source, agreement with it isn't independent.

- **DC:** building footprints and addresses were imported from DC GIS (import plan reviewed 2013-2014; completion not recorded on the OSM wiki). Building metrics in DC are reported separately and treated as not independent. No parking or driveway import is recorded.
- **Denver:** an import of DRCOG roofprints into OSM was planned from 2016 (the OSM wiki records no completion), so building agreement there may not be independent.
- **Connecticut:** no import of the 2023 impervious data is recorded.
- **Fairfax, Arlington, Alexandria:** no import of county or city buildings, roads or parking is recorded on the OSM wiki. A statewide Virginia buildings import (VGIN footprints, public domain, planned 2023) adds only buildings not already in OSM; which localities it reached isn't recorded.

## Fetching

```sh
bundle exec rake "benchmark:regional:fetch[dc]"   # into data/regional/dc/, about 620 requests
```

Each layer is fetched whole, page by page, so no site locations are sent. Every feature is reduced to its class and geometry (owner names on parcel layers never reach the cache), outlines over 20,000 vertices or of an unknown class are dropped, and `manifest.json` records each layer's source, fetch time, features kept and dropped, and SHA256. Pages come in ID order; a page that repeats earlier features stops the fetch. A layer already in the manifest isn't fetched again.

## Classes

Every source is mapped to `building`, `canopy`, `parking_garage`, `shed`, `structure`, `parking`, `driveway`, `paved`, `road`, `sidewalk`, `alley` and `parcel`.

| Source layer | Class |
|---|---|
| DC Roads 2023, `FEATURECODE` 1070 Parking Lot | `parking` |
| DC Roads 2023, 1065 Paved Drive | `driveway` |
| DC Roads 2023, 1060 Alley | `alley` |
| DC Roads 2023, 1050 Road, 1090 Intersection, 1091 Hidden Road, 1093 Hidden Intersection, 1055-1058 and 1092 medians and islands | `road` |
| DC Sidewalks 2023 | `sidewalk` |
| DC Building Footprints 2023, `FEATURECODE` 2000 Building | `building` |
| DC Building Footprints 2023, 2050 Canopy Structure | `canopy` |
| DC Building Footprints 2023, 2030 Parking Garage | `parking_garage` |
| DC Building Footprints 2023, 2010 Memorial, 2020 Bleacher, 2040 Fountain | `structure` |
| DC Owner Polygons (Common Ownership Lots) | `parcel` |
| Denver Paved Parking 2024 | `parking` |
| Denver Polygon Driveways 2024 | `driveway` |
| Denver Edge of Pavement Polygons 2024 (corridors and medians) | `road` |
| Denver Polygon Sidewalks 2024 | `sidewalk` |
| Denver Building Roofprints 2024, `Bldg_Type` Garage/Shed | `shed` |
| Denver Building Roofprints 2024, Parking Structure | `parking_garage` |
| Denver Building Roofprints 2024, Tank, Foundation/Ruin | `structure` |
| Denver Building Roofprints 2024, other types | `building` |
| Denver parcels | `parcel` |
| Connecticut impervious 2023, `CateTitle` building, driveway, parking, road, sidewalk | the same |
| Connecticut impervious 2023, bridge | `road` |
| Connecticut impervious 2023, pavement | `paved` |
| Connecticut State Parcel Layer 2023 | `parcel` |

## Choosing sites

```sh
bundle exec rake "benchmark:regional:sites[dc]"   # Overture places in the region, sorted (data/regional/dc/selection.json)
```

Places of the 13 types the benchmark's random picks use (pharmacy, gas station, fast food, grocery, bank, hotel, hardware, restaurant, coffee shop, post office, library, department store, convenience store), confidence 0.9 or more, inside the region's Geofabrik outline, from the Overture release pinned in `../config.json`. A site is **clear** when pavement on its parcel can be put down to the business:

- one official building is under the pin, or exactly one within 5 m (15 m from a pin on a fuel canopy, which means the shop beside it, as the gem reads it);
- the official parcel holding most of that building holds at least 75% of it, and no other Overture business is on it (any place in nine top-level categories: food and drink, shopping, health care, lodging, services and business, lifestyle services, travel and transportation, arts and entertainment, sports and recreation; confidence 0.7 or more);
- the parcel holds at least 50 m2 of official parking or driveway.

Everything else is **unclear** (shared lots, multi-tenant buildings, pins away from a building), with the reasons recorded; it is to be scored for the "out" measures only. Official polygons are repaired where invalid before any area is measured. Places within 500 m of a held-out benchmark site are left out (`benchmark/README.md`, held-out rules). The selection runs in DuckDB (`select.sql`).

DC, Overture 2026-11-18.0: 4,090 places, 10 of them with no official parcel within 50 m (outside the data), leaving 124 clear and 3,956 unclear (2,755 share their parcel with other businesses, 2,241 have no parking or driveway on their parcel, 731 have no single building at the pin, 404 have a building spanning parcels, 32 no parcel under the building; a site can have several reasons). Clear sites are 3% of DC's places: the standalone cases, where curtilage does best, so DC's clear-site figures flatter dense urban use; the unclear sample's figures sit beside them.

## Metrics

```sh
bundle exec rake "benchmark:regional:run[dc]"   # curtilage and the baselines on the sites; saves data/regional/dc/runs/
```

Every clear site and a seeded sample of 400 unclear ones (seed 20261126) are generated from the region's own OpenStreetMap build (Geofabrik), then scored in DuckDB (`score.sql`) against the official polygons:

- **Building:** the share of the official building inside the premises (whole when 98% or more), and the store zone's IoU with it.
- **Own pavement:** the share of the parcel's official parking and driveway inside the premises.
- **Road and sidewalk leak:** premises area on official road or alley, and on sidewalk, measured on those polygons shrunk by the alignment tolerance; a site leaks when either is over 10 m2. Curtilage keeps the sidewalk in front of a building on the street by design, so the two are reported apart.
- **Neighbour leak:** premises area on other buildings (not mostly on the site's parcel) or on parking and driveways on other parcels. The right of way is in no parcel, so a driveway apron there doesn't count. Saved as both parts too (`neighbour_building_m2`, `neighbour_paving_m2`).
- **Structures:** official buildings, canopies, parking garages and other structures within 60 m: on the site's parcel (should be in) or off it (should be out), counted in when their interior point is inside the premises.
- **Entrances:** where paving that reaches the parcel meets official road or alley; an access point within 15 m of one matches it (recall over official entrances, precision over access points).
- **All in / nothing out:** a site has everything in when the whole building, 90% of its pavement and every structure on its parcel are inside; nothing out when no road, sidewalk or neighbour leak passes 10 m2 and no structure off its parcel is inside.
- **Vintage:** sites where the official building and the OSM building curtilage used disagree (IoU under 0.5: built, demolished or drawn differently since capture) are counted and left out of the figures.

Baselines, scored the same way: 50 m and 75 m circles round the pin, the OSM building alone, and the official parcel alone.

**Alignment tolerance: 2 m.** Where the OSM building matches the official one (IoU 0.5 or more, 366 DC sites), their centres are a median 1.1 m apart (75th percentile 1.6 m, 90th 3.7 m, partly from different shapes), so 2 m covers the usual offset without hiding real leaks.

## Options

```sh
bundle exec rake "benchmark:regional:options[dc]"   # each option alone, then the combinations (REGIONAL_RUNS=a,b for some)
bundle exec rake "benchmark:regional:table[dc]"     # the latest run of each, side by side
```

Every option that might change results on this data, run alone on the same sites, then two combinations the single runs pointed to. ML footprints (none in the region's build), `candidates` (the main result doesn't change) and `unit_m` (the store zone only) aren't run. The parcel options use the official parcels, which the neighbour measure also uses, so their neighbour figures aren't independent; their road and sidewalk figures are.

DC, 105 clear sites (19 vintage left out), share of sites:

| Run | Whole building | Everything in | Nothing out | Road leak | Sidewalk leak | Neighbour leak | Entrances found / right | Seconds |
|---|---|---|---|---|---|---|---|---|
| default | 94% | 70% | 21% | 33% | 43% | 64% | 47% / 70% | 63 |
| `parcels:`, `parcel_mode: :grow`, `road_offset_m: 9`, `snap_m: 20` | 96% | 83% | 27% | 21% | 32% | 65% | 45% / 71% | 300 |
| `parcels:`, `parcel_mode: :clip`, `snap_m: 20` | 85% | 58% | 41% | 18% | 19% | 48% | 47% / 70% | 116 |
| `parcels:`, `parcel_mode: :grow` | 96% | 83% | 21% | 34% | 41% | 66% | 47% / 70% | 370 |
| `parcels:`, `parcel_mode: :clip` | 86% | 59% | 40% | 21% | 20% | 48% | 47% / 70% | 197 |
| `road_offset_m: 9` | 94% | 68% | 25% | 24% | 36% | 64% | 45% / 71% | 51 |
| `snap_m: 20` | 94% | 70% | 21% | 31% | 43% | 64% | 47% / 70% | 53 |
| `grow_m: 20` | 94% | 70% | 22% | 34% | 38% | 63% | 47% / 70% | 51 |
| `parking_max_extent_m: 90` | 94% | 70% | 21% | 33% | 43% | 64% | 47% / 69% | 51 |
| `touching_neighbours: :cut` | 90% | 66% | 24% | 34% | 43% | 58% | 47% / 70% | 84 |
| `neighbour_cut: :notch` | 95% | 73% | 18% | 40% | 46% | 70% | 47% / 70% | 71 |
| `entrances: :all` | 96% | 72% | 18% | 41% | 44% | 68% | 61% / 56% | 124 |
| `method: :partition` | 96% | 59% | 18% | 44% | 41% | 64% | none recorded | 976 |
| `scope: :centre` | 91% | 73% | 18% | 43% | 47% | 70% | 34% / 73% | 119 |
| `preset: :tight` | 97% | 17% | 31% | 20% | 30% | 64% | none recorded | 33 |
| 50 m circle | 92% | 79% | 0% | 99% | 80% | 97% | | |
| the parcel alone | 62% | 61% | 96% | 2% | 12% | 2% | | |

What it shows, as findings, not decisions:

- With parcels, `:grow` with a 9 m road offset and pin snapping is better than the default on every measure here: more caught (everything in 70% to 83%) and less leak (road 33% to 21%, nothing out 21% to 27%). `:clip` leaks least (nothing out 41%) but loses whole buildings (94% to 85%).
- Without parcels, a 9 m road offset cuts road leak (33% to 24%) at little cost. Not because DC's roads are wider than the half-widths by road class: measured from OpenStreetMap centrelines to the edge of DC's road polygons, they're narrower (median half-width primary 5.7 m against curtilage's 7.5 m, secondary 5.4 against 7, tertiary 4.9 against 6, residential 4.2 against 4.5). A larger fixed offset trims harder where the usual trim is held back (near the building or pin, at corners, where the OSM line is off-centre); which of these causes the leak isn't established yet.
- `touching_neighbours: :cut` lowers neighbour leak (64% to 58%) but loses whole buildings at 40 sites, often where OpenStreetMap draws one building as several parts.
- `method: :partition` leaks more road here than the default, records no entrances and is far slower in a dense city.
- `shared_checks` changes flags only (its scores match the default's). Its `takes_in_building` flag marks the sites that leak onto neighbours: 78% of flagged sites against 51% of the rest. In DC it fires on half the sites, so it orders a review rather than singling out a few. The other flags separate leaking sites little.
- Unclear sites move the same way, with smaller gains.

DC, the sample of unclear sites (351 scored, 49 vintage left out of 400), default settings and baselines. Which parcel is the site's is a guess here (the one under the pin), so the building, everything-in and neighbour figures are rougher than road and sidewalk, which don't depend on it:

| Run | Whole building | Everything in | Nothing out | Road leak | Sidewalk leak | Neighbour leak |
|---|---|---|---|---|---|---|
| default | 73% | 61% | 12% | 58% | 71% | 65% |
| 50 m circle | 55% | 50% | 1% | 97% | 92% | 87% |
| the parcel alone | 24% | 24% | 86% | 11% | 15% | 7% |
