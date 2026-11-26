# frozen_string_literal: true

module Curtilage
  class Server
    STATUS = { 200 => "OK", 204 => "No Content", 400 => "Bad Request", 401 => "Unauthorized", 404 => "Not Found",
               405 => "Method Not Allowed", 408 => "Request Timeout", 411 => "Length Required",
               413 => "Content Too Large", 500 => "Internal Server Error", 503 => "Service Unavailable",
               504 => "Gateway Timeout" }.freeze
    # One HTTP request, read with caps: the head (request line and headers)
    # at most MAX_HEADER_BYTES, the body only with a Content-Length up to
    # the limit, and the whole request within READ_TIMEOUT_S (one deadline,
    # so a client sending a byte at a time can't hold a slot for hours).
    Request = Struct.new(:verb, :path, :headers, :body) do
      def self.read(socket, max_body, timeout_s = READ_TIMEOUT_S)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_s
        head, rest = read_head(socket, deadline)
        line, *fields = head.split("\r\n")
        method, target, = line.to_s.split(" ", 3)
        raise Refused.new(400, "bad request line") unless method&.match?(/\A[A-Z]{3,7}\z/) && target&.start_with?("/")

        headers = fields.to_h do |f|
          name, value = f.split(":", 2)
          [name.to_s.strip.downcase, value.to_s.strip]
        end
        body = method == "POST" ? read_body(socket, rest, headers, max_body, deadline) : ""
        new(method, target.split("?", 2).first, headers, body)
      end

      # [head, the bytes read past it (the body's start)].
      def self.read_head(socket, deadline)
        data = +""
        until data.include?("\r\n\r\n")
          raise Refused.new(413, "request headers too large") if data.bytesize > MAX_HEADER_BYTES

          data << chunk(socket, 4096, deadline)
        end
        head, rest = data.split("\r\n\r\n", 2)
        [head, rest.to_s]
      end

      def self.read_body(socket, rest, headers, max_body, deadline)
        raise Refused.new(411, "chunked bodies aren't accepted: send Content-Length") if headers["transfer-encoding"]

        length = headers["content-length"]
        raise Refused.new(411, "Content-Length is required") unless length&.match?(/\A\d{1,12}\z/)
        raise Refused.new(413, "body over #{max_body} bytes") if length.to_i > max_body

        body = rest.byteslice(0, length.to_i)
        body << chunk(socket, length.to_i - body.bytesize, deadline) while body.bytesize < length.to_i
        body.force_encoding(Encoding::UTF_8)
      end

      def self.chunk(socket, max, deadline)
        left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Refused.new(408, "timed out reading the request") unless left.positive? && socket.wait_readable(left)

        data = socket.readpartial([max, 65_536].min)
        data.force_encoding(Encoding::BINARY)
      rescue EOFError
        raise Refused.new(400, "request cut short")
      end
    end

    # POST /premises bodies: { "pins": [[lng, lat], ...] or [{ "id":, "pin": }],
    # "options": { ... } }, a GeoJSON FeatureCollection of points, or NDJSON
    # (Content-Type: application/x-ndjson) as the command line reads it.
    module ServerInput
      module_function

      # [[{ id:, pin: }], options]
      def parse(request, max_pins)
        sites, options = sites_and_options(request)
        raise Refused.new(400, "no pins given") if sites.empty?
        raise Refused.new(413, "#{sites.size} pins is over the limit of #{max_pins} a request") if sites.size > max_pins

        [sites, checked_options(options)]
      end

      def sites_and_options(request)
        ndjson = request.headers["content-type"].to_s.include?("ndjson")
        return [Formats.parse_pins(request.body, :ndjson), {}] if ndjson

        doc = JSON.parse(request.body, max_nesting: 20)
        return [Formats.parse_pins(request.body, :geojson), {}] if doc.is_a?(Hash) && doc["type"] == "FeatureCollection"
        raise Refused.new(400, "expected { \"pins\": [...] } or a FeatureCollection") unless doc.is_a?(Hash)

        [pins(doc["pins"]), doc.fetch("options", {})]
      rescue JSON::ParserError
        raise Refused.new(400, "body isn't valid JSON")
      end

      def pins(list)
        raise Refused.new(400, "pins must be a list") unless list.is_a?(Array)

        list.each_with_index.map do |item, i|
          pin = item.is_a?(Hash) ? item["pin"] : item
          id = item.is_a?(Hash) && item["id"] ? item["id"].to_s[0, 200] : (i + 1).to_s
          { id: id, pin: Validation.pin(pin) }
        rescue ArgumentError => e
          raise Refused.new(400, "pin #{i + 1}: #{e.message[0, 200]}")
        end
      end

      def checked_options(options)
        raise Refused.new(400, "options must be an object") unless options.is_a?(Hash)

        options.to_h do |key, value|
          name = key.to_s.to_sym
          allowed = REQUEST_OPTIONS.include?(name)
          raise Refused.new(400, "option #{key.to_s[0, 50]} can't be set per request") unless allowed

          [name, option_value(name, value)]
        end
      end

      def option_value(name, value)
        return value.to_sym if NAMED_OPTIONS.include?(name) && value.is_a?(String)
        return value.transform_keys(&:to_sym) if name == :validation && value.is_a?(Hash)

        value
      end
    end
  end
end
