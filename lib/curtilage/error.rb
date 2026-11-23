# frozen_string_literal: true

module Curtilage
  # Every error the gem raises on purpose is one of these (input mistakes
  # are ArgumentError).
  class Error < StandardError; end

  # DuckDB or one of its extensions is missing (the command line exits 3).
  class DependencyError < Error; end
end
