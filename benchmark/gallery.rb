# frozen_string_literal: true

# The gallery (docs/gallery/index.html): every public benchmark site as a
# preview card (premises, store and pickup zones, entrances, flags, steps),
# with its category and what the labels say it got wrong, failures included.
# Built from the pinned Overture release; the page loads nothing.
module CurtilageBenchmark
  module_function

  def gallery(sites, features, labels_dir, view, options)
    sites = sites.reject { |s| s["placeholder"] }
    results = sites.map do |site|
      opts = symbolised(options.merge(site.fetch("options", {})))
      Curtilage.generate(site["pin"], features.fetch(site["id"]), pickup_m: 25, **opts).tap do |r|
        r.attribution = Curtilage::Overture.attribution(r.features)
      end
    end
    notes = sites.zip(results).map { |site, r| gallery_note(site, r, labels(site["id"], labels_dir), view) }
    Curtilage::Preview.html(results, ids: sites.map { |s| s["id"] }, notes: notes,
                                     title: "curtilage gallery: the public benchmark sites")
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
