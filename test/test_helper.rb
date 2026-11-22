# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "curtilage"
require "minitest/autorun"

# Swaps a module method for impl while the block runs, then puts it back,
# visibility included, without Ruby's method-redefined warnings.
def with_stub(mod, name, impl)
  host = mod.singleton_class
  original = host.instance_method(name)
  hidden = host.private_method_defined?(name)
  host.send(:remove_method, name)
  host.send(:define_method, name, impl)
  yield
ensure
  host.send(:remove_method, name)
  host.send(:define_method, name, original)
  host.send(:private, name) if hidden
end

# Synthetic scene: a 20 x 15 m building at a made-up pin, a public road 40 m
# south, a neighbour 50 m east and a parking lot west of the building.
module SyntheticScene
  PIN = [-80.0, 35.0].freeze

  def lnglat(x, y)
    sx = Curtilage::Geometry.metres_per_degree_lng(PIN[1])
    [PIN[0] + (x / sx), PIN[1] + (y / Curtilage::Geometry::METRES_PER_DEGREE_LAT)]
  end

  def polygon(kind, id, x0, y0, x1, y1, type: nil)
    ring = [[x0, y0], [x1, y0], [x1, y1], [x0, y1], [x0, y0]].map { |x, y| lnglat(x, y) }
    { "feature" => kind, "id" => id, "highway" => type,
      "geometry" => { "type" => "Polygon", "coordinates" => [ring] } }
  end

  def road(id, highway, points)
    { "feature" => "road", "id" => id, "highway" => highway,
      "geometry" => { "type" => "LineString", "coordinates" => points.map { |x, y| lnglat(x, y) } } }
  end

  def scene
    [
      polygon("building", 1, -10, -7.5, 10, 7.5),
      polygon("building", 2, 50, -10, 70, 10),
      polygon("parking", 3, -45, -20, -11, 20),
      road(4, "secondary", [[-200, -40], [200, -40]]),
    ]
  end

  def xy(result)
    Curtilage::Geometry.open_ring(Curtilage::Geometry.project(result.ring, PIN))
  end
end
