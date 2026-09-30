# changelog

## 0.1.0

the first public release.

- stay awake keeps your macbook running with the lid closed, on battery or plugged in. normal sleep puts things back. somnus only changes `SleepDisabled` and leaves every other power setting alone.
- the menu bar app, a Control Center tile, Shortcuts and the `somnus` cli all use the same root helper. the helper checks who's calling, runs fixed `pmset` commands with a timeout and reads every change back.
- the battery safety net warns you at 20% and turns stay awake off at 10%. with the lid closed it also puts the macbook to sleep. if the net turned stay awake off, it turns it back on 5% above the off level. turning stay awake off yourself, or restarting the app, cancels that.
- the helper won't turn stay awake on unless the app has checked in recently with its safety net armed. if the app stops checking in for 90 seconds, the helper turns stay awake off by itself. it starts at boot and restarts if it exits, so this works even if the app never opens.
- the tile tells you when something's wrong, like the app not running or the safety net being off, instead of just showing on or off.
- ac-aware mode, off by default, turns stay awake on when you plug in and off when you unplug.
- everything updates when something changes, not on a timer. the helper signals each confirmed change and every surface reads the real setting again. a five-minute check is only there as a backup.
- if somnus can't keep an external display awake or can't read the battery properly, it tells you.
- `scripts/install.sh` builds, signs, checks and installs somnus from source, then walks you through setup. when you update, it only turns stay awake back on after the new version passes its checks. `scripts/uninstall.sh` makes sure your macbook is back to normal sleep before it removes anything.
- `somnus setup` walks you through the approvals macOS asks for. `somnus doctor` checks the whole install, and `somnus why` shows what's keeping your macbook awake.
- release builds leave out Xcode's debug-only `get-task-allow` entitlement. the release check scans every published file for private paths, personal email addresses, credentials and signing files.
