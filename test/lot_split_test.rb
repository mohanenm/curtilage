# frozen_string_literal: true

require_relative "test_helper"

# lot_split: :voronoi (a shared lot split by nearest building), made-up.
class LotSplitTest < Minitest::Test
  include SyntheticScene

  G = Curtilage::Geometry

  # A row of four shops along the north edge of one big shared lot; the
  # site is the second from the west.
  def centre
    [
      polygon("building", 1, -10, 10, 10, 30),
      polygon("building", 2, -50, 10, -30, 30),
      polygon("building", 3, 30, 10, 60, 30),
      polygon("building", 4, 80, 10, 100, 30),
      polygon("parking", 5, -60, -60, 110, 8),
      road(6, "secondary", [[-200, -75], [300, -75]]),
    ]
  end

  def test_voronoi_claims_the_part_nearer_the_site
    result = Curtilage.generate(PIN, centre, lot_split: :voronoi)
    ring = xy(result)

    assert result.ok?, result.validation.errors.inspect
    assert G.contains?(ring, [0, -40]) # in front of the site, well out into the lot
    refute G.contains?(ring, [-45, -10]) # in front of the shop to the west
    refute G.contains?(ring, [45, -10]) # in front of the shop to the east
    assert(result.steps.any? { |s| s[:rule] == "lot_split" })
  end

  def test_square_is_the_default_and_unknown_values_are_refused
    assert_equal Curtilage.generate(PIN, centre).ring, Curtilage.generate(PIN, centre, lot_split: :square).ring
    assert_raises(ArgumentError) { Curtilage.generate(PIN, centre, lot_split: :hex) }
  end

  def test_grid_keeps_cells_nearer_one_polygon
    grid = Curtilage::Grid.new([0, 0, 40, 10], 0.5).paint([[0, 0], [40, 0], [40, 10], [0, 10]])
    grid.keep_nearer([[0, 0], [2, 0], [2, 10], [0, 10]], [[[30, 0], [40, 0], [40, 10], [30, 10]]])

    assert grid.on?([10, 5])
    refute grid.on?([20, 5])
    assert_in_delta 16, G.bounds(grid.hull)[2], 0.5 # halfway between the two edges
  end
end
