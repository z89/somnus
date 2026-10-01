<h1 align="center">somnus</h1>

<p align="center">
  <img src="https://img.shields.io/badge/macos-26%2B-c4a7ff?style=flat-square&labelColor=1b1a20" alt="macOS 26+">
  <img src="https://img.shields.io/badge/pmset-SleepDisabled-c4a7ff?style=flat-square&labelColor=1b1a20" alt="pmset SleepDisabled">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-c4a7ff?style=flat-square&labelColor=1b1a20" alt="license MIT"></a>
</p>

somnus keeps your macbook awake with the lid closed. turn it on from the menu bar, Control Center, Shortcuts or the terminal, and your macbook keeps running until you turn it off again.

a macbook left awake can drain its battery, so somnus comes with a safety net. it warns you at 20% and lets the macbook sleep again at 10%. if the somnus app crashes or stops running, a small helper notices within 90 seconds and turns stay awake off for you.

somnus runs entirely on your macbook, with no accounts, no tracking and no internet connection.

> tested on macOS 27.0 with Xcode 27.0 on an M5 Pro macbook pro. somnus needs macOS 26 or newer. Intel macbooks haven't been tested.

## ✨ highlights

- 🌙 **stays awake with the lid shut**, on battery or plugged in, until you turn it off.
- 🔋 **a battery safety net** that warns you at 20% and lets the macbook sleep at 10%. if the net turned stay awake off, it turns it back on at 15%.
- 🔌 **an optional ac-aware mode** that turns stay awake on when you plug in and off when you unplug.
- 🔒 **a helper that fails safe**. it won't turn stay awake on without the safety net, and it turns it off if the app goes quiet.
- 🧭 **the same answer everywhere**. the menu bar, the tile, Shortcuts and the cli all read the real setting, so they always agree.
- 🩺 **guided setup**. `somnus setup` walks you through the approvals macOS asks for, and `somnus doctor` checks that everything works.

## 📦 install

there's no download yet, so you build somnus yourself. you need macOS 26 or newer, Xcode 26 or newer, and a free Apple developer account so Xcode can sign the build.

add your Apple account in Xcode's settings under accounts, then run

```sh
git clone https://github.com/z89/somnus
cd somnus
./scripts/install.sh
```

the installer finds your signing team, builds and checks the app, moves it into `/Applications` and adds the `somnus` command to `/usr/local/bin`. then it walks you through setup. macOS asks you to approve the helper, the login item and notifications, and you can add the Control Center tile. you have to flip those switches yourself, because macOS doesn't let any app do it for you. at the end the installer runs `somnus doctor` to check everything.

to update, pull the latest code and run the installer again. if stay awake was on, the installer turns it off while it swaps the app, and turns it back on once the new version passes its checks.

if you'd rather install by hand, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and put your team id in it. build with `./scripts/build.sh --signed`, move `.build/release/Build/Products/Release/Somnus.app` into `/Applications` and run `/Applications/Somnus.app/Contents/Helpers/somnus setup`.

to uninstall, run `./scripts/uninstall.sh` from the repo. it makes sure your macbook is back to normal sleep before it removes anything.

## 🌙 modes

somnus has two modes. **stay awake** keeps your macbook running with the lid open or closed. **normal sleep** is your macbook behaving the way it always does.

closing the lid still turns off the built-in screen. that's the hardware, and nothing can change it. while stay awake is on, somnus also stops the idle timer from turning off an external display. if it can't, it tells you instead of failing quietly.

wherever you look, you see the mode your macbook is really in, not the last button you pressed.

## 🎛️ menu bar and control center

the menu bar icon is the main control. from there you can switch modes, turn ac-aware mode and open at login on or off, set the battery levels and open settings and diagnostics.

to add the tile, open Control Center, choose edit controls and add Stay Awake from Somnus. the tile shows the current mode, and adds `· AC Auto` when ac-aware mode is on. if something is wrong, it shows one of these instead.

