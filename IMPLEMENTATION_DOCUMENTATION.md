# CineWall V2 Implementation Documentation

This document explains what we implemented for CineWall V2 from the beginning of the monetization and release work, why each piece was added, how the current system works, and what still needs to happen before a full public launch.

It only describes V2 work in this repository.
V1 at `/Volumes/APFS X9/cinewall/SimpleVideoWallpaper` was intentionally left untouched.

## 1. Goal We Were Solving

The main goal was to take CineWall V2 from a local app with a lot of new features and turn it into something that can be:

- distributed outside the Mac App Store
- sold with a one-time Pro unlock
- activated securely with a license key
- promoted from a website
- updated later with Sparkle

From the product side, the plan became:

- free core app
- 7-day Pro trial
- lifetime Pro unlock
- no monthly or yearly subscription
- direct website distribution instead of the Mac App Store

## 2. Product Decisions We Settled On

We worked through the pricing and packaging first.

Final direction:

- target audience: primarily US buyers
- price direction: `$6.99` lifetime Pro
- free tier: basic usage stays free
- Pro trial: `7 days`
- no recurring subscription
- sell through hosted checkout
- distribute the app outside the App Store

Why:

- the app is not a cloud-content subscription product
- it has strong local-media value, especially local folders, playlists, and lock-screen sync
- a one-time payment fits the category better than recurring billing

## 3. Apple Distribution Direction

We concluded that CineWall should not rely on the Mac App Store because the app modifies wallpaper-related data under the user's Library for lock-screen sync behavior.

So the chosen path was:

- Apple Developer Program membership
- notarized outside-App-Store distribution
- direct downloads from your website / GitHub releases

This keeps Gatekeeper friction lower and makes the app feel more trustworthy to buyers.

## 4. Pro System Added to the App

We added a real Free / Trial / Pro system to the app.

Main implementation lives in:

- [AppDelegate.swift](./SimpleVideoWallpaper/AppDelegate.swift)
- [LiquidUI.swift](./SimpleVideoWallpaper/LiquidUI.swift)

### 4.1 Access Model

We introduced:

- `ProFeature`
- `ProAccessTier`
- `ProManager`

Feature areas:

- `folderImport`
- `playlists`
- `timer`
- `lockScreenSync`
- `smartSettings`

Current gating behavior:

- `folderImport` is free
- `playlists` is Pro/trial
- `timer` is Pro/trial
- `lockScreenSync` is Pro/trial
- `smartSettings` is Pro/trial

### 4.2 Trial Behavior

We added:

- 7-day trial length
- consumed/not-consumed tracking
- current tier status messaging
- automatic UI refresh when trial/pro state changes

Later, we hardened trial storage so it is no longer only stored in `UserDefaults`.

Current trial storage:

- migrated into Keychain-backed state inside `ProManager`

Why this matters:

- `UserDefaults` alone is too easy to reset
- Keychain does not make piracy impossible, but it removes the most trivial “delete prefs and retry” abuse path

### 4.3 License Storage

The Pro license key is stored locally in Keychain.

Keychain items:

- service: `com.cinewall.pro`
- account: `licenseKey`
- account: `trialState`
- account: `activationInstanceID`
- account: `installID`

### 4.4 Debug Build Storage Behavior

After repeated Keychain password prompts during Xcode runs, we changed the local development flow:

- `Debug` builds now store Pro/trial/install state in `UserDefaults`
- release builds continue using Keychain

Why:

- repeated Keychain access from Xcode runs was noisy and frustrating during development
- this does not change the production security model
- real shipping builds still use Keychain-backed local storage

## 5. Pro UI Changes

We added and refined a dedicated Pro flow inside the Liquid UI menu.

Main UI file:

- [LiquidUI.swift](./SimpleVideoWallpaper/LiquidUI.swift)

### 5.1 Footer Navigation

The bottom footer was redesigned into 3 cards:

- `Bring Here`
- `Pro`
- `Quit`

We iterated on this a few times to match the rest of the glass UI instead of looking like a separate style.

### 5.2 Pro Submenu

The Pro submenu now contains:

- explanation of what Pro unlocks
- trial status
- license key input
- `Paste Key`
- `Activate Key`
- `Get License Key`

