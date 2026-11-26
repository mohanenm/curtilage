# Spot-checks of held-out labels

A seeded sample of 5 hand-placed points per site from a sealed held-out set (`rake "benchmark:spot_check_sample[SET]"`, which also fetches the imagery), labelled again by a second labeller who has never seen the rules' output, and scored against the sealed labels (`rake "benchmark:spot_check_score[SET,ANSWERS]"`). The second labeller gets each point under a shuffled number, never its kind or its place in the label file. Disagreements are logged here and never change a sealed label; they inform how the next set is labelled.

## Held-out set 3 (2026-11-25)

Second labeller: a separate AI process. It got the kinds table from LABELS.md, and for each point a 50 m USGS image centred on it, its offset from the pin, and the site's notes (business name and type), with a 240 m image of each site. It saw no labels, results or rules. That is weaker than a second person: the close-ups are coarse, and doors and property edges are hard to see.

- 40 points: the same kind for 31 (78%); `unclear` for 1.
- Where it gave a kind: the same for 31 of 39 (79%), and on the same side (in, out or not scored) of the default view for 36 (92%).
- Most disagreements are judgements the imagery can't settle: a shared lot read as the site's own, a driveway entrance read as parking.

A first run was discarded: it handed out points by their place in the label file, which lists points grouped by kind, so the number could hint at the kind.

| Number | Label | Sealed | Second labeller |
|---|---|---|---|
| 2 | `ms-fast-food-restaurant:2` | `entrance` | `own_parking` |
| 5 | `in-department-store:47` | `shared_parking_near` | `own_parking` |
| 9 | `ms-fast-food-restaurant:1` | `entrance` | `own_parking` |
| 10 | `id-convenience-store:14` | `centre_entrance` | `own_parking` |
| 18 | `mt-hardware-store:10` | `shared_parking_near` | `unclear` |
| 25 | `ar-hardware-store:28` | `shared_parking_near` | `shared_parking_far` |
| 29 | `mt-hardware-store:5` | `shared_parking_near` | `own_parking` |
| 36 | `wv-coffee-shop:4` | `own_parking` | `walkway` |
| 40 | `wv-coffee-shop:44` | `shared_parking_far` | `shared_parking_near` |

## Held-out set 2 (2026-11-25)

Same method and second labeller (a separate AI process, imagery and the kinds table only). This set has more dense urban sites, where the aerial photos are tilted (roofs offset from their footprints) and kerbs are hard to place.

- 80 points: the same kind for 52 (65%); `unclear` for 7.
- Where it gave a kind: the same for 52 of 73 (71%), and on the same side of the default view for 62 (85%).
- The disagreements that change the side are mostly where a road ends and a lot begins, and a shared lot read as the site's own.

| Number | Label | Sealed | Second labeller |
|---|---|---|---|
| 6 | `ks-hotel:62` | `shared_parking_far` | `own_parking` |
| 10 | `ny-coffee-shop:20` | `entrance` | `unclear` |
| 11 | `mi-bank:8` | `entrance` | `centre_entrance` |
| 12 | `sc-library:3` | `own_parking` | `shared_parking_near` |
| 13 | `ks-hotel:64` | `shared_parking_far` | `own_parking` |
| 17 | `al-fast-food-restaurant:36` | `centre_entrance` | `unclear` |
| 22 | `ks-hotel:50` | `neighbour_building` | `residential` |
| 23 | `sc-library:2` | `own_parking` | `shared_parking_near` |
| 24 | `la-grocery-store:64` | `neighbour_building` | `residential` |
| 28 | `ne-post-office:11` | `own_parking` | `public_road` |
| 31 | `va-grocery-store:3` | `own_parking` | `sidewalk` |
| 34 | `ok-department-store:0` | `building` | `unclear` |
| 36 | `nj-convenience-store:29` | `entrance` | `unclear` |
| 40 | `ks-hotel:68` | `shared_parking_far` | `own_parking` |
| 42 | `ne-post-office:18` | `centre_road` | `public_road` |
| 47 | `ok-department-store:11` | `own_parking` | `public_road` |
| 48 | `il-hotel:2` | `own_parking` | `shared_parking_near` |
| 50 | `ne-post-office:22` | `centre_road` | `public_road` |
| 51 | `il-hotel:35` | `shared_parking_near` | `unclear` |
| 52 | `nm-gas-station:34` | `forecourt` | `building` |
| 56 | `mi-bank:28` | `shared_parking_near` | `shared_parking_far` |
| 57 | `nj-convenience-store:0` | `building` | `own_parking` |
| 60 | `ne-post-office:44` | `shared_parking_near` | `public_road` |
| 66 | `va-grocery-store:29` | `public_road` | `unclear` |
| 69 | `mi-bank:2` | `own_parking` | `shared_parking_near` |
| 73 | `la-grocery-store:68` | `shared_parking_near` | `own_parking` |
| 74 | `ky-post-office:25` | `neighbour_building` | `residential` |
| 78 | `or-library:20` | `shared_parking_near` | `unclear` |
