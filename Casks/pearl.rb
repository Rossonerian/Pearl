cask "pearl" do
  version "3.1.0"
  sha256 "a97a9909a247ac5ae8ecedc135fc5fd4e64fcb2d4c2dc0381f51f16f0002a255"

  url "https://github.com/rossonerian/Pearl/releases/download/v#{version}/Pearl-#{version}.dmg"
  name "Pearl"
  desc "Capable, private, lightweight native macOS personal AI assistant"
  homepage "https://github.com/rossonerian/Pearl"

  livecheck do
    url "https://raw.githubusercontent.com/rossonerian/Pearl/main/appcast.xml"
    strategy :sparkle
  end

  auto_updates true
  depends_on macos: ">= :sequoia"

  app "Pearl.app"
  binary "#{appdir}/Pearl.app/Contents/Helpers/pearl-cli", target: "pearl"

  postflight do
    system_command "/bin/mkdir", args: ["-p", "#{Dir.home}/.pearl"]
  end

  zap trash: [
    "~/.pearl",
    "~/Library/Application Support/Pearl",
    "~/Library/Caches/ai.pearl.Pearl",
    "~/Library/HTTPStorages/ai.pearl.Pearl",
    "~/Library/Preferences/ai.pearl.Pearl.plist",
    "~/Library/Saved Application State/ai.pearl.Pearl.savedState",
  ]
end
