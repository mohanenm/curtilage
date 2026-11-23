# frozen_string_literal: true

require "json"

module Curtilage
  # Two runs compared site by site (curtilage diff OLD NEW), to refresh
  # results as the map changes without reviewing everything again: only
  # sites whose premises changed beyond a threshold need a look.
  module Diff
    # Below this IoU between old and new premises, a site needs review.
    REVIEW_IOU = 0.9
    COLUMNS = %w[id status review iou area_old_m2 area_new_m2 area_change_pct ok_old ok_new
                 flags_gained flags_lost confidence_old confidence_new].freeze

    module_function

    # Rows, by id, for results read with Formats.read_results. status:
    # same, changed, added or removed. review: true when a site was added
    # or removed, gained or lost premises, changed ok, gained a flag, or
    # its premises overlap the old ones less than threshold (IoU).
    def compare(old, new, threshold: REVIEW_IOU)
      unless threshold.is_a?(Numeric) && threshold.between?(0, 1)
        raise ArgumentError, "threshold is 0 to 1: #{threshold.inspect}"
      end

      (old.keys | new.keys).sort.map { |id| row(id, old[id], new[id], threshold) }
    end

    def row(id, before, after, threshold)
      return { id: id, status: before ? "removed" : "added", review: true } unless before && after

      a = props(before)
      b = props(after)
      iou, area_a, area_b = overlap(before[:ring], after[:ring])
      same = before[:ring] == after[:ring] && a == b
      { id: id, status: same ? "same" : "changed", review: !same && review?(a, b, iou, threshold),
        iou: iou&.round(3), area_old_m2: area_a, area_new_m2: area_b, area_change_pct: change(area_a, area_b),
        ok_old: a[:ok], ok_new: b[:ok], flags_gained: b[:flags] - a[:flags], flags_lost: a[:flags] - b[:flags],
        confidence_old: a[:confidence], confidence_new: b[:confidence] }
    end

    def review?(before, after, iou, threshold)
      (after[:flags] - before[:flags]).any? || before[:ok] != after[:ok] || iou.nil? || iou < threshold
    end

    def change(before, after)
      before&.positive? && after ? ((after - before) * 100.0 / before).round(1) : nil
    end

    def props(entry)
      p = entry[:properties]
      { ok: p["ok"], flags: Array(p["flags"]).map(&:to_s), confidence: p["confidence"] }
    end

    # [IoU, old area, new area] in square metres, or [nil, ...] when either
    # ring is missing or not a usable shape. Premises are convex; a manual
    # one that isn't is compared by its convex outline.
    def overlap(ring_a, ring_b)
      origin = (ring_a || ring_b)&.first
      return [nil, nil, nil] unless origin.is_a?(Array) && Geometry.valid_coordinates?([origin])

      a, b = [ring_a, ring_b].map { |r| usable_xy(r, origin) }
      areas = [a, b].map { |xy| xy && Geometry.area(xy).round }
      return [nil, *areas] unless a && b

      inter = Geometry.clip_convex(a, Geometry.counter_clockwise(Geometry.convex_hull(b)))
      shared = inter.size >= 3 ? Geometry.area(inter) : 0
      [shared / (Geometry.area(a) + Geometry.area(b) - shared), *areas]
    end

    # The ring in metres around origin, or nil if it isn't a usable shape.
    def usable_xy(ring, origin)
      return nil unless ring && Validation.shape_errors(origin, ring).empty?

      Geometry.counter_clockwise(Geometry.open_ring(Geometry.project(ring, origin)))
    end

    # The rows as :csv (flags ;-separated) or :ndjson.
    def write(rows, format)
      case format.to_sym
      when :csv
        Formats.csv_text([COLUMNS] + rows.map { |r| COLUMNS.map { |c| cell(r[c.to_sym]) } })
      when :ndjson then rows.map { |r| "#{JSON.generate(r)}\n" }.join
      else raise ArgumentError, "unknown diff format #{format.inspect} (have: csv, ndjson)"
      end
    end

    def cell(value) = value.is_a?(Array) ? value.join(";") : value
  end
end
