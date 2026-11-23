# Geofences on your own server

Store each site's premises ring and check a device's location against it. No database needed:

```ruby
ring = stored_site.premises_ring                     # [[lng, lat], ...] as generated
Curtilage.point_in_premises?(ring, [-80.00005, 35.00002])   # => true
```

For a margin around the premises (GPS is off by 5-20 m), store a buffered ring and check against that:

```ruby
result = Curtilage.premises([-80.0, 35.0])
arrived = result.ring                 # "on the premises"
nearby  = result.buffered(25)         # "within 25 m"
```

Or ask for zones made for this when generating: `approach_m: 150` (the premises grown for "on the way") and `pickup_m: 25` (the parking right by the store). Each zone nests inside the next.

From another language, run `curtilage serve` and `POST /premises`, then check points with your platform's point-in-polygon (Shapely's `contains`, JTS, Turf's `booleanPointInPolygon`).
