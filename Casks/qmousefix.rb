cask "qmousefix" do
  version "0.1.0"
  # Internal/temporary build: fill in after `shasum -a 256 QmouseFix.zip`.
  sha256 :no_check

  url "https://github.com/MinhQuang28/QmouseFix/releases/download/v#{version}/QmouseFix.zip"
  name "QmouseFix"
  desc "Lightweight menu-bar mouse utility: smooth scroll, button remap, Space-drag gestures"
  homepage "https://github.com/MinhQuang28/QmouseFix"

  depends_on macos: ">= :sequoia"

  app "QmouseFix.app"

  uninstall quit: "com.qmousefix.app"

  zap trash: [
    "~/Library/Preferences/com.qmousefix.app.plist",
    "~/Library/Application Support/QmouseFix",
  ]

  caveats <<~EOS
    QmouseFix is signed with a local (non-notarized) certificate, so Gatekeeper
    quarantines it on first launch. Clear the quarantine flag once after install:

      xattr -dr com.apple.quarantine /Applications/QmouseFix.app

    Then grant Accessibility access so it can read mouse input:
      System Settings → Privacy & Security → Accessibility → enable QmouseFix.
  EOS
end
