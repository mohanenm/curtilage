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

    # The whole body as a string. complete: a block that's given the body and
    # returns true when it's whole (it parses, say): a body cut short without
    # a declared length to catch it is then fetched again, not trusted.
    def read(host, path, max_bytes:, &complete)
      with_retries("reading https://#{host}#{path}") do
        body = start(host) do |http|
          got = nil
          http.request_get(path) do |res|
            check(res, host, path)
            got = stream(res, String.new, max_bytes)
          end
          got
        end
        raise Transient, "incomplete download: https://#{host}#{path}" if complete && !whole?(body, &complete)

        body
      end
    end

    def whole?(body)
      yield(body)
    rescue StandardError
      false
    end

    # Overture's file index is Parquet: whole when it starts and ends with
    # the format's marker.
    def parquet?(body) = body.start_with?("PAR1") && body.end_with?("PAR1")

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
    # as soon as it passes max_bytes rather than after it has all arrived. A
    # body shorter than its declared length was cut off: worth another try.
    def stream(res, out, max_bytes)
      expected = declared_length(res)
      bytes = 0
      res.read_body do |chunk|
        bytes += chunk.bytesize
        raise Error, "download over #{max_bytes} bytes" if bytes > max_bytes

        out << chunk
      end
      raise Transient, "download cut short: #{bytes} of #{expected} bytes" if expected && bytes < expected

      out
    end

    # The Content-Length, unless the body is compressed in transit (then it
    # counts the compressed bytes, not the ones read).
    def declared_length(res)
      return nil unless res.respond_to?(:content_length) && res.respond_to?(:[])

      res["content-encoding"] ? nil : res.content_length
    end

    def start(host, &)
      allowed!(host)
      proxy = proxy_for(host)
      Net::HTTP.start(host, 443, proxy&.host, proxy&.port, proxy&.user, proxy&.password,
                      use_ssl: true, open_timeout: 30, read_timeout: 120, &)
    end

    # The proxy for an HTTPS download, as curl picks it: https_proxy (or
    # HTTPS_PROXY) unless no_proxy covers the host. Net::HTTP on its own
    # would read http_proxy instead.
    def proxy_for(host)
      URI("https://#{host}").find_proxy
    end

    def allowed!(host)
      Curtilage.online!("downloading from #{host}")
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
