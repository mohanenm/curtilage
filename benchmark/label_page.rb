# frozen_string_literal: true

require "json"

# The labelling page (see LABELS.md): one HTML file, opened locally, for
# placing labelled points on public-domain USGS imagery and saving them as
# <id>.geojson for the labels folder. It never shows curtilage's output, so
# labels can't drift toward it. Opening it loads Leaflet from cdnjs and
# imagery tiles from USGS for each site's area.
module CurtilageBenchmark
  # Shortcut keys, in the order of the kinds table.
  KEYS = "1234567890qwertyuiop"
  RANDOM_POINTS = 15
  RANDOM_RADIUS_M = 120

  module_function

  def label_page(sites, labels_dir)
    data = sites.map do |s|
      s.slice("id", "category", "notes", "pin").merge("labels" => labels(s["id"], labels_dir) || [])
    end
    kinds = KINDS.each_with_index.map { |k, i| { "kind" => k, "key" => KEYS[i], "group" => kind_group(k) } }
    format(PAGE, sites: safe_json(data), kinds: safe_json(kinds), random: RANDOM_POINTS, radius: RANDOM_RADIUS_M)
  end

  # Colours group kinds by what they are, not by any view's in or out.
  def kind_group(kind)
    case kind
    when "shared_parking_near", "shared_parking_far", "centre_road" then "shared"
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
    <title>Benchmark labels</title>
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.css">
    <script src="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.js"></script>
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
      #status { margin: 6px 0; }
      @media (max-width: 700px) { #app { flex-direction: column; } #side { width: 100%%; height: 45%%; } }
    </style></head><body>
    <div id="app"><div id="side">
      <b>Label what is at each spot</b>
      <p class="muted">Pick a kind (or press its key), click the map to place a point; click a point to remove it.
        Follow benchmark/LABELS.md. Save downloads <i>id</i>.geojson for the labels folder.</p>
      <p class="muted"><b>Random points:</b> the page picks 15 spots near the pin that nobody chose (the same ones
        every time) and shows them one by one in a yellow ring. Press the key for what's there. They catch mistakes
        in places you wouldn't have thought to check, and are scored apart from the points you place.</p>
      <div><button id="undo">Undo</button><button id="random">Random points</button><button id="save">Save</button></div>
      <div id="status" class="muted"></div>
      <div id="kinds"></div>
      <p><b>Sites</b></p><div id="list"></div>
      <p class="muted">Imagery: USGS The National Map (public domain). Drafts stay in this browser until saved.</p>
    </div><div id="map"></div></div>
    <script>
    const SITES = %<sites>s, KINDS = %<kinds>s, RANDOM = %<random>d, RADIUS = %<radius>d;
    const COLOUR = { site: "#1a7f37", shared: "#d4a000", outside: "#cf222e", other: "#888" };
    const map = L.map("map", { maxZoom: 21 });
    L.tileLayer("https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/{z}/{y}/{x}", {
      maxNativeZoom: 16, maxZoom: 21, attribution: "Imagery: USGS The National Map (public domain)" }).addTo(map);
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
      L.circleMarker([s.pin[1], s.pin[0]], { radius: 4, color: "#000", weight: 1, fillColor: "#fff", fillOpacity: 1, interactive: false }).addTo(layer);
      labels.forEach((l, i) => {
        const m = L.circleMarker([l.point[1], l.point[0]], { radius: 6, weight: l.source === "random" ? 3 : 1,
          color: "#000", fillColor: COLOUR[group(l.kind)], fillOpacity: .9 }).addTo(layer);
        m.bindTooltip(l.kind + (l.source === "random" ? " (random)" : ""));
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
