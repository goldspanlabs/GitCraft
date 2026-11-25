# Template for the cask in goldspanlabs/homebrew-tap (Casks/gitcraft.rb).
# The release workflow fills in VERSION and SHA256 and pushes the result to
# the tap, so edit this file rather than the copy in the tap.
cask "gitcraft" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/goldspanlabs/gitcraft/releases/download/v#{version}/GitCraft-v#{version}.dmg"
  name "GitCraft"
  desc "Native Git client"
  homepage "https://github.com/goldspanlabs/gitcraft"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "GitCraft.app"

  zap trash: [
    "~/Library/Preferences/com.goldspanlabs.gitcraft.plist",
    "~/Library/Saved Application State/com.goldspanlabs.gitcraft.savedState",
  ]

  caveats <<~EOS
    GitCraft is not notarized by Apple. The first time you open it, macOS
    will say it can't verify the app. Open System Settings > Privacy & Security
    and click "Open Anyway". You only need to do this once per install.
  EOS
end
