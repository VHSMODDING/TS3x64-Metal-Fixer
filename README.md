# TS3 Mac Fixer

A macOS tool for applying fixes to your own installation of **The Sims 3 64-bit & Metal**. The app supports Apple Silicon and Intel Macs running macOS 12 or later.

## Installation and use

1. Download the DMG from Releases, open it and drag TS3 Mac Fixer into Applications.
2. The first time, right-click the app and choose **Open**.
3. Let the app detect the game, or use **Browse** to select `Sims3Launcher.app` or the game's inner `The Sims 3.app`. The app searches Applications subfolders (including `EA Games`) and uses Spotlight to find indexed installations elsewhere.
4. Select the fixes you want, click **Apply**, then restart the game. Launch the game once before applying package fixes so that its Documents folder exists.
5. Use **Revert all** to remove the fixes and restore the backed-up native game files.

## Included fixes

### Display (native)

- **Native macOS resolutions** adds display sizes such as 1512×982 and 1728×1117, including Apple Silicon screen sizes.
- **Fullscreen** makes the game window cover the display.
- **Anisotropic filtering** (beta) sharpens ground textures viewed at an angle.
- **Triple buffering** (beta) aims to make rendering smoother.
- **Disappearing terrain paint** keeps lot terrain paint visible while painting. On Mac, after each brush stroke the engine uploads a lot paint weight map that contains only the current stroke, so earlier paint vanished and the world ground showed through until the save was reloaded. The fix keeps a copy of the lot's paint weights and merges each upload with it: painted points of the upload are used, empty points keep the existing paint. Limitation: erased or undone paint stays visible until the save is reloaded (the save itself is correct).
- **Walls holed by snowy roads** stops walls from showing the road behind them in winter. On Metal, the game draws an invisible depth pre-pass for snow-covered ground and roads at the wrong depth, so walls behind which a snowy road passes are not drawn. The fix skips only that pre-pass in the on-screen image. Snow and shadows are still drawn normally.

### Mods (packages)

- **Ocean + insects clicking** restores interaction with the ocean and helps select insects, nanites and sea life. This is a package installed in the game's `Mods/Overrides` folder (migrated from `Packages` when applying). It replaces `UI.dll` and can conflict with other mods that do the same. If using Tiny UI Fix, install this fix first and then run or regenerate Tiny UI Fix. Remove older OceanPickFix or TS3MacInsectPick packages.
- **Smooth Patch** installs the included Smooth Patch package for smoother gameplay. Credit: [LazyDuchess](https://modthesims.info/m/10124945).
- **SF Font Bold** installs a macOS-style font override.

### Shaders

- **Red pools fix** corrects the red/pink appearance of pool water.
- **Pink flash fix** (beta) patches the affected shader.
- **Flickering frosted windows** stops community building ("rabbit hole") windows from flickering in winter. The frosted-glass shaders are drawn opaque (frosted glass is already 95% opaque), which removes the order-dependent transparency blending that flickers on Metal. Frost and snow stay visible.

Shader fixes are applied only when the existing bytes match the expected game version; otherwise the file is left untouched.

### Graphics settings

- **Recommended graphics settings for Apple Silicon** edits the game's `GraphicsRules.sgr`: CPU level set to the highest tier, shadow maps 4096 instead of 2048, texture size threshold 4096, larger intermediate render textures (512/1024), more detailed Sim textures (2048, 2048, 1024, 512), a higher nearby object detail limit (400) and a resource memory cache of about 3.9 GB instead of 200 MB (`MemCacheBudgetValue` 4147483648, the largest value commonly used on Windows; the setting is a 32-bit number, so larger values such as 6 GB are truncated). This keeps more game resources in memory and reduces reloading when moving the camera or changing lots. For the Sim textures and object detail, set **Sim quality to Very High** in the game options.
- **Recommended performance settings for Apple Silicon** edits the game's `Sims3.ini`: more processing time per frame for the simulation, background jobs, resource loading and texture compositing (`[Timeslices]`: SimService 20,20,40,75; JobManager 15,15,35,60; ResourceSystem and TextureCompositor 20,20,50,100, instead of 10,10,25,50), and a 512 MB resource memory (`MemoryUsageLimit`, 20 MB by default). This is the configuration counterpart of Smooth Patch's native part, which does not exist on Mac.

Each settings change is applied only if the file contains the expected original text, and the original file is backed up and restored by **Revert all**.

The app can create the standard Mods folders and `Resource.cfg` when necessary. Existing Resource.cfg rules are preserved; missing root Packages or Overrides rules are appended, with a backup. Overrides priority does not necessarily exceed other custom priorities. Its log reports what it detected and applied. Native fixes modify and ad-hoc sign your own game installation; the tool stores backups (game binary, shaders, graphics settings) in `~/Library/Application Support/TS3MacFixes`.

## Build

On macOS with the Command Line Tools installed, run `./scripts/build.sh`. The script builds a universal app, packages the supplied resources, signs it ad hoc and creates `dist/TS3 Mac Fixer.dmg`. The script also compiles the native library injected into the game (`assets/libts3fix.dylib`, x86_64 because the game runs under Rosetta) from the sources in `dylib/`. Signing is ad hoc and the app is not notarized by this build script.

This project is not affiliated with Electronic Arts. The Sims is a trademark of Electronic Arts.

## License

The project's original source code is licensed under the [MIT License](LICENSE), copyright © 2026 VHSmodding. Retain the copyright and license notice when redistributing it. Third-party code and bundled assets are subject to their respective authors' terms; the project license does not override them. Fishhook is distributed under its own [MIT license](dylib/FISHHOOK-LICENSE.txt).
