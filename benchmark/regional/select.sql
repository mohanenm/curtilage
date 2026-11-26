-- The regional check's site selection (benchmark/regional_sites.rb fills the {{...}} values).
-- Metres in a UTM projection; places within {{holdout_m}} m of a held-out site are left out.
{{setup}}
CREATE TABLE f AS SELECT class, ST_Transform(ST_GeomFromGeoJSON(to_json(geometry)), 'EPSG:4326', {{crs}}, always_xy := true) AS g
  FROM read_json([{{layers}}], format = 'newline_delimited', maximum_object_size = 50000000);
CREATE TABLE pins AS SELECT id, name, category, lng, lat, ST_Transform(ST_Point(lng, lat), 'EPSG:4326', {{crs}}, always_xy := true) AS g
  FROM read_json({{sites}}, format = 'newline_delimited');
CREATE TABLE biz AS SELECT id, ST_Transform(ST_Point(lng, lat), 'EPSG:4326', {{crs}}, always_xy := true) AS g
  FROM read_json({{businesses}}, format = 'newline_delimited');
CREATE TABLE held AS SELECT ST_Transform(ST_Point(x, y), 'EPSG:4326', {{crs}}, always_xy := true) AS g FROM (VALUES {{held}}) t(x, y);
CREATE TABLE near AS SELECT p.id, b.g AS bg, ST_Distance(p.g, b.g) AS d
  FROM pins p JOIN f b ON b.class = 'building' AND ST_DWithin(p.g, b.g, {{pin_m}});
CREATE TABLE at_pin AS SELECT id, count(*) AS n,
  CASE WHEN count(*) FILTER (WHERE d = 0) > 0 THEN arg_min(bg, ST_Area(bg)) FILTER (WHERE d = 0)
       WHEN count(*) = 1 THEN any_value(bg) END AS b
  FROM near GROUP BY id;
CREATE TABLE lot AS SELECT a.id, arg_min(p.g, ST_Area(p.g)) AS parcel
  FROM at_pin a JOIN f p ON p.class = 'parcel' AND a.b IS NOT NULL AND ST_Contains(p.g, ST_PointOnSurface(a.b))
  GROUP BY a.id;
CREATE TABLE others AS SELECT l.id, count(*) FILTER (WHERE b.id <> l.id) AS n
  FROM lot l JOIN biz b ON ST_Contains(l.parcel, b.g) GROUP BY l.id;
CREATE TABLE paved AS SELECT l.id, sum(ST_Area(ST_Intersection(l.parcel, f.g))) AS m2
  FROM lot l JOIN f ON f.class IN ('parking', 'driveway') AND ST_Intersects(l.parcel, f.g) GROUP BY l.id;
CREATE TABLE sel AS SELECT p.id, p.name, p.category, p.lng, p.lat, a.b, l.parcel, coalesce(o.n, 0) AS others,
  coalesce(v.m2, 0) AS paved_m2,
  list_distinct([CASE WHEN a.b IS NULL THEN 'no single building at the pin' END,
               CASE WHEN a.b IS NOT NULL AND l.parcel IS NULL THEN 'no parcel under the building' END,
               CASE WHEN coalesce(o.n, 0) > 0 THEN 'other businesses on the parcel' END,
               CASE WHEN l.parcel IS NOT NULL AND coalesce(v.m2, 0) < {{pavement_m2}}
                    THEN 'no parking or driveway on the parcel' END]) AS reasons
  FROM pins p LEFT JOIN at_pin a USING (id) LEFT JOIN lot l USING (id) LEFT JOIN others o USING (id)
  LEFT JOIN paved v USING (id)
  WHERE NOT EXISTS (SELECT 1 FROM held h WHERE ST_DWithin(p.g, h.g, {{holdout_m}}));
COPY (SELECT id, name, category, lng, lat, CASE WHEN len(reasons) = 0 THEN 'clear' ELSE 'unclear' END AS "group",
             reasons, others, round(paved_m2) AS paved_m2
      FROM sel ORDER BY id) TO {{out}} (FORMAT json, ARRAY true);
