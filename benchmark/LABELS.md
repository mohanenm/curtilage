# Labelling benchmark sites (draft)

Instead of one hand-drawn polygon per site, each site gets **labelled points**. A label records what is physically at that spot, something anyone can check on aerial imagery. It never records whether the spot "should" be in the premises. Whether a kind of spot counts as in, out or ignored is decided separately, by a **view**: a published table that maps each kind to in, out or ignore. The same labels can then score any use case, and anyone can disagree with a table without relabelling anything.

## Kinds

Pick the most specific kind that fits. "This site" means the business at the pin. A spot belongs to it when you can only reach it through this site's own entrances, or when kerbs, fences or planting enclose it with this site.

| kind | what it is |
| --- | --- |
| `building` | Inside this site's building. |
| `walkway` | Pavement between this site's building and its own parking or the street (front apron, side path). |
| `own_parking` | A stall or aisle on a lot only this site uses. |
| `drive_through` | A drive-through lane, including the menu board and window. |
| `forecourt` | A fuel forecourt: pumps, the canopy, the lanes between them. |
| `entrance` | This site's driveway, on the site side of the kerb, where it meets a public road. |
| `service` | Loading dock, bins or rear service lane used only by this site. |
| `landscaping` | Grass or planting enclosed with this site. |
| `shared_parking_near` | A stall on a lot shared with other businesses, nearer this site's door than any other business's door. |
| `shared_parking_far` | A stall on a shared lot, nearer another business's door. |
| `centre_road` | A private road inside a shopping centre or business park (a ring road, an internal street), not a public street. |
| `sidewalk` | The public pavement between the kerb and the site. |
| `public_road` | The carriageway of a public road, past the kerb. |
| `neighbour_lot` | Parking, yard or forecourt of another business with its own access. |
| `neighbour_building` | Inside another business's building, outside this site's lot or centre. |
| `centre_building` | Inside another business's separate building on the same shared lot or in the same centre (a pad, another strip). Units in this site's own building are `building`. |
| `residential` | A house, its yard or a residential street's frontage. |
| `railway` | Track, ballast or the lineside strip. |
| `open_land` | Field, woods or vacant land that isn't part of any lot. |
| `construction` | Land being cleared or built on next to the site. Including it is optional ("it could be something"), so every view ignores it. |
| `unclear` | You can't tell. Every view ignores it. Use it rather than guessing. |

## Views

`in` and `out` are scored; `-` means ignored. A user can add their own view as a file (same kinds, their own in/out). The scorer reads any number of them.

| kind | default | arrival | centre | core |
| --- | --- | --- | --- | --- |
| building | in | in | in | in |
| walkway | in | in | in | in |
| own_parking | in | in | in | in |
| drive_through | in | in | in | in |
| forecourt | in | in | in | in |
| entrance | in | in | in | in |
| service | - | out | in | - |
| landscaping | in | - | in | - |
| shared_parking_near | in | in | in | - |
| shared_parking_far | out | out | in | - |
| centre_road | - | - | in | - |
| sidewalk | - | - | - | - |
| public_road | out | out | out | out |
| neighbour_lot | out | out | out | out |
| neighbour_building | out | out | out | out |
| centre_building | out | out | in | - |
| residential | out | out | out | out |
| railway | out | out | out | out |
| open_land | out | out | out | out |
| construction | - | - | - | - |
| unclear | - | - | - | - |

- **default** is what curtilage documents as premises: the building and its customer-facing lot, up to the kerb and short of neighbours. It describes the place and serves no particular use. It scores the default settings and is the headline number.
- **arrival** (opt-in): where a customer counts as having arrived at the store. It scores the arrival settings (approach and pickup zones). Service yards are out because staff aren't customers.
- **centre**: the whole shopping centre, scoring `scope: :centre`.
- **core**: only the kinds every other view agrees on. Shared parking, service yards, landscaping and centre roads are ignored, so no convention for shared lots or back of house counts for or against a result. Judge rule changes on it first; the other views then show what a change does for each convention.
- `landscaping` is ignored for arrival rather than out: planting islands sit between stalls, inside any sensible outline, so marking them out would punish good outlines. `open_land` is out: an outline may cut around it.
- `service` is ignored in the default view for now: the goal says "customer-facing", but today's rules take service yards in, and ignoring them rewards neither.
- `centre_building` is out for default and arrival (another business's building is never this site's premises) and in for centre; core ignores it, as the views disagree. Sites labelled before it existed used `neighbour_building` for these points.
- `sidewalk` is ignored everywhere: it lies within GPS error of the kerb, so it can't tell a good outline from a bad one.
- `tight` has no view: it's a shape, not a use, and stays unscored until someone needs it scored.

## How to label a site

1. **Don't look at curtilage's output while labelling.** The labelling page doesn't show it. Labels made while looking at the result drift toward it.
2. Use public-domain imagery (USGS, the page's default). Don't label on Esri or Google imagery: their terms don't allow it.
3. Place 15–25 points by hand:
   - every entrance;
   - 3–5 `own_parking` or `shared_parking_near` points spread over the lot, **including its far corners**;
   - the drive-through lane, forecourt and service yard, where they exist;
   - 2 `public_road` points per frontage;
   - 1–2 points on each neighbour (`neighbour_lot`, `neighbour_building`, `residential`) and behind the site.
   - Buildings: one `building` point inside the pinned building (a second in the far wing of a big or odd-shaped one), and one point on each building **next to** the site. Don't label buildings further away: any sensible outline gets them right, and the random points cover them. Another building that is clearly part of the same business on the same enclosed lot (a garden centre's sheds, a dealership's service building) is `building` too; if you can't tell, `unclear`.
4. **Most points go 5–15 m from where the site ends, on both sides of that line.** Points in the middle of a lot or a road are easy for any outline and tell us nothing.
5. **Stay 3 m from any line you can't place precisely** (a faded kerb, an unmarked lot edge). If a spot is genuinely ambiguous, label it `unclear`.
6. Then classify the **random points**: the page drops 15 points at random within 120 m of the pin and shows them one at a time. These keep the score honest about places you wouldn't have chosen yourself.
7. Write a short note for anything odd: imagery older than the map data, a lot under construction, a closed business.

That works out to about 3–5 minutes per site once you're used to it.

## Consistency

- About 1 site in 10 is labelled again, independently, by someone else, and the README reports how often their labels agree (per kind). Until there's a second labeller, the README says the labels come from one person.
- The kinds table changes only by pull request, never as part of a rule change: a rule change that also edits a table hides what it did to the score.

## Open question

`shared_parking_near` measures "nearer this door" with a straight line. That's simple and checkable, but a lot split by a kerb or an aisle would be fairer. For now the straight line stands; revisit if labellers disagree on shared lots.
