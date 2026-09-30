#!/bin/sh
# Build, safely update, and guide the one-time macOS setup.
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_product="$repo_dir/.build/release/Build/Products/Release/Somnus.app"
target_app=/Applications/Somnus.app
target_cli=/usr/local/bin/somnus
transaction_dir=
stage_app=
backup_app=
lsregister=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
caffeinate_pid=
old_was_awake=0
updating=0
safe_to_restore=1
applications_writable=0
cli_link_ready=0
cli_directory_writable=0
control_process_pattern='^/Applications/Somnus\.app/Contents/PlugIns/SomnusControl\.appex/Contents/MacOS/SomnusControl( |$)'

say() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

app_write() {
  if [ "$applications_writable" -eq 1 ]; then "$@"; else /usr/bin/sudo "$@"; fi
}

cli_write() {
  if [ "$cli_directory_writable" -eq 1 ]; then "$@"; else /usr/bin/sudo "$@"; fi
}

# Prints exactly 0 or 1. Unreadable, duplicated or malformed pmset output is
# an error, never silently interpreted as Normal Sleep.
read_sleep_disabled() {
  /usr/bin/pmset -g | /usr/bin/awk '
    /^(System-wide power settings|Currently in use):/ { valid = 1 }
    tolower($1) == "sleepdisabled" {
      if ($2 != "0" && $2 != "1") { bad = 1 }
      value = $2
      found++
    }
    END {
      if (!valid || bad || found > 1) { exit 1 }
      # macOS omits the key until it has been set; absent means the default.
      if (found == 0) { value = 0 }
      print value
    }
  '
}

# Control Center may keep an extension executable mapped after its containing
# app has been atomically replaced. That old process then talks to the new
# helper with old code and can leave the tile stuck unavailable. Terminate only
# Somnus's precisely anchored extension process; WidgetKit relaunches the newly
# registered copy on the next render.
stop_stale_control_process() {
  /usr/bin/pkill -TERM -f "$control_process_pattern" >/dev/null 2>&1 || true
  # A configured tile can make WidgetKit launch the new copy immediately, so
  # process absence is not a valid success condition here. Somnus installs no
  # termination handler in the extension, so this request retires the old copy.
  /bin/sleep 0.25
}

# Restore the old state only while the old bundle is still authoritative. The
# current helper requires a live battery guardian before accepting ON, so first
# restart the old app and wait briefly for its diagnostic to become healthy.
restore_old_state_if_safe() {
  [ "$old_was_awake" -eq 1 ] || return 0
  [ "$safe_to_restore" -eq 1 ] || return 0
  [ -x "$target_app/Contents/Helpers/somnus" ] || return 0

  /usr/bin/open "$target_app" >/dev/null 2>&1 || return 0
  restore_attempts=0
  while [ "$restore_attempts" -lt 20 ]; do
    if "$target_app/Contents/Helpers/somnus" doctor >/dev/null 2>&1; then
      "$target_app/Contents/Helpers/somnus" on >/dev/null 2>&1 || true
      return 0
    fi
    /bin/sleep 0.5
    restore_attempts=$((restore_attempts + 1))
  done
}

cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  set +e

  # A signal can arrive between the two destination renames. If the backup is
  # still present, put it back before cleaning the transaction directory. Any
  # partially placed new bundle is moved into that same private directory.
  if [ "$status" -ne 0 ] && [ "$safe_to_restore" -eq 1 ] \
      && [ -n "$backup_app" ] && [ -d "$backup_app" ]; then
    if [ -d "$target_app" ]; then
      app_write /bin/mv "$target_app" "$transaction_dir/Somnus.failed.app" >/dev/null 2>&1 || true
    fi
    app_write /bin/mv "$backup_app" "$target_app" >/dev/null 2>&1 || true
  fi

  if [ "$status" -ne 0 ]; then restore_old_state_if_safe; fi
  if [ -n "$transaction_dir" ] && [ -d "$transaction_dir" ]; then
    case "$transaction_dir" in
      /Applications/.somnus-install.*)
        # Never erase the only remaining copy of the previous app.
        if [ -z "$backup_app" ] || [ ! -d "$backup_app" ]; then
          app_write /bin/rm -rf "$transaction_dir" >/dev/null 2>&1
        else
          printf 'warning: previous Somnus.app remains recoverable at %s\n' "$backup_app" >&2
        fi
        ;;
    esac
  fi
  if [ -n "$caffeinate_pid" ]; then kill "$caffeinate_pid" >/dev/null 2>&1; fi
  exit "$status"
}
# A signal handler's `$?` is the last command's status, often 0, so each
# signal exits with its own non-zero status and cleanup runs from EXIT.
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

