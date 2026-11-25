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
