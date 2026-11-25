# frozen_string_literal: true

require "json"

# The corrections log (corrections.csv): one row per label change, with why,
# what was checked, whether the review sample was looked at, and whether the
# change raised or lowered the score under the default and core views (as
# scored by the current rules: a wrong point that becomes right or stops
# counting raises it; a right one that becomes wrong or stops counting
# lowers it). Held-out labels never change, so they never appear here.
module CurtilageBenchmark
  CORRECTION_COLUMNS = %w[date commit site role point old_kind new_kind reason checked sample_reviewed
                          default_effect core_effect].freeze

  module_function

  def corrections_file = File.join(DIR, "corrections.csv")

  # [[point, old kind or nil, new kind or nil]] between two label documents,
  # matching points by exact coordinates (nil: added or deleted).
  def label_diffs(old_doc, new_doc)
    before = kinds_by_point(old_doc)
    after = kinds_by_point(new_doc)
    (before.keys | after.keys).filter_map do |point|
      [point, before[point], after[point]] unless before[point] == after[point]
    end
  end

  def kinds_by_point(doc)
    doc.fetch("features", []).to_h { |f| [f.dig("geometry", "coordinates"), f.dig("properties", "kind")] }
  end

  # true when a view counts the kind as in, false as out, nil when ignored.
  def wanted(view, kind)
    return true if view["in"].include?(kind)

    view["out"].include?(kind) ? false : nil
  end

  # :raised, :lowered or :none for one change ([point, old kind, new kind])
  # under a view, given the site's premises in metres (xy, or nil for no
  # premises).
  def correction_effect(view, xy, pin, change)
    point, old_kind, new_kind = change
    inside = !xy.nil? && G.contains?(xy, G.project([point], pin).first)
    right = ->(kind) { (want = kind && wanted(view, kind)).nil? ? nil : want == inside }
    before = right.call(old_kind)
    after = right.call(new_kind)
    return :none if before == after
    return :raised if before == false # a wrong point became right or stopped counting
    return :lowered if before == true

    after ? :raised : :lowered
  end

  # Every field quoted (points start with "-"), read back with the gem's
  # strict RFC 4180 reader: no csv gem needed.
  def write_corrections(rows, file = corrections_file)
    line = ->(fields) { fields.map { |v| "\"#{v.to_s.gsub('"', '""')}\"" }.join(",") }
    File.write(file, "#{([line.call(CORRECTION_COLUMNS)] + rows.map { |r| line.call(r) }).join("\n")}\n")
  end

  def append_corrections(rows, file = corrections_file)
    write_corrections(read_corrections(file).map { |r| r.values_at(*CORRECTION_COLUMNS) } + rows, file)
  end

  def read_corrections(file = corrections_file)
    return [] unless File.file?(file)

    head, *rows = Curtilage::Formats.parse_csv(File.read(file, encoding: "utf-8"))
    rows.map { |r| head.zip(r).to_h }
  end
end
