#!/bin/bash
# install-control-forwarder — put scripts/control-forwarder.py where a paired
# phone actually depends on it: copied out of the checkout, kept alive by a
# LaunchAgent, and removable — so pairing a phone is a procedure anyone with
# this checkout can follow, not a plist hand-made once.
#
# The control API binds 127.0.0.1 only, so every tailnet or Wi-Fi address the
# pairing sheet offers is reachable only while control-forwarder.py is running.
# Its own docstring names the LaunchAgent that is supposed to keep it alive,
# but nothing in the repo wrote that plist — it was made by hand, once, and run
# from a copy under ~/.kiteloop/bin because launchd's python is not always
# permitted by TCC to read a path under a protected folder (Documents, Desktop,
# Downloads). This script is that copy
# and that plist, made the same way on every Mac that runs it.
#
# What install (the default) does, in order:
#   1. Copies scripts/control-forwarder.py to ~/.kiteloop/bin/control-forwarder.py
#      and makes it executable — never a path inside this checkout, which can
#      move, be deleted, or simply not be one launchd is allowed to read.
#   2. Writes ~/Library/LaunchAgents/ai.kasatkin.kiteloop-forwarder.plist, naming
#      an absolute python3 and the copied script, with RunAtLoad and KeepAlive
#      set and StandardOutPath/StandardErrorPath under ~/.kiteloop/logs.
#   3. Boots out any previous instance of the job (harmless if there was none),
#      then bootstraps the new plist into the user's GUI launchd domain.
#
# Running install again is how you pick up a change to control-forwarder.py:
# it leaves exactly one copy and one plist behind, not a second of either.
#
# --uninstall reverses both halves — boots the job out, then removes the plist
# and the copied script — and is not an error when nothing is installed.
#
# --tailnet-only passes the same flag to the forwarder, so it never listens on
# the LAN address: the install for a work laptop on shared office Wi-Fi.
# Installing again without it goes back to both addresses.
#
# --dry-run prints every step this would take and performs none of them: it
# writes no file and does not invoke launchctl.
#
#   ./scripts/install-control-forwarder.sh              # install (or reinstall)
#   ./scripts/install-control-forwarder.sh --dry-run     # print the plan only
#   ./scripts/install-control-forwarder.sh --tailnet-only # never the LAN address
#   ./scripts/install-control-forwarder.sh --uninstall   # tear it down
#   ./scripts/install-control-forwarder.sh --uninstall --dry-run

set -u

LABEL="ai.kasatkin.kiteloop-forwarder"
SOURCE_SCRIPT_NAME="control-forwarder.py"

usage() {
  awk 'NR == 1 { next } /^#/ { print; next } { exit }' "${BASH_SOURCE[0]}" |
    sed 's/^# \{0,1\}//'
}

say() {
  printf '%s\n' "$*"
}

fail() {
  printf 'install-control-forwarder: %s\n' "$*" >&2
}

# Print one argument the way you would have to type it, so the dry-run plan is
# both a faithful record and safe to paste — same shape as make-release.sh's.
print_command() {
  local arg sep=""
  for arg in "$@"; do
    printf '%s' "$sep"
    case "$arg" in
      '') printf '""' ;;
      *[!A-Za-z0-9._/:=-]*) printf '"%s"' "$arg" ;;
      *) printf '%s' "$arg" ;;
    esac
    sep=" "
  done
  printf '\n'
}

dry_run=0
do_uninstall=0
tailnet_only=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --uninstall) do_uninstall=1 ;;
    --tailnet-only) tailnet_only=1 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option $1"; usage >&2; exit 2 ;;
  esac
  shift
done

script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
source_script="$script_dir/$SOURCE_SCRIPT_NAME"

if [ ! -e "$source_script" ]; then
  fail "$source_script does not exist."
  exit 1
fi

interpreter=$(command -v python3) || interpreter=""
if [ -z "$interpreter" ]; then
  fail "python3 is not on PATH; the forwarder needs it to run."
  exit 1
fi

bin_dir="$HOME/.kiteloop/bin"
logs_dir="$HOME/.kiteloop/logs"
launch_agents_dir="$HOME/Library/LaunchAgents"
dest_script="$bin_dir/$SOURCE_SCRIPT_NAME"
plist_path="$launch_agents_dir/$LABEL.plist"
uid=$(id -u)
domain="gui/$uid"
service_target="$domain/$LABEL"

# The plist content, on stdout — used both to write the real file and to show
# what --dry-run would have written. ProgramArguments names the copied script
# and an absolute interpreter, never a path into this checkout: launchd's own
# working directory is not this one, and the checkout it was invoked from may
# not exist by the time launchd next runs it.
plist_contents() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$interpreter</string>
		<string>$dest_script</string>$( [ "$tailnet_only" -eq 1 ] && printf '\n\t\t<string>--tailnet-only</string>' )
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$logs_dir/control-forwarder.out.log</string>
	<key>StandardErrorPath</key>
	<string>$logs_dir/control-forwarder.err.log</string>
</dict>
</plist>
PLIST
}

# Unloading is the first half of both install (so a reinstall does not try to
# bootstrap a label that is already loaded) and uninstall, and in both places a
# job that was never loaded is not a failure — there is nothing to undo.
unload() {
  launchctl bootout "$service_target" >/dev/null 2>&1
  return 0
}

install() {
  if [ "$dry_run" -eq 1 ]; then
    say 'Would run:'
    print_command mkdir -p "$bin_dir"
    print_command cp "$source_script" "$dest_script"
    print_command chmod +x "$dest_script"
    print_command mkdir -p "$logs_dir"
    print_command mkdir -p "$launch_agents_dir"
    say "Would write $plist_path:"
    plist_contents | sed 's/^/  /'
    print_command launchctl bootout "$service_target"
    print_command launchctl bootstrap "$domain" "$plist_path"
    exit 0
  fi

  mkdir -p "$bin_dir" || exit 1
  cp "$source_script" "$dest_script" || exit 1
  chmod +x "$dest_script" || exit 1
  mkdir -p "$logs_dir" || exit 1
  mkdir -p "$launch_agents_dir" || exit 1
  plist_contents >"$plist_path" || exit 1

  if command -v plutil >/dev/null 2>&1; then
    if ! plutil -lint "$plist_path" >/dev/null; then
      fail "generated an invalid plist at $plist_path."
      exit 1
    fi
  fi

  unload
  if ! launchctl bootstrap "$domain" "$plist_path"; then
    fail "launchctl bootstrap failed; $plist_path is written but not loaded."
    exit 1
  fi

  say "Installed $dest_script"
  say "Loaded    $plist_path ($service_target)"
}

teardown() {
  if [ "$dry_run" -eq 1 ]; then
    say 'Would run:'
    print_command launchctl bootout "$service_target"
    print_command rm -f "$plist_path"
    print_command rm -f "$dest_script"
    exit 0
  fi

  unload
  rm -f "$plist_path"
  rm -f "$dest_script"

  say "Removed   $dest_script"
  say "Unloaded  $plist_path ($service_target)"
}

if [ "$do_uninstall" -eq 1 ]; then
  teardown
else
  install
fi
