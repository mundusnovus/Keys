# Asteria Keys 2.0

Asteria Keys is a private password manager for iPhone, iPad, and Mac. The vault is encrypted on the device
with AES-GCM; the key is wrapped by the master password with PBKDF2-HMAC-SHA256 at 600,000 iterations.
Only ciphertext is stored in the person's own private iCloud database. There is no Asteria account, no Asteria
server, no analytics, and no advertising.

## What 2.0 includes

- **Vault**: logins, passwords, secure notes, cards, identities, passkeys, Wi-Fi passwords, one-time codes, and
  folders. Search covers names, usernames, sites, and notes, never secrets.
- **Unlock**: master password, recovery key, Face ID / Touch ID, and the device passcode. The vault key is kept
  in the data-protection keychain behind `.userPresence`.
- **Sync**: a custom CloudKit zone in the private database. Each item is a sealed record; the header carries the
  wrapped key and a stable vault identity. Change tokens, full re-fetch, conflict copies, and a per-device sync
  pause.
- **AutoFill**: iOS and macOS credential-provider extensions share the vault through the app group and unlock
  with the same keychain item.
- **Apple Intelligence**: on-device Foundation Models draft a login from a sentence and turn a search request into
  filters. The security coach uses counts only and can run on Private Cloud Compute with deep reasoning when the
  managed entitlement is present and the person opts in. No password, username, site name, note, card number, or
  key reaches a model.
- **Siri AI / App Intents**: open an item, search the vault, compose a login, draft a login from a sentence,
  generate a password, lock the vault, and check vault health. Entities are indexed in Spotlight, annotated on
  screen with `appEntityIdentifier`, and carried by Handoff.
- **Design**: SF Pro for reading, Asteria Pixel for the word "Asteria" only, hierarchical SF Symbols, Liquid Glass
  chrome, light and dark, one target for iOS and macOS.

## Privacy contract

1. The master password never leaves the device and is never sent to Apple or Asteria.
2. A model never receives a password, username, site name, note, card number, one-time code, recovery key, or
   passkey private key. Capture and smart search are on-device only.
3. The security coach receives counts and finding kinds. Private Cloud Compute is opt-in and only used for that
   coach.
4. Spotlight indexes titles and sites only, and only while "Share item names with Siri and Spotlight" is on.
5. Private Cloud Compute remains off in this build until Apple grants the managed entitlement.

## Platform and versions

- iOS 27.2 and macOS 27.2, one multiplatform target, Swift 5 language mode with Swift 6 concurrency checking.
- Version 2.0, build 3. Bundle id `technology.asteria.keys`.
- iCloud container `iCloud.technology.asteria.keys`, app group `group.technology.asteria.keys`.
- The CloudKit Production schema must be deployed in the CloudKit Console before a TestFlight or App Store build
  can see records created by a Development build.

## Acceptance bar for 2.0

- Face ID / Touch ID works after one master-password unlock and survives relaunch, lock, and password change.
- A password created on one signed-in device appears on the other without a manual sync when both apps are open,
  and after the next foreground/network return when one was closed.
- Both platforms build without warnings in our sources, and the Keychain self-test passes on a simulator.
- The privacy manifest declares UserDefaults and file timestamp access.
- Both platforms archive and export locally before the owner uploads.

## Out of scope for this version

- Sharing a vault with another person (CloudKit sharing).
- A web app or browser extension.
- Importing an encrypted Bitwarden vault that is still encrypted (export it unencrypted first).
- Private Cloud Compute until Apple grants the entitlement.
