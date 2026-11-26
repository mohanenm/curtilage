-- The regional check's scoring (benchmark/regional_run.rb fills the {{...}} values): each result
-- against the official polygons, in metres (UTM). {{tol}} m allows for alignment between OSM and
-- the official data: leaks are measured on official polygons shrunk by it.
{{setup}}
CREATE TABLE f AS SELECT class, g FROM (
  SELECT class, ST_MakeValid(ST_Transform(ST_GeomFromGeoJSON(geometry), 'EPSG:4326', {{crs}}, always_xy := true)) AS g
  FROM read_json([{{layers}}], format = 'newline_delimited', maximum_object_size = 50000000,
                 columns = {class: 'VARCHAR', geometry: 'JSON'})
) WHERE NOT ST_IsEmpty(g);
CREATE MACRO m(j) AS CASE WHEN j IS NULL OR j::VARCHAR = 'null' THEN NULL
  ELSE ST_MakeValid(ST_Transform(ST_GeomFromGeoJSON(j), 'EPSG:4326', {{crs}}, always_xy := true)) END;
CREATE TABLE r AS SELECT id, "group", kind, m(premises) AS p, m(store) AS s, m(osm) AS o, m(building) AS b,
  m(parcel) AS parcel, [ST_Transform(ST_Point(a[1], a[2]), 'EPSG:4326', {{crs}}, always_xy := true) FOR a IN access] AS access
  FROM read_json({{results}}, format = 'newline_delimited', maximum_object_size = 50000000,
                 columns = {id: 'VARCHAR', "group": 'VARCHAR', kind: 'VARCHAR', premises: 'JSON', store: 'JSON',
                            osm: 'JSON', building: 'JSON', parcel: 'JSON', access: 'DOUBLE[][]'});
-- Road and alley, and sidewalk, under the premises, shrunk by the tolerance.
CREATE TABLE road AS SELECT r.id, r.kind, ST_Buffer(ST_Union_Agg(f.g), -{{tol}}) AS u
  FROM r JOIN f ON f.class IN ('road', 'alley') AND ST_Intersects(r.p, f.g) GROUP BY r.id, r.kind;
CREATE TABLE walk AS SELECT r.id, r.kind, ST_Buffer(ST_Union_Agg(f.g), -{{tol}}) AS u
  FROM r JOIN f ON f.class = 'sidewalk' AND ST_Intersects(r.p, f.g) GROUP BY r.id, r.kind;
-- The parcel's own parking and driveways.
CREATE TABLE pav AS SELECT r.id, r.kind, ST_Union_Agg(ST_Intersection(f.g, r.parcel)) AS u
  FROM r JOIN f ON f.class IN ('parking', 'driveway') AND ST_Intersects(r.parcel, f.g) GROUP BY r.id, r.kind;