The `Get License Key` button now opens your hosted checkout directly instead of just opening the marketing site.

Current checkout URL is stored in:

- [AppDelegate.swift](./SimpleVideoWallpaper/AppDelegate.swift)

### 5.3 PRO Badges

We added `PRO` badges to locked UI areas and later changed the behavior so:

- badges show while the feature is locked
- badges disappear after the Mac is actually unlocked with Pro

This keeps the UI cleaner for paying users.

## 6. Locked Feature Behavior

We also fixed an important logic issue:

- when a trial ended, some already-enabled Pro settings were still active

So we added state normalization logic in the app.

Now, if access is lost:

- timer rotation is disabled
- playlist-only mode is disabled
- smart settings are disabled
- lock-screen sync toggles are reset appropriately

This prevents “trial ended but Pro behavior keeps running” bugs.

## 7. Lock Screen Sync Improvements

We improved lock-screen handling as part of the Pro work.

Changes:

- added a master `Enable Lock Screen Sync` toggle
- made fast/compatible sync behavior respect the master toggle
- prevented startup / unlock auto-sync from firing if the user no longer has Pro access

This fixed the earlier issue where the Pro screen could open unexpectedly because lock-screen sync tried to run on launch/unlock.

## 8. Developer Self-Unlock for Local Testing

For local testing, we added a debug-only developer unlock path.

It is:

- available only in Debug builds
- not intended as a production unlock path
- useful so you can test paid flows without buying repeatedly

This was added behind `#if DEBUG`.

## 9. Website Work

We created a separate website deployment flow for CineWall.

The website code now lives in:

- [website](./website)

This folder is its own git repo and is connected to Vercel.

Live site:

