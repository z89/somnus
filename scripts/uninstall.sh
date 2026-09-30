#!/bin/sh
# Safely disarm Somnus before removing its app bundle and CLI link.
set -eu

target_app=/Applications/Somnus.app
target_cli=/usr/local/bin/somnus
assume_yes=0
applications_writable=0
cli_directory_writable=0
control_process_pattern='^/Applications/Somnus\.app/Contents/PlugIns/SomnusControl\.appex/Contents/MacOS/SomnusControl( |$)'

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

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

case "${1:-}" in
  "") ;;
  --yes) assume_yes=1 ;;
  *) printf 'usage: %s [--yes]\n' "$0" >&2; exit 64 ;;
esac

[ -d "$target_app" ] || fail "Somnus.app is not installed in /Applications."
if [ -w /Applications ]; then applications_writable=1; fi
if [ -w /usr/local/bin ]; then cli_directory_writable=1; fi

if [ "$assume_yes" -ne 1 ]; then
  [ -t 0 ] || fail "confirmation requires a terminal; rerun with --yes for unattended removal."
  printf 'Turn Stay Awake off and remove Somnus.app, its helper, login item, CLI link, and settings? [y/N] '
  IFS= read -r answer
  case "$answer" in y|Y|yes|YES) ;; *) printf '%s\n' 'Cancelled.'; exit 0 ;; esac
fi

# Stop the ordinary app before service removal. Otherwise AC-aware policy could
# turn Stay Awake back on between the one-shot disarm and unregister calls.
"$target_app/Contents/Helpers/somnus" off >/dev/null 2>&1 || true
/usr/bin/osascript -e 'tell application id "com.z89.somnus" to quit' >/dev/null 2>&1 || true
attempts=0
while /usr/bin/pgrep -f '^/Applications/Somnus.app/Contents/MacOS/Somnus$' >/dev/null 2>&1 \
    && [ "$attempts" -lt 20 ]; do
  /bin/sleep 0.25
  attempts=$((attempts + 1))
done
if /usr/bin/pgrep -f '^/Applications/Somnus.app/Contents/MacOS/Somnus$' >/dev/null 2>&1; then
  if ! before_kill=$(read_sleep_disabled) || [ "$before_kill" -ne 0 ]; then
    fail "Somnus is still running and Normal Sleep is not verified. Finish its quit prompt, then run this script again."
  fi
  /usr/bin/pkill -TERM -f '^/Applications/Somnus.app/Contents/MacOS/Somnus$' || true
  attempts=0
  while /usr/bin/pgrep -f '^/Applications/Somnus.app/Contents/MacOS/Somnus$' >/dev/null 2>&1 \
      && [ "$attempts" -lt 20 ]; do
    /bin/sleep 0.25
    attempts=$((attempts + 1))
  done
fi
/usr/bin/pgrep -f '^/Applications/Somnus.app/Contents/MacOS/Somnus$' >/dev/null 2>&1 \
  && fail "Somnus is still running. Quit it and run this script again."

# Do not leave Control Center executing code from an app bundle that is about
# to disappear. The anchored pattern cannot match another vendor's extension.
/usr/bin/pkill -TERM -f "$control_process_pattern" >/dev/null 2>&1 || true

# The app owns SMAppService registration. Its one-shot removal command disarms
# and verifies first, disconnects XPC, then awaits both unregister completions.
"$target_app/Contents/MacOS/Somnus" --somnus-uninstall-services \
  || fail "service removal was not verified, so Somnus.app was left in place."

# Even after successful teardown, independently prove the persistent system
# setting is safe before deleting the last recovery UI and embedded CLI.
if ! final_sleep_disabled=$(read_sleep_disabled) || [ "$final_sleep_disabled" -ne 0 ]; then
  /usr/bin/sudo /usr/bin/pmset -a disablesleep 0
fi
if ! final_sleep_disabled=$(read_sleep_disabled) || [ "$final_sleep_disabled" -ne 0 ]; then
  fail "services were removed, but Normal Sleep could not be verified. Somnus.app was left in place; run: sudo pmset -a disablesleep 0"
fi

if [ -L "$target_cli" ]; then
  current_link=$(/usr/bin/readlink "$target_cli")
  if [ "$current_link" = "$target_app/Contents/Helpers/somnus" ]; then
    if [ "$cli_directory_writable" -eq 1 ]; then
      /bin/rm "$target_cli"
    else
      /usr/bin/sudo /bin/rm "$target_cli"
    fi
  else
    printf 'warning: %s is not the exact Somnus CLI link and was left untouched.\n' "$target_cli" >&2
  fi
elif [ -e "$target_cli" ]; then
  printf 'warning: %s is not a Somnus symlink and was left untouched.\n' "$target_cli" >&2
fi

if [ "$applications_writable" -eq 1 ]; then
  /bin/rm -rf "$target_app"
else
  /usr/bin/sudo /bin/rm -rf "$target_app"
fi
/usr/bin/defaults delete com.z89.somnus >/dev/null 2>&1 || true
printf '%s\n' 'Somnus was removed. Its app and local settings are not recoverable from this script.'
