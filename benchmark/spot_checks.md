# Spot-checks of held-out labels

A seeded sample of hand-placed points from a held-out set (`rake "benchmark:spot_check_sample[SET]"`), labelled again by a second labeller who has never seen the rules' output, and scored against the sealed labels (`rake "benchmark:spot_check_score[ANSWERS]"`). Disagreements are logged here and never change a sealed label; they inform how the next set is labelled.

## Held-out set 3 (2026-11-25)

Second labeller: a separate AI process given only USGS imagery (a 50 m image centred on each point, a 240 m image of each site), the site's business name and the kinds table from LABELS.md; it saw no labels, results or rules. Weaker than a second person: the close-ups are blurry at the centre and it can't see doors.

- 40 points (5 per site): the same kind for 31 (78%); the second labeller answered `unclear` for 7.
- Where it gave a kind: 31 of 33 the same (94%), and all 33 on the same side (in or out) of the default view.

| Point | Sealed label | Second labeller |
|---|---|---|
| `in-department-store:17` | `public_road` | `unclear` |
| `ar-hardware-store:35` | `shared_parking_near` | `unclear` |
| `ms-fast-food-restaurant:3` | `entrance` | `own_parking` |
| `ms-fast-food-restaurant:14` | `own_parking` | `unclear` |
| `ms-fast-food-restaurant:35` | `centre_road` | `unclear` |
| `id-convenience-store:10` | `shared_parking_near` | `landscaping` |
| `ct-convenience-store:16` | `public_road` | `unclear` |
| `mt-hardware-store:15` | `entrance` | `unclear` |
| `mt-hardware-store:29` | `public_road` | `unclear` |