case "${1:-}" in
  "") ;;
  *) printf 'usage: %s\n' "$0" >&2; exit 64 ;;
esac

[ "$(/usr/bin/uname -s)" = Darwin ] || fail "Somnus can only be installed on macOS."
major=$(/usr/bin/sw_vers -productVersion | /usr/bin/awk -F. '{print $1}')
[ "$major" -ge 26 ] || fail "Somnus requires macOS 26 or newer."
for command in /usr/bin/xcodebuild /usr/bin/codesign /usr/bin/ditto /usr/bin/security \
    /usr/bin/open /usr/bin/sudo /usr/bin/caffeinate /usr/bin/osascript \
    /usr/bin/pgrep /usr/bin/pkill /usr/bin/pmset /usr/bin/mktemp \
    /usr/bin/openssl; do
  [ -x "$command" ] || fail "required command not found: $command"
done
/usr/bin/xcodebuild -version >/dev/null 2>&1 || fail "Xcode is not configured. Run xcode-select or open Xcode once."

if [ -w /Applications ]; then applications_writable=1; fi
if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then cli_directory_writable=1; fi

if [ -e "$target_app" ] && [ ! -d "$target_app" ]; then
  fail "$target_app exists but is not an app bundle; it was left untouched."
fi
if [ -e "$target_cli" ] || [ -L "$target_cli" ]; then
  [ -L "$target_cli" ] \
    || fail "$target_cli already exists and is not a symlink; it was left untouched."
  current_link=$(/usr/bin/readlink "$target_cli")
  [ "$current_link" = "$target_app/Contents/Helpers/somnus" ] \
    || fail "$target_cli is not the exact Somnus CLI link; it was left untouched."
  cli_link_ready=1
fi

# Keep an open-lid install from being interrupted by the ordinary idle timers.
# This assertion dies automatically with the script and changes no pmset value.
/usr/bin/caffeinate -dimsu -w "$$" >/dev/null 2>&1 &
caffeinate_pid=$!

if [ ! -f "$repo_dir/Config/Local.xcconfig" ]; then
  team_id=${DEVELOPMENT_TEAM:-}
  if [ -z "$team_id" ]; then
    identity_hashes=$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
      | /usr/bin/sed -n 's/^[[:space:]]*[0-9][0-9]*) \([A-F0-9][A-F0-9]*\) "Apple Development:.*"$/\1/p' \
      | /usr/bin/sort -u)
    count=$(printf '%s\n' "$identity_hashes" | /usr/bin/awk 'NF { count++ } END { print count + 0 }')
    if [ "$count" -eq 1 ]; then
      # The parentheses in an Apple Development identity label are a user or
      # certificate identifier, not necessarily the signing Team ID. Read the
      # matching valid certificate's OU field, which is the TeamIdentifier.
      identity_hash=$identity_hashes
      team_id=$(/usr/bin/security find-certificate -a -Z -c 'Apple Development' -p 2>/dev/null \
        | /usr/bin/awk -v wanted="$identity_hash" '
            /^SHA-1 hash:/ { matched = ($3 == wanted); next }
            matched && /-----BEGIN CERTIFICATE-----/ { printing = 1 }
            printing { print }
            printing && /-----END CERTIFICATE-----/ { exit }
          ' \
        | /usr/bin/openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null \
        | /usr/bin/sed -n 's/.*OU=\([A-Z0-9][A-Z0-9]*\).*/\1/p')
      [ -n "$team_id" ] \
        || fail "could not read the Team ID from the Apple Development certificate."
      say "Found one Apple Development signing team in Keychain."
    elif [ -t 0 ]; then
      say "Somnus needs the Team ID from an Apple Development certificate."
      say "Add your Apple account in Xcode > Settings > Accounts first if needed."
      printf 'Team ID: '
      IFS= read -r team_id
    else
      fail "no unique Apple Development team found; set DEVELOPMENT_TEAM and run again."
    fi
  fi
  case "$team_id" in
    ""|*[!A-Z0-9]*) fail "the signing Team ID must contain only uppercase letters and digits." ;;
  esac
  {
    printf '%s\n' '// Generated locally by scripts/install.sh; intentionally gitignored.'
    printf 'DEVELOPMENT_TEAM = %s\n' "$team_id"
  } > "$repo_dir/Config/Local.xcconfig"
  say "Saved the local signing team in Config/Local.xcconfig."
