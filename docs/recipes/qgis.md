# QGIS

```sh
curtilage generate --in sites.csv --out premises.gpkg
```

Drag `premises.gpkg` into QGIS (or Layer > Add Layer > Add Vector Layer). One row a site: the premises as the geometry, with `id`, `ok`, `flags`, `confidence`, `store_wkt`, `attribution` and `provenance` as fields.

- Style by review need: Layer Properties > Symbology > Rule-based, with rules such as `"ok" = false` (red), `"flags" LIKE '%store_may_be_unit%'` (orange), else green.
- Show the store zone: add a virtual layer, `SELECT id, GeomFromText(store_wkt, 4326) AS geometry FROM premises`.
- Edit a few premises by hand, save, then export as GeoJSON or NDJSON and pass it back as `--corrections fixed.geojson`: those sites use your polygon from then on.
- For aerial imagery under the polygons, add a basemap layer you're licensed to use. Opening it sends the area you view to the tile provider.

Credit OpenStreetMap on any map you make from the layer (the `attribution` field says what to credit).
