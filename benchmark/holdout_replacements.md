# Held-out site replacements

Held-out sites are replaced only for data problems visible without running the gem, decided from the site data alone (see README.md, "Roles and the held-out rules"). Each replacement, with its reason:

| Date | Site replaced | Replacement | Reason, from the site data | Checked how |
|---|---|---|---|---|
| 2026-11-24 | md-gas-station | md-gas-station-2 (now a validation site) | No gas station within 45 m of the Overture point: only houses. | Map data round the point (buildings and their tags) and USGS imagery, before any result for the site was seen. |
| 2026-11-24 | nc-pharmacy | nc-pharmacy-2 (now a validation site) | The only supermarket-sized building near the Overture point (the store's likely building) was 160 m away; nothing within 80 m matched. | Map data round the point (building sizes and names). |
| 2026-11-24 | mi-pharmacy | mi-bank | The Overture point was off the business: it couldn't be found near the point on the labelling page. | Labelling page (imagery and map data only), before any result for the site was seen. Redrawn with seed 20261127, same procedure. |
| 2026-11-24 | mo-library | mo-pharmacy | The Overture point was off the business: it couldn't be found near the point on the labelling page. | Labelling page (imagery and map data only), before any result for the site was seen. Redrawn with seed 20261127, same procedure. |

The second held-out set (16 sites, drawn 2026-11-24) needed no redraws at draw time: every pick had a building within 40 m of its point. Two were replaced while labelling (above).

## Corrections before the first release check

Labels may be corrected before a held-out set's first release check, while no result for it has been seen; after that they never change.

| Date | Sites | What changed | Why |
|---|---|---|---|
| 2026-11-25 | 8 of the 16: va-grocery-store, nj-convenience-store, ny-coffee-shop, il-hotel, mi-bank, sc-library, la-grocery-store, ks-hotel | 41 `own_parking` points re-marked as shared parking (23 `shared_parking_near`, 13 `shared_parking_far`); 20 `sidewalk` points replaced by 39 `public_road` points (va, nj); 8 `centre_entrance`/`centre_building` points and a few entrances and neighbours adjusted. | The first pass marked some shared lots as the site's own (thinking of where a customer has arrived), but labels record what is physically there and the views decide what counts. Re-checked on the labelling page, which shows no results. |

