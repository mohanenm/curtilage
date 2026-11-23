# Rails

curtilage is a plain gem with no runtime dependencies: add it to the Gemfile and call it from a background job (generation reads map data, which takes seconds per area, so never in a web request).

```ruby
# app/jobs/premises_job.rb
class PremisesJob < ApplicationJob
  queue_as :default

  def perform(site_ids)
    sites = Site.where(id: site_ids).to_a
    results = Curtilage.generate_many(sites.map { |s| [s.lng, s.lat] }, cache_dir: Rails.root.join("tmp/curtilage"))
    sites.zip(results).each do |site, result|
      next site.update!(premises_status: "failed", premises_problem: result.problem) unless result.ok?

      site.update!(premises_status: "review", premises_geojson: result.to_geojson,
                   premises_flags: result.flags, premises_confidence: result.confidence)
    end
  end
end
```

- Never save a result that isn't `ok?`. Send flagged or low-confidence ones to a person.
- With RGeo or PostGIS (activerecord-postgis-adapter), store `result.to_wkt` in a geometry column with SRID 4326 ([PostGIS recipe](postgis.md)).
- Check a device's location against a stored ring with `Curtilage.point_in_premises?(ring, [lng, lat])`.
- A persistent `cache_dir` reuses on-demand region builds for a month. On hosts with an ephemeral disk, prebuild regions (`curtilage build`) into a bucket and pass `catalogue: Curtilage::Catalogue.from_dir(dir, base_url:)`.
