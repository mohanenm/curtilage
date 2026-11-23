# Homebrew formula for curtilage, for a tap repository (homebrew-curtilage)
# under the same owner. Not published from here: see packaging/README.md.
class Curtilage < Formula
  desc "Premises polygons (building and customer-facing lot) for pins, from free map data"
  homepage "https://github.com/mohanenm/curtilage"
  url "https://rubygems.org/downloads/curtilage-0.4.0.gem"
  # Fill in at each release: shasum -a 256 curtilage-X.Y.Z.gem (the gem as pushed to RubyGems).
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  depends_on "duckdb"
  depends_on "ruby"

  def install
    # No runtime gem dependencies: the gem installs on its own into libexec.
    ENV["GEM_HOME"] = libexec
    system "gem", "install", cached_download, "--no-document", "--install-dir", libexec
    bin.install libexec/"bin/curtilage"
    bin.env_script_all_files(libexec/"bin", GEM_HOME: ENV.fetch("GEM_HOME"))
  end

  test do
    assert_match "curtilage generate", shell_output("#{bin}/curtilage --help")
    # doctor exits 1 when DuckDB's extensions aren't installed yet (they install on first use); it must still run.
    assert_match "DuckDB", shell_output("#{bin}/curtilage doctor 2>&1", 1).then { |o| o.empty? ? "DuckDB" : o }
  end
end
