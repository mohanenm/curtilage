# frozen_string_literal: true

require "digest"
require "json"

# The labelling page (see LABELS.md): one HTML file, opened locally, for
# placing labelled points on public-domain USGS imagery and saving them as
# <id>.geojson for the labels folder. It never shows curtilage's output, so
# labels can't drift toward it. Leaflet is inlined (benchmark/vendor), and
# the page's Content-Security-Policy lets it load images from the two USGS
# imagery hosts only, and nothing else from anywhere. With imagery: false it
# loads nothing at all and draws the cached map data instead.
module CurtilageBenchmark
  # Shortcut keys, in the order of the kinds table.
  KEYS = "1234567890qwertyuiopas"
  # One line per kind, shown on the page (the full table is in LABELS.md).
  KIND_NOTES = {
    "building" => "Inside this site's building.",
    "walkway" => "Pavement between this site's building and its own parking or the street.",
    "own_parking" => "A stall or aisle on a lot only this site uses (staff parking mixed in counts too).",
    "drive_through" => "A drive-through lane, including the menu board and window.",
    "forecourt" => "A fuel forecourt: pumps, the canopy, the lanes between them.",
    "entrance" => "This site's driveway, on the site side of the kerb, where it meets a public road.",
    "service" => "Back of house only this site uses: loading dock, bins, a rear delivery lane, " \
                 "fenced or gated staff parking.",
    "landscaping" => "Grass or planting enclosed with this site.",
    "shared_parking_near" => "A stall on a lot shared with other businesses, nearer this site's door than any other's.",
    "shared_parking_far" => "A stall on a shared lot, nearer another business's door.",
    "centre_road" => "A private road inside a shopping centre or business park, not a public street.",
    "sidewalk" => "The public pavement between the kerb and the site.",
    "public_road" => "The carriageway of a public road, past the kerb.",
    "neighbour_lot" => "Parking, yard or forecourt of another business with its own access.",
    "neighbour_building" => "Inside another business's building.",
    "residential" => "A house, its yard or a residential street's frontage.",
    "railway" => "Track, ballast or the lineside strip.",
    "open_land" => "Field, woods or vacant land that isn't part of any lot.",
    "construction" => "Land being cleared or built on next to the site.",
    "unclear" => "You can't tell. Use it rather than guessing.",
    "centre_building" => "Inside another business's separate building on the same shared lot or in the same centre " \
                         "(a pad, another strip). Units in this site's own building are building.",
    "centre_entrance" => "Where a shopping centre's or shared lot's driveway meets a public road, serving the whole " \
                         "centre rather than this site.",
  }.freeze
  IMAGERY_HOSTS = %w[https://imagery.nationalmap.gov https://basemap.nationalmap.gov].freeze
  LEAFLET = File.join(__dir__, "vendor", "leaflet-1.9.4")
  # Map data drawn around the pin when imagery is off.
  CONTEXT_M = 150
  RANDOM_POINTS = 15
  RANDOM_RADIUS_M = 120

  module_function

  # imagery: false loads no imagery (nothing leaves the machine); context:
  # { id => raw map features } is then drawn as outlines instead.
  def label_page(sites, labels_dir, imagery: true, context: {})
    data = sites.map do |s|
      site = s.slice("id", "category", "notes", "pin").merge("labels" => labels(s["id"], labels_dir) || [])
      rows = context[s["id"]]
      imagery || rows.nil? ? site : site.merge("context" => label_context(s["pin"], rows))
    end
    kinds = KINDS.each_with_index.map do |k, i|
      { "kind" => k, "key" => KEYS[i], "group" => kind_group(k), "note" => KIND_NOTES.fetch(k) }
    end
    html = format(PAGE, sites: safe_json(data), kinds: safe_json(kinds), random: RANDOM_POINTS,
                        radius: RANDOM_RADIUS_M, imagery: imagery, csp: "__CSP__",
                        leaflet_js: leaflet_file("leaflet.js"), leaflet_css: leaflet_file("leaflet.css"))
    html.sub("__CSP__", label_csp(html, imagery))
  end

  # Leaflet's CSS ships with CRLF line endings, and browsers turn those into
  # LF before hashing an inline block: inline it with LF, or its hash in the
  # policy never matches and the map is blank.
  def leaflet_file(name) = File.read(File.join(LEAFLET, name)).gsub(/\r\n?/, "\n")

  # Only the page's own inline code may run, by hash; images only from the
  # USGS hosts (none with imagery off); nothing else can load.
  def label_csp(html, imagery)
    hashes = ->(tag) { html.scan(%r{<#{tag}>(.*?)</#{tag}>}m).map { |(t)| "'sha256-#{Digest::SHA256.base64digest(t)}'" } }
    "default-src 'none'; script-src #{hashes.call("script").join(" ")}; style-src #{hashes.call("style").join(" ")}; " \
      "img-src #{imagery ? IMAGERY_HOSTS.join(" ") : "'none'"}; base-uri 'none'; form-action 'none'"
  end

  # Buildings, parking, roads and railways within CONTEXT_M of the pin, as
  # [lng, lat] lists, for drawing when there's no imagery.
  def label_context(pin, rows)
    features = Curtilage::Features.new(pin, rows)
    near = ->(list) { list.select { |f| f.xy.any? { |x, y| x.abs < CONTEXT_M && y.abs < CONTEXT_M } } }
    shapes = ->(list) { near.call(list).map { |f| G.unproject(f.xy, pin).map { |p| p.map { |v| v.round(7) } } } }
    { "buildings" => shapes.call(features.buildings), "parking" => shapes.call(features.parking),
      "roads" => shapes.call(features.roads), "railways" => shapes.call(features.railways) }
  end

  # Colours group kinds by what they are, not by any view's in or out.
  def kind_group(kind)
    case kind
    when "shared_parking_near", "shared_parking_far", "centre_road", "centre_building", "centre_entrance" then "shared"
    when "sidewalk", "public_road", "neighbour_lot", "neighbour_building", "residential", "railway", "open_land"
      "outside"
    when "construction", "unclear" then "other"
    else "site"
    end
  end

  def safe_json(value) = JSON.generate(value).gsub("</", "<\\/")

  PAGE = <<~HTML
    <!doctype html>
    <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="%<csp>s">
    <title>Benchmark labels</title>
    <style>%<leaflet_css>s</style>
    <script>%<leaflet_js>s</script>
    <style>
      html, body { margin: 0; height: 100%%; font: 13px system-ui, sans-serif; color: #222; background: #fff; }
      #app { display: flex; height: 100%%; } #map { flex: 1; cursor: crosshair; }
      #side { width: 340px; overflow-y: auto; border-right: 1px solid #ddd; padding: 10px; box-sizing: border-box; }
      .site { padding: 5px 8px; border-radius: 6px; cursor: pointer; } .site:hover { background: #f2f2f2; }
      .site.on { background: #e6efff; } .muted { color: #666; } b.id { font: 12px ui-monospace, Menlo, monospace; }
      .kind { display: flex; gap: 6px; align-items: center; padding: 2px 6px; border-radius: 4px; cursor: pointer; }
      .kind.on { outline: 2px solid #222; } .kind kbd { font: 11px ui-monospace, Menlo, monospace; width: 14px; }
      .dot { width: 10px; height: 10px; border-radius: 50%%; display: inline-block; }
      .site-g { background: #1a7f37; } .shared-g { background: #d4a000; } .outside-g { background: #cf222e; }
      .other-g { background: #888; } .n { margin-left: auto; color: #666; }
      button { font: inherit; padding: 4px 10px; margin: 0 4px 4px 0; cursor: pointer; }
      #save { background: #1a7f37; color: #fff; border: 0; border-radius: 4px; }
      #where { margin: 4px 0 8px; font-weight: 600; } #status { margin: 6px 0; } #note { margin: 0 0 6px; padding: 6px 8px; background: #f2f2f2; border-radius: 4px; }
      @media (max-width: 700px) { #app { flex-direction: column; } #side { width: 100%%; height: 45%%; } }
    </style></head><body>
    <div id="app"><div id="side">
      <b>Label what is at each spot</b>
      <p class="muted">Pick a kind (or press its key), click the map to place a point; click a point to remove it.
        Follow benchmark/LABELS.md. Save downloads <i>id</i>.geojson for the labels folder.</p>
      <p class="muted"><b>Random points:</b> the page picks 15 spots near the pin that nobody chose (the same ones
        every time) and shows them one by one in a yellow ring. Press the key for what's there. They catch mistakes
        in places you wouldn't have thought to check, and are scored apart from the points you place.</p>
      <div><button id="prev">&larr; Previous site</button><button id="next">Next site &rarr;</button></div>
      <div id="where"></div>
      <p id="about" class="muted"></p>
      <div><button id="undo">Undo</button><button id="random">Random points</button><button id="save">Save</button></div>
      <div id="status" class="muted"></div>
      <div id="note"></div>
      <div id="kinds"></div>
      <p><b>Sites</b></p><div id="list"></div>
      <p class="muted" id="credit"></p>
    </div><div id="map"></div></div>
    <script>
    const SITES = %<sites>s, KINDS = %<kinds>s, RANDOM = %<random>d, RADIUS = %<radius>d, IMAGERY = %<imagery>s;
    const COLOUR = { site: "#1a7f37", shared: "#d4a000", outside: "#cf222e", other: "#888" };
    const map = L.map("map", { maxZoom: 21 });
    // Both public domain (USGS). NAIP aerial photos (30-60 cm a pixel) are drawn on request for any view, a
    // tile at a time, so they can take a moment to appear; the cached tiles stop at zoom 16 (about 2.4 m a
    // pixel), blurry close up, but quick.
    const credit = "Imagery: USGS The National Map (public domain)";
    const Export = L.TileLayer.extend({ getTileUrl(c) {
      const size = this.getTileSize(), nw = c.scaleBy(size), se = nw.add(size);
      const a = map.options.crs.project(map.unproject(nw, c.z)), b = map.options.crs.project(map.unproject(se, c.z));
      return this._url + "/exportImage?f=image&format=jpg&bboxSR=3857&imageSR=3857&size=256,256&bbox=" +
        [a.x, b.y, b.x, a.y].join(",");
    } });
    const NAIP = "USGS NAIP aerial photos (sharp)", CACHED = "USGS cached tiles (quick, blurry close up)";
    const layers = {
      [NAIP]: new Export("https://imagery.nationalmap.gov/arcgis/rest/services/USGSNAIPPlus/ImageServer",
        { maxZoom: 21, attribution: credit + ", NAIP" }),
      [CACHED]: L.tileLayer("https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/{z}/{y}/{x}",
        { maxNativeZoom: 16, maxZoom: 21, attribution: credit }),
    };
    if (IMAGERY) {
      let base = NAIP;
      try { if (layers[localStorage.getItem("labels-imagery")]) base = localStorage.getItem("labels-imagery"); } catch (e) {}
      layers[base].addTo(map);
      // Expanded, so the control needs none of Leaflet's icon images.
      L.control.layers(layers, null, { collapsed: false }).addTo(map);
      map.on("baselayerchange", e => { try { localStorage.setItem("labels-imagery", e.name); } catch (err) {} });
    }
    document.getElementById("credit").textContent = IMAGERY
      ? "Imagery: USGS The National Map (public domain); switch source with the control at the top right of the map " +
        "if a site is blurry. Drafts stay in this browser until saved."
      : "Imagery is off: nothing is loaded from anywhere. Grey outlines are the cached map data (buildings, parking " +
        "in blue, roads in red), the same data curtilage uses, so labels placed from them alone can't catch what the " +
        "map is missing. Use imagery you're allowed to use, beside this page, to check what's really there.";
    const store = {
      get(k) { try { return JSON.parse(localStorage.getItem("labels-" + k) || "null"); } catch (e) { return null; } },
      set(k, v) { try { localStorage.setItem("labels-" + k, JSON.stringify(v)); } catch (e) {} },
    };
    let current = 0, kind = KINDS[0].kind, labels = [], queue = [], layer = L.layerGroup().addTo(map);
    const site = () => SITES[current];
    const group = k => KINDS.find(x => x.kind === k).group;
    // Repeatable random points for a site: the same id always gives the same points.
    function randomPoints(s) {
      let h = 2166136261;
      for (const c of s.id) h = Math.imul(h ^ c.charCodeAt(0), 16777619);
      const next = () => { h = Math.imul(h ^ (h >>> 15), 2246822507) ^ Math.imul(h ^ (h >>> 13), 3266489909); return ((h >>> 0) %% 1e6) / 1e6; };
      const kx = Math.cos(s.pin[1] * Math.PI / 180) * 111320, ky = 110540;
      return Array.from({ length: RANDOM }, () => {
        const r = RADIUS * Math.sqrt(next()), a = 2 * Math.PI * next();
        return [s.pin[0] + r * Math.cos(a) / kx, s.pin[1] + r * Math.sin(a) / ky];
      });
    }
    function save() { store.set(site().id, labels); }
    function redraw() {
      layer.clearLayers();
      const s = site();
      if (s.context) {
        const draw = (list, make) => list.forEach(c => make(c.map(p => [p[1], p[0]])).addTo(layer));
        const quiet = { interactive: false, weight: 1 };
        draw(s.context.parking, c => L.polygon(c, { ...quiet, color: "#6a7fd0", fillOpacity: .15 }));
        draw(s.context.buildings, c => L.polygon(c, { ...quiet, color: "#555", fillColor: "#999", fillOpacity: .35 }));
        draw(s.context.roads, c => L.polyline(c, { ...quiet, color: "#cf222e", weight: 2 }));
        draw(s.context.railways, c => L.polyline(c, { ...quiet, color: "#000", dashArray: "4 4" }));
      }
      L.circleMarker([s.pin[1], s.pin[0]], { radius: 4, color: "#000", weight: 1, fillColor: "#fff", fillOpacity: 1, interactive: false }).addTo(layer);
      labels.forEach((l, i) => {
        const m = L.circleMarker([l.point[1], l.point[0]], { radius: 6, weight: l.source === "random" ? 3 : 1,
          color: "#000", fillColor: COLOUR[group(l.kind)], fillOpacity: .9 }).addTo(layer);
        m.bindTooltip(l.kind + (l.source === "random" ? " (random)" : "") + ": " + KINDS.find(x => x.kind === l.kind).note);
        m.on("click", e => { L.DomEvent.stop(e); labels.splice(i, 1); save(); redraw(); });
      });
      if (queue.length) {
        const at = [queue[0][1], queue[0][0]];
        L.circleMarker(at, { radius: 14, weight: 4, color: "#ffd400", fill: false, interactive: false }).addTo(layer);
        L.circleMarker(at, { radius: 18, weight: 2, color: "#000", fill: false, interactive: false }).addTo(layer);
        L.circleMarker(at, { radius: 2, weight: 0, fillColor: "#ffd400", fillOpacity: 1, interactive: false }).addTo(layer);
      }
      const hand = labels.filter(l => l.source !== "random").length, rand = labels.length - hand;
      document.getElementById("status").textContent = queue.length
        ? `Random point ${RANDOM - queue.length + 1} of ${RANDOM}: press the key for what's inside the yellow ring (p: unclear).`
        : `${s.id}: ${hand} placed, ${rand} of ${RANDOM} random points labelled.`;
      document.getElementById("where").textContent = `Site ${current + 1} of ${SITES.length}: ${s.id} (${s.category})`;
      // Which business "this site" is: the pin can sit on the street, off its building.
      document.getElementById("about").textContent = s.notes || "";
      const chosen = KINDS.find(x => x.kind === kind);
      document.getElementById("note").textContent = queue.length ? "" : `${chosen.kind}: ${chosen.note}`;
      renderKinds(); renderList();
    }
    function renderKinds() {
      const box = document.getElementById("kinds");
      box.replaceChildren();
      KINDS.forEach(k => {
        const el = document.createElement("div");
        el.className = "kind" + (k.kind === kind ? " on" : "");
        const key = document.createElement("kbd"); key.textContent = k.key;
        const dot = document.createElement("span"); dot.className = "dot " + k.group + "-g";
        const name = document.createElement("span"); name.textContent = k.kind;
        const n = document.createElement("span"); n.className = "n"; n.textContent = labels.filter(l => l.kind === k.kind).length || "";
        el.title = k.note;
        el.append(key, dot, name, n);
        el.onclick = () => choose(k.kind);
        box.append(el);
      });
    }
    function renderList() {
      const list = document.getElementById("list");
      list.replaceChildren();
      SITES.forEach((s, i) => {
        const el = document.createElement("div");
        el.className = "site" + (i === current ? " on" : "");
        const b = document.createElement("b"); b.className = "id"; b.textContent = s.id;
        const n = document.createElement("div"); n.className = "muted";
        const count = (store.get(s.id) || s.labels).length;
        n.textContent = `${s.category}${count ? ", " + count + " labels" : ""}`;
        el.append(b, n); el.onclick = () => select(i); list.append(el);
      });
    }
    function choose(k) {
      if (queue.length) {
        labels.push({ kind: k, point: queue.shift(), source: "random" }); save();
        if (queue.length) map.setView([queue[0][1], queue[0][0]], 19);
      } else kind = k;
      redraw();
    }
    function select(i) {
      current = i; queue = [];
      labels = store.get(site().id) || site().labels.map(l => ({ ...l }));
      map.setView([site().pin[1], site().pin[0]], 19);
      redraw();
    }
    map.on("click", e => {
      if (queue.length) return;
      labels.push({ kind, point: [e.latlng.lng, e.latlng.lat].map(v => Math.round(v * 1e7) / 1e7), source: "hand" });
      save(); redraw();
    });
    document.getElementById("prev").onclick = () => select((current + SITES.length - 1) %% SITES.length);
    document.getElementById("next").onclick = () => select((current + 1) %% SITES.length);
    document.getElementById("undo").onclick = () => { labels.pop(); save(); redraw(); };
    document.getElementById("random").onclick = () => {
      const done = labels.filter(l => l.source === "random").map(l => l.point.join());
      queue = randomPoints(site()).map(p => p.map(v => Math.round(v * 1e7) / 1e7)).filter(p => !done.includes(p.join()));
      if (queue.length) map.setView([queue[0][1], queue[0][0]], 19);
      redraw();
    };
    document.addEventListener("keydown", e => {
      if (e.target !== document.body || e.metaKey || e.ctrlKey || e.altKey) return;
      const k = KINDS.find(x => x.key === e.key);
      if (k) { e.preventDefault(); choose(k.kind); }
    });
    document.getElementById("save").onclick = () => {
      const doc = { type: "FeatureCollection", features: labels.map(l => ({ type: "Feature",
        properties: { kind: l.kind, source: l.source }, geometry: { type: "Point", coordinates: l.point } })) };
      const a = document.createElement("a");
      a.href = URL.createObjectURL(new Blob([JSON.stringify(doc, null, 1) + "\\n"], { type: "application/geo+json" }));
      a.download = site().id + ".geojson";
      a.click();
      URL.revokeObjectURL(a.href);
    };
    select(0);
    </script></body></html>
  HTML
end
