# frozen_string_literal: true

require_relative "test_helper"

# What ships in the gem: code and the user docs, never notes, tests, data,
# CI or Docker files.
class PackagingTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SHIPPED = [%r{\Alib/.+\.rb\z}, %r{\Asql/[^/]+\.sql\z}, %r{\Aexe/[^/]+\z},
             %r{\A(docs/reference|README|CHANGELOG|SECURITY)\.md\z}, /\ALICENSE\.txt\z/].freeze

  def files
    Dir.chdir(ROOT) { Gem::Specification.load("curtilage.gemspec").files }
  end

  def test_only_code_and_user_docs_ship
    unexpected = files.reject { |f| SHIPPED.any? { |pattern| f.match?(pattern) } }

    assert_empty unexpected
  end

  def test_the_essentials_ship
    %w[lib/curtilage.rb exe/curtilage sql/build_from_shapefiles.sql docs/reference.md LICENSE.txt].each do |f|
      assert_includes files, f
    end
  end
end
