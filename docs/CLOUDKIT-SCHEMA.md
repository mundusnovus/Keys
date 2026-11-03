# CloudKit schema: why the iPhone sees no vault

Keys uses two custom record types in the private database:

| Record type | Field | Type |
| --- | --- | --- |
| `Header` | `salt` | Bytes |
| | `iterations` | Int64 |
| | `wrappedKey` | Bytes |
| | `recoveryWrap` | Bytes |
| | `vaultID` | String |
| | `revised` | Date/Time |
| `Item` | `ciphertext` | Bytes |
| | `revision` | Date/Time |

They live in the custom zone `KeysVault`, container `iCloud.technology.asteria.keys`.

## The two environments

| Build | CloudKit environment |
| --- | --- |
| Xcode **Debug** | Development |
| TestFlight / App Store | Production |

They are separate databases. A vault created by a Debug Mac is in Development. A TestFlight iPhone looks in
Production and finds no header, so it offers "Create your vault". If it creates one, the app then tries to
create the `Header` type in Production and fails with:

> Cannot create new type Header in production schema

That is the error in the 2 November report. It is not a sync bug in the app; the two builds are looking at
different databases, and the Production database has no schema.

## Fix for the current iPhone + Mac

1. **Deploy the schema.** On the Mac, run a **Debug** build, unlock the vault, and sync once so the `Header`
   and `Item` types exist in Development. In [CloudKit Console](https://icloud.developer.apple.com/), choose
   container `iCloud.technology.asteria.keys` → **Development** → Schema → **Deploy Schema to Production**.
   Confirm both `Header` and `Item` appear under Production.
2. **Put the Mac on the same environment.** Install the TestFlight build on the Mac (or run the iPhone from
   Xcode Debug instead). Open it, unlock the existing vault, and wait for "Synced". The Mac's header is now in
   Production.
3. **Do not make a second vault on the iPhone.** If the iPhone already created a local vault, open
   Settings → Security → **Erase This Device's Vault**, then relaunch. It should now see the Production header
   and show the lock screen. Unlock with the Mac's master password. The full vault downloads with a fresh
   change token.
4. If the iPhone shows the mismatch screen instead, choose **Use iCloud Vault**; it keeps the iCloud copy and
   discards the device-only copy.

## Why the app no longer silently offers a new vault

`CloudSync.lookupHeader()` now separates three cases:

- **found**: an iCloud vault exists; show the lock screen.
- **absent**: the `Header` type exists and has no record; this is a genuinely new account, so setup is allowed.
- **unavailable**: iCloud could not be read, including a missing Production schema. Setup is **blocked** and
  the app offers "Try Again" or an explicit "Create a vault on this device" choice. It never forks the vault
  by accident.

## One command, if you have a management token

```sh
xcrun cktool save-token --type management   # paste the CloudKit Console token once
tools/cloudkit-schema.sh                    # export Development, import to Production
```

`tools/cloudkit-schema.sh` copies the current Development schema, validates it, and imports it into
Production. It never deletes data. Without a token, use the Console button above.

## Verifying

```sh
tools/cloudkit-schema.sh
xcrun cktool export-schema --team-id KZFR2T5L2A \
  --container-id iCloud.technology.asteria.keys --environment production
```

After deploying, install the same TestFlight build on both devices, create a login on one, and confirm it on
the other. A Debug Mac and a TestFlight iPhone will still not see each other; that is expected.