-- Other buildings (not mostly on the site's parcel) and pavement off the parcel, under the premises.
CREATE TABLE nb AS SELECT r.id, r.kind, sum(ST_Area(ST_Intersection(r.p, ST_Buffer(f.g, -{{tol}})))) AS m2
  FROM r JOIN f ON ST_Intersects(r.p, f.g) AND f.class IN ('building', 'parking_garage', 'structure', 'canopy')
   AND ST_Area(ST_Intersection(f.g, coalesce(r.parcel, r.b))) < 0.5 * ST_Area(f.g)
  GROUP BY r.id, r.kind;
-- Pavement on other parcels (the right of way is in no parcel: a driveway apron there isn't a neighbour's).
CREATE TABLE other_lots AS SELECT r.id, r.kind, ST_Buffer(ST_Union_Agg(f.g), -{{tol}}) AS u
  FROM r JOIN f ON f.class = 'parcel' AND ST_Intersects(r.p, f.g)
   AND (r.parcel IS NULL OR ST_Area(ST_Intersection(f.g, r.parcel)) < 0.5 * ST_Area(f.g))
  GROUP BY r.id, r.kind;
CREATE TABLE np AS SELECT r.id, r.kind, ST_Area(ST_Intersection(ST_Intersection(r.p, ST_Union_Agg(f.g)), any_value(o.u))) AS m2
  FROM r JOIN other_lots o USING (id, kind) JOIN f ON f.class IN ('parking', 'driveway') AND ST_Intersects(r.p, f.g)
  GROUP BY r.id, r.kind, r.p;
-- Structures near the site: on its parcel (should be in) or off it (should be out); in = its interior point is.
CREATE TABLE st AS SELECT r.id, r.kind, list({'class': f.class,
    'own': r.parcel IS NOT NULL AND ST_Area(ST_Intersection(f.g, r.parcel)) >= 0.5 * ST_Area(f.g),
    'inside': r.p IS NOT NULL AND ST_Contains(r.p, ST_PointOnSurface(f.g))}) AS structures
  FROM r JOIN f ON f.class IN ('building', 'parking_garage', 'structure', 'canopy') AND ST_DWithin(f.g, r.b, 60)
   AND ST_Area(ST_Intersection(f.g, r.b)) < 0.5 * ST_Area(f.g)
  GROUP BY r.id, r.kind;
-- Vehicle entrances: where paving that reaches the parcel meets official road or alley (within 1 m), as points.
CREATE TABLE paving AS SELECT r.id, r.kind, ST_Union_Agg(f.g) AS u
  FROM r JOIN f ON f.class IN ('parking', 'driveway') AND ST_Intersects(r.parcel, f.g) GROUP BY r.id, r.kind;
CREATE TABLE ent AS SELECT id, kind, list(ST_Centroid(e.geom)) AS pts FROM (
  SELECT pv.id, pv.kind, UNNEST(ST_Dump(ST_Intersection(ST_Buffer(pv.u, 1), ST_Union_Agg(f.g)))) AS e
  FROM paving pv JOIN f ON f.class IN ('road', 'alley') AND ST_DWithin(f.g, pv.u, 1)
  GROUP BY pv.id, pv.kind, pv.u) GROUP BY id, kind;
COPY (SELECT r.id, r."group", r.kind,
  round(ST_Area(r.p)) AS area_m2,
  round(ST_Area(ST_Intersection(r.p, r.b)) / ST_Area(r.b), 3) AS building_share,
  round(ST_Area(ST_Intersection(r.s, r.b)) / ST_Area(ST_Union(r.s, r.b)), 3) AS store_iou,
  round(ST_Area(ST_Intersection(r.o, r.b)) / ST_Area(ST_Union(r.o, r.b)), 3) AS osm_iou,
  round(ST_Distance(ST_Centroid(r.o), ST_Centroid(r.b)), 2) AS osm_offset_m,
  round(ST_Area(pav.u)) AS pavement_m2,
  round(ST_Area(ST_Intersection(r.p, pav.u)) / ST_Area(pav.u), 3) AS pavement_share,
  round(coalesce(ST_Area(ST_Intersection(r.p, road.u)), 0)) AS road_m2,
  round(coalesce(ST_Area(ST_Intersection(r.p, walk.u)), 0)) AS sidewalk_m2,
  round(coalesce(nb.m2, 0) + coalesce(np.m2, 0)) AS neighbour_m2,
  coalesce(st.structures, []) AS structures,
  len(coalesce(ent.pts, [])) AS entrances,
  len(list_filter(coalesce(ent.pts, []), lambda e: len(list_filter(r.access, lambda a: ST_Distance(a, e) <= {{entrance_m}})) > 0)) AS entrances_found,
  len(r.access) AS access_points,
  len(list_filter(r.access, lambda a: len(list_filter(coalesce(ent.pts, []), lambda e: ST_Distance(a, e) <= {{entrance_m}})) > 0)) AS access_right
  FROM r LEFT JOIN road USING (id, kind) LEFT JOIN walk USING (id, kind) LEFT JOIN pav USING (id, kind) LEFT JOIN nb USING (id, kind)
  LEFT JOIN np USING (id, kind) LEFT JOIN st USING (id, kind) LEFT JOIN ent USING (id, kind)
  ORDER BY r.kind, r.id) TO {{out}} (FORMAT json, ARRAY true);
