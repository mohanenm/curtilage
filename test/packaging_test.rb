# frozen_string_literal: true

require_relative "test_helper"

# What ships in the gem: code and the user docs, never notes, tests, data,
# CI or Docker files.
class PackagingTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SHIPPED = [%r{\Alib/.+\.rb\z}, %r{\Asql/[^/]+\.sql\z}, %r{\Aexe/[^/]+\z}, %r{\Adocs/schema/[^/]+\.json\z},
             %r{\A(docs/reference|docs/security|README|CHANGELOG|SECURITY)\.md\z}, /\ALICENSE\.txt\z/,
             %r{\Adocs/openapi\.yaml\z}].freeze

  def files
    Dir.chdir(ROOT) { Gem::Specification.load("curtilage.gemspec").files }
  end

  def test_only_code_and_user_docs_ship
    unexpected = files.reject { |f| SHIPPED.any? { |pattern| f.match?(pattern) } }

    assert_empty unexpected
  end

  def test_the_essentials_ship
    %w[lib/curtilage.rb exe/curtilage sql/build_from_shapefiles.sql docs/reference.md docs/security.md
       docs/schema/site-v1.json LICENSE.txt].each do |f|
      assert_includes files, f
    end
  end

  # The Docker build stage copies files in by path: every file the gem
  # ships must be under something it copies, or gem build fails there.
  def test_the_docker_build_copies_everything_the_gem_ships
    dockerfile = File.read(File.join(ROOT, "Dockerfile"))
    copied = dockerfile.scan(/^COPY (?!--from)(.+)$/).flat_map { |(args)| args.split[0...-1] }
    missing = files.reject { |f| copied.any? { |c| f == c || f.start_with?("#{c.chomp("/")}/") } }

    assert_empty missing
  end
end