fi

say "Building a signed Somnus.app..."
"$repo_dir/scripts/build.sh" --signed
[ -d "$app_product" ] || fail "the build did not produce Somnus.app."

verify_app() {
  candidate=$1
  /usr/bin/codesign --verify --strict "$candidate"
  /usr/bin/codesign --verify --strict "$candidate/Contents/MacOS/Somnus"
  /usr/bin/codesign --verify --strict "$candidate/Contents/Helpers/somnus"
  /usr/bin/codesign --verify --strict "$candidate/Contents/MacOS/somnusd"
  /usr/bin/codesign --verify --strict "$candidate/Contents/PlugIns/SomnusControl.appex"

  for executable in \
      "$candidate/Contents/MacOS/Somnus" \
      "$candidate/Contents/Helpers/somnus" \
      "$candidate/Contents/MacOS/somnusd" \
      "$candidate/Contents/PlugIns/SomnusControl.appex"; do
    if /usr/bin/codesign -d --entitlements :- "$executable" 2>/dev/null \
        | /usr/bin/grep -q 'com.apple.security.get-task-allow'; then
      fail "Release component carries the debug-only get-task-allow entitlement: $executable"
    fi
  done
}

say "Verifying every signed component..."
verify_app "$app_product"

if [ "$applications_writable" -ne 1 ] \
    || { [ "$cli_link_ready" -ne 1 ] && [ "$cli_directory_writable" -ne 1 ]; }; then
  say "Administrator access is needed to write the system application or CLI path."
  /usr/bin/sudo -v
fi

# Root (or the current Applications owner) creates an unpredictable, private
# transaction directory on the destination volume. No pre-created path or
# symlink can redirect the privileged copy.
if [ "$applications_writable" -eq 1 ]; then
  transaction_dir=$(/usr/bin/mktemp -d /Applications/.somnus-install.XXXXXX)
else
  transaction_dir=$(/usr/bin/sudo /usr/bin/mktemp -d /Applications/.somnus-install.XXXXXX)
fi
case "$transaction_dir" in
  /Applications/.somnus-install.*) ;;
  *) fail "could not create a safe installation transaction directory." ;;
esac
stage_app="$transaction_dir/Somnus.app"
backup_app="$transaction_dir/Somnus.backup.app"

