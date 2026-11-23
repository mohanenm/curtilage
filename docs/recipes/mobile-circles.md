# Circles for mobile geofences

Android's Geofencing API and iOS's `CLCircularRegion` take a centre and a radius, not polygons. Every result offers two circles:

- `enclosing_circle`: the smallest circle holding the whole premises. Nothing on the premises is outside it; it can reach well beyond a long, thin site.
- `fit_circle`: a circle with the premises' area, centred on them. Closer to the premises' size, but it cuts their far corners.

```ruby
result = Curtilage.premises([-80.0, 35.0])
result.enclosing_circle   # => { centre: [-80.0000274, 35.0000249], radius_m: 55.0 }
result.fit_circle         # => { centre: [...], radius_m: 41.3 }
```

Both are in every GeoJSON/NDJSON premises (`properties.enclosing_circle`, `properties.fit_circle`) and in CSV (`circle_lng`, `circle_lat`, `circle_radius_m`, `fit_*`).

Android (Kotlin):

```kotlin
Geofence.Builder()
    .setRequestId(siteId)
    .setCircularRegion(lat, lng, radiusM.toFloat())   // note: latitude first
    .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_ENTER)
    .setExpirationDuration(Geofence.NEVER_EXPIRE)
    .build()
```

iOS (Swift):

```swift
let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                              radius: radiusM, identifier: siteId)
```

Both platforms have a minimum useful radius (around 100-150 m in practice) and a cap on how many regions an app watches (100 on Android, 20 on iOS), so use circles to wake the app near a site, then check the polygon on the server.
