# PostGIS

Write NDJSON or GeoJSON, then load it with `ogr2ogr` (GDAL) or plain SQL.

```sh
curtilage generate --in sites.csv --out premises.gpkg        # GeoPackage: one row a site
ogr2ogr -f PostgreSQL PG:"dbname=geo" premises.gpkg -nln premises -lco GEOMETRY_NAME=geom
```

Or keep it in Ruby: every result has WKT (`to_wkt`, `store_wkt`), in longitude-latitude order, SRID 4326.

```ruby
result = Curtilage.premises([-80.0, 35.0])
conn.exec_params(<<~SQL, [result.to_wkt, result.flags.join(";"), result.attribution.join("; ")]) if result.ok?
  INSERT INTO premises (geom, flags, attribution) VALUES (ST_GeomFromText($1, 4326), $2, $3)
SQL
```

Which premises hold a point (a device's location)? Use `geography` for metres:

```sql
SELECT id FROM premises
WHERE ST_Intersects(geom, ST_SetSRID(ST_MakePoint(-80.0001, 35.0001), 4326));

-- within 15 m of the premises
SELECT id FROM premises
WHERE ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-80.0001, 35.0001), 4326)::geography, 15);
```

Index the column (`CREATE INDEX ON premises USING gist (geom);`) once you have more than a few thousand rows.
