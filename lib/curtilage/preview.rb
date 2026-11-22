# frozen_string_literal: true

require "cgi/escape"

module Curtilage
  # A self-contained HTML page for checking results by eye: one map per
  # site, drawn from the map data the premises were made from (buildings,
  # parking, roads, railways) with the premises, store zone and driveway
  # entrances on top, and the site's flags, details and steps beside it.
  #
  # It loads nothing from anywhere (no map tiles, scripts or fonts), so
  # opening it reveals no locations. It does hold the coordinates you gave,
  # so share it only as you would those.
  #
  #   results = Curtilage.generate_many(pins, keep_features: true)
  #   File.write("preview.html", Curtilage::Preview.html(results))
  module Preview
    # Half the width of each map, in metres.
    VIEW_M = 120
    SCALE_BAR_M = 50

    module_function

    # ids: one label per result (default 1, 2, ...). buffer_m: also draw the
    # premises grown by this many metres (Result#buffered), e.g. a geofence
    # margin. Results without features (generate_many without
    # keep_features: true) show only the premises, store zone and entrances.
    def html(results, ids: nil, title: "curtilage preview", buffer_m: nil)
      ids ||= (1..results.size).map(&:to_s)
      cards = results.zip(ids).each_with_index.map { |(result, id), i| card(result, id, i, buffer_m) }
      credits = results.flat_map { |r| r.attribution || Result::OSM_ATTRIBUTION }.uniq
      page(title, cards, toolbar(results), credits, buffer_m)
    end

    # ok, flagged (ok, with flags) or invalid.
    def state(result)
      return "invalid" unless result.ok?

      result.flags.any? ? "flagged" : "ok"
    end

    # Filter and sort controls (the page's only script, inline). Without
    # scripts every card shows, in input order.
    def toolbar(results)
      states = results.map { |r| state(r) }.tally
      <<~HTML
        <p>#{h(summary(states, results.size))}</p>
        <p class="tools"><label>Show <select id="show">#{select_options(filters(results, states))}</select></label>
        <label>Sort by <select id="sort">#{select_options(SORTS)}</select></label> <span id="shown"></span></p>
      HTML
    end

    def filters(results, states)
      count = ->(*keys) { keys.sum { |k| states.fetch(k, 0) } }
      flags = results.flat_map(&:flags).tally.sort_by { |f, n| [-n, f.to_s] }
      [["all", "All sites (#{results.size})"],
       ["look", "Needs a look: flagged or not valid (#{count.call("flagged", "invalid")})"],
       ["invalid", "Not valid (#{count.call("invalid")})"],
       ["ok", "Ok, no flags (#{count.call("ok")})"]] + flags.map { |f, n| ["flag:#{f}", "Flag #{f} (#{n})"] }
    end

    SORTS = [%w[input Input order], ["look", "Needs a look first"], %w[id Id], ["large", "Largest premises first"],
             ["small", "Smallest premises first"]].map { |key, *words| [key, words.join(" ")] }.freeze

    def select_options(options)
      options.map { |value, text| %(<option value="#{h(value)}">#{h(text)}</option>) }.join
    end

    def summary(states, total)
      "#{total} site(s): #{states.fetch("ok", 0)} ok, #{states.fetch("flagged", 0)} ok but flagged for a look, " \
        "#{states.fetch("invalid", 0)} without usable premises"
    end

    def card(result, id, index, buffer_m)
      status = result.ok? ? "" : %(<span class="bad">#{h(result.problem)}</span>)
      notes = result.explanation.map { |n| "<li>#{h(n)}</li>" }.join
      <<~HTML
        <section #{card_data(result, id, index)}><h2>#{h(id)} #{status}</h2>
        <svg viewBox="#{-VIEW_M} #{-VIEW_M} #{VIEW_M * 2} #{VIEW_M * 2}" role="img" aria-label="site #{h(id)}">#{shapes(result, buffer_m).join}</svg>
        <p>#{flag_tags(result.flags)}</p>#{facts(result)}<details><summary>How it was made</summary><ol>#{notes}</ol></details></section>
      HTML
    end

    # What the filter and sort read.
    def card_data(result, id, index)
      area = result.ring ? result.validation.metrics[:area_m2].to_f.round : -1
      %(data-index="#{index}" data-id="#{h(id)}" data-state="#{state(result)}" ) +
        %(data-flags="#{h(result.flags.join(" "))}" data-nflags="#{result.flags.size}" data-area="#{area}")
    end

    def flag_tags(flags)
      flags.map { |f| %(<span class="flag" title="#{h(FLAGS[f])}">#{h(f)}</span>) }.join(" ")
    end

    def shapes(result, buffer_m)
      parts = result.features ? map_shapes(result.features, result.building) : []
      grown = buffer_m && result.ring && result.buffered(buffer_m)
      parts << path(grown, result.pin, "buffer") if grown
      parts << path(result.ring, result.pin, "premises") if result.ring
      parts << path(result.store_ring, result.pin, "store") if result.store_ring
      parts.concat(access_marks(result))
      parts << %(<circle r="2.2" class="pin"><title>pin</title></circle>) << scale_bar
    end

    def access_marks(result)
      points = result.details ? result.details[:access_points] : []
      tip = "<title>driveway entrance</title>"
      Geometry.project(points, result.pin).map do |x, y|
        %(<circle cx="#{x.round(1)}" cy="#{(-y).round(1)}" r="3.5" class="access">#{tip}</circle>)
      end
    end

    def scale_bar
      x0 = -VIEW_M + 8
      y = VIEW_M - 8
      %(<g class="scale"><path d="M#{x0},#{y - 3} V#{y} H#{x0 + SCALE_BAR_M} V#{y - 3}"/>) +
        %(<text x="#{x0 + SCALE_BAR_M + 4}" y="#{y}">#{SCALE_BAR_M} m</text></g>)
    end

    def map_shapes(features, building_id)
      parts = in_view(features.parking).map { |p| xy_path(p.xy, "parking") }
      parts += building_shapes(features, building_id)
      parts += in_view(features.roads).map do |road|
        kind = Generator::PUBLIC_HIGHWAYS.include?(road.highway) ? "road" : "service"
        xy_path(road.xy, kind, close: false, title: [road.name, road.highway].compact.join(" "))
      end
      parts + in_view(features.railways).map { |r| xy_path(r.xy, "rail", close: false) }
    end

    # The building the premises were made from is drawn darker than its
    # neighbours.
    def building_shapes(features, building_id)
      in_view(features.buildings).map do |b|
        b.id == building_id ? xy_path(b.xy, "building site", title: "the site's building") : xy_path(b.xy, "building")
      end
    end

    def in_view(list)
      reach = VIEW_M * 1.5
      list.select { |f| f.xy.any? { |x, y| x.abs < reach && y.abs < reach } }
    end

    def facts(result)
      d = result.details
      return "" unless d

      items = []
      items << "building #{d[:building][:area_m2]} m²" if d[:building]
      items << "premises #{result.validation.metrics[:area_m2]&.round} m²" if result.ring
      items << "parking #{d[:parking_area_m2]} m² (about #{d[:parking_spaces_estimate]} spaces)"
      items << "street frontage #{d[:frontage_m]} m"
      items << "#{d[:access_points].size} driveway entrance(s)" if d[:access_points].any?
      %(<p class="facts">#{h(items.join(" · "))}</p>)
    end

    def path(ring, pin, css)
      xy_path(Geometry.open_ring(Geometry.project(ring, pin)), css)
    end

    # SVG y runs down; north is up.
    def xy_path(xy, css, close: true, title: nil)
      d = xy.map.with_index { |(x, y), i| "#{i.zero? ? "M" : "L"}#{x.round(1)},#{(-y).round(1)}" }.join(" ")
      d << " Z" if close
      tip = title && !title.empty? ? "<title>#{h(title)}</title>" : ""
      %(<path d="#{d}" class="#{css}">#{tip}</path>)
    end

    def h(text) = CGI.escapeHTML(text.to_s)

    def page(title, cards, toolbar, credits, buffer_m)
      <<~HTML
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>#{h(title)}</title><style>#{STYLE}</style></head><body>
        <h1>#{h(title)}</h1>#{toolbar}
        <p class="legend">#{legend(buffer_m)}</p>
        <p class="muted">Each map is #{VIEW_M * 2} m across, north up, drawn from the map data only (no imagery).
        Hover over a flag for what it means, or a road for its name. Map data: #{h(credits.join("; "))}.</p>
        <main>#{cards.join}</main><script>#{SCRIPT}</script></body></html>
      HTML
    end

    def legend(buffer_m)
      keys = [%w[premises premises], ["store", "store zone"], ["site", "the site's building"],
              ["building", "other buildings"], %w[parking parking], ["road", "public road"],
              ["service", "service road or driveway"], %w[rail railway], ["access", "driveway entrance"]]
      keys << ["buffer", "premises + #{format("%g", buffer_m)} m"] if buffer_m
      keys.map { |css, text| %(<span><i class="k-#{css}"></i>#{h(text)}</span>) }.join(" ")
    end

    SCRIPT = <<~JS
      (() => {
        const main = document.querySelector("main"), show = document.getElementById("show"),
              sort = document.getElementById("sort"), shown = document.getElementById("shown");
        const cards = [...main.children];
        const rank = { invalid: 0, flagged: 1, ok: 2 };
        const num = (c, k) => Number(c.dataset[k]);
        const order = {
          input: (a, b) => num(a, "index") - num(b, "index"),
          look: (a, b) => rank[a.dataset.state] - rank[b.dataset.state] || num(b, "nflags") - num(a, "nflags") ||
                          num(a, "index") - num(b, "index"),
          id: (a, b) => a.dataset.id.localeCompare(b.dataset.id, undefined, { numeric: true }),
          large: (a, b) => num(b, "area") - num(a, "area"),
          small: (a, b) => (num(a, "area") < 0) - (num(b, "area") < 0) || num(a, "area") - num(b, "area"),
        };
        const keep = (c) => {
          const v = show.value, s = c.dataset.state;
          if (v === "all") return true;
          if (v === "look") return s !== "ok";
          if (v.startsWith("flag:")) return c.dataset.flags.split(" ").includes(v.slice(5));
          return s === v;
        };
        const update = () => {
          let n = 0;
          [...cards].sort(order[sort.value]).forEach((c) => {
            c.hidden = !keep(c);
            n += !c.hidden;
            main.appendChild(c);
          });
          shown.textContent = `showing ${n} of ${cards.length}`;
          try { localStorage.setItem("curtilage-preview", JSON.stringify([show.value, sort.value])); } catch (e) {}
        };
        try {
          const saved = JSON.parse(localStorage.getItem("curtilage-preview") || "null");
          if (saved) {
            if ([...show.options].some((o) => o.value === saved[0])) show.value = saved[0];
            if ([...sort.options].some((o) => o.value === saved[1])) sort.value = saved[1];
          }
        } catch (e) {}
        show.onchange = sort.onchange = update;
        update();
      })();
    JS

    STYLE = <<~CSS
      :root { --bg: #fff; --fg: #222; --muted: #666; --card: #fafaf7; --line: #ddd; --building: #d6d1c8;
              --site: #9c9385; --parking: #e7e2f3; --road: #e05050; --premises: #1a9a4a; --store: #111;
              --access: #1565c0; }
      @media (prefers-color-scheme: dark) {
        :root { --bg: #161616; --fg: #e8e8e8; --muted: #aaa; --card: #202020; --line: #333; --building: #4a4741;
                --site: #8a8378; --parking: #3a3550; --road: #ff6b6b; --premises: #3ddc84; --store: #f2f2f2;
                --access: #64b5f6; } }
      body { font: 14px system-ui, sans-serif; margin: 16px; background: var(--bg); color: var(--fg); }
      h1 { font-size: 20px; margin-bottom: 4px; } h2 { font-size: 15px; margin: 0 0 6px; }
      main { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 340px), 1fr)); gap: 16px; }
      section { border: 1px solid var(--line); border-radius: 6px; padding: 8px; min-width: 0; }
      svg { width: 100%; background: var(--card); display: block; }
      .building { fill: var(--building); } .site { fill: var(--site); } .parking { fill: var(--parking); }
      .road { fill: none; stroke: var(--road); stroke-width: 2; }
      .service { fill: none; stroke: var(--road); stroke-width: 1; stroke-dasharray: 3 2; opacity: .6; }
      .rail { fill: none; stroke: var(--fg); stroke-width: 2; stroke-dasharray: 6 3; }
      .premises { fill: var(--premises); fill-opacity: .12; stroke: var(--premises); stroke-width: 2; }
      .buffer { fill: none; stroke: var(--premises); stroke-width: 1.2; stroke-dasharray: 4 3; }
      .store { fill: none; stroke: var(--store); stroke-width: 1.5; } .pin { fill: var(--fg); }
      .access { fill: var(--access); stroke: var(--card); stroke-width: 1; }
      .scale path { fill: none; stroke: var(--fg); stroke-width: 1.2; }
      .scale text { fill: var(--fg); font-size: 9px; dominant-baseline: middle; }
      .bad { color: #d33; font-weight: normal; font-size: 13px; }
      .flag { display: inline-block; background: #fff3d6; color: #8a5a00; border-radius: 4px; padding: 0 4px;
              font-size: 12px; cursor: help; }
      .facts, .muted, details { color: var(--muted); font-size: 13px; }
      .tools label { margin-right: 14px; white-space: nowrap; } .tools select { font: inherit; }
      #shown { color: var(--muted); } section[hidden] { display: none; }
      .legend span { margin-right: 14px; white-space: nowrap; display: inline-block; }
      .legend i { display: inline-block; width: 16px; height: 10px; margin-right: 4px; vertical-align: middle; }
      .k-premises { border: 2px solid var(--premises); } .k-store { border: 2px solid var(--store); }
      .k-site { background: var(--site); } .k-building { background: var(--building); }
      .k-parking { background: var(--parking); }
      .k-road { height: 0 !important; border-top: 2px solid var(--road); }
      .k-service { height: 0 !important; border-top: 1px dashed var(--road); }
      .k-rail { height: 0 !important; border-top: 2px dashed var(--fg); }
      .k-access { width: 9px !important; height: 9px !important; border-radius: 50%; background: var(--access); }
      .k-buffer { border: 1px dashed var(--premises); }
    CSS
  end
end