| tile | what it means |
|---|---|
| `App Not Running` | the somnus app isn't running, so stay awake can't be turned on |
| `Unprotected` | stay awake is on but the app has stopped checking in. the helper turns it off within 90 seconds |
| `Safety Net Off` | the app is running but its safety net isn't armed, usually because `hibernatemode` isn't 3 or 25 |
| `Monitoring Degraded` | the app can't get a reliable battery reading |
| `Unavailable` | the helper is missing, not approved yet, not answering or out of date |

Shortcuts can turn stay awake on and off and check which mode you're in. turning it on only works while the safety net is running, the same as everywhere else.

## 🖥️ cli

the `somnus` command talks to the same helper as the app.

| command | what it does |
|---|---|
| `somnus on` | turn stay awake on. only works while the app's safety net is armed |
| `somnus off` | go back to normal sleep. always works |
| `somnus toggle` | switch to the other mode |
| `somnus status` | show the mode, the helper, the app, the safety net and the battery, one per line |
| `somnus why` | list the processes keeping your macbook awake, somnus included |
| `somnus setup` | walk through setup. add `--repair` to fix the helper after an update |
| `somnus doctor` | check that everything is installed and working |
| `somnus help` | show usage. `-h` and `--help` work too |
| `somnus --version` | show the version. `-v` works too |

`somnus` exits with 0 when it works and 1 when a read fails or `setup` or `doctor` finds a problem. it exits with 2 when the helper can't be reached or says no, and 64 when the command is wrong. `somnus status` still prints what it can when the helper is missing.

## ⚙️ settings

open settings and diagnostics from the somnus menu.

- **open at login**. somnus has to be running to protect you, so setup waits until macOS has really approved the login item.
- **battery levels**. somnus warns you at 20% and turns stay awake off at 10%. you can set the off level anywhere from 5% to 50%, and the warning always stays above it.
- **automatic restore**. if the safety net turned stay awake off, somnus turns it back on once the battery is 5% above the off level, charging or not. turning stay awake off yourself cancels this, and so does restarting the app.
- **ac-aware mode**, off by default.
- **system integration** shows whether the helper, notifications and the tile are healthy. repair and removal live under advanced.

if you quit somnus while stay awake is on, it asks you to go back to normal sleep first. a force quit skips that question, so the helper turns stay awake off by itself after 90 seconds.

## 🛡️ safety

the helper runs as root, so it's kept small and strict. it only answers signed somnus apps run by you, it only runs fixed `pmset` commands, and it checks the setting after every change.

if somnus can't get a reliable battery reading, it treats the safety net as off and tries again every minute. it never assumes your macbook has no battery.

when the safety net turns stay awake off with the lid closed, it also puts the macbook to sleep straight away. with the lid open it only switches the mode back.

a closed macbook still gets warm. keep it on a hard surface with some air around it, never in a bag, and don't rely on somnus for anything that can't handle the macbook shutting down unexpectedly.

if somnus ever stops responding, you can turn stay awake off yourself.

```sh
sudo pmset -a disablesleep 0
pmset -g | grep SleepDisabled   # should print 0, or nothing
```

## ✅ requirements

- a macbook. desktop macs have no lid or battery, so somnus has nothing to do there
- macOS 26 or newer
- Xcode 26 or newer, and a free Apple developer account
- an admin account, once, to approve the helper

## 🩺 troubleshooting

- **the tile says unavailable**. choose refresh status in the somnus menu. if `somnus doctor` still shows a helper problem, run `somnus setup --repair`. you shouldn't need to restart.
- **the tile says app not running or unprotected**. open somnus and wait until `somnus status` shows `app_running: yes`. the tile catches up the next time macOS redraws it.
- **monitoring is degraded**. open the lid, then unplug and replug the power. if that doesn't clear it, run `somnus off` and restart the app. don't force quit it while stay awake is on.
- **the mode changed by itself**. ac-aware mode is probably on. the tile shows `· AC Auto` and `somnus status` shows `ac_aware_mode: yes`.
- **the safety net is off**. run `pmset -g | grep hibernatemode`. somnus needs it to be 3 or 25, which is how macbooks ship, and it never changes it.

## 📚 documentation

- [how it's built](docs/architecture.md) covers the parts, the helper, the power engine, logs and release checks.
- [changelog](CHANGELOG.md) lists what's in each release.

## 📄 license

MIT
