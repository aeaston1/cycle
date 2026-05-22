# Homebrew formula template for the public tap.
#
# Copy this file into the tap repository as Formula/cycle.rb after publishing a
# versioned release artifact. Replace homepage, url, sha256, and version in that
# tap commit only after the artifact exists.

class Cycle < Formula
  desc "Control plane for running OpenAI Symphony across Linear projects"
  homepage "https://github.com/OWNER/REPO"
  url "https://github.com/OWNER/REPO/releases/download/vX.Y.Z/cycle-vX.Y.Z.tar.gz"
  sha256 "REPLACE_WITH_RELEASE_SHA256"
  license "MIT"
  version "X.Y.Z"

  depends_on "codex"
  depends_on "erlang"
  depends_on "git"
  depends_on "mise"

  uses_from_macos "curl"

  def install
    bin.install "bin/cycle"
    doc.install "README.md"
    doc.install "docs"
  end

  test do
    assert_match "cycle v#{version}", shell_output("#{bin}/cycle --version")
    assert_match "Cycle doctor", shell_output("#{bin}/cycle doctor")
  end
end
