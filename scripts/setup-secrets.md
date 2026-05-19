# Multiharness Release Setup — Secrets & Credentials

## Prerequisites

You need an **Apple Developer Program** account ($99/year) to use `notarytool` for notarization.

## GitHub Secrets to Add

Go to **Settings → Secrets and variables → Actions** in the Multiharness repo.

### Required Secrets

| Secret | Description | Example |
|---|---|---|
| `APPLE_API_KEY_ID` | API Key ID from developer.apple.com | `ABC123DEFG` |
| `APPLE_TEAM_ID` | Your team ID | `AJMH7Y6WZA` |
| `APPLE_DEV_ID_CN` | Certificate name (optional, for local builds) | `Developer ID Application: ...` |

### Optional Secrets

| Secret | Description |
|---|---|
| `SPARKLE_FEED_URL` | URL for Sparkle auto-update feed |
| `APPLE_BOTS_EMAIL` | Apple developer account email for bots |

## How to Get API Key

1. Go to [developer.apple.com → Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/authkeys/list)
2. Click **+** to create a new **Private Key**
3. Name it (e.g., `multiharness-ci`)
4. Check **App Stores and CoreML** only (notarytool needs this)
5. **Download the `.p8` file** — this is your API key
6. Copy **Key ID** (e.g., `ABC123DEFG`)
7. Copy **Team ID** (e.g., `AJMH7Y6WZA`)

### Install API Key to GitHub Secrets

```bash
# Store in GitHub repo secrets:
gh secret set APPLE_API_KEY_ID --body "ABC123DEFG"
gh secret set APPLE_TEAM_ID --body "AJMH7Y6WZA"
gh secret set APPLE_DEV_ID_CN --body "Developer ID Application: Jeremy Nelson (AJMH7Y6WZA)"
```

For the `.p8` file itself, you can upload it via GitHub's UI or use:

```bash
gh secret set APPLE_API_KEY_PATH --body "~/.multiharness-api-key/Key_XXX.p8"
```

Or, for **local builds**, store credentials locally:

```bash
# If you prefer CLI-only authentication:
notarytool store-credentials "Multiharness" \
  --apple-id "jeremy@rainmakers.com" \
  --private-key-id "ABC123DEFG" \
  --private-key-path "$HOME/.multiharness-api-key/Key_XXX.p8" \
  --team-id "AJMH7Y6WZA"
```

## Workflow Usage

Once configured, the release CI will:

1. Build the Swift app + sidecar binary
2. Code sign with your Developer ID cert
3. Create a DMG
4. **Notarize** the DMG (if secrets are set)
5. Generate checksums for Sparkle
6. Upload everything to GitHub Release

### Manual Release

For a quick development build (ad-hoc only):

```bash
bash scripts/build-release.sh
```

For a notarized build (requires API key):

```bash
APPLE_API_KEY_ID="..." \
APPLE_API_KEY_PATH="$HOME/.multiharness-api-key/Key.p8" \
APPLE_TEAM_ID="AJMH7Y6WZA" \
bash scripts/build-release.sh --notarize
```

### Automated Release

Create a tag and push:

```bash
# Prepare:
bash scripts/prepare-release.sh 0.1.1

# OR manually:
echo "1.1.0" > VERSION
git add VERSION CHANGELOG.md
git commit -m "v1.1.0 release"
git tag -a v1.1.0 -m "Multiharness 1.1.0"
git push origin main --tags
```

The `release.yml` workflow will auto-trigger on the `v*` tag push.

## Apple Developer Certificate (Local)

You have these installed on your Mac:

- `iPhone Distribution: Crescendo Digital Media LLC (AJMH7Y6WZA)`
- `Apple Development: Jeremy Nelson (72A6A56636)`
- `Apple Development: jnelson872@icloud.com (7LSMX479YW)`

For **Developer ID Application** (needed for notarized downloads):

1. Go to developer.apple.com → Certificates
2. Create a new **Developer ID Application** certificate
3. If you can't generate a CSR locally, I can help with that
4. Install the resulting `.cer` into your keychain

## Local Code Signing

Already handled by `scripts/build-app.sh` and `scripts/build-release.sh`.

The script checks for these identities in order:

1. **Multi-app Development Certificate** — for local testing
2. **Developer ID Application** — for distribution
3. **Self-Signed** — ad-hoc fallback (users see "app is damaged" warning)

Run to see your identities:

```bash
security find-identity -v -p codesigning
```

## Troubleshooting

### "App is damaged" error

- The app isn't notarized. Run `notarytool staple` or rebuild with notarization.
- Ad-hoc signatures get flagged by Gatekeeper. Use Developer ID.

### Notarytool auth fails

- Check your API key is still active in developer.apple.com
- Ensure your Team ID matches your account
- Ensure the API key has "App Stores and CoreML" permission checked

### DMG won't open

- Notarization ticket might have expired. Re-notarize.
- Try `xattr -dr com.apple.quarantine dist/Multiharness-0.1.0.dmg` locally.

## Sparkle Update Feed

For auto-updates without re-downloading from GitHub, you'll want:

- Sparkle 2 framework (included in `sidecar/`)
- A GitHub Pages repo for the feed URL
- A private key for signing updates (see Sparkle docs)

The `prepare-release.sh` can be extended to:

1. Generate appcast XML with checksums
2. Sign the appcast digest
3. Post to GitHub Pages branch
4. Update the Sparkle URL in the app bundle
