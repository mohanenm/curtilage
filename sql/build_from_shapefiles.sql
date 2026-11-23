-- Build one region's features file (Parquet) from Geofabrik's free
-- shapefiles. The geometry is already assembled (multipolygons included), so
-- this is read, filter, write. Run it with `curtilage build <state>`
-- (Curtilage::Build), which sets everything below up.
-- Output columns: id, feature, highway, name, min_lng, min_lat, max_lng, max_lat, wkb.
-- feature is building, ml_building, parking, road or railway. highway holds
-- the class: the road or railway class (Geofabrik's fclass), or the building
-- type (house, parking, roof, ...; empty when OSM only says building=yes). ML footprints have no OSM
-- id, so they get negative ids, unique within the file.
--
-- The caller defines, before this runs:
--   views buildings_a_src, traffic_a_src, roads_src and railways_src, each
--   reading every part of that layer (large layers are split into _1, _2, ...)
--   view ml_buildings_src (geom): machine-learned footprints, empty unless asked for
--   SET VARIABLE out_path = '<features>.parquet';


COPY (
  WITH features AS (
    SELECT osm_id::BIGINT AS id, 'building' AS feature, type AS highway, name, geom
    FROM buildings_a_src
    UNION ALL
    SELECT osm_id::BIGINT, 'parking', NULL, name, geom
    FROM traffic_a_src
    WHERE fclass = 'parking'
    UNION ALL
    -- Drivable roads and service roads at ground level: a tunnel under a lot
    -- or a flyover above it doesn't bound the premises.
    SELECT osm_id::BIGINT, 'road', fclass, name, geom
    FROM roads_src
    WHERE fclass IN ('motorway', 'trunk', 'primary', 'secondary', 'tertiary', 'unclassified', 'residential',
                     'service', 'motorway_link', 'trunk_link', 'primary_link', 'secondary_link', 'tertiary_link')
      AND tunnel = 'F' AND bridge = 'F'
    UNION ALL
    -- Railways at ground level bound premises like public roads. Trams run
    -- in the street, which is already a road.
    SELECT osm_id::BIGINT, 'railway', fclass, name, geom
    FROM railways_src
    WHERE fclass IN ('rail', 'light_rail', 'subway', 'narrow_gauge')
      AND tunnel = 'F' AND bridge = 'F'
    UNION ALL
    SELECT -row_number() OVER (), 'ml_building', NULL, NULL, geom
    FROM ml_buildings_src
  )
  SELECT id, feature, highway, name,
         ST_XMin(geom) AS min_lng, ST_YMin(geom) AS min_lat,
         ST_XMax(geom) AS max_lng, ST_YMax(geom) AS max_lat,
         ST_AsWKB(geom) AS wkb
  FROM features
  WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom)  -- a few shapefile records have no geometry
  ORDER BY ST_Hilbert(geom, {'min_x': -180, 'min_y': -90, 'max_x': 180, 'max_y': 90}::BOX_2D)
) TO (getvariable('out_path')) (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE 5000);
