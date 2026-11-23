# frozen_string_literal: true

module Curtilage
  # How the rules record what they did: each line of the explanation with
  # its structured step (Result#steps). Split from generator.rb only to keep
  # files a readable size.
  module Generator
    module_function

    # Whole square metres, for steps.
    def m2(xy) = xy && xy.size >= 3 ? Geometry.area(xy).round : 0

    # Each failed attempt first, in order, as a step of its own.
    def prepend_failures(result, failures)
      failures.reverse_each { |text, method| result.prepend_step(text, step: "fallback", rule: method.to_s) }
      result
    end

    # One step per road, however many of its stretches trimmed: a later
    # stretch updates the area after. rule: what set the distance (a fixed
    # road_offset_m, half the road's width by class, or a clearance that
    # kept the cut further from the centreline's other side).
    def note_trim(log, road, distances, polys, opts)
      used, offset = distances
      label = "trimmed at #{road_label(road)}, #{used.round} m short of its centreline"
      earlier = (log.steps || []).find { |s| s[:text] == label }
      return earlier[:area_after_m2] = m2(polys[1]) if earlier

      rule = if used < offset - 0.01 then "clearance"
             elsif opts[:road_offset_m] then "road_offset_m"
             else "road_class_half_width"
             end
      log.note(label, step: "trim_road", rule: rule, features: [road.id], distance_m: used.round(1),
                      area_before_m2: m2(polys[0]), area_after_m2: m2(polys[1]))
    end

    # home: :behind, :beside or false (not a home).
    def explain_cut(log, other, home, strip, **areas)
      step = { step: "split_neighbour", features: [other.id], rule: strip ? "neighbour_gap_m" : "halfway",
               distance_m: strip, **areas }
      case home
      when :behind
        log.flag(:near_houses, "the lot backs onto a home (building #{other.id}): split halfway, " \
                               "check where its yard starts", **step)
      when :beside
        log.flag(:near_houses, "the lot runs beside a home (building #{other.id}), stopping " \
                               "#{strip} m short of it: check the property line", **step)
      else
        log.note(strip ? "stopped #{strip} m short of building #{other.id}" : "split halfway to building #{other.id}",
                 **step)
      end
    end
  end
end