- [https://cinewall-site.vercel.app/](https://cinewall-site.vercel.app/)

GitHub repo:

- private repo `saivinay1805/cinewall-site`

### 9.1 Website Source Changes

We initially created a simple site.
Later, you replaced it with the Claude-generated version from your Desktop.

Then we:

- synced it into the `website/` repo
- kept the app repo and website repo separate
- pushed it to GitHub
- let Vercel deploy it

### 9.2 Website Link Wiring

We wired the site so:

- every download button points to [CineWall releases](https://github.com/saivinay1805/CineWall-App/releases)
- every Pro purchase button points to your hosted checkout

We also removed embedded checkout behavior so the site uses the normal hosted checkout page instead of the overlay.

## 10. License Activation Backend

We built the activation backend in the website repo using a Vercel serverless function.

File:

- [api/activate-license.js](./website/api/activate-license.js)

### 10.1 What It Does

The app sends:

- `license_key`
- `product`
- `device_name`

The server function:

1. receives the request
2. calls the payment provider license API server-to-server
3. validates the result
4. returns success or failure JSON to the app

Then the app:

- stores the key locally in Keychain
- flips into Pro mode

### 10.2 Why This Was Important

This is the key security improvement over putting secrets in the app.

What stays off the client:

- secret store credentials
- any provider-side secret verification logic

This is not perfect anti-piracy, but it is the correct architecture for an indie app.

### 10.3 Backend Hardening

Later, we tightened the activation endpoint in two small but important ways:

- malformed JSON payloads now return a proper `400` JSON error instead of throwing
- the backend validates the license first, checks that it belongs to CineWall Pro, and only then attempts activation
- the endpoint continues to respond in a predictable JSON format for app-side handling

This avoids ugly generic serverless failures and makes the activation path more robust against bad clients or malformed requests.

### 10.4 License Deactivation Endpoint

We later added a matching deactivation endpoint so local debug resets would not keep leaking activation slots.

File:

- [api/deactivate-license.js](./website/api/deactivate-license.js)

What it does:

- receives `license_key`
- receives `instance_id`
- verifies the license still belongs to CineWall Pro
- deactivates that specific activation instance through the provider API

Why it matters:

- local reset flows can now free a used activation slot
- future debug testing no longer burns through the activation limit unnecessarily

## 11. Server-Backed Trial

After discussing local trial abuse and system clock rollbacks, we moved the trial design toward a server-backed model.

Files:

- [SimpleVideoWallpaper/AppDelegate.swift](./SimpleVideoWallpaper/AppDelegate.swift)
- [website/api/trial-status.js](./website/api/trial-status.js)

### 11.1 How It Works

The app now keeps a stable install ID in Keychain and sends it to a dedicated trial endpoint.

The app sends:

- `install_id`
- `device_name`
- `action` (`status` or `start`)

The website endpoint:

1. hashes the install ID
2. reads or creates a trial record in Vercel KV / Upstash Redis
3. returns normalized JSON with:
   - `has_consumed`
   - `trial_active`
   - `started_at`
   - `expires_at`

The app then caches the returned trial window locally in Keychain so the UI can still render cleanly even before the next network check.

We also fixed an important parsing bug here:

- the backend returns ISO 8601 timestamps with fractional seconds
- the app originally failed to parse those reliably
- this made some fresh server-backed trials appear as “already used”

That is now fixed by supporting both normal and fractional-second ISO 8601 date parsing on the app side.

### 11.2 Why This Is Better

This is better than a purely local clock-based trial because:

- the start time is created on the server
- the expiry window is created on the server
- the app can silently refresh trial state on launch
- simple local `UserDefaults` resets are no longer the only thing standing between free and Pro

This still does not make piracy impossible, but it is a much stronger design than a local-only 7-day timer.

### 11.3 Vercel Setup Required

The server-backed trial endpoint expects one of these environment-variable pairs in Vercel:

- `KV_REST_API_URL` and `KV_REST_API_TOKEN`
- or `UPSTASH_REDIS_REST_URL` and `UPSTASH_REDIS_REST_TOKEN`

If trial storage is not configured, the endpoint returns a clear error instead of pretending the trial started.

## 12. Activation URL Hardening

We tightened activation URL handling after discussing reverse engineering and fake local host overrides.

Current behavior:

- Debug builds can still override activation URL for testing
- Release builds only trust the secure production activation endpoint

This reduces the chance of someone “activating” Pro by simply redirecting the app to a fake local service.

The same production-only trust rule was later applied to:

- activation
- deactivation
- trial status refresh

## 13. Security Discussion and Reality

We also discussed whether CineWall can still be hacked.

Honest answer:

- yes, like other local Mac apps, it still can be hacked

What someone determined could still do:

- patch the binary
- force the app to always return `.pro`
- skip UI gates
- alter runtime behavior locally

What we improved:

- trial is now server-backed and cached locally
- activation is server-side
- secrets are not embedded in the app
- release activation host is restricted
- app-side activation now checks HTTP status codes and shows clearer server failure messages
- Sparkle update signing is now wired into the release flow
- app transport is no longer configured as “allow everything”

So the security model is now:

- remove easy abuse
- raise the effort required
- keep legitimate customers on the smooth path

That is the right level for a product like this.

## 14. Sparkle Integration

We added Sparkle integration to prepare for updates.

Main pieces:

- [SparkleUpdater.swift](./SimpleVideoWallpaper/SparkleUpdater.swift)
- [Info.plist](./SimpleVideoWallpaper/Info.plist)
- [LiquidUI.swift](./SimpleVideoWallpaper/LiquidUI.swift)

### 13.1 What Was Added

We added:

- Sparkle package reference to the Xcode project
- wrapper updater class
- `Check for Updates` action in Settings
- `SUFeedURL`
- `SUPublicEDKey`

Current feed URL:

- `https://cinewall-site.vercel.app/appcast.xml`

### 13.2 Sparkle Keys

You generated the Ed25519 Sparkle key pair locally.

Important result:

- public key was added to `Info.plist`
- private key was stored in your macOS Keychain

The private key should never be committed or uploaded.

## 15. Sparkle Release Pipeline

We also built helper tooling for the release process.

Files:

- [prepare_sparkle_release.sh](./scripts/prepare_sparkle_release.sh)
- [SPARKLE_SETUP.md](./SPARKLE_SETUP.md)
- [website/updates](./website/updates)

### 14.1 What the Script Does

The helper script:

1. reads version info from a built `.app`
2. creates a Sparkle-safe zip archive
3. puts it in `website/updates/`
4. regenerates `website/appcast.xml`
5. points the enclosure URL at `https://cinewall-site.vercel.app/updates/...`

### 14.2 Current Release Hosting Plan

Vercel website repo serves:

- `appcast.xml`
- `updates/CineWall-x.y.z.zip`
- `updates/*.delta`

That means your website repo doubles as:

- marketing site
- activation backend
- Sparkle update hosting

This is simple and good enough for launch.

### 14.3 Current Feed State

After the release helper was working and the app version was bumped correctly, we generated:

- `CineWall-2.0.zip`
- `CineWall2-1.delta`
- `appcast.xml` with a `2.0` entry

That generated feed and update payload were then committed and pushed through the website repo so Vercel can serve them from the live site.

## 16. Versioning Fix

When we first ran the Sparkle release flow, the app was still versioned as `1.0 / 1`.

So we updated the project version metadata to:

- `MARKETING_VERSION = 2.0`
- `CURRENT_PROJECT_VERSION = 2`

This was necessary so Sparkle would generate v2 update metadata instead of looking like a v1 update.

## 17. Current Known Sparkle Gotcha

When you generated updates, Sparkle warned about a mismatch between `CineWall-1.0.zip` and `CineWall-2.0.zip`.

That warning is expected if old archives remain in `website/updates/` and Sparkle is comparing old and new signed payloads for delta/update history.

In the current state, keeping both files is acceptable because it preserves the update path from `1` to `2`.

If you later want a cleaner feed:

- remove old archives you no longer want
- regenerate `appcast.xml`
- commit and push the trimmed update set

## 18. Settings and UI Polish

We also did a long series of UI polish changes along the way:

- footer cards restyled to match the glass design
- Pro submenu reshaped to feel like the other detail views
- paste support fixed for license key entry
- `Get License Key` added to Pro
- Settings submenu height increased to avoid clipping
- bottom action labels centered and cleaned up
- startup/update settings moved out of `Settings` and into a separate `CineWall` submenu
- the CineWall header chip was made clickable and wired to its own detail view
- recursive menu-darkness tinting was removed from regular cards so the main cards stop looking muddy
- footer cards, pills, and input shells were normalized away from the milky white fill issue
- the CineWall header chip went through a few iterations and currently uses the cleaner two-line title/subtitle layout again

These changes mostly live in:

- [LiquidUI.swift](./SimpleVideoWallpaper/LiquidUI.swift)
- [LiquidUIComponents.swift](./SimpleVideoWallpaper/LiquidUIComponents.swift)

## 19. Website / Store / Pricing State

Current public-facing pieces:

- website live on Vercel
- hosted Pro checkout exists
- product published
- direct Pro purchase path works
- direct public app download now points to the v2.0 GitHub asset, not the generic releases page
- activation endpoint exists
- app UI has a path to purchase and activate
- Sparkle appcast and update payloads are generated and pushed through the website repo
- private admin dashboard exists for downloads, trials, activations, and platform breakdowns

That means the product is now much closer to a real paid launch than it was at the beginning.

## 20. What Still Needs To Happen Before Full Public Launch

The remaining launch checklist is now mostly operational, not architectural.

### App

- verify Pro purchase flow end-to-end
- verify Sparkle `Check for Updates`
- test one full install outside Xcode on a clean Mac or clean macOS user
- verify that Debug-only controls do not appear in a Release build

### Security / Distribution

- notarize the release
- build the actual public DMG / zip that matches your release process
- keep using Xcode `Archive -> Distribute App -> Direct Distribution` for the real Developer ID signing/notarization step
- keep normal local build/run signing on `Apple Development` so Xcode automatic signing does not conflict

### Website

- keep `appcast.xml`, `updates/`, and activation endpoint current
- push the website repo after each real update release

### Sparkle

- regenerate appcast after each release
- keep the update archives and delta files in sync with the feed

## 21. Final Architecture Summary

The system now looks like this:

### App side

- Liquid UI with Free / Trial / Pro states
- local Keychain storage for trial and license
- Pro-gated features
- direct checkout shortcut from the Pro menu
- Sparkle update client
- minimum supported OS is now `macOS 26.0` (Tahoe-only for v2)

### Website side

- marketing landing page
- hosted purchase links
- activation API endpoint
- private admin dashboard
- Sparkle appcast hosting
- update archive hosting

### Purchase / activation flow

1. user clicks `Get License Key`
2. user completes checkout on hosted checkout page
3. user receives license key
4. user pastes key in Pro submenu
5. app calls website activation endpoint
6. website verifies key with payment provider
7. app stores key in Keychain
8. Pro unlocks on that Mac

### Update flow

1. you build a new Release app
2. export the notarized app from Xcode Organizer
3. run `prepare_sparkle_release.sh` on that exported app
3. archive goes into `website/updates/`
4. `appcast.xml` is regenerated
5. push website repo
6. app sees the new update through Sparkle

## 22. Files Most Important To Know

### App

- [AppDelegate.swift](./SimpleVideoWallpaper/AppDelegate.swift)
- [LiquidUI.swift](./SimpleVideoWallpaper/LiquidUI.swift)
- [LiquidUIComponents.swift](./SimpleVideoWallpaper/LiquidUIComponents.swift)
- [SparkleUpdater.swift](./SimpleVideoWallpaper/SparkleUpdater.swift)
- [Info.plist](./SimpleVideoWallpaper/Info.plist)
- [project.pbxproj](./SimpleVideoWallpaper.xcodeproj/project.pbxproj)

### Website / backend / updates

- [website/index.html](./website/index.html)
- [website/api/activate-license.js](./website/api/activate-license.js)
- [website/api/admin-stats.js](./website/api/admin-stats.js)
- [website/api/admin-test-installs.js](./website/api/admin-test-installs.js)
- [website/admin.html](./website/admin.html)
- [website/appcast.xml](./website/appcast.xml)
- [website/updates](./website/updates)
- [website/README.md](./website/README.md)

### Release helper docs

- [prepare_sparkle_release.sh](./scripts/prepare_sparkle_release.sh)
- [SPARKLE_SETUP.md](./SPARKLE_SETUP.md)
- [IMPLEMENTATION_DOCUMENTATION.md](./IMPLEMENTATION_DOCUMENTATION.md)

## 23. Plain-English Status

At the start, CineWall V2 was just “a much better version of the app.”

Now it is:

- packaged as a real product
- monetized with a one-time Pro model
- connected to a hosted checkout
- activatable with license keys
- backed by a server-side activation endpoint
- equipped with a website
- equipped with a private analytics/admin dashboard
- publishing a Sparkle feed and update archives from the website repo
- downloadable directly from a public v2.0 release asset
- much harder to trivially bypass than the first draft

That is the real implementation story from start to here.

## 24. Release Recommendation

Current honest recommendation:

- ready for a controlled release candidate / launch prep
- not quite “publish instantly without one last outside-Xcode verification”

Reason:

- architecture is now in place
- monetization path exists
- activation works
- server-backed trial works
- Sparkle is wired
- Tahoe-only support removes the old cross-version UI and lock-screen mismatch problems

But before a full public push, one final operational pass still matters:

1. build a real Release build
2. archive and export it through Xcode Organizer direct distribution
3. install the exported notarized app outside Xcode
4. verify:
   - trial start
   - license activation
   - Pro persistence after relaunch
   - Sparkle update check
   - no stray debug UI

If that last pass is clean, CineWall is in reasonable shape to release.

## 25. Dashboard / Analytics Notes

The private dashboard now reports:

- GitHub release downloads
- total trial starts
- active trials
- successful Pro activations
- macOS version breakdown
- Intel vs Apple Silicon breakdown
- recent trial and activation records

Important notes:

- older early test records may not contain platform metadata
- legacy local test rows are now excluded from conversion metrics
- manually marked test installs are also excluded from the top-line stats
- the dashboard token is no longer accepted from a URL query string; it is sent through the auth header only

Main files:

- [website/api/_analytics.js](./website/api/_analytics.js)
- [website/api/admin-stats.js](./website/api/admin-stats.js)
- [website/api/admin-test-installs.js](./website/api/admin-test-installs.js)
- [website/admin.html](./website/admin.html)
- [website/admin.js](./website/admin.js)
