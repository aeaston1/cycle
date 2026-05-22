# Draft Homebrew formula.
#
# Copy this file into the tap repository as Formula/cycle.rb after the first
# versioned Cycle release exists. Replace homepage, url, and sha256 with the
# release artifact values from the public Cycle repository.

class Cycle < Formula
  desc "Control plane for running OpenAI Symphony across Linear projects"
  homepage "REPLACE_WITH_PROJECT_HOMEPAGE"
  url "REPLACE_WITH_RELEASE_TARBALL_URL"
  sha256 "REPLACE_WITH_RELEASE_SHA256"
  license "MIT"

  depends_on "git"
  depends_on "mise"

  def install
    bin.install "bin/cycle"
    doc.install "README.md"
    doc.install "docs/architecture.md"
  end

  test do
    assert_match "cycle", shell_output("#{bin}/cycle --version")
  end
end
