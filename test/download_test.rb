# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class DownloadTest < Minitest::Test
  D = Curtilage::Download

  def test_transient_failures_are_retried
    calls = 0
    result = D.with_retries("test", base_delay: 0) do
      calls += 1
      raise Net::ReadTimeout if calls < 3

      :done
    end

    assert_equal :done, result
    assert_equal 3, calls
  end

  def test_gives_up_after_three_tries_with_a_clear_error
    calls = 0
    error = assert_raises(D::Error) do
      D.with_retries("downloading x", base_delay: 0) do
        calls += 1
        raise Errno::ECONNRESET
      end
    end

    assert_equal 3, calls
    assert_includes error.message, "downloading x failed after 3 tries"
  end

  def test_other_errors_are_not_retried
    calls = 0
    assert_raises(ArgumentError) do
      D.with_retries("test", base_delay: 0) do
        calls += 1
        raise ArgumentError
      end
    end

    assert_equal 1, calls
  end

  def test_stream_stops_at_the_size_cap
    res = Object.new
    def res.read_body(&) = %w[abc def gh].each(&)

    assert_equal "abcdefgh", D.stream(res, String.new, 8)
    error = assert_raises(D::Error) { D.stream(res, String.new, 5) }
    assert_includes error.message, "over 5 bytes"
  end

  def test_only_allowed_hosts_are_contacted
    error = assert_raises(D::Error) { D.start("example.com") { flunk "connected" } }
    assert_includes error.message, "example.com"
    assert_raises(D::Error) { D.curl_args("example.com", "/x") }
    [Curtilage::Regions::HOST, Curtilage::Build::HOST, Curtilage::Overture::STAC_HOST,
     Curtilage::Footprints::MICROSOFT_HOST].each { |host| assert_includes D::ALLOWED_HOSTS, host }
  end

  def test_a_failed_download_leaves_no_partial_file
    Dir.mktmpdir do |dir|
      dest = File.join(dir, "region.zip")
      half = lambda do |_host, _path, part, _max|
        File.write(part, "half")
        raise D::Error, "connection lost"
      end
      with_stub(D, :curl, -> {}) do
        with_stub(D, :http_fetch, half) do
          assert_raises(D::Error) { D.fetch("download.geofabrik.de", "/x.zip", dest, max_bytes: 10) }
        end
      end

      assert_empty Dir.children(dir)
    end
  end

  # Ruby's client follows the same proxy settings curl does for HTTPS.
  def test_https_downloads_use_the_https_proxy
    saved = ENV.to_h.slice("https_proxy", "HTTPS_PROXY", "no_proxy", "NO_PROXY", "http_proxy")
    %w[https_proxy HTTPS_PROXY no_proxy NO_PROXY http_proxy].each { |k| ENV.delete(k) }
    ENV["http_proxy"] = "http://wrong.example:1"

    assert_nil D.proxy_for("download.geofabrik.de")
    ENV["https_proxy"] = "http://user:pass@proxy.example:3128"
    proxy = D.proxy_for("download.geofabrik.de")

    assert_equal ["proxy.example", 3128, "user"], [proxy.host, proxy.port, proxy.user]
    ENV["no_proxy"] = ".geofabrik.de"

    assert_nil D.proxy_for("download.geofabrik.de")
  ensure
    %w[https_proxy HTTPS_PROXY no_proxy NO_PROXY http_proxy].each { |k| ENV.delete(k) }
    saved&.each { |k, v| ENV[k] = v }
  end

  def test_curl_can_be_turned_off
    ENV["CURTILAGE_CURL"] = "0"

    assert_nil D.curl
  ensure
    ENV.delete("CURTILAGE_CURL")
  end
end
