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
