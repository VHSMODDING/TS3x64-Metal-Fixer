
# TS3 Mac Fixer

A macOS tool for applying fixes to your own installation of **The Sims 3 64-bit & Metal**. The app supports Apple Silicon and Intel Macs running macOS 12 or later.

## Installation and use

1. Download the DMG from Releases, open it and drag TS3 Mac Fixer into Applications.
2. The first time, right-click the app and choose **Open**.
3. Let the app detect the game, or use **Browse** to select `Sims3Launcher.app` or the game's inner `The Sims 3.app`. The app searches Applications subfolders (including `EA Games`) and uses Spotlight to find indexed installations elsewhere.
4. Select the fixes you want, click **Apply**, then restart the game. Launch the game once before applying package fixes so that its Documents folder exists.
5. Use **Revert all** to remove the fixes and restore the backed-up native game files.

With the **Buggy launcher** fix applied, start the launcher from the EA app whenever you want to install a `.Sims3Pack`. The game only accepts an install request while it can see the EA session, and that session reaches it through the launcher the EA app started. Everything else in the launcher works however you start it.

## Important – Please read before applying fixes

> [!WARNING]
> Some fixes may be incompatible with Tiny UI Fix or other third-party mods.
> You do not need to enable every available fix or reorganize your entire Mods folder.
> Choose only the options that suit your setup and needs.

The fixes work well on my personal setup, a Mac with an Apple M1 Pro and 32 GB of RAM. I mainly use the standard fixes alongside several NRaas mods, including PortraitPanel and Relativity etc.

However, every game installation, hardware configuration and mod collection is different. Compatibility with every existing mod cannot be guaranteed.

If you experience crashes, graphical glitches, performance issues or unexpected behavior:

- Disable individual fixes to identify potential conflicts.
- Review or adjust your installed mods if necessary.
- If you use Tiny UI Fix, follow the compatibility instructions provided in the Ocean + insects clicking section.
- Use **Revert all** if you need to restore the original game files.

