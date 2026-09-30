# changelog

## 0.1.0, first public release

- stay awake keeps a Mac running with the lid shut, on battery as well as
  ac, by writing `SleepDisabled` through a root helper. normal sleep puts it
  back. no other power setting is changed.

- one helper serves every surface: the menu bar app, a Control Center tile,
  Shortcuts actions and the `somnus` cli. the helper checks each caller's
  signature, bundle id and user, runs fixed `pmset` commands with timeouts
  and reads every write back.

- the battery safety net in the app warns at 20% and turns stay awake off at
  10%, verified and retried, and asks a lid-closed Mac to sleep straight
  away. when the net was what turned stay awake off, it turns it back on at
  the off threshold plus 5%. an explicit off, even a redundant one, cancels
  that restore, and a pending restore never survives an app restart.

- the helper refuses to turn stay awake on without a fresh heartbeat from an
  armed safety net, and restores normal sleep by itself when that 90-second
  lease expires. the tile reports app not running, unprotected, safety net
  off, monitoring degraded and unavailable instead of a plain on or off.

- ac-aware mode, off by default, lets the power cable drive stay awake.

- the mode is event driven. every confirmed write sends a payload-free
  signal, and the app re-reads the live setting, reconciles its idle
  assertions and reloads the tile. a five-minute evaluation remains only as
  a fallback.

- display-assertion and battery-read failures surface as degraded health. a
  valid display assertion is kept when only the redundant system assertion
  fails.

- `scripts/install.sh` builds, signs, verifies and installs from source,
  preserves a running stay awake across an update only once the new safety
  net passes diagnostics, and guides the approvals macOS requires.
  `scripts/uninstall.sh` confirms normal sleep before it unregisters
  services or deletes the exact app and cli paths.

- `somnus setup` walks through helper, login item, notification and tile
  setup, and waits for macOS to approve the login item before calling
  battery protection ready. `somnus doctor` checks the live installation,
  and `somnus why` lists what is holding the Mac awake.

- release builds leave out Xcode's debug-only `get-task-allow` entitlement,
  and signing auto-detection reads the certificate's real team id. the
  release check scans every publishable file for private paths, personal
  email addresses, common credential formats and signing artifacts.
