# Held-out site replacements

Held-out sites are replaced only for data problems visible without running the gem, decided from the site data alone (see README.md, "Roles and the held-out rules"). Each replacement, with its reason:

| Date | Site replaced | Replacement | Reason, from the site data | Checked how |
|---|---|---|---|---|
| 2026-11-24 | md-gas-station | md-gas-station-2 (now a validation site) | No gas station within 45 m of the Overture point: only houses. | Map data round the point (buildings and their tags) and USGS imagery, before any result for the site was seen. |
| 2026-11-24 | nc-pharmacy | nc-pharmacy-2 (now a validation site) | The only supermarket-sized building near the Overture point (the store's likely building) was 160 m away; nothing within 80 m matched. | Map data round the point (building sizes and names). |

The second held-out set (16 sites, drawn 2026-11-24) needed no redraws at draw time: every pick had a building within 40 m of its point.