**Remember that all fixes are optional. More fixes do not necessarily mean better performance or stability.**

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
- **Buggy EA eyelashes** removes the broken EA eyelash meshes with a default replacement installed in `Mods/Overrides`. Credit: [Slamyy](https://modthesims.info/m/10188588).

### Shaders

- **Red pools fix** corrects the red/pink appearance of pool water.
- **Pink flash fix** (beta) patches the affected shader.
- **Flickering frosted windows** stops community building ("rabbit hole") windows from flickering in winter. The frosted-glass shaders are drawn opaque (frosted glass is already 95% opaque), which removes the order-dependent transparency blending that flickers on Metal. Frost and snow stay visible.

Shader fixes are applied only when the existing bytes match the expected game version; otherwise the file is left untouched.

### Graphics settings

- **Recommended graphics settings for Apple Silicon** edits the game's `GraphicsRules.sgr`: CPU level set to the highest tier, shadow maps 4096 instead of 2048, texture size threshold 4096, larger intermediate render textures (512/1024), more detailed Sim textures (2048, 2048, 1024, 512), a higher nearby object detail limit (400) and a resource memory cache of about 3.9 GB instead of 200 MB (`MemCacheBudgetValue` 4147483648, the largest value commonly used on Windows; the setting is a 32-bit number, so larger values such as 6 GB are truncated). This keeps more game resources in memory and reduces reloading when moving the camera or changing lots. For the Sim textures and object detail, set **Sim quality to Very High** in the game options.
- **Recommended performance settings for Apple Silicon** edits the game's `Sims3.ini`: more processing time per frame for the simulation, background jobs, resource loading and texture compositing (`[Timeslices]`: SimService 20,20,40,75; JobManager 15,15,35,60; ResourceSystem and TextureCompositor 20,20,50,100, instead of 10,10,25,50), and a resource memory limit of about 3.9 GB (`MemoryUsageLimit` 4176855695, 20 MB by default). This is the configuration counterpart of Smooth Patch's native part, which does not exist on Mac.

Each settings change is applied only if the file contains the expected original text, and the original file is backed up and restored by **Revert all**.

### Launcher

- **Buggy launcher** repairs The Sims 3 Launcher itself (`Sims3Launcher.app`), which EA last built against macOS 10.14. A library injected into the launcher fixes five defects:
  - *Crash when opening Downloads, Uploads or Installed Content.* The launcher's table data source encodes each row's thumbnail with the legacy, non-keyed `NSArchiver`. Since macOS 11, `NSImage` can no longer encode that way and raises an uncaught Objective-C exception while the table is drawing, which kills the app. That archive is only ever unarchived by the launcher's own cells a moment later, so the fix passes the image through directly instead of encoding it.
  - *"Install" and "Uninstall" do nothing.* To install or remove a `.Sims3Pack`, the launcher relaunches the game with `-ccinstall` / `-ccuninstall` through `posix_spawn`, and the game refuses those parameters unless it can see the EA session: it hands them to the EA app through an `origin2://game/launch/` URL and exits with code 100010, the EA app passes them back to `Sims3Launcher.app`, which ignores them, and nothing is installed. The EA app gives that session to the launcher as environment variables (`EALicenseToken`, `EALaunchCode`, `EARtPLaunchCode`, `EALsxPort`), and the game inherits them from the launcher — which is why **Play** has always worked. The fix keeps that inheritance intact for the install relaunch, and writes the file list to a copy the launcher cannot delete before the game reads it. When the launcher was not started by the EA app there is no session to inherit, so the game is relaunched through LaunchServices instead, which at least starts it.

    Because the session comes from the EA app, **start the launcher from the EA app when you want to install a `.Sims3Pack`**. Started from the Finder it has no session to pass on, and the game will refuse the install.
  - *Warnings shown as raw keys,* such as `Sims3Launcher/Strings/kWarn_VerifyEPDependenciesFail:Text`. Twenty-three strings were never shipped in the Mac `Localizable.strings`: the two dependency warnings and every "requires this pack" line. The fix supplies them in English and French, so a pack with missing dependencies now explains that an expansion or stuff pack is missing and that the content is installed anyway.
  - *"Show file" buttons do nothing.* `NSWorkspace selectFile:inFileViewerRootedAtPath:` reveals a file through an Apple event to the Finder, which fails silently without Automation permission. The fix uses `activateFileViewerSelectingURLs:` instead, and falls back to opening the current tab's folder (`Downloads`, `Exports`, `Library`) when the launcher cannot resolve the file's path.
  - *Crash on quit.* The launcher's `UpdateBusinessLogic:` timer keeps firing during `[NSApplication terminate:]`, after its C++ host has been torn down. The timer is stopped as soon as quitting starts.

  The fix contains no hard-coded addresses and no assumptions about paths: everything goes through the Objective-C runtime and dyld interposing, and the launcher and game are located from the bundle you select. It therefore works on any Mac and with the game installed anywhere, whatever the launcher's language. The launcher's original binary and code signature are backed up and restored by **Revert all**. Applying it re-signs `Sims3Launcher.app` ad hoc, which drops EA's keychain access group; the Exchange services that used it have been shut down for years. What the fix did is logged to `~/Library/Logs/TS3LauncherFix.log`.

## Build

On macOS with the Command Line Tools installed, run `./scripts/build.sh`. The script builds a universal app, packages the supplied resources, signs it ad hoc and creates `dist/TS3 Mac Fixer.dmg`. The script also compiles the native libraries injected into the game (`assets/libts3fix.dylib`, from `dylib/`) and into the launcher (`assets/libts3launcherfix.dylib`, from `dylib-launcher/`), both x86_64 because the game and the launcher run under Rosetta. Signing is ad hoc and the app is not notarized by this build script.

This project is not affiliated with Electronic Arts. The Sims is a trademark of Electronic Arts.

## License

The project's original source code is licensed under the [MIT License](LICENSE), copyright © 2026 VHSmodding. Retain the copyright and license notice when redistributing it. Third-party code and bundled assets are subject to their respective authors' terms; the project license does not override them. Fishhook is distributed under its own [MIT license](dylib/FISHHOOK-LICENSE.txt).