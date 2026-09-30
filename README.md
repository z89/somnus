<h1 align="center">somnus</h1>

<p align="center">lid-closed mode for macOS: keep a Mac awake with the lid shut, behind a battery safety net, from the menu bar, Control Center, Shortcuts or a cli</p>

<p align="center">
  <a href="https://github.com/z89/somnus/stargazers"><img src="https://img.shields.io/github/stars/z89/somnus?style=flat-square&color=8fd3ff&labelColor=1b1a20" alt="stars"></a>
  <a href="https://github.com/z89/somnus/commits/main"><img src="https://img.shields.io/github/last-commit/z89/somnus?style=flat-square&color=8fd3ff&labelColor=1b1a20" alt="last commit"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/z89/somnus?style=flat-square&color=8fd3ff&labelColor=1b1a20" alt="license"></a>
  <img src="https://img.shields.io/badge/macos-26%2B-8fd3ff?style=flat-square&labelColor=1b1a20" alt="macOS 26+">
  <img src="https://img.shields.io/badge/pmset-SleepDisabled-8fd3ff?style=flat-square&labelColor=1b1a20" alt="pmset SleepDisabled">
</p>

somnus keeps a Mac awake with the lid shut. it changes one macOS power setting, `SleepDisabled`, the same one `sudo pmset -a disablesleep 1` writes, through a small root helper with a fixed api, and reads the value back after every write. nothing else is changed: your sleep, display and disk timers, hibernation, standby, power nap, thermal shutdown and critical-battery sleep are all left as they are.

stay awake is only allowed while its battery safety net is running. the menu bar app watches charge and power source, warns at 20%, returns the Mac to normal sleep at 10% and, with the lid shut, asks it to sleep straight away. if the app stops reporting, after a crash, a force quit, a restart or a login launch that never happened, the helper restores normal sleep on its own once a 90-second lease runs out. turning stay awake off is always allowed.

the menu bar app, a Control Center tile, Shortcuts actions and the `somnus` cli all drive the same helper and all read the live setting, so none of them can show a mode the Mac is not in. there are no accounts, no analytics, no updater and no network client.

> tested on macOS 27.0 with Xcode 27.0 on an M5 Pro MacBook Pro. builds target macOS 26.0, and ci builds and analyzes on a macOS 26 runner. Intel Macs are untested.

## ✨ highlights

- 🌙 **stay awake with the lid shut**: the Mac keeps running on battery or ac, and the idle timer never blanks an attached display, until you turn it off or the battery net does.
- 🔋 **battery safety net**: a warning at 20%, normal sleep at 10%, each write verified and retried. if the net turned stay awake off, it turns it back on at 15%.
- 🔌 **ac-aware mode**: optional. stay awake follows the cable, on when it is plugged in and off when it is pulled.
- 🔒 **fail-safe helper**: the helper refuses to turn stay awake on without a fresh report from an armed safety net, and restores normal sleep by itself when that report stops.
- 🧭 **one source of truth**: every surface reads `SleepDisabled` live, and a change made anywhere reaches the app only after the helper has read it back.
- 🩺 **guided setup and diagnostics**: `somnus setup` walks through the approvals macOS requires, and `somnus doctor` checks the whole live installation.

## 📦 install

somnus is a source build for now. you need macOS 26 or newer, Xcode 26 or newer and a free Apple developer account to sign your own build. there is no notarized download yet.

add your Apple account in Xcode under settings, accounts, then:

```sh
git clone https://github.com/z89/somnus
cd somnus
./scripts/install.sh
```

the installer picks up your signing team when exactly one Apple Development team is in your keychain and saves it to the gitignored `Config/Local.xcconfig`. it builds and verifies every signed component, stages the new app before swapping it into `/Applications`, links the cli at `/usr/local/bin/somnus`, then starts the guided setup: helper and login item approval, battery-warning notifications and the Control Center tile. macOS still needs you to click its own approval switches; no script or app can grant those for you. the run ends with `somnus doctor`.

to update, run `git pull` and `./scripts/install.sh` again. if stay awake was on, the installer turns it off before replacing the app and turns it back on only after the new helper and battery net pass `somnus doctor`.

to install by hand, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your team, run `./scripts/build.sh --signed`, move `.build/release/Build/Products/Release/Somnus.app` to `/Applications`, then run `/Applications/Somnus.app/Contents/Helpers/somnus setup`. link the cli yourself if you want it on your path.

to remove everything, run `./scripts/uninstall.sh` from the checkout. it refuses to remove the helper until normal sleep has been read back, and it only deletes `/usr/local/bin/somnus` when that path is a symlink into `/Applications/Somnus.app`.

## 🌙 modes

there are two modes, and each surface shows the one the Mac is actually in, not the last thing you pressed.

- **stay awake** keeps the Mac running, lid open or shut, on battery or ac.
- **normal sleep** is macOS as you left it.

closing the lid still turns the built-in display off. that is hardware, and nothing overrides it.

while stay awake is on, the app holds a `PreventUserIdleDisplaySleep` assertion, plus a redundant `PreventUserIdleSystemSleep`, so the idle timer never blanks the screen. if the display assertion cannot be taken, the app reports degraded health rather than carrying on silently.

