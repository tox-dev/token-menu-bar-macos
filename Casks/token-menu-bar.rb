cask "token-menu-bar" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/tox-dev/token-menu-bar-macos/releases/download/v#{version}/TokenMenuBar-Homebrew.dmg"
  name "Token Menu Bar"
  desc "Menu bar monitor for Claude Code and Codex plan usage limits"
  homepage "https://github.com/tox-dev/token-menu-bar-macos"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Token Menu Bar.app"

  zap trash: [
    "~/Library/Application Support/Token Menu Bar",
    "~/Library/Caches/dev.tox.token-menu-bar",
    "~/Library/HTTPStorages/dev.tox.token-menu-bar",
    "~/Library/Preferences/dev.tox.token-menu-bar.plist",
    "~/Library/Saved Application State/dev.tox.token-menu-bar.savedState",
  ]
end
