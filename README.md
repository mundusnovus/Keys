# Asteria Keys 2.0

A native password manager for iPhone, iPad, and Mac: an encrypted vault, passkeys, one-time codes, AutoFill,
Face ID / Touch ID, iCloud ciphertext sync, Apple Intelligence, and new Siri — built with SwiftUI for iOS 27
and macOS 27.

| | |
| --- | --- |
| Version | 2.0 (build 4) |
| Bundle id | `technology.asteria.keys` |
| Project | `Keys.xcodeproj` |
| Design system | `Keys/Theme.swift` (SF Pro, Asteria Pixel, hierarchical SF Symbols, Liquid Glass) |
| Product | `docs/PRODUCT.md` |
| Release | `docs/RELEASE.md` |
| iCloud schema | `docs/CLOUDKIT-SCHEMA.md` |

## Build and test

```sh
tools/build.sh all          # both platforms, unsigned compile
tools/check.sh              # tests, both builds, privacy, entitlements, placeholders, version
tools/archive.sh ios        # archive + local App Store export (uploads nothing)
tools/archive.sh mac
```

Tests use Swift Testing in `KeysTests/` and exercise the pure vault rules: PBKDF2/AES-GCM, recovery, TOTP,
generator, CSV/Bitwarden import, conflicts, passkey bytes, Base32, and vault identity across password changes.

## Demo for screenshots and App Review

Debug only. Launch with `-demo -no-cloud`; the master password is `AsteriaDemo!2026`. Add `-open first` to
open an item and `dark` to force dark appearance. The demo uses an isolated `KeysDemo` vault folder and never
touches a real vault.

```sh
tools/screenshots-ios.sh "iPhone 18 Pro Max" AppStore/screenshots/iphone
tools/screenshots-ios.sh "iPad Pro 13-inch (M5)" AppStore/screenshots/ipad
```

## Privacy

The vault key is wrapped by the master password (PBKDF2-HMAC-SHA256, 600,000 iterations) and the items are
sealed with AES-GCM. Only ciphertext goes to the person's private CloudKit database. No Asteria account, no
Asteria server, no analytics, no advertising. Apple Intelligence receives counts only for the security coach;
Capture and smart search are on-device. Private Cloud Compute stays off until Apple grants the managed
entitlement.

## Status

- Verified: 6 pure tests, both platform builds, Keychain save → lock → Face ID unlock → 8 items, iPhone/iPad
  runs and screenshots, iOS and macOS archives, local App Store exports with production signing, privacy
  manifest, app icon, version/extension parity.
- Not verified by the agent: two physical devices syncing through iCloud, Siri phrases spoken, Spotlight
  results, AutoFill in another app, Private Cloud Compute (entitlement not held), a visible Mac window under
  the automation host, and upload/TestFlight.
