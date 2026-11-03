# Asteria Keys 2.0 — App Review notes

> **Status: draft.** The six answers are written. The screen recordings have **not** been made by the agent;
> the owner records them on physical hardware before submission. Do not paste answer 1 until that recording
> exists.

Paste the six answers below into App Review Information › Notes for both the iOS and macOS versions. Record on
physical devices; a simulator recording is rejected.

## Demo access

Keys has no account. The DEBUG demo build opens a complete sample vault with:

- Launch arguments: `-demo -no-cloud`
- Master password: `AsteriaDemo!2026`
- To open the first item directly: `-demo -no-cloud -open first`
- To force dark appearance: add `dark`

The demo is compiled out of Release. A Release build starts at "Create your vault" and needs no credentials.

## The six answers

**1. Screen recording.** Recorded on a physical iPhone running iOS 27 and a Mac running macOS 27. Each recording
starts at launch and shows: creating a vault and saving the recovery key; adding a login; generating a password;
copying it; locking and unlocking with Face ID or Touch ID; the security review; a login saved on one device
appearing on the other through iCloud; Apple Intelligence drafting a login from a sentence; the security coach;
Siri composing a login; Settings. Keys has no account registration or login, no user-generated content shared
with other people, and no paid content.

**2. Purpose and audience.** Asteria Keys is a password manager for people who want their credentials private
and available on every Apple device. It stores logins, passkeys, one-time codes, cards, identities, Wi-Fi
passwords, and notes in an encrypted vault; syncs only ciphertext through the person's own private iCloud
database; and uses Face ID or Touch ID to unlock. It is for anyone who wants a calm, native password manager
without an Asteria account or server.

**3. How to use it.** On first launch choose a master password of at least 12 characters, then save the recovery
key shown once. Add a login with the plus button. Settings › Security turns on Face ID or Touch ID. Settings ›
iCloud Sync shows the account, last sync, and a "Sync Everything Again" action. Settings › AutoFill opens the
system AutoFill settings. Siri: "Compose a login in Asteria Keys", "Find in Asteria Keys", "Lock Asteria Keys".
Apple Intelligence features appear when Apple Intelligence is on in system Settings and the device supports it;
otherwise the same screens work with the manual fields.

**4. External services.** iCloud (CloudKit private database) stores encrypted records and syncs them between the
person's devices. Apple Foundation Models on the device draft logins and search filters. Private Cloud Compute is
off in this build; if Apple grants the managed entitlement and the person opts in, the security coach alone may
use it, with counts of findings only. There is no Asteria server, no account, no analytics, no advertising, and
no payment processing.

**5. Regional differences.** The app works the same in all regions. Apple Intelligence features depend on Apple
Intelligence availability and supported languages; the vault, sync, AutoFill, and Siri item actions do not.

**6. Regulated industry / third-party material.** Not applicable. Keys does not provide medical, financial, or
legal advice, and bundles no third-party code beyond Apple frameworks and the Asteria Pixel font.

## What to test on hardware

1. Create a vault, save the recovery key, add a login, lock, unlock with Face ID / Touch ID. Repeat after a
   relaunch and after changing the master password.
2. Sign in to the same iCloud account on an iPhone and a Mac. Create a login on one, wait for "Synced", and open
   the other. Repeat in the other direction. Turn off Wi-Fi on one device, edit, reconnect, and confirm both
   changes survive (a conflict copy is acceptable and is labelled "Conflict").
3. Turn on Keys in AutoFill and fill a password and a one-time code in Safari.
4. Speak each Siri phrase; confirm no password is spoken or shown in a dialog.
5. With Apple Intelligence on, run Capture and the security coach. Confirm the coach's "What the coach sees" card
   contains counts only.
6. Settings › Data: export a plaintext CSV to a temporary location, delete it, and confirm the warning appeared.

## Known limitations to state honestly

- Private Cloud Compute is not enabled in this build; it needs Apple's managed entitlement.
- The CloudKit Production schema must be deployed before TestFlight/App Store sync works.
- A vault created on another iCloud account is refused with a mismatch screen; it is never merged.
- The demo vault is DEBUG only and is not part of the shipping product.
