#
# Homebrew cask formula for ToooT.
#
# Publish path: homebrew-tooot tap hosted at https://github.com/mstits/homebrew-tooot
# Users install with:
#     brew tap mstits/tooot
#     brew install --cask tooot
#
# When a new release lands:
#     1. Run `./bundle.sh && ./scripts/make-dmg.sh 1.0.0`
#     2. Upload the DMG to the GitHub Release page.
#     3. Update `version` + `sha256` below, push to the tap repo.
#

cask "tooot" do
  version "2.0.1"
  sha256 "11b851bcb557f3b49aab22e70175f822fdc1337cff978c85658b1adab4bdb3d2"

  url "https://github.com/mstits/Tooot/releases/download/v#{version}/ToooT-#{version}.dmg"
  name "ToooT"
  desc "Open-source macOS-native Digital Audio Workstation (tracker + DAW hybrid)"
  homepage "https://github.com/mstits/Tooot"

  app "ToooT.app"

  zap trash: [
    "~/Library/Application Support/ToooT",
    "~/Library/Preferences/com.apple.projecttooot.plist"
  ]
end
