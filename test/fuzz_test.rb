# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

# Property tests on random and degenerate input, in plain Ruby. A fixed seed
# keeps runs repeatable; FUZZ_SEED changes it and FUZZ_ITERATIONS runs more
# cases (e.g. FUZZ_ITERATIONS=5000 bundle exec rake test).
class FuzzTest < Minitest::Test
  include SyntheticScene

  F = Curtilage::Formats
  G = Curtilage::Geometry
  ITERATIONS = Integer(ENV.fetch("FUZZ_ITERATIONS", "150"))
  SEED = Integer(ENV.fetch("FUZZ_SEED", "20261123"))
  CSV_CHARS = ["a", "b", "1", "-", ".", ",", '"', "\n", "\r", " ", "=", "é", "\t"].freeze

  def setup
    @rng = Random.new(SEED)
  end

  # Runs the block ITERATIONS times; a case that hangs or raises something
  # unexpected fails with the case number, so it can be replayed.
  def cases
    ITERATIONS.times do |i|
      Timeout.timeout(5) { yield i }
    rescue Timeout::Error
      flunk "case #{i} (seed #{SEED}) took over 5 s"
    end
  end

  def text(chars, max)
    Array.new(@rng.rand(0..max)) { chars.sample(random: @rng) }.join
  end

  def test_csv_reader_returns_rows_or_refuses_cleanly
    cases do
      rows = F.parse_csv(text(CSV_CHARS, 60))

      assert(rows.all? { |row| row.all?(String) })
    rescue ArgumentError
      nil # a clear refusal is fine
    end
  end

  def test_csv_written_reads_back_the_same
    plain = CSV_CHARS - ["=", "-", "\t", "\r", " "]
    cases do
      rows = Array.new(@rng.rand(1..4)) { Array.new(@rng.rand(1..4)) { "x#{text(plain, 8)}" } }
      csv = rows.map { |row| row.map { |v| F.csv_field(v) }.join(",") }.join("\r\n")

      assert_equal rows, F.parse_csv(csv)
    end
  end

  def random_json(depth = 0)
    case @rng.rand(depth > 3 ? 4 : 6)
    when 0 then @rng.rand(-400.0..400.0)
    when 1 then text(%w[a 1 - . e x], 6)
    when 2 then [nil, true, false].sample(random: @rng)
    when 3 then @rng.rand(-10..10)
    when 4 then Array.new(@rng.rand(0..4)) { random_json(depth + 1) }
    else { "type" => %w[Feature FeatureCollection Point].sample(random: @rng), "geometry" => random_json(depth + 1),
           "features" => random_json(depth + 1), "coordinates" => random_json(depth + 1) }
    end
  end

  def test_geojson_reader_returns_checked_pins_or_refuses_cleanly
    cases do
      pins = F.parse_pins(JSON.generate(random_json), :geojson)

      assert(pins.all? { |p| F.pin?(p[:pin]) && p[:pin].all?(&:finite?) })
    rescue ArgumentError
      nil
    end
  end

  def test_map_data_parsing_never_raises
    cases do
      raw = Array.new(@rng.rand(0..6)) do
        { "feature" => %w[building parking road railway ml_building junk].sample(random: @rng),
          "id" => random_json(3), "highway" => random_json(3),
          "geometry" => { "type" => %w[Polygon MultiPolygon LineString MultiLineString Point].sample(random: @rng),
                          "coordinates" => random_json(1) } }
      end
      features = Curtilage::Features.new(PIN, raw)

      assert_operator features.dropped, :>=, 0
      Curtilage.generate(PIN, features)
    end
  end

  # Points in metres: often repeated, lined up or all in one place.
  def points
    n = @rng.rand(1..12)
    case @rng.rand(4)
    when 0 then Array.new(n) { [@rng.rand(-100.0..100.0), @rng.rand(-100.0..100.0)] }
    when 1 then Array.new(n) { |i| [i * 5.0, i * 2.5] } # collinear
    when 2 then Array.new(n) { [3.0, 4.0] } # one spot
    else
      base = Array.new(3) { [@rng.rand(-50.0..50.0), @rng.rand(-50.0..50.0)] }
      Array.new(n) { base.sample(random: @rng) } # repeats
    end
  end

  def finite?(xy)
    xy.flatten.all?(&:finite?)
  end

  def test_geometry_holds_up_on_degenerate_input
    cases do
      pts = points
      hull = G.convex_hull(pts)
      cleaned = G.clean(pts)

      assert finite?(hull) && finite?(cleaned)
      assert_operator G.area(hull), :>=, 0
      next if hull.size < 3

      assert(pts.all? { |p| G.contains?(hull, p) || G.distance_to_edges(hull, p) < 1e-6 })
      other = G.convex_hull(points)
      overlap = other.size >= 3 ? G.clip_convex(hull, other) : []

      assert_operator(overlap.size >= 3 ? G.area(overlap) : 0, :<=, G.area(hull) + 1e-6)
      simple = G.simplify(hull, 4)

      assert_operator simple.size, :<=, [hull.size, 4].max
      assert_operator G.area(simple), :<=, G.area(hull) + 1e-6
      grown = G.round_buffer(hull, 5)

      assert(hull.all? { |p| G.contains?(grown, p) || G.distance_to_edges(grown, p) < 1e-6 })
      assert finite?(G.clip_inside(hull, hull, 2))
      rect = G.minimum_rectangle(hull)

      assert_operator rect[:area], :>=, G.area(hull) - 1e-6 if rect
      G.self_intersects?(pts)
    end
  end

  def test_validation_never_raises
    cases do
      ring = Array.new(@rng.rand(0..8)) { [random_json(3), random_json(3)].sample(@rng.rand(0..2), random: @rng) }
      ring = Array.new(@rng.rand(0..8)) { [@rng.rand(-200.0..200.0), @rng.rand(-100.0..100.0)] } if @rng.rand(2).zero?
      result = Curtilage::Validation.check(PIN, ring)

      assert_kind_of Array, result.errors
    end
  end

  # The flat projection is weakest near the poles and the antimeridian:
  # generation must still finish, and anything it offers must be valid.
  def test_generation_near_the_antimeridian_and_poles
    [[179.9999, 0.0], [-179.9999, 10.0], [180.0, -45.0], [0.0, 89.99], [0.0, -89.99], [10.0, 90.0],
     [-10.0, -90.0]].each do |pin|
      sx = G.metres_per_degree_lng(pin[1])
      to = ->(x, y) { [pin[0] + (x / sx), pin[1] + (y / G::METRES_PER_DEGREE_LAT)] }
      ring = [[-10, -8], [10, -8], [10, 8], [-10, 8], [-10, -8]].map { |x, y| to.call(x, y) }
      raw = [{ "feature" => "building", "id" => 1, "geometry" => { "type" => "Polygon", "coordinates" => [ring] } }]
      result = Timeout.timeout(5) { Curtilage.generate(pin, raw) }

      next unless result.ok?

      assert(result.ring.flatten.all?(&:finite?), pin.inspect)
      assert Curtilage::Validation.check(pin, result.ring).ok?, pin.inspect
    end
  end
end
