# frozen_string_literal: true

require_relative "test_helper"
require "net/http"
require "stringio"

# curtilage serve: endpoints and every limit, on 127.0.0.1 with a stub in
# place of fetching map data (made-up pins).
class ServerTest < Minitest::Test
  include SyntheticScene

  TOKEN = "s3cret-token"

  def start(**options)
    raw = scene
    generate = options.delete(:generate) || ->(pins, opts) { pins.map { |p| Curtilage.generate(p, raw, **opts) } }
    @log = StringIO.new
    @server = Curtilage::Server.new(port: 0, log: @log, generate: generate, **options)
    ready = Queue.new
    @thread = Thread.new { @server.run { ready << true } }
    ready.pop
  end

  def teardown
    @server&.stop
    @thread&.join(2)
  end

  def http(method, path, body: nil, headers: {})
    Net::HTTP.start("127.0.0.1", @server.port, read_timeout: 10) do |h|
      request = Net::HTTP.const_get(method.capitalize).new(path, headers)
      request.body = body if body
      h.request(request)
    end
  end

  # The server logs a request after sending its response, so the log can
  # lag the reply: wait for the line rather than racing it.
  def log_after_request(pattern)
    100.times do
      break if @log.string.match?(pattern)

      sleep 0.02
    end
    @log.string
  end

  def pins_body(count = 1, options = {}) = JSON.generate(pins: Array.new(count) { PIN }, options: options)

  def test_health_version_and_premises
    start(token: TOKEN)
    auth = { "Authorization" => "Bearer #{TOKEN}" }

    assert_equal({ "status" => "ok" }, JSON.parse(http(:get, "/health").body)) # no token needed
    assert_equal Curtilage::VERSION, JSON.parse(http(:get, "/version", headers: auth).body)["gem"]
    response = http(:post, "/premises", body: pins_body(2), headers: auth.merge("Content-Type" => "application/json"))

    assert_equal "200", response.code
    assert_equal "application/geo+json", response["Content-Type"]
    premises = JSON.parse(response.body)["features"].select { |f| f["properties"]["role"] == "premises" }

    assert_equal(%w[1 2], premises.map { |f| f["properties"]["id"] })
    ndjson = http(:post, "/premises", body: pins_body, headers: auth.merge("Accept" => "application/x-ndjson"))

    assert_equal 1, ndjson.body.lines.size
  end

  def test_token_is_required_and_checked
    start(token: TOKEN)

    missing = http(:get, "/version")

    assert_equal "401", missing.code
    assert_equal "Bearer", missing["WWW-Authenticate"]
    assert_equal "401", http(:post, "/premises", body: pins_body, headers: { "Authorization" => "Bearer nope" }).code
  end

  def test_geojson_and_options_in_the_body
    start
    collection = JSON.generate(type: "FeatureCollection",
                               features: [{ type: "Feature", id: "a", geometry: { type: "Point", coordinates: PIN } }])

    assert_equal "200", http(:post, "/premises", body: collection).code
    tight = http(:post, "/premises", body: pins_body(1, { "preset" => "tight" }))

    assert_equal "building", JSON.parse(tight.body)["features"][0]["properties"]["method"]
  end

  def test_bad_input_is_refused_without_internals
    start(max_body_bytes: 2_000, max_pins: 3)
    {
      "{" => "400", pins_body(4) => "413", pins_body(1, { "parquet" => "/etc/passwd" }) => "400",
      pins_body(1, { "nope" => 1 }) => "400", JSON.generate(pins: [[200, 100]]) => "400",
      JSON.generate(pins: Array.new(200) { PIN }) => "413"
    }.each do |body, code|
      response = http(:post, "/premises", body: body)

      assert_equal code, response.code, body[0, 60]
      refute_match(/\.rb:\d|backtrace/, response.body)
    end
    assert_equal "404", http(:get, "/nope").code
    assert_equal "405", http(:get, "/premises").code
  end

  def test_content_length_is_required
    start
    socket = TCPSocket.new("127.0.0.1", @server.port)
    socket.write("POST /premises HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")

    assert_match(%r{\AHTTP/1.1 411}, socket.read)
  ensure
    socket&.close
  end

  # One deadline for the whole request: a client trickling a byte at a
  # time (each read well inside the limit) is still cut off.
  def test_a_trickled_request_times_out
    reader, writer = UNIXSocket.pair
    writer.write("GET /health HTTP/1.1\r\n")
    trickle = Thread.new { loop { writer.write("a") && sleep(0.05) } }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Curtilage::Server::Refused) { Curtilage::Server::Request.read(reader, 100, 0.3) }

    assert_equal 408, error.status
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
  ensure
    trickle&.kill
    [reader, writer].each { |s| s&.close }
  end

  def test_slow_generation_times_out
    start(timeout_s: 0.2, generate: ->(*) { sleep 2 })

    assert_equal "504", http(:post, "/premises", body: pins_body).code
  end

  def test_requests_beyond_the_concurrency_cap_are_turned_away
    gate = Queue.new
    start(max_concurrent: 1, generate: lambda { |*|
      gate.pop
      []
    })
    first = Thread.new { http(:post, "/premises", body: pins_body) }
    sleep 0.2

    assert_equal "503", http(:get, "/health").code
    gate << true
    first.join
  end

  def test_cors_only_when_configured
    start

    assert_nil http(:get, "/health")["Access-Control-Allow-Origin"]
    @server.stop
    @thread.join(2)
    start(cors_origin: "https://maps.example")

    assert_equal "https://maps.example", http(:get, "/health")["Access-Control-Allow-Origin"]
  end

  def test_pins_stay_out_of_the_log_unless_asked
    start
    http(:post, "/premises", body: pins_body)

    assert_match(%r{POST /premises 200}, log_after_request(%r{POST /premises 200}))
    refute_includes @log.string, PIN[0].to_s
    @server.stop
    @thread.join(2)
    start(log_pins: true)
    http(:post, "/premises", body: pins_body)

    assert_includes log_after_request(%r{POST /premises 200}), PIN[0].to_s
  end

  def test_binds_localhost_by_default_and_refuses_unknown_limits
    start

    assert_equal "127.0.0.1", @server.instance_variable_get(:@host)
    assert_raises(ArgumentError) { Curtilage::Server.new(max_everything: 1) }
  end

  def test_openapi_spec_lists_the_endpoints
    require "yaml"
    spec = YAML.safe_load_file(File.expand_path("../docs/openapi.yaml", __dir__))

    assert_equal %w[/health /premises /version], spec["paths"].keys.sort
  end
end
