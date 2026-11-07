# Sparkle Setup

## What is already wired

- Sparkle Swift package reference is added to the Xcode project.
- CineWall now has a `Check for Updates` action in Settings.
- `Info.plist` includes:
  - `SUFeedURL = https://cinewall-site.vercel.app/appcast.xml`
  - `SUPublicEDKey = wUKNxkJ/ZhwaqFk9zN5H9ZrNOzyZzC/ISSSOo8i02Xg=`

## Still required before shipping

1. Open the project in full Xcode and let Swift Package Manager resolve `Sparkle`.
2. Archive your signed app with Developer ID.
3. Run [prepare_sparkle_release.sh](/Users/saivinaykumarreddyvavilla/Documents/SimpleVideoWallpaper/scripts/prepare_sparkle_release.sh) with your signed `.app` bundle.
4. Host:
   - `appcast.xml`
   - signed release archives
5. Keep `CFBundleVersion` increasing for every release.

## Suggested hosting layout

- `https://cinewall-site.vercel.app/appcast.xml`
- `https://cinewall-site.vercel.app/updates/CineWall-2.0.0.zip`

## Helper script

Use:

```bash
./scripts/prepare_sparkle_release.sh "/absolute/path/to/CineWall.app"
```

Optional release notes:

```bash
./scripts/prepare_sparkle_release.sh "/absolute/path/to/CineWall.app" "/absolute/path/to/CineWall-2.0.0.md"
```

## Why the app may still say updates are unavailable

- Sparkle package has not resolved in Xcode yet.
- the installed app was not built with the resolved Sparkle package.
- the shipped build is not signed/notarized the way your release flow expects.
