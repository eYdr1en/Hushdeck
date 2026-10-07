# Homebrew cask template for Hushdeck.
#
# Publish it from a tap repository (e.g. github.com/eYdr1en/homebrew-tap, file
# Casks/hushdeck.rb). For each release, `app/scripts/package-release.sh` (or the
# release workflow) writes a copy with `version` and `sha256` filled in to
# app/dist/hushdeck.rb. The URLs point at eYdr1en/Hushdeck; for a fork, set
# HUSHDECK_REPOSITORY_URL when packaging.
#
# Users then install with:
#   brew tap eYdr1en/tap
#   brew trust --cask eYdr1en/tap/hushdeck     # Homebrew 6+ asks you to trust third-party taps
#   brew install --cask eYdr1en/tap/hushdeck
cask "hushdeck" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256"

  url "https://github.com/eYdr1en/Hushdeck/releases/download/v#{version}/Hushdeck-#{version}.zip"
  name "Hushdeck"
  desc "Menu bar app for the Arctis Nova Pro Omni and other headsets"
  homepage "https://github.com/eYdr1en/Hushdeck"

  livecheck do
    url :url
    strategy :github_latest
  end

  # The release build is Apple Silicon only (the bundled headsetcontrol is arm64).
  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "Hushdeck.app"

  # Hushdeck is ad-hoc signed, not notarised, so Gatekeeper would refuse to open a
  # quarantined copy. Clearing the flag here is fine for a personal tap; the official
  # homebrew/cask repository would not accept this.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Hushdeck.app"],
                   sudo: false
  end

  uninstall quit: "com.adrianhorvath.hushdeck"

  zap trash: [
    "~/Library/Preferences/com.adrianhorvath.hushdeck.plist",
  ]

  caveats <<~EOS
    Hushdeck bundles HeadsetControl (GPL-3.0), which it runs as a separate program.
    Its licence is in Hushdeck.app/Contents/Resources/headsetcontrol-LICENSE.txt and
    its source code is at https://github.com/Sapd/HeadsetControl.
  EOS
end
