# frozen_string_literal: true

require_relative "test_helper"

class FootprintsTest < Minitest::Test
  F = Curtilage::Footprints

  # Bing Maps' documented example: tile (3, 5) at level 3 is "213".
  def test_quadkey
    assert_equal "213", F.quadkey(3, 5, 3)
  end

  def test_quadkeys_cover_the_box
    keys = F.quadkeys([-80.01, 34.99, -79.99, 35.01], 9)

    refute_empty keys
    assert(keys.all? { |k| k.size == 9 && k.match?(/\A[0-3]+\z/) })
  end

  def test_index_keeps_only_footprint_urls_on_microsofts_host
    csv = <<~CSV
      Location,QuadKey,Url,Size,UploadDate
      UnitedStates,021230030,https://minedbuildings.z5.web.core.windows.net/global-buildings/x/part-1.csv.gz,1MB,2026-01-01
      UnitedStates,021230031,https://example.com/global-buildings/x/part-2.csv.gz,1MB,2026-01-01
      UnitedStates,021230032,http://minedbuildings.z5.web.core.windows.net/global-buildings/x/part-3.csv.gz,1MB,2026-01-01
      UnitedStates,021230033,https://minedbuildings.z5.web.core.windows.net/global-buildings/../etc,1MB,2026-01-01
      Bad Name,021230034,https://minedbuildings.z5.web.core.windows.net/global-buildings/x/part-4.csv.gz,1MB,2026-01-01
    CSV
    rows = F.parse_index(csv)

    assert_equal([%w[UnitedStates 021230030]], rows.map { |r| [r[:location], r[:quadkey]] })
  end
end
