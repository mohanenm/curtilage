# GeoPandas

GeoPandas reads every format curtilage writes:

```python
import geopandas as gpd

premises = gpd.read_parquet("premises.parquet")            # GeoParquet
# or: gpd.read_file("premises.gpkg"), gpd.read_file("premises.geojson")

premises[premises.ok].plot(column="confidence", legend=True)
```

Straight from the command line (no files), with NDJSON on standard output:

```python
import json, subprocess
import geopandas as gpd

pins = "\n".join(json.dumps({"id": i, "pin": p}) for i, p in enumerate([[-80.0, 35.0], [-80.01, 35.01]]))
out = subprocess.run(["curtilage", "generate", "--in", "-", "--format", "ndjson"],   # a list: no shell
                     input=pins, capture_output=True, text=True, check=False).stdout
features = [json.loads(line) for line in out.splitlines()]
gdf = gpd.GeoDataFrame.from_features(features, crs="EPSG:4326")
```

Exit status 1 means some sites have no usable premises (their rows have `ok` false); 2 or more is an error, with the reason on standard error.
