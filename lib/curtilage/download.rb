# frozen_string_literal: true

require "fileutils"
require "net/http"
require "English"
require "openssl"
require "uri"

module Curtilage
  # HTTPS downloads of public map data, from an allowed host only, streamed
  # to disk with a size cap: Geofabrik extracts and region index, Overture's
  # file index, Microsoft's footprint tiles. (DuckDB itself reads Overture
  # and bucket files.) Nothing else in the gem talks to the network.
  #
  # Network hiccups (timeouts, dropped connections, server errors) are
  # retried with a short backoff. Big transfers use the curl command when
  # it's installed, which streams several times faster than Net::HTTP; set
  # CURTILAGE_CURL=0 to always use Net::HTTP.
  module Download
    class Error < Curtilage::Error; end

    # Worth another try: the next attempt may well succeed.
    class Transient < Error; end

    TRANSIENT_ERRORS = [Transient, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED,
                        Errno::ECONNABORTED, Errno::EPIPE, Errno::ETIMEDOUT, EOFError, OpenSSL::SSL::SSLError,
                        SocketError].freeze
    ATTEMPTS = 3
    # Every host the gem itself downloads from; anything else is refused.
    # (DuckDB's own reads of Overture's storage, your bucket and its
    # extension repository don't go through here.)
    ALLOWED_HOSTS = %w[download.geofabrik.de stac.overturemaps.org minedbuildings.z5.web.core.windows.net].freeze

    module_function

    def exists?(host, path)
      with_retries("checking https://#{host}#{path}") do
        start(host) do |http|
          res = http.head(path)
          raise Transient, "HTTP #{res.code}" if res.is_a?(Net::HTTPServerError)

          res.is_a?(Net::HTTPSuccess)
        end
      end
    end

    # Writes to dest.part, then renames, so a dest file is always complete.
    def fetch(host, path, dest, max_bytes:)
      part = "#{dest}.part"
      with_retries("downloading https://#{host}#{path}") do
        curl ? curl_fetch(host, path, part, max_bytes) : http_fetch(host, path, part, max_bytes)
      end
      File.rename(part, dest)
      dest
    ensure
      FileUtils.rm_f(part) if part && File.exist?(part) # failed or interrupted: no half file left behind
    end

    def read(host, path, max_bytes:)
      with_retries("reading https://#{host}#{path}") do
        start(host) do |http|
          body = nil
          http.request_get(path) do |res|
            check(res, host, path)
            body = stream(res, String.new, max_bytes)
          end
          body
        end
      end
    end

    # Yields the bytes first..last of https://host/path as they arrive. The
    # caller's block must cope with being restarted if a retry happens.
    def stream_range(host, path, first, last, &)
      curl ? curl_range(host, path, first, last, &) : http_range(host, path, first, last, &)
    end

    # Runs the block, retrying transient failures (2 s, then 4 s, apart).
    def with_retries(what, attempts: ATTEMPTS, base_delay: 2)
      tries = 0
      begin
        tries += 1
        yield
      rescue *TRANSIENT_ERRORS => e
        raise Error, "#{what} failed after #{tries} tries: #{e.class}: #{e.message}" if tries >= attempts

        sleep(base_delay**tries)
        retry
      end
    end

    def check(res, host, path)
      raise Transient, "HTTP #{res.code} for https://#{host}#{path}" if res.is_a?(Net::HTTPServerError)
      raise Error, "HTTP #{res.code} for https://#{host}#{path}" unless res.is_a?(Net::HTTPSuccess)
    end

    def http_fetch(host, path, dest, max_bytes)
      start(host) do |http|
        http.request_get(path) do |res|
          check(res, host, path)
          raise Error, "too large: https://#{host}#{path}" if res.content_length.to_i > max_bytes

          File.open(dest, "wb") { |f| stream(res, f, max_bytes) }
        end
      end
    end

    def http_range(host, path, first, last, &block)
      start(host) do |http|
        request = Net::HTTP::Get.new(path)
        request["Range"] = "bytes=#{first}-#{last}"
        http.request(request) do |res|
          raise Transient, "HTTP #{res.code}" if res.is_a?(Net::HTTPServerError)
          raise Error, "range request ignored (HTTP #{res.code})" unless res.code == "206"

          res.read_body(&block)
        end
      end
    end

    # The curl command, or nil when it isn't installed or CURTILAGE_CURL=0.
    def curl
      return nil if ENV["CURTILAGE_CURL"] == "0"
      return @curl if defined?(@curl)

      @curl = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "curl") }
                 .find { |file| File.executable?(file) && !File.directory?(file) }
    end

    def curl_args(host, path)
      allowed!(host)
      [curl, "--silent", "--show-error", "--fail", "--proto", "=https", "--connect-timeout", "30",
       "--speed-limit", "1000", "--speed-time", "60", "https://#{host}#{path}"]
    end

    def curl_fetch(host, path, dest, max_bytes)
      ok = system(*curl_args(host, path), "--max-filesize", max_bytes.to_s, "--output", dest)
      raise Transient, "curl failed for https://#{host}#{path}" unless ok
    end

    def curl_range(host, path, first, last)
      IO.popen([*curl_args(host, path), "--range", "#{first}-#{last}"], "rb") do |io|
        while (chunk = io.read(1 << 20))
          yield chunk
        end
      end
      raise Transient, "curl failed for https://#{host}#{path}" unless $CHILD_STATUS.success?
    end

    # Appends the response body to out (a file or a binary string), stopping
    # as soon as it passes max_bytes rather than after it has all arrived.
    def stream(res, out, max_bytes)
      bytes = 0
      res.read_body do |chunk|
        bytes += chunk.bytesize
        raise Error, "download over #{max_bytes} bytes" if bytes > max_bytes

        out << chunk
      end
      out
    end

    def start(host, &)
      allowed!(host)
      Net::HTTP.start(host, 443, use_ssl: true, open_timeout: 30, read_timeout: 120, &)
    end

    def allowed!(host)
      raise Error, "not an allowed download host: #{host}" unless ALLOWED_HOSTS.include?(host)
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
