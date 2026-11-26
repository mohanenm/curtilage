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

DC, Overture 2026-11-18.0: 4,090 places, 124 clear, 3,966 unclear (2,755 share their parcel with other businesses, 2,241 have no parking or driveway on their parcel, 735 have no single building at the pin, 404 have a building spanning parcels, 38 no parcel; a site can have several reasons).

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
