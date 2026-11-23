# DuckDB and GeoParquet

```sh
curtilage generate --in sites.csv --out premises.parquet     # GeoParquet
```

```sql
INSTALL spatial; LOAD spatial;

-- review queue: the least confident first
SELECT id, confidence, flags FROM 'premises.parquet' ORDER BY confidence LIMIT 20;

-- premises area by flag
SELECT unnest(string_split(flags, ';')) AS flag, count(*) AS sites, median(area_m2) AS median_m2
FROM 'premises.parquet' WHERE ok GROUP BY flag ORDER BY sites DESC;

-- visits: join device pings to premises
SELECT p.id, count(*) AS pings
FROM 'pings.parquet' g JOIN 'premises.parquet' p ON ST_Contains(p.geometry, ST_Point(g.lng, g.lat))
GROUP BY p.id;
```

`provenance` holds the full record as JSON (gem version, data source and release, options, a hash of the map data): `json_extract_string(provenance, '$.gem_version')`.
