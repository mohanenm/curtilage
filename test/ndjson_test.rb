# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"

class NdjsonTest < Minitest::Test
  include SyntheticScene

  F = Curtilage::Formats
  SCHEMA = JSON.parse(File.read(File.expand_path("../docs/schema/site-v1.json", __dir__)))
  TYPES = { "object" => Hash, "array" => Array, "string" => String, "boolean" => [TrueClass, FalseClass],
            "number" => Numeric, "null" => NilClass }.freeze

  # Enough of JSON Schema for this one file (type, const, enum, required,
  # properties, items, oneOf, $ref, pattern): problems as "path: what".
  def problems(value, schema, path = "$")
    schema = SCHEMA.dig("$defs", schema["$ref"].split("/").last) if schema["$ref"]
    if schema["oneOf"]
      return schema["oneOf"].any? { |s| problems(value, s, path).empty? } ? [] : ["#{path}: matches no oneOf"]
    end

    own(value, schema, path) + nested(value, schema, path)
  end

  def own(value, schema, path)
    types = Array(schema["type"])
    [("#{path}: not #{types.join("/")}" if types.any? && types.none? { |t| type?(value, t) }),
     ("#{path}: not #{schema["const"]}" if schema.key?("const") && value != schema["const"]),
     ("#{path}: #{value.inspect} not in enum" if schema["enum"] && !schema["enum"].include?(value)),
     ("#{path}: doesn't match" if schema["pattern"] && value.is_a?(String) && !value.match?(schema["pattern"]))].compact
  end

  def type?(value, name)
    Array(TYPES.fetch(name)).any? { |type| value.is_a?(type) }
  end

  def nested(value, schema, path)
    if value.is_a?(Hash)
      missing = (schema["required"] || []) - value.keys
      missing.map { |k| "#{path}.#{k}: missing" } +
        (schema["properties"] || {}).flat_map { |k, s| value.key?(k) ? problems(value[k], s, "#{path}.#{k}") : [] }
    elsif value.is_a?(Array) && schema["items"]
      value.each_with_index.flat_map { |v, i| problems(v, schema["items"], "#{path}[#{i}]") }
    else
      []
    end
  end

  def results
    error = Curtilage.send(:generate_safely, PIN, :not_features, { grow_m: -1 })
    [Curtilage.generate(PIN, scene), Curtilage.generate([-80.01, 35.01], scene), error]
  end

  def test_one_feature_per_line_matching_the_schema
    lines = F.write(results, :ndjson, ids: %w[a b c]).lines

    assert_equal 3, lines.size
    lines.each do |line|
      assert_empty problems(JSON.parse(line), SCHEMA), line[0, 200]
    end
    first = JSON.parse(lines[0])

    assert_equal "a", first["properties"]["id"]
    assert_equal "Polygon", first["properties"]["store"]["type"]
    assert_nil JSON.parse(lines[1])["geometry"]
  end

  def test_the_checker_catches_a_broken_line
    line = JSON.parse(F.write(results.first(1), :ndjson).lines.first)
    line["properties"].delete("ok")
    line["properties"]["flags"] = "x"

    assert_equal ["$.properties.ok: missing", "$.properties.flags: not array"], problems(line, SCHEMA)
  end

  def test_without_the_store_zone
    refute JSON.parse(F.write(results.first(1), :ndjson, store: false))["properties"].key?("store")
  end

  def test_reads_each_line_style
    text = <<~NDJSON
      {"id":"a","lng":-80,"lat":35}

      {"site_id":7,"pin":[-80.1,35.1]}
      {"type":"Feature","id":"c","geometry":{"type":"Point","coordinates":[-80.2,35.2]}}
      {"longitude":"-80.3","latitude":"35.3"}
    NDJSON

    assert_equal [{ id: "a", pin: [-80.0, 35.0] }, { id: "7", pin: [-80.1, 35.1] }, { id: "c", pin: [-80.2, 35.2] },
                  { id: "4", pin: [-80.3, 35.3] }], F.parse_pins(text, :ndjson)
    assert_equal :ndjson, F.format_of("x.jsonl")
  end

  def test_bad_lines_are_named
    { "[1,2]\n" => "line 1 isn't a JSON object", "{\"id\":1}\n" => "line 1 needs pin",
      "{}\n{nope\n" => "line 1 needs pin", "{\"lng\":1,\"lat\":2}\n{nope\n" => "line 2 isn't valid JSON",
      "{\"pin\":[\"0x1A\",2]}\n" => "isn't a number" }.each do |text, message|
      error = assert_raises(ArgumentError) { F.parse_pins(text, :ndjson) }

      assert_includes error.message, message
    end
  end

  def test_the_cli_reads_standard_input
    exe = File.expand_path("../exe/curtilage", __dir__)
    lib = File.expand_path("../lib", __dir__)
    _, err, status = Open3.capture3("ruby", "-I", lib, exe, "generate", "--in", "-",
                                    stdin_data: "{\"id\":\"x\",\"lng\":-80,\"lat\":95}\n")

    refute_predicate status, :success?
    assert_includes err, "x: a pin is LNG,LAT"
  end
end
