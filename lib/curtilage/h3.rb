# frozen_string_literal: true

require "json"

module Curtilage
  # H3 cells (the hexagon grid) covering each result's premises, at a
  # resolution from 0 to 15, through DuckDB's community h3 extension. It's
  # installed only when this is used, from DuckDB's community repository
  # (built and signed by DuckDB from third-party code), so no other path
  # loads it; with CURTILAGE_OFFLINE it must be installed already. The cover
  # is "overlap": every cell the premises touch, so even a small site gets
  # at least one.
  module H3
    RESOLUTIONS = (0..15)
    BATCH = 500

    module_function

    # Sets result.h3 = { resolution:, cells: [...] } on each result with
    # premises; returns the results. options: duckdb, extension_directory.
    def cover(results, resolution, **options)
      unless resolution.is_a?(Integer) && RESOLUTIONS.cover?(resolution)
        raise ArgumentError, "an H3 resolution is a whole number from 0 to 15: #{resolution.inspect}"
      end

      options = Curtilage.duckdb_options(options)
      results.each_index.select { |i| results[i].ring }.each_slice(BATCH) do |batch|
        cells(batch.map { |i| results[i].to_wkt }, resolution, options).each_with_index do |list, k|
          results[batch[k]].h3 = { resolution: resolution, cells: list }
        end
      end
      results
    end

    # One list of cell ids per WKT polygon, in order.
    def cells(wkts, resolution, options)
      duckdb = options.fetch(:duckdb, "duckdb")
      out, err, status = DuckDB.capture(duckdb, sql(wkts, resolution, options), "-json",
                                        timeout: options.fetch(:timeout, Curtilage.config.duckdb_timeout))
      raise unavailable(duckdb) if !status.success? && err.match?(/download extension|h3\.duckdb_extension.*not found/i)
      raise Error, "H3 cover failed: #{DuckDB.clean(err).strip[0, 300]}" unless status.success?

      rows = out.strip.empty? ? [] : JSON.parse(out)
      rows.sort_by { |r| r["i"] }.map { |r| r["cells"].is_a?(String) ? JSON.parse(r["cells"]) : Array(r["cells"]) }
    end

    def sql(wkts, resolution, options)
      rows = wkts.each_with_index.map { |wkt, i| "(#{i}, #{DuckDB.quote(wkt)})" }
      [(DuckDB.extension_sql(options[:extension_directory], options[:duckdb]) if options[:extension_directory]),
       ("INSTALL h3 FROM community;" unless Curtilage.offline?), "LOAD h3;",
       # As JSON text: DuckDB 1.4 prints a list in -json output as a string, 2.0 as an array.
       "SELECT i, to_json(h3_polygon_wkt_to_cells_experimental_string(wkt, #{Integer(resolution)}, 'overlap'))" \
       "::VARCHAR AS cells " \
       "FROM (VALUES #{rows.join(", ")}) t(i, wkt);"].compact.join("\n")
    end

    def unavailable(duckdb)
      which = DuckDB.version(duckdb) || "this DuckDB"
      DependencyError.new("DuckDB's community h3 extension isn't available for #{which} " \
                          "on this platform (it's published for DuckDB 1.4 LTS; newer releases can lag): " \
                          "use DuckDB 1.4, or leave out H3")
    end
  end
end
