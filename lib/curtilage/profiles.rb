# frozen_string_literal: true

require "json"
require "psych"

module Curtilage
  # Your own named styles, from a JSON or YAML file: each profile is a set
  # of generation options, optionally starting from a built-in preset.
  #
  #   # profiles.yml
  #   big_box:
  #     preset: whole_lot
  #     parking_max_extent_m: 150
  #     validation: { max_area_error_m2: 300000 }
  #
  #   options = Curtilage::Profiles.load("profiles.yml")[:big_box]
  #   Curtilage.generate_many(pins, **options)
  module Profiles
    MAX_BYTES = 1_000_000
    MAX_PROFILES = 100
    # Options whose values are names, given as text in the file.
    NAMES = %i[method scope buildings preset].freeze

    module_function

    # { name => options } from path (.json, .yml or .yaml). Every profile
    # is checked like generate's options, so a mistake fails here, naming it.
    def load(path)
      raise ArgumentError, "#{path} is over #{MAX_BYTES / 1000} KB" if File.size(path) > MAX_BYTES

      text = File.read(path, encoding: "bom|utf-8")
      parse(text, File.extname(path).downcase == ".json" ? :json : :yaml)
    rescue SystemCallError => e
      raise ArgumentError, "can't read profiles: #{e.message}"
    end

    def parse(text, format)
      doc = format == :json ? JSON.parse(text, max_nesting: 10) : Psych.safe_load(text)
      raise ArgumentError, "profiles are a map of name => options" unless doc.is_a?(Hash) && doc.values.all?(Hash)
      raise ArgumentError, "more than #{MAX_PROFILES} profiles" if doc.size > MAX_PROFILES

      doc.to_h { |name, options| [name.to_s.to_sym, profile(name, options)] }
    rescue JSON::ParserError, Psych::Exception => e
      raise ArgumentError, "unreadable profiles: #{e.message[0, 200]}"
    end

    def profile(name, options)
      opts = options.to_h { |k, v| [k.to_s.to_sym, value(k.to_s.to_sym, v)] }
      Curtilage.send(:check_generation_options, opts)
      opts
    rescue ArgumentError => e
      raise ArgumentError, "profile #{name}: #{e.message}"
    end

    def value(key, value)
      return value.to_s.to_sym if NAMES.include?(key) && value.is_a?(String)
      return value.to_h { |k, v| [k.to_s.to_sym, v] } if key == :validation && value.is_a?(Hash)

      value
    end
  end
end
