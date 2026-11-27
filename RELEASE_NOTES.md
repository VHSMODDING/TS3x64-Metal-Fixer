## TS3 Mac Fixer 1.4.1

- New: **Buggy launcher** fix for The Sims 3 Launcher, which EA last built against macOS 10.14. It no longer crashes when you open Downloads, Uploads or Installed Content; **Install** and **Uninstall** install and remove `.Sims3Pack` files again; warnings are no longer shown as raw keys such as `Sims3Launcher/Strings/kWarn_VerifyEPDependenciesFail:Text` (23 strings EA never shipped on Mac are supplied in English and French); the **Show file** buttons reveal the file in the Finder; and the launcher no longer crashes on quit.
- To install a `.Sims3Pack`, start the launcher from the EA app. The game only accepts an install request when it inherits the EA session the EA app hands to the launcher.
- The fix uses no hard-coded addresses or paths, so it works on any Mac and wherever the game is installed. The launcher's original binary and signature are backed up, and **Revert all** puts them back.

## TS3 Mac Fixer 1.3.2

- New: **Buggy EA eyelashes** fix. Installs Slamyy's eyelash mesh terminator as a default replacement in `Mods/Overrides`, removing the broken EA eyelash meshes. Credit: [Slamyy](https://modthesims.info/m/10188588).
- **Recommended performance settings for Apple Silicon** now set `MemoryUsageLimit` in `Sims3.ini` to about 3.9 GB (4176855695) instead of 512 MB, matching the resource memory cache used by the graphics settings.

## TS3 Mac Fixer 1.3.1

- **Recommended graphics settings for Apple Silicon** now also raise the game's resource memory cache from 200 MB to about 3.9 GB (`MemCacheBudgetValue` in `GraphicsRules.sgr`). If the graphics settings are already applied, click **Apply** again to add it; **Revert all** restores the original value.

## TS3 Mac Fixer 1.3.0

- New: **Disappearing terrain paint** fix. Lot terrain paint no longer vanishes after each brush stroke. Erased or undone paint stays visible until the save is reloaded; the save itself is correct.
- Includes the recommended graphics and performance settings for Apple Silicon, the snowy-road wall fix and the frosted window flicker fix.

Download the DMG, drag the app to Applications, and right-click Open on first launch. The app is ad-hoc signed and is not notarized. If using Tiny UI Fix, install the ocean and insect fix before regenerating Tiny UI Fix.
