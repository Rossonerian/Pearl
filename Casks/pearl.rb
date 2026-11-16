cask "pearl" do
  version "3.3.0"
  sha256 "e38e344b2644eec948d5cc4ebc12d0db2fd125d97fbec23ce104b4d7a0bb42a6"

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
