# Rewritten by scripts/release.sh when a version is published.
class Macstat < Formula
  desc "Full-screen terminal monitor for Mac system stats"
  homepage "https://github.com/mikelittman/macstat"
  url "https://github.com/mikelittman/macstat/releases/download/v0.0.0/macstat-0.0.0-macos.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  version "0.0.0"

  livecheck do
    url :homepage
    strategy :github_latest
  end

  depends_on macos: :sonoma

  def install
    bin.install "macstat"
  end

  test do
    assert_match "macstat", shell_output("#{bin}/macstat --help")
  end
end
