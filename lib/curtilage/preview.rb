# frozen_string_literal: true

require "cgi"

module Curtilage
  # A self-contained HTML page for checking results by eye: one map per
  # site, drawn from the map data the premises were made from (buildings,
  # parking, roads, railways) with the premises and store zone on top.
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

    module_function

    # ids: one label per result (default 1, 2, ...). Results without
    # features (generate_many without keep_features: true) show only the
    # premises and store zone.
    def html(results, ids: nil, title: "curtilage preview")
      ids ||= (1..results.size).map(&:to_s)
      cards = results.zip(ids).map { |result, id| card(result, id) }
      credits = results.flat_map { |r| r.attribution || Result::OSM_ATTRIBUTION }.uniq
      page(title, cards, credits)
    end

    def card(result, id)
      status = result.ok? ? "" : %(<span class="bad">not valid: #{h(result.validation.errors.join(", "))}</span>)
      flags = result.flags.map { |f| %(<span class="flag">#{h(f)}</span>) }.join(" ")
      notes = result.explanation.map { |n| "<li>#{h(n)}</li>" }.join
      <<~HTML
        <section><h2>#{h(id)} #{status}</h2>
        <svg viewBox="#{-VIEW_M} #{-VIEW_M} #{VIEW_M * 2} #{VIEW_M * 2}" role="img" aria-label="site #{h(id)}">#{shapes(result).join}</svg>
        <p>#{flags}</p>#{facts(result)}<details><summary>How it was made</summary><ol>#{notes}</ol></details></section>
      HTML
    end

    def shapes(result)
      parts = result.features ? map_shapes(result.features) : []
      parts << path(result.ring, result.pin, "premises") if result.ring
      parts << path(result.store_ring, result.pin, "store") if result.store_ring
      parts << %(<circle r="2" class="pin"/>)
    end

    def map_shapes(features)
      parts = in_view(features.parking).map { |p| xy_path(p.xy, "parking") }
      parts += in_view(features.buildings).map { |b| xy_path(b.xy, "building") }
      parts += in_view(features.roads).map do |road|
        kind = Generator::PUBLIC_HIGHWAYS.include?(road.highway) ? "road" : "service"
        xy_path(road.xy, kind, close: false, title: [road.name, road.highway].compact.join(" "))
      end
      parts + in_view(features.railways).map { |r| xy_path(r.xy, "rail", close: false) }
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
      items << "parking #{d[:parking_area_m2]} m² (about #{d[:parking_spaces_estimate]} spaces)"
      items << "street frontage #{d[:frontage_m]} m"
      items << "#{d[:access_points].size} driveway(s) to the street" if d[:access_points].any?
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

    def page(title, cards, credits)
      <<~HTML
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>#{h(title)}</title><style>#{STYLE}</style></head><body>
        <h1>#{h(title)}</h1>
        <p class="legend"><span><i class="k-premises"></i>premises</span><span><i class="k-store"></i>store zone</span>
        <span><i class="k-building"></i>building</span><span><i class="k-parking"></i>parking</span>
        <span><i class="k-road"></i>public road</span><span><i class="k-service"></i>service road</span>
        <span><i class="k-rail"></i>railway</span></p>
        <p class="muted">Each map is #{VIEW_M * 2} m across, north up, drawn from the map data only (no imagery).
        Map data: #{h(credits.join("; "))}.</p>
        <main>#{cards.join}</main></body></html>
      HTML
    end

    STYLE = <<~CSS
      :root { --bg: #fff; --fg: #222; --muted: #666; --card: #fafaf7; --line: #ddd; --building: #c9c4bb;
              --parking: #e7e2f3; --road: #e05050; --premises: #1a9a4a; --store: #111; }
      @media (prefers-color-scheme: dark) {
        :root { --bg: #161616; --fg: #e8e8e8; --muted: #aaa; --card: #202020; --line: #333; --building: #5a564f;
                --parking: #3a3550; --road: #ff6b6b; --premises: #3ddc84; --store: #f2f2f2; } }
      body { font: 14px system-ui, sans-serif; margin: 16px; background: var(--bg); color: var(--fg); }
      h1 { font-size: 20px; } h2 { font-size: 15px; margin: 0 0 6px; }
      main { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 340px), 1fr)); gap: 16px; }
      section { border: 1px solid var(--line); border-radius: 6px; padding: 8px; min-width: 0; }
      svg { width: 100%; background: var(--card); display: block; }
      .building { fill: var(--building); } .parking { fill: var(--parking); }
      .road { fill: none; stroke: var(--road); stroke-width: 2; }
      .service { fill: none; stroke: var(--road); stroke-width: 1; stroke-dasharray: 3 2; opacity: .6; }
      .rail { fill: none; stroke: var(--fg); stroke-width: 2; stroke-dasharray: 6 3; }
      .premises { fill: var(--premises); fill-opacity: .12; stroke: var(--premises); stroke-width: 2; }
      .store { fill: none; stroke: var(--store); stroke-width: 1.5; } .pin { fill: var(--fg); }
      .bad { color: #d33; font-weight: normal; font-size: 13px; }
      .flag { display: inline-block; background: #fff3d6; color: #8a5a00; border-radius: 4px; padding: 0 4px; font-size: 12px; }
      .facts, .muted, details { color: var(--muted); font-size: 13px; }
      .legend span { margin-right: 14px; white-space: nowrap; }
      .legend i { display: inline-block; width: 16px; height: 10px; margin-right: 4px; vertical-align: middle; }
      .k-premises { border: 2px solid var(--premises); } .k-store { border: 2px solid var(--store); }
      .k-building { background: var(--building); } .k-parking { background: var(--parking); }
      .k-road { height: 0 !important; border-top: 2px solid var(--road); }
      .k-service { height: 0 !important; border-top: 1px dashed var(--road); }
      .k-rail { height: 0 !important; border-top: 2px dashed var(--fg); }
    CSS
  end
end
