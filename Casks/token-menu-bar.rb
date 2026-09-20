cask "token-menu-bar" do
  version "0.1.6"
  sha256 "61467f9c0cb78e4db238c797dd1016c1bb46f85562ff1568ca3a1961f0314816"

  url "https://github.com/tox-dev/token-menu-bar-macos/releases/download/v#{version}/TokenMenuBar-Homebrew.dmg"
  name "Token Menu Bar"
  desc "Menu bar monitor for Claude, Codex, Gemini, Antigravity, Cursor and Copilot usage limits"
  homepage "https://github.com/tox-dev/token-menu-bar-macos"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sequoia

  app "Token Menu Bar.app"
  uninstall quit: "dev.tox.token-menu-bar"

  zap trash: [
    "~/Library/Application Support/Token Menu Bar",
    "~/Library/Caches/dev.tox.token-menu-bar",
    "~/Library/Group Containers/*.dev.tox.token-menu-bar",
    "~/Library/Group Containers/group.dev.tox.token-menu-bar",
    "~/Library/HTTPStorages/dev.tox.token-menu-bar",
    "~/Library/Preferences/dev.tox.token-menu-bar.plist",
    "~/Library/Saved Application State/dev.tox.token-menu-bar.savedState",
  ]
end