if [ -d "$target_app" ]; then
  updating=1
  if ! old_was_awake=$(read_sleep_disabled); then
    fail "could not read SleepDisabled exactly; the installed app was not changed."
  fi

  if [ "$old_was_awake" -eq 1 ]; then
    say "Temporarily returning the Mac to Normal Sleep for the update..."
    "$target_app/Contents/Helpers/somnus" off >/dev/null 2>&1 || true
    if ! still_on=$(read_sleep_disabled); then
      fail "could not verify Normal Sleep; the installed app was not changed."
    fi
    if [ "$still_on" -eq 1 ]; then
      /usr/bin/sudo /usr/bin/pmset -a disablesleep 0
    fi
    if ! still_on=$(read_sleep_disabled); then
      fail "could not verify Normal Sleep; the installed app was not changed."
    fi
    [ "$still_on" -eq 0 ] || fail "could not verify Normal Sleep; the installed app was not changed."
  fi

  /usr/bin/osascript -e 'tell application id "com.z89.somnus" to quit' >/dev/null 2>&1 || true
  attempts=0
  while /usr/bin/pgrep -f '^/Applications/Somnus.app/Contents/MacOS/Somnus$' >/dev/null 2>&1 \
      && [ "$attempts" -lt 20 ]; do
    /bin/sleep 0.25
    attempts=$((attempts + 1))
  done
  if /usr/bin/pgrep -f '^/Applications/Somnus.app/Contents/MacOS/Somnus$' >/dev/null 2>&1; then
    # A stale app snapshot can leave its quit guard open even though the live
    # setting was just verified off. At this point terminating this exact app
    # process cannot strand Stay Awake, and is safer than replacing it in use.
    /usr/bin/pkill -TERM -f '^/Applications/Somnus.app/Contents/MacOS/Somnus$' || true
    attempts=0
    while /usr/bin/pgrep -f '^/Applications/Somnus.app/Contents/MacOS/Somnus$' >/dev/null 2>&1 \
        && [ "$attempts" -lt 20 ]; do
      /bin/sleep 0.25
      attempts=$((attempts + 1))
    done
  fi
  /usr/bin/pgrep -f '^/Applications/Somnus.app/Contents/MacOS/Somnus$' >/dev/null 2>&1 \
    && fail "Somnus is still running. Quit it, then run the installer again."

  # The old app was a writer too: AC-aware policy could have raced the first
  # disarm while it was shutting down. With that writer gone, prove Normal
  # Sleep again immediately before replacing the helper's containing bundle.
  stop_stale_control_process
  if ! still_on=$(read_sleep_disabled); then
    fail "could not verify Normal Sleep after quitting Somnus; the installed app was not changed."
  fi
  if [ "$still_on" -eq 1 ]; then
    /usr/bin/sudo /usr/bin/pmset -a disablesleep 0
  fi
  if ! still_on=$(read_sleep_disabled); then
    fail "could not verify Normal Sleep after quitting Somnus; the installed app was not changed."
  fi
  [ "$still_on" -eq 0 ] \
    || fail "Normal Sleep did not remain on after quitting Somnus; the installed app was not changed."
fi

# ditto into an empty staging path, verify again, then rename on the same
# volume. Never merge a new bundle into an old one.
app_write /usr/bin/ditto "$app_product" "$stage_app"
verify_app "$stage_app"

if [ "$updating" -eq 1 ]; then
  app_write /bin/mv "$target_app" "$backup_app"
fi
if ! app_write /bin/mv "$stage_app" "$target_app"; then
  if [ "$updating" -eq 1 ] && [ -d "$backup_app" ]; then
    app_write /bin/mv "$backup_app" "$target_app" || true
  fi
  fail "could not place Somnus.app in /Applications; the previous copy was restored."
fi
safe_to_restore=0
if [ "$updating" -eq 1 ]; then
  app_write /bin/rm -rf "$backup_app"
fi

if [ "$cli_link_ready" -ne 1 ]; then
  cli_write /bin/mkdir -p /usr/local/bin
  cli_write /bin/ln -s "$target_app/Contents/Helpers/somnus" "$target_cli"
fi
if [ -x "$lsregister" ]; then "$lsregister" -f "$target_app" >/dev/null 2>&1 || true; fi
stop_stale_control_process

say "Starting the guided macOS setup..."
if [ "$updating" -eq 1 ]; then
  "$target_app/Contents/MacOS/Somnus" --somnus-setup --repair-helper \
    || fail "Somnus.app is installed, but setup did not finish. Run: somnus setup --repair"
else
  "$target_app/Contents/MacOS/Somnus" --somnus-setup \
    || fail "Somnus.app is installed, but setup did not finish. Run: somnus setup --repair"
fi

/usr/bin/open "$target_app"

# Launching an accessory app is asynchronous. Give its first heartbeat and
# safety evaluation a bounded window, then print one authoritative diagnostic.
attempts=0
while [ "$attempts" -lt 20 ]; do
  if "$target_cli" doctor >/dev/null 2>&1; then break; fi
  /bin/sleep 0.5
  attempts=$((attempts + 1))
done

say "Running final diagnostics..."
"$target_cli" doctor \
  || fail "installation completed, but diagnostics found a problem. Run: somnus doctor"

if [ "$old_was_awake" -eq 1 ]; then
  say "Restoring the Stay Awake state that was active before the update..."
  "$target_cli" on || fail "Somnus is installed and safe, but Stay Awake could not be restored. Run: somnus on"
fi

say "Somnus is installed and ready."
