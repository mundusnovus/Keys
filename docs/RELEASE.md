# Releasing Asteria Keys 2.0

The app is archived and exported locally by the agent on 2 November 2026 (build 3). Uploading, TestFlight, and
the App Store listing are the owner's steps.

## Before every upload

1. Bump `CURRENT_PROJECT_VERSION` in the **Keys**, **KeysKit**, **KeysFill**, **KeysFillMac**, and **KeysTests**
   targets. Keep the app and both extensions equal, or App Store validation warns and the App Review build can
   behave differently.
2. `tools/check.sh` must print **All checks passed.**
3. Run `tools/archive.sh ios` and `tools/archive.sh mac`. Both must print **EXPORT SUCCEEDED** and produce
   `build/export-ios/Keys.ipa` and `build/export-mac/Keys.pkg`.
4. Open the archive's `Products/Applications/Keys.app`: it must exist and the archive's
   `ApplicationProperties:ApplicationPath` must be `Applications/Keys.app`.
5. Confirm the exported iOS `Keys.ipa` contains `Payload/Keys.app/PrivacyInfo.xcprivacy` and that its profile
   says `aps-environment = production`. The Mac package's `DistributionSummary.plist` must say
   `com.apple.developer.aps-environment = production` and `icloud-container-environment = Production`.

## CloudKit Production schema (required for TestFlight and the App Store)

A development build creates the `Header` and `Item` record types in the Development environment. A
TestFlight/App Store build uses Production and cannot see them until the schema is deployed.

1. Run a Debug build on a device signed in to the owner's iCloud account. Create a vault and one item.
2. In the CloudKit Console, select container `iCloud.technology.asteria.keys`.
3. Development → Schema → **Deploy Schema to Production**.
4. Install the TestFlight build on two devices and verify a new item travels both ways.

The `vaultID` field on `Header` is new in 2.0. Deploy the schema **before** the first 2.0 TestFlight.

## Face ID / Touch ID checklist

- Create a vault, unlock once, enable Face ID/Touch ID, lock, unlock with biometrics.
- Relaunch and repeat.
- Change the master password, lock, unlock with biometrics; the keychain item must still work.
- Disable and re-enable biometrics; the toggle must reflect the real keychain state (`Stored key` = Ready).
- With the device passcode removed, the toggle must explain that a passcode is required.

## Two-device sync checklist

- Same iCloud account on an iPhone and a Mac. Both apps open.
- Create a login on the iPhone; the Mac shows it after its next foreground or within 45 seconds while open.
- Edit the same item offline on both, reconnect; the newer secret wins and the older is kept as
  "Conflict · <title>".
- Delete on one device; the other removes it. An edit newer than the last sync wins over an older deletion.
- Erase the local vault on one device, relaunch, sign in; the full vault returns (change token was reset).

## Screenshots

- `AppStore/screenshots/iphone/` has 6.9-inch captures (1320×2868).
- `AppStore/screenshots/ipad/` has 13-inch captures (2064×2752).
- `AppStore/screenshots/mac/` is **empty**; capture three Mac screens before submitting. Steps are in its
  README. The agent could not create a visible Mac window under the automation host.

## App Review

`AppStore/review-notes.md` has the six answers and a shot list. The recordings must be made on physical
hardware. Do not paste the answer until the recording exists.

## Upload

Ask the owner before uploading. The owner does the App Store Connect upload, TestFlight, and submission.
