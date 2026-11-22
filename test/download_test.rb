# frozen_string_literal: true

require_relative "test_helper"

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

  def test_curl_can_be_turned_off
    ENV["CURTILAGE_CURL"] = "0"

    assert_nil D.curl
  ensure
    ENV.delete("CURTILAGE_CURL")
  end
end
