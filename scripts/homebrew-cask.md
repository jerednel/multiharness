# Homebrew Cask for Multiharness

This Cask file can be used to install Multiharness via Homebrew.
Save it in your Homebrew tap (e.g. `jeremy/homebrew-multiharness`) as `Casks/multiharness.rb`.

## Cask File

```ruby
cask "multiharness" do
  version "0.1.0"
  sha256 "YOUR_SHA256_HERE"

  url "https://github.com/jerednel/Multiharness/releases/download/v#{version}/Multiharness-#{version}.dmg"
  name "Multiharness"
  desc "A local-first AI coding harness for macOS"
  homepage "https://github.com/jerednel/Multiharness"

  app "Multiharness.app"

  zap trash: [
    "~/Library/Application Support/Multiharness",
    "~/Library/Preferences/com.multiharness.app.plist",
    "~/Library/Saved Application State/com.multiharness.app.savedState",
  ]
end
```

## Setup Instructions

1. Create a Homebrew tap repo: `gh repo create jeremy/homebrew-multiharness --public`
2. Add the Cask file above: `Casks/multiharness.rb`
3. Push the repo: `git push origin main`
4. Install: `brew install jeremy/homebrew-multiharness/multiharness`
5. Uninstall: `brew uninstall jeremy/homebrew-multiharness/multiharness`
6. Auto-update: `brew update` and `brew upgrade`

## Cask Best Practices

- Version matches the `VERSION` file in the Multiharness repo
- SHA is calculated from the DMG: `shasum -a 256 dist/Multiharness-0.1.0.dmg`
- URL includes the version variable for auto-updates
- `zap` cleans up all app data (for full uninstall)
