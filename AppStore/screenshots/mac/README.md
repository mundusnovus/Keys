# Mac screenshots

Capture these on a Mac running macOS 27 from a **Debug** build with the demo vault. The demo uses an
isolated `KeysDemo` folder, so it never touches a real vault.

```sh
tools/build.sh mac
open -n build/DerivedData/Build/Products/Debug/Keys.app --args -demo -no-cloud
```

1. **Home**: the Asteria Keys home screen with the security card and quick actions.
2. **Item detail**: relaunch with `-demo -no-cloud -open first`, or click a recent item.
3. **Settings**: press Command-Comma or click Settings in the sidebar.

Capture the window itself, not the desktop:

```sh
# Get the window id for Keys, then capture it.
screencapture -x -o -l<windowID> AppStore/screenshots/mac/home.png
```

Recommended size: 2880×1800 (or the window's natural size at 2x). Light and dark are both acceptable; keep
all shots in the same appearance. Do not use mockups.

The agent could not create a visible Mac window in this session (the app launched without a window under the
automation host), so this folder is intentionally empty rather than filled with a misleading capture.
