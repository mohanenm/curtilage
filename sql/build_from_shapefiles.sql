-- Build one region's features file (Parquet) from
-- Geofabrik's free shapefiles. The geometry is
-- already assembled (multipolygons included), so this is read, filter, write.
-- Output columns: id, feature, highway, name, min_lng, min_lat, max_lng, max_lat, wkb.
-- feature is building, parking, road or railway; highway holds the road or
-- railway class (Geofabrik's fclass).
--
-- The caller sets, before .read:
--   SET VARIABLE shp_dir = '<folder with the unzipped gis_osm_*_free_1 files>';
--   SET VARIABLE out_path = '<features>.parquet';

LOAD spatial;

COPY (
  WITH features AS (
    SELECT osm_id::BIGINT AS id, 'building' AS feature, NULL AS highway, name, geom
    FROM ST_Read(getvariable('shp_dir') || '/gis_osm_buildings_a_free_1.shp')
    UNION ALL
    SELECT osm_id::BIGINT, 'parking', NULL, name, geom
    FROM ST_Read(getvariable('shp_dir') || '/gis_osm_traffic_a_free_1.shp')
    WHERE fclass = 'parking'
    UNION ALL
    -- Drivable roads and service roads at ground level: a tunnel under a lot
    -- or a flyover above it doesn't bound the premises.
    SELECT osm_id::BIGINT, 'road', fclass, name, geom
    FROM ST_Read(getvariable('shp_dir') || '/gis_osm_roads_free_1.shp')
    WHERE fclass IN ('motorway', 'trunk', 'primary', 'secondary', 'tertiary', 'unclassified', 'residential',
                     'service', 'motorway_link', 'trunk_link', 'primary_link', 'secondary_link', 'tertiary_link')
      AND tunnel = 'F' AND bridge = 'F'
    UNION ALL
    -- Railways at ground level bound premises like public roads. Trams run
    -- in the street, which is already a road.
    SELECT osm_id::BIGINT, 'railway', fclass, name, geom
    FROM ST_Read(getvariable('shp_dir') || '/gis_osm_railways_free_1.shp')
    WHERE fclass IN ('rail', 'light_rail', 'subway', 'narrow_gauge')
      AND tunnel = 'F' AND bridge = 'F'
  )
  SELECT id, feature, highway, name,
         ST_XMin(geom) AS min_lng, ST_YMin(geom) AS min_lat,
         ST_XMax(geom) AS max_lng, ST_YMax(geom) AS max_lat,
         ST_AsWKB(geom) AS wkb
  FROM features
  WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom)  -- a few shapefile records have no geometry
  ORDER BY ST_Hilbert(geom, {'min_x': -180, 'min_y': -90, 'max_x': 180, 'max_y': 90}::BOX_2D)
) TO (getvariable('out_path')) (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE 20000);
