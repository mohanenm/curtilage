# frozen_string_literal: true

module Curtilage
  # Every error the gem raises on purpose is one of these (input mistakes
  # are ArgumentError).
  class Error < StandardError; end
end