## 🎛️ menu bar and control center

the menu bar item is the everyday control. it carries the stay awake, ac-aware and open-at-login toggles, the battery thresholds, setup and repair actions, refresh status and the settings and diagnostics window.

to add the tile, open Control Center, choose edit controls, then add Somnus, Stay Awake. the tile shows the live mode, with `· AC Auto` appended while ac-aware mode is on, or one of these warnings:

| tile | what it means |
|---|---|
| `App Not Running` | no recent report from the app. turning stay awake on is blocked |
| `Unprotected` | stay awake is on but the app has stopped reporting. the helper restores normal sleep when the 90-second lease expires |
| `Safety Net Off` | the app is running but the net is not armed, usually because `hibernatemode` is not 3 or 25 |
| `Monitoring Degraded` | the app could not get a reliable battery reading |
| `Unavailable` | the helper is missing, not yet approved, unreachable or out of date |

Shortcuts can set and read stay awake. turning it on succeeds only while the app is running with its net armed, so a shortcut can never create an unprotected mode.

## 🖥️ cli reference

`somnus` talks to the helper directly for the mode and runs setup and diagnostics through the installed app.

| command | arguments | what it does |
|---|---|---|
| `somnus on` | | stay awake. refused unless the app's battery net is armed |
| `somnus off` | | normal sleep. always allowed |
| `somnus toggle` | | switch to the other mode |
| `somnus status` | | mode, helper, app, safety net, monitoring, ac-aware, power source, charging and battery, as `key: value` lines |
| `somnus why` | | every process holding an assertion against sleep, somnus included, as pid, process, type and detail. kernel assertions have no owning process and are not listed |
| `somnus setup` | `--repair` | guided approvals. `--repair` re-registers the helper after an update or version mismatch |
| `somnus doctor` | | checks the app, helper, login item and live battery protection. notification and tile problems are warnings |
| `somnus help` | | usage, also `-h` and `--help` |
| `somnus --version` | | version and build, also `-v` |

exit codes are `0` for success, `1` when a read fails or `setup` or `doctor` reports a problem, `2` when the helper is unreachable, refuses the request or fails the read, and `64` for a usage error. `somnus status` still prints everything it could read when the helper is missing.

## ⚙️ settings

open settings and diagnostics from the somnus menu.

- **open at login**: setup waits until macOS has actually approved the login item, because a login item that was only requested does not protect you after a restart.
- **warn at** and **turn stay awake off at**: 20% and 10% by default. the off threshold can be set from 5% to 50%, and the warning always sits above it.
- **automatic restore**: after the net turns stay awake off, somnus turns it back on at the off threshold plus 5%, charging or not. an explicit off, even a redundant one, cancels the restore, and a pending restore never survives an app restart.
- **ac-aware mode**: off by default.
- **system integration**: a short health summary for the helper, notifications and the tile, with repair and service removal under advanced.

quitting somnus while stay awake is on asks you to return to normal sleep first. a force quit cannot be intercepted, so the helper lets the app's 90-second lease expire and restores normal sleep itself.

## 🛡️ safety

the helper checks every caller's code signature, bundle id and user before it answers, runs `pmset` with fixed arguments and a timeout, and reads every write back. an unreliable battery reading disarms protection and retries every minute instead of assuming the Mac has no battery.

on battery, stay awake holds exactly as it does on ac, and the net is what ends it. with the lid shut, the net also asks the Mac to sleep as soon as it turns stay awake off; with the lid open, it only changes the mode.

a Mac with its lid shut still makes heat. give it a hard surface and some air, never a bag, and do not rely on somnus for anything that cannot survive an unexpected shutdown.

if somnus cannot answer, reset the setting yourself:

```sh
sudo pmset -a disablesleep 0
pmset -g | grep SleepDisabled   # expect 0, or no line at all
```

## ✅ requirements

- macOS 26 or newer.
- Xcode 26 or newer, and a free Apple developer account for signing.
- an administrator account, once, to approve the helper.

## 🩺 troubleshooting

if the tile says unavailable, choose **refresh status** in the somnus menu. if `somnus doctor` still reports a helper problem, run `somnus setup --repair`; a reboot should not be needed.

if the tile says app not running or unprotected, open somnus and wait for `somnus status` to show `app_running: yes`. after a crash the helper restores normal sleep when the lease expires, and the tile catches up the next time macOS redraws it.

if monitoring is degraded, open the lid and plug the power in and out to get a fresh power event. if it stays degraded, run `somnus off` and restart the app. do not force quit it while stay awake is on.

if the mode changed on its own, ac-aware mode is probably on. the tile shows `· AC Auto` and `somnus status` shows `ac_aware_mode: yes`.

if the safety net is off, check `pmset -g | grep hibernatemode`. the net needs 3 or 25, which is what a Mac ships with, and somnus never changes it.

## 📚 documentation

- [how it is built](docs/architecture.md): the components, the privileged boundary, the power engine, data and logs, and the release checks.
- [changelog](CHANGELOG.md): what each release contains.
- [security policy](SECURITY.md): how to report a vulnerability privately.

## 📄 license

mit
