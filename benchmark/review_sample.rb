# frozen_string_literal: true

require "json"

# The review aid: for one site, a seeded sample of each of the four outcomes
# under a view (in caught, in missed, out taken in, out left out), on USGS
# imagery with the premises drawn. Any label correction is checked against
# this sample first, so corrections look at what the rules get right as well
# as what they get wrong (corrections.csv records that it was reviewed).
# Held-out sites are refused: their results are for the release check only.
module CurtilageBenchmark
  OUTCOMES = %w[in_caught in_missed out_included out_left_out].freeze
  SAMPLE_PER_OUTCOME = 5

  module_function

  # { outcome => [label, ...] } with up to count labels each, the same
  # every time for the same site.
  def review_sample(site, ring, labels, view, count: SAMPLE_PER_OUTCOME)
    raise ArgumentError, "#{site["id"]} is a held-out site: no per-point review" if role(site) == "holdout"

    xy = ring && G.counter_clockwise(G.open_ring(G.project(ring, site["pin"])))
    groups = labels.group_by { |l| outcome(view, xy, site["pin"], l) }
    rng = Random.new(site["id"].bytes.sum)
    OUTCOMES.to_h { |o| [o, (groups[o] || []).sample(count, random: rng)] }
  end

  # in_caught, in_missed, out_included or out_left_out; nil when the view
  # ignores the kind.
  def outcome(view, xy, pin, label)
    want = wanted(view, label["kind"])
    return nil if want.nil?

    inside = !xy.nil? && G.contains?(xy, G.project([label["point"]], pin).first)
    prefix = want ? "in" : "out"
    suffix = { [true, true] => "caught", [true, false] => "missed", [false, true] => "included",
               [false, false] => "left_out" }.fetch([want, inside])
    "#{prefix}_#{suffix}"
  end

  def review_page(site, ring, sample, view_name)
    data = { "id" => site["id"], "notes" => site["notes"].to_s, "pin" => site["pin"], "ring" => ring,
             "view" => view_name, "sample" => sample }
    html = format(REVIEW_PAGE, data: safe_json(data), csp: "__CSP__", leaflet_js: leaflet_file("leaflet.js"),
                               leaflet_css: leaflet_file("leaflet.css"))
    html.sub("__CSP__", label_csp(html, true))
  end

  REVIEW_PAGE = <<~HTML
    <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="%<csp>s">
    <title>Review sample</title><style>%<leaflet_css>s</style><script>%<leaflet_js>s</script>
    <style>
      html, body { margin: 0; height: 100%%; font: 13px system-ui, sans-serif; } #app { display: flex; height: 100%%; }
      #map { flex: 1; } #side { width: 340px; overflow-y: auto; padding: 10px; box-sizing: border-box; }
      .g { font-weight: 600; margin: 10px 0 2px; } .row { cursor: pointer; padding: 1px 4px; } .row:hover { background: #eef; }
      .dot { display: inline-block; width: 10px; height: 10px; border-radius: 50%%; margin-right: 6px; }
    </style></head><body><div id="app"><div id="side"><b id="title"></b><p id="notes"></p><div id="list"></div>
    <p>Review every group, not only the misses, before correcting a label.</p></div><div id="map"></div></div>
    <script>
    const D = %<data>s;
    const COLOUR = { in_caught: "#1a7f37", in_missed: "#cf222e", out_included: "#ff8c00", out_left_out: "#3b82f6" };
    const NAME = { in_caught: "In, caught", in_missed: "In, missed", out_included: "Out, taken in", out_left_out: "Out, left out" };
    const map = L.map("map", { maxZoom: 21 });
    const Export = L.TileLayer.extend({ getTileUrl(c) {
      const size = this.getTileSize(), nw = c.scaleBy(size), se = nw.add(size);
      const a = map.options.crs.project(map.unproject(nw, c.z)), b = map.options.crs.project(map.unproject(se, c.z));
      return this._url + "/exportImage?f=image&format=jpg&bboxSR=3857&imageSR=3857&size=256,256&bbox=" + [a.x, b.y, b.x, a.y].join(",");
    } });
    new Export("https://imagery.nationalmap.gov/arcgis/rest/services/USGSNAIPPlus/ImageServer",
      { maxZoom: 21, attribution: "Imagery: USGS The National Map (public domain)" }).addTo(map);
    if (D.ring) L.polygon(D.ring.map(p => [p[1], p[0]]), { color: "#00e05a", weight: 3, fillOpacity: 0.1, interactive: false }).addTo(map);
    L.circleMarker([D.pin[1], D.pin[0]], { radius: 4, color: "#000", fillColor: "#ff0", fillOpacity: 1 }).addTo(map);
    document.getElementById("title").textContent = `${D.id}: review sample (${D.view} view)`;
    document.getElementById("notes").textContent = D.notes;
    const list = document.getElementById("list");
    Object.keys(NAME).forEach(o => {
      const h = document.createElement("div"); h.className = "g"; h.textContent = `${NAME[o]} (${D.sample[o].length})`; list.append(h);
      D.sample[o].forEach(l => {
        const m = L.circleMarker([l.point[1], l.point[0]], { radius: 7, color: "#000", weight: 1, fillColor: COLOUR[o], fillOpacity: 0.95 })
          .bindTooltip(`${l.kind}: ${NAME[o]}`).addTo(map);
        const r = document.createElement("div"); r.className = "row";
        const dot = document.createElement("span"); dot.className = "dot"; dot.style.background = COLOUR[o];
        r.append(dot, document.createTextNode(l.kind)); r.onclick = () => map.setView(m.getLatLng(), 20); list.append(r);
      });
    });
    map.setView([D.pin[1], D.pin[0]], 18);
    </script></body></html>
  HTML
end
