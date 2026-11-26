# Regional check: official planimetric data

An automated check that scores curtilage against official, survey-grade polygons (roads, driveways, parking lots, sidewalks, buildings, parcels) across many real sites in one region. It complements the labelled benchmark ([../README.md](../README.md)); it doesn't replace it. It measures pavement and buildings, not who a piece of ground belongs to.

Raw layers are never committed: the repository holds only the download code and this table. Downloads go to `data/regional/` (gitignored).

## Sources

Checked 2026-11-25 from each publisher's own pages. Check again before any other use.

| Jurisdiction | Publisher | Layers | Capture | Terms as published | What may be published |
|---|---|---|---|---|---|
| Washington DC | DC Office of the Chief Technology Officer (DC GIS), opendata.dc.gov | Planimetrics 2023: Roads (`FEATURECODE`: road, alley, paved drive, parking lot, medians, intersections), Sidewalks, Building Footprints; Common Ownership Lots (parcels, Department of Buildings) | 2023 planimetrics (published 2026-02-20); lots regenerated weekly | CC BY 4.0 | Results with attribution ("DC GIS, CC BY 4.0"), including illustrated sites |
| Fairfax County | Fairfax County DIT GIS Division | Driveways and Parking Lots (`TYPE`: paved/unpaved parking lot, paved/unpaved private road, driveways), buildings, roads, parcels | Driveways and parking: updated 2024 from 2022-2023 orthophotos | "Copyright by Fairfax County. Except as provided herein, all rights are reserved." Reproduction granted "for internal or personal use"; redistribution and derived works not addressed | Not clear: aggregate numbers at most, after asking |
| Arlington County | Arlington County GIS | Planimetric layers and parcels on the county's ArcGIS hub (list not readable without a browser) | Not confirmed | No open licence found. The county website's terms bar distributing or creating derivative works "without the written permission" of the county; the hub's per-dataset licence field couldn't be read | Nothing until the terms are confirmed |
| City of Alexandria | City of Alexandria GIS Division | Buildings, parcels, roads named; parking lots not confirmed | Updated twice a year | Disclaimer only ("provided as is"), no licence; a 2009 email from city GIS staff: "You can not profit from redistribution" | Nothing until the terms are confirmed |

## Capture rules that affect scoring

- **DC:** "If a driveway is less than 200 feet and leads to a parking lot, the entire paved area is captured as Parking Lot"; longer drives are Paved Drive. Small parking areas off a public alley in the middle of a block aren't captured as parking. Roads don't overlap sidewalks. No minimum feature size is stated.
- **Fairfax:** driveways and parking lots outside the right of way, up to the edge of pavement, paved and unpaved.

## OpenStreetMap imports from the same sources

Where OSM data was imported from the same source, agreement with it isn't independent.

- **DC:** building footprints and addresses were imported from DC GIS (import plan reviewed 2013-2014; completion not recorded on the OSM wiki). Building metrics in DC are reported separately and treated as not independent. No parking or driveway import is recorded.
- **Fairfax, Arlington, Alexandria:** no import of county or city buildings, roads or parking is recorded on the OSM wiki. A statewide Virginia buildings import (VGIN footprints, public domain, planned 2023) adds only buildings not already in OSM; which localities it reached isn't recorded.

## Fetching

```sh
bundle exec rake "benchmark:regional:fetch[dc]"   # into data/regional/dc/, about 400 requests
```

Each layer is fetched whole, page by page, so no site locations are sent. Every feature is reduced to its class and geometry (owner names on parcel layers never reach the cache), outlines over 20,000 vertices are dropped, and `manifest.json` records each layer's source, fetch time, feature count and SHA256. A layer already in the manifest isn't fetched again.

## Classes

Every source is mapped to `building`, `parking`, `driveway`, `road`, `sidewalk`, `alley` and `parcel`.

| Source layer | Class |
|---|---|
| DC Roads 2023, `FEATURECODE` 1070 Parking Lot | `parking` |
| DC Roads 2023, 1065 Paved Drive | `driveway` |
| DC Roads 2023, 1060 Alley | `alley` |
| DC Roads 2023, 1050 Road, 1090 Intersection, 1091 Hidden Road, 1093 Hidden Intersection, 1055-1058 and 1092 medians and islands | `road` |
| DC Sidewalks 2023 | `sidewalk` |
| DC Building Footprints 2023 | `building` |
| DC Owner Polygons (Common Ownership Lots) | `parcel` |

## Choosing sites

```sh
bundle exec rake "benchmark:regional:sites[dc]"   # Overture places in the region, sorted (data/regional/dc/selection.json)
```

Places of the 13 types the benchmark's random picks use (pharmacy, gas station, fast food, grocery, bank, hotel, hardware, restaurant, coffee shop, post office, library, department store, convenience store), confidence 0.9 or more, inside the region's Geofabrik outline, from the Overture release pinned in `../config.json`. A site is **clear** when pavement on its parcel can be put down to the business:

- one official building is under the pin, or exactly one within 5 m;
- an official parcel holds that building, and no other Overture business (any category, confidence 0.7 or more) is on it;
- the parcel holds at least 50 m2 of official parking or driveway.

Everything else is **unclear** (shared lots, multi-tenant buildings, pins away from a building), with the reasons recorded, and scored for the "out" measures only. Places within 500 m of a held-out benchmark site are left out (`benchmark/README.md`, held-out rules). The selection runs in DuckDB (`select.sql`).

DC, Overture 2026-11-18.0: 4,090 places, 146 clear, 3,944 unclear (2,748 share their parcel with other businesses, 2,267 have no parking or driveway on their parcel, 667 have no single building at the pin, 88 no parcel; a site can have several reasons).
