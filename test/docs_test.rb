# frozen_string_literal: true

require_relative "test_helper"

# The flag list lives in Curtilage::FLAGS; the docs list it too. These keep
# them from drifting apart.
class DocsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def raised_flags
    Dir[File.join(ROOT, "lib/**/*.rb")].flat_map do |file|
      File.read(file).scan(/(?:log\.flag\(|flags << |flags\.unshift\():(\w+)/).flatten
    end.uniq.map(&:to_sym)
  end

  def test_every_flag_raised_is_described
    assert_empty raised_flags - Curtilage::FLAGS.keys
  end

  def test_docs_list_every_flag
    %w[README.md docs/reference.md].each do |doc|
      text = File.read(File.join(ROOT, doc))
      Curtilage::FLAGS.each_key { |flag| assert_includes text, "| `#{flag}` |", "#{doc} is missing #{flag}" }
    end
  end
end
