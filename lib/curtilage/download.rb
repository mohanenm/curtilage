# frozen_string_literal: true

require "net/http"
require "uri"

module Curtilage
  # HTTPS downloads of public map data, from an allowed host only, streamed
  # to disk with a size cap: Geofabrik extracts and region index, Overture's
  # file index, Microsoft's footprint tiles. (DuckDB itself reads Overture
  # and bucket files.) Nothing else in the gem talks to the network.
  module Download
    class Error < StandardError; end

    module_function

    def exists?(host, path)
      start(host) { |http| http.head(path).is_a?(Net::HTTPSuccess) }
    end

    # Writes to dest.part, then renames, so a dest file is always complete.
    def fetch(host, path, dest, max_bytes:)
      start(host) do |http|
        http.request_get(path) do |res|
          raise Error, "HTTP #{res.code} for https://#{host}#{path}" unless res.is_a?(Net::HTTPSuccess)
          raise Error, "too large: https://#{host}#{path}" if res.content_length.to_i > max_bytes

          stream(res, "#{dest}.part", max_bytes)
        end
      end
      File.rename("#{dest}.part", dest)
      dest
    end

    def read(host, path, max_bytes:)
      start(host) do |http|
        res = http.get(path)
        raise Error, "HTTP #{res.code} for https://#{host}#{path}" unless res.is_a?(Net::HTTPSuccess)
        raise Error, "too large: https://#{host}#{path}" if res.body.bytesize > max_bytes

        res.body
      end
    end

    def stream(res, dest, max_bytes)
      bytes = 0
      File.open(dest, "wb") do |f|
        res.read_body do |chunk|
          bytes += chunk.bytesize
          raise Error, "download over #{max_bytes} bytes" if bytes > max_bytes

          f.write(chunk)
        end
      end
    end

    def start(host, &)
      Net::HTTP.start(host, 443, use_ssl: true, open_timeout: 30, read_timeout: 120, &)
    end

    # The path of an https URL on host, or nil for anything else.
    def path_on(url, host, prefix)
      uri = URI.parse(url)
      return nil unless uri.scheme == "https" && uri.host == host && uri.path.start_with?(prefix)
      return nil if uri.path.include?("..")

      uri.path
    rescue URI::InvalidURIError
      nil
    end
  end
end
