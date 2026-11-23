# frozen_string_literal: true

require "json"
require "openssl"
require "socket"
require "timeout"

module Curtilage
  # curtilage serve: a small HTTP/1.1 server on the standard library (no
  # server gem), one connection per request.
  #
  #   GET  /health    {"status":"ok"}
  #   GET  /version   gem, DuckDB and data source
  #   POST /premises  pins in, premises out (docs/openapi.yaml)
  #
  # Safe by default: it binds 127.0.0.1 unless told otherwise; with a token
  # every request but /health needs "Authorization: Bearer TOKEN" (compared
  # in constant time); bodies, pins, time and concurrent requests are
  # capped; no CORS headers unless an origin is given; errors never carry a
  # stack trace; pins are never logged unless log_pins. Put it behind a
  # reverse proxy for TLS.
  class Server
    LIMITS = { max_body_bytes: 1_000_000, max_pins: 100, timeout_s: 120, max_concurrent: 4 }.freeze
    MAX_HEADER_BYTES = 16_384
    READ_TIMEOUT_S = 10
    # What a request may set: generation options only. Where data comes
    # from (files, buckets, sources) is fixed when the server starts.
    REQUEST_OPTIONS = (Generator::DEFAULTS.keys + %i[preset candidates method]).freeze

    # A refusal with an HTTP status and a message that's safe to send.
    class Refused < StandardError
      attr_reader :status

      def initialize(status, message)
        @status = status
        super(message)
      end
    end

    attr_reader :port

    # options: generate_many options for every request (source:, catalogue:,
    # ...). generate: how to make results (tests swap it).
    def initialize(host: "127.0.0.1", port: 8754, token: nil, cors_origin: nil, log_pins: false, log: $stderr,
                   options: {}, generate: nil, **limits)
      unknown = limits.keys - LIMITS.keys
      raise ArgumentError, "unknown server limit(s): #{unknown.join(", ")}" if unknown.any?

      @host = host
      @port = port
      @token = token.to_s.empty? ? nil : token.to_s
      @cors = cors_origin
      @log_pins = log_pins
      @log = log
      @options = options
      @limits = LIMITS.merge(limits)
      @generate = generate || ->(pins, opts) { Curtilage.generate_many(pins, **opts) }
      @busy = 0
      @lock = Mutex.new
    end

    # Listens until stopped (stop, or the process ends). Yields once bound.
    def run
      @server = TCPServer.new(@host, @port)
      @port = @server.addr[1]
      @log.puts "curtilage serve: listening on http://#{@host}:#{@port}"
      yield self if block_given?
      loop { accept(@server.accept) }
    rescue IOError, Errno::EBADF
      nil # stopped
    end

    def stop = @server&.close

    private

    def accept(socket)
      unless claim
        respond(socket, 503, { error: "busy: try again shortly" })
        return socket.close
      end
      Thread.new do
        serve(socket)
      ensure
        release
        socket.close unless socket.closed?
      end
    end

    def claim = @lock.synchronize { @busy < @limits[:max_concurrent] && (@busy += 1) }
    def release = @lock.synchronize { @busy -= 1 }

    def serve(socket)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      request = Request.read(socket, @limits[:max_body_bytes])
      status, body, type = route(request)
      respond(socket, status, body, type)
      log(request, status, started)
    rescue Refused => e
      respond(socket, e.status, { error: e.message })
      log(request, e.status, started)
    rescue StandardError => e
      respond(socket, 500, { error: "internal error" })
      @log.puts "curtilage serve: internal error: #{e.class}"
    end

    def route(request)
      case [request.verb, request.path]
      in ["GET", "/health"] then [200, { status: "ok" }]
      in ["GET", "/version"] then check_token(request) || [200, version]
      in ["POST", "/premises"] then check_token(request) || premises(request)
      in ["OPTIONS", _] then [204, nil]
      in [_, "/health" | "/version" | "/premises"] then raise Refused.new(405, "method not allowed")
      else raise Refused.new(404, "not found")
      end
    end

    # Raises unless the request carries the token (or none is set).
    def check_token(request)
      return nil unless @token

      given = request.headers["authorization"].to_s[/\ABearer (.+)\z/, 1].to_s
      ok = given.bytesize == @token.bytesize && OpenSSL.fixed_length_secure_compare(given, @token)
      raise Refused.new(401, "a valid bearer token is required") unless ok

      nil
    end

    def version
      { gem: VERSION, duckdb: DuckDB.version(Curtilage.config.duckdb),
        source: (@options[:source] || Curtilage.config.source).to_s }
    end

    def premises(request)
      sites, options = ServerInput.parse(request, @limits[:max_pins])
      results = Timeout.timeout(@limits[:timeout_s]) do
        @generate.call(sites.map { |s| s[:pin] }, @options.merge(options))
      end
      ids = sites.map { |s| s[:id] }
      if request.headers["accept"].to_s.include?("application/x-ndjson")
        [200, Formats.write(results, :ndjson, ids: ids), "application/x-ndjson"]
      else
        [200, Formats.write(results, :geojson, ids: ids), "application/geo+json"]
      end
    rescue Timeout::Error
      raise Refused.new(504, "took longer than #{@limits[:timeout_s]} s: send fewer pins")
    rescue ArgumentError => e
      raise Refused.new(400, e.message[0, 300])
    end

    def respond(socket, status, body, type = "application/json")
      text = body.is_a?(String) ? body : (body && JSON.generate(body)) || ""
      head = ["HTTP/1.1 #{status} #{STATUS.fetch(status, "Error")}", "Content-Type: #{type}",
              "Content-Length: #{text.bytesize}", "Connection: close", "X-Content-Type-Options: nosniff",
              "Cache-Control: no-store"]
      head << "WWW-Authenticate: Bearer" if status == 401
      if @cors
        head.push("Access-Control-Allow-Origin: #{@cors}", "Access-Control-Allow-Headers: Authorization, Content-Type",
                  "Access-Control-Allow-Methods: GET, POST, OPTIONS")
      end
      socket.write("#{head.join("\r\n")}\r\n\r\n#{text}")
    rescue IOError, SystemCallError
      nil # the client went away
    end

    def log(request, status, started)
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      line = "#{request&.verb} #{request&.path} #{status} #{ms} ms"
      line += " body=#{request.body[0, 2000]}" if @log_pins && request&.body && !request.body.empty?
      @log.puts line
    end
  end
end
