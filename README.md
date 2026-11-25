# TS3 Mac Fixer

A macOS tool for applying fixes to your own installation of **The Sims 3 64-bit & Metal**. The app supports Apple Silicon and Intel Macs running macOS 12 or later.

## Installation and use

1. Download the DMG from Releases, open it and drag TS3 Mac Fixer into Applications.
2. The first time, right-click the app and choose **Open**.
3. Let the app detect the game, or use **Browse** to select `Sims3Launcher.app` or the game's inner `The Sims 3.app`. The app searches Applications subfolders (including `EA Games`) and uses Spotlight to find indexed installations elsewhere.
4. Select the fixes you want, click **Apply**, then restart the game. Launch the game once before applying package fixes so that its Documents folder exists.
5. Use **Revert all** to remove the fixes and restore the backed-up native game files.

## Included fixes

- **Native macOS resolutions** adds display sizes such as 1512×982 and 1728×1117, including Apple Silicon screen sizes.
- **Fullscreen** makes the game window cover the display.
- **Anisotropic filtering** (beta) sharpens ground textures viewed at an angle.
- **Triple buffering** (beta) aims to make rendering smoother.
- **Ocean + insects clicking** restores interaction with the ocean and helps select insects, nanites and sea life. This is a package installed in the game's `Mods/Packages` folder. It replaces `UI.dll` and can conflict with other mods that do the same. If using Tiny UI Fix, install this fix first and then run or regenerate Tiny UI Fix. Remove older OceanPickFix or TS3MacInsectPick packages.
- **Smooth Patch** installs the included Smooth Patch package for smoother gameplay. Credit: [LazyDuchess](https://modthesims.info/m/10124945).
- **SF Font Bold** installs a macOS-style font override.
- **Red pools fix** corrects the red/pink appearance of pool water.
- **Pink flash fix** (beta) patches the affected shader. Shader fixes are applied only when the existing bytes match the expected game version.

The app can create the standard Mods folders and `Resource.cfg` when necessary. Its log reports what it detected and applied. Native fixes modify and ad-hoc sign your own game installation; the tool stores backups in `~/Library/Application Support/TS3MacFixes`.

## Build

On macOS with the Command Line Tools installed, run `./scripts/build.sh`. The script builds a universal app, packages the supplied resources, signs it ad hoc and creates `dist/TS3 Mac Fixer.dmg`. The prebuilt `assets/libts3fix.dylib` is used by the build; the available native source is in `dylib/`. Signing is ad hoc and the app is not notarized by this build script.

This project is not affiliated with Electronic Arts. The Sims is a trademark of Electronic Arts.
