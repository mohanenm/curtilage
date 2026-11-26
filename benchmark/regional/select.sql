-- The regional check's site selection (benchmark/regional_sites.rb fills the {{...}} values).
-- Metres in a UTM projection; places within {{holdout_m}} m of a held-out site are left out.
{{setup}}
-- Official polygons, repaired where invalid (untrusted data); empty results dropped.
CREATE TABLE f AS SELECT class, g FROM (
  SELECT class, ST_MakeValid(ST_Transform(ST_GeomFromGeoJSON(geometry), 'EPSG:4326', {{crs}}, always_xy := true)) AS g
  FROM read_json([{{layers}}], format = 'newline_delimited', maximum_object_size = 50000000,
                 columns = {class: 'VARCHAR', geometry: 'JSON'})
) WHERE NOT ST_IsEmpty(g);
CREATE TABLE pins AS SELECT id, name, category, lng, lat, ST_Transform(ST_Point(lng, lat), 'EPSG:4326', {{crs}}, always_xy := true) AS g
  FROM read_json({{sites}}, format = 'newline_delimited');
CREATE TABLE biz AS SELECT id, ST_Transform(ST_Point(lng, lat), 'EPSG:4326', {{crs}}, always_xy := true) AS g
  FROM read_json({{businesses}}, format = 'newline_delimited');
CREATE TABLE held AS SELECT ST_Transform(ST_Point(x, y), 'EPSG:4326', {{crs}}, always_xy := true) AS g FROM (VALUES {{held}}) t(x, y);
-- A pin on a fuel canopy means the shop beside it (as the gem reads it): look further.
CREATE TABLE reach AS SELECT p.id, CASE WHEN bool_or(c.g IS NOT NULL) THEN {{canopy_m}} ELSE {{pin_m}} END AS m
  FROM pins p LEFT JOIN f c ON c.class = 'canopy' AND ST_Contains(c.g, p.g) GROUP BY p.id;
CREATE TABLE near AS SELECT p.id, b.g AS bg, ST_Distance(p.g, b.g) AS d
  FROM pins p JOIN reach r USING (id) JOIN f b ON b.class = 'building' AND ST_DWithin(p.g, b.g, r.m);
CREATE TABLE at_pin AS SELECT id,
  CASE WHEN count(*) FILTER (WHERE d = 0) > 0 THEN arg_min(bg, ST_Area(bg)) FILTER (WHERE d = 0)
       WHEN count(*) = 1 THEN any_value(bg) END AS b
  FROM near GROUP BY id;
-- The parcel holding most of the building; it must hold at least {{parcel_share}} of it.
CREATE TABLE lot AS SELECT a.id, arg_max(p.g, ST_Area(ST_Intersection(p.g, a.b))) AS parcel,
  max(ST_Area(ST_Intersection(p.g, a.b))) / any_value(ST_Area(a.b)) AS share
  FROM at_pin a JOIN f p ON p.class = 'parcel' AND a.b IS NOT NULL AND ST_Intersects(p.g, a.b)
  GROUP BY a.id;
CREATE TABLE others AS SELECT l.id, count(*) FILTER (WHERE b.id <> l.id) AS n
  FROM lot l JOIN biz b ON ST_Contains(l.parcel, b.g) GROUP BY l.id;
CREATE TABLE paved AS SELECT l.id, sum(ST_Area(ST_Intersection(l.parcel, f.g))) AS m2
  FROM lot l JOIN f ON f.class IN ('parking', 'driveway') AND ST_Intersects(l.parcel, f.g) GROUP BY l.id;
CREATE TABLE sel AS SELECT p.id, p.name, p.category, p.lng, p.lat, coalesce(o.n, 0) AS others,
  coalesce(v.m2, 0) AS paved_m2,
  list_filter([CASE WHEN a.b IS NULL THEN 'no single building at the pin' END,
               CASE WHEN a.b IS NOT NULL AND l.parcel IS NULL THEN 'no parcel under the building' END,
               CASE WHEN l.share < {{parcel_share}} THEN 'building spans parcels' END,
               CASE WHEN coalesce(o.n, 0) > 0 THEN 'other businesses on the parcel' END,
               CASE WHEN l.parcel IS NOT NULL AND coalesce(v.m2, 0) < {{pavement_m2}}
                    THEN 'no parking or driveway on the parcel' END], lambda x: x IS NOT NULL) AS reasons
  FROM pins p LEFT JOIN at_pin a USING (id) LEFT JOIN lot l USING (id) LEFT JOIN others o USING (id)
  LEFT JOIN paved v USING (id)
  WHERE NOT EXISTS (SELECT 1 FROM held h WHERE ST_DWithin(p.g, h.g, {{holdout_m}}));
COPY (SELECT id, name, category, lng, lat, CASE WHEN len(reasons) = 0 THEN 'clear' ELSE 'unclear' END AS "group",
             reasons, others, round(paved_m2) AS paved_m2
      FROM sel ORDER BY id) TO {{out}} (FORMAT json, ARRAY true);
