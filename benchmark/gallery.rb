# frozen_string_literal: true

# The gallery (docs/gallery/index.html): every public benchmark site as a
# preview card (premises, store and pickup zones, entrances, flags, steps),
# with its category and what the labels say it got wrong, failures included.
# Built from the pinned Overture release. Each map is drawn over a snapshot
# of public-domain USGS aerial imagery, fetched once when the gallery is
# built and stored next to the page (images/<id>.jpg), so the page still
# loads nothing from anywhere. It is published (GitHub Pages), so it refuses
# any site that isn't in the public benchmark/sites.geojson with the same pin.
module CurtilageBenchmark
  SNAPSHOT_SERVICE = "https://imagery.nationalmap.gov/arcgis/rest/services/USGSNAIPPlus/ImageServer/exportImage"
  SNAPSHOT_PX = 480
  MAX_SNAPSHOT_BYTES = 3_000_000
  IMAGERY_CREDIT = "imagery: USGS The National Map, NAIP (public domain)"

  module_function

  def gallery(sites, features, labels_dir, view, options, public_sites: self.sites(File.join(DIR, "sites.geojson")),
              backgrounds: nil)
    refuse_private(sites, public_sites)
    sites = sites.reject { |s| s["placeholder"] }
    results = sites.map do |site|
      opts = symbolised(options.merge(site.fetch("options", {})))
      Curtilage.generate(site["pin"], features.fetch(site["id"]), pickup_m: 25, **opts).tap do |r|
        r.attribution = Curtilage::Overture.attribution(r.features)
      end
    end
    notes = sites.zip(results).map { |site, r| gallery_note(site, r, labels(site["id"], labels_dir), view) }
    Curtilage::Preview.html(results, ids: sites.map { |s| s["id"] }, notes: notes,
                                     title: "curtilage gallery: the public benchmark sites",
                                     backgrounds: backgrounds && sites.map { |s| backgrounds[s["id"]] },
                                     background_credit: IMAGERY_CREDIT)
  end

  # { id => "images/<id>.jpg" } for each site whose snapshot is in dir,
  # fetching the missing ones: the map's square around the pin, in plain
  # longitude and latitude so it lines up with the preview's drawing.
  def snapshots(sites, dir)
    FileUtils.mkdir_p(dir)
    sites.to_h do |site|
      file = File.join(dir, "#{site["id"]}.jpg")
      File.binwrite(file, snapshot(site["pin"])) unless File.file?(file)
      [site["id"], "images/#{site["id"]}.jpg"]
    end
  end

  # half: metres either side of the pin (the gallery map's square by default).
  def snapshot(pin, half = Curtilage::Preview::VIEW_M)
    uri = snapshot_uri(pin, half)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 20, read_timeout: 120) do |http|
      http.request(Net::HTTP::Get.new(uri))
    end
    raise "#{uri.host}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    body = response.body.to_s
    raise "#{uri.host}: snapshot over #{MAX_SNAPSHOT_BYTES} bytes" if body.bytesize > MAX_SNAPSHOT_BYTES
    raise "#{uri.host}: not a JPEG" unless body.start_with?("\xFF\xD8".b)

    body
  end

  def snapshot_uri(pin, half = Curtilage::Preview::VIEW_M)
    (w, s), (e, n) = G.unproject([[-half, -half], [half, half]], pin)
    width = (SNAPSHOT_PX * (e - w) / (n - s)).round
    URI("#{SNAPSHOT_SERVICE}?#{URI.encode_www_form(bbox: [w, s, e, n].join(","), bboxSR: 4326, imageSR: 4326,
                                                   size: "#{width},#{SNAPSHOT_PX}", format: "jpg", f: "image")}")
  end

  def refuse_private(sites, public_sites)
    known = public_sites.to_h { |s| [s["id"], s["pin"]] }
    strays = sites.reject { |s| known[s["id"]] == s["pin"] }.map { |s| s["id"] }
    raise ArgumentError, "the gallery takes public benchmark sites only, not: #{strays.join(", ")}" if strays.any?
  end

  def gallery_note(site, result, labels, view)
    note = "#{site["category"]}: #{site["notes"]}"
    return "#{note} Not labelled yet." unless labels

    s = score_labels(view, result.ring, labels, site["pin"])
    note += " Labels: caught #{s["caught"]} of #{s["in"]} points that should be in, took in #{s["included"]} " \
            "of #{s["out"]} that should stay out."
    return note if s["hard"].empty?

    flags = result.flags.empty? ? "no flags raised" : "flags raised: #{result.flags.join(", ")}"
    "#{note} Failed: #{s["hard"].join(", ")} (#{flags})."
  end
end
