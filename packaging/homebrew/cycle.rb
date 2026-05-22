# Homebrew formula template for the public tap.
#
# Copy this file into the tap repository as Formula/cycle.rb after publishing a
# versioned release artifact. Replace homepage, url, sha256, and version in that
# tap commit only after the artifact exists.

class Cycle < Formula
  desc "Control plane for running OpenAI Symphony across Linear projects"
  homepage "https://github.com/OWNER/REPO"
  url "https://github.com/OWNER/REPO/releases/download/v0.1.0/cycle-v0.1.0.tar.gz"
  sha256 "43c49f850fc90948971569be65b248abe19c7824629ec1641ce28eb7a3ecb5e2"
  license "MIT"
  version "0.1.0"

  depends_on "codex"
  depends_on "erlang"
  depends_on "git"

  uses_from_macos "curl"

  def install
    bin.install "bin/cycle"
    doc.install "README.md"
    doc.install "docs"
  end

  test do
    assert_match "cycle #{version}", shell_output("#{bin}/cycle --version")
    assert_match "Cycle doctor", shell_output("#{bin}/cycle doctor")
  end
end
