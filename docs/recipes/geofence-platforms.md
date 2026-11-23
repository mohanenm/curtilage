# Geofence platforms

Services that take polygon geofences usually accept GeoJSON, often with a vertex limit and always `[lng, lat]` order.

```sh
curtilage generate --in sites.csv --out premises.geojson --simplify 20 --no-store
```

- `--simplify N` keeps at most N corners per premises without ever dropping the pin or the store zone (`Result#simplified(n)` in Ruby). Most platforms allow 50 or more, so the default (at most 10 corners, more with `entrances: :all`) usually fits as is.
- `--no-store` leaves out the store zones, so each feature is one site's premises. Feature `properties.id` carries your site id.
- Keep the `attribution` property, or show it where the geofences are displayed.

To give a platform one file per site, split the NDJSON output: each line is a complete GeoJSON Feature.

```sh
curtilage generate --in sites.csv --format ndjson --no-store | split -l 1 - site-
```
