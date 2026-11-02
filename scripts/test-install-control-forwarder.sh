#!/bin/bash
# test-install-control-forwarder — run install-control-forwarder.sh end to
# end, with a temp HOME and a stub launchctl first on PATH, and assert what it
# leaves behind.
#
# None of this can be checked by running the real thing: the real thing loads
# a launchd job under the account running this test, and a test that starts a
# background process on a machine it does not own is not a test anyone would
# trust to run in CI or on their own Mac by accident. So HOME is a throwaway
# temp directory for the whole run and launchctl is a stub, first on PATH, that
# only records the arguments it was called with — nothing here loads, unloads,
# or asks launchd about anything real.
#
#   ./scripts/test-install-control-forwarder.sh

set -u

here=$(cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
installer="$here/install-control-forwarder.sh"

tmp=$(mktemp -d -t test-install-control-forwarder) || exit 1
trap 'rm -rf "$tmp"' EXIT

failed=0

check() {
  local name=$1 expected=$2 actual=$3
  if [ "$actual" = "$expected" ]; then
    printf '  ok    %s\n' "$name"
  else
    printf '  FAIL  %s\n          expected: %s\n          actual:   %s\n' \
      "$name" "$expected" "$actual"
    failed=$((failed + 1))
  fi
}

check_contains() {
  local name=$1 needle=$2 haystack=$3
  case "$haystack" in
    *"$needle"*) printf '  ok    %s\n' "$name" ;;
    *)
      printf '  FAIL  %s\n          expected to contain: %s\n          actual:   %s\n' \
        "$name" "$needle" "$haystack"
      failed=$((failed + 1))
      ;;
  esac
}

check_lacks() {
  local name=$1 needle=$2 haystack=$3
  case "$haystack" in
    *"$needle"*)
      printf '  FAIL  %s\n          expected NOT to contain: %s\n          actual:   %s\n' \
        "$name" "$needle" "$haystack"
      failed=$((failed + 1))
      ;;
    *) printf '  ok    %s\n' "$name" ;;
  esac
}

# A stub launchctl, first on PATH, that only records its argument line. python3
# is left to resolve off the real PATH behind it, since the installer needs a
# real interpreter to name in the plist.
stub_bin="$tmp/bin"
mkdir -p "$stub_bin" || exit 1
calls="$tmp/launchctl-calls"
: >"$calls"
cat >"$stub_bin/launchctl" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$calls"
exit 0
STUB
chmod +x "$stub_bin/launchctl"

run_installer() {
  ( PATH="$stub_bin:$PATH" HOME="$home" "$installer" "$@" )
}

label="ai.kasatkin.kiteloop-forwarder"
plist_path_for() { printf '%s/Library/LaunchAgents/%s.plist' "$1" "$label"; }
dest_script_for() { printf '%s/.kiteloop/bin/control-forwarder.py' "$1"; }

# --- install -------------------------------------------------------------

printf '\ninstall\n'

home="$tmp/home-install"
mkdir -p "$home" || exit 1
: >"$calls"

install_out=$(run_installer)
plist_path=$(plist_path_for "$home")
dest_script=$(dest_script_for "$home")

check 'a first install exits 0' '0' "$(run_installer >/dev/null 2>&1; echo $?)"
check 'the copy exists' 'yes' "$([ -e "$dest_script" ] && echo yes || echo no)"
check 'the copy is executable' 'yes' "$([ -x "$dest_script" ] && echo yes || echo no)"
check 'the plist exists' 'yes' "$([ -e "$plist_path" ] && echo yes || echo no)"

if command -v plutil >/dev/null 2>&1; then
  check 'plutil -lint accepts the generated plist' \
    '0' "$(plutil -lint "$plist_path" >/dev/null 2>&1; echo $?)"
fi

plist_body=$(cat "$plist_path")
check_contains 'ProgramArguments names the copied script under ~/.kiteloop/bin' \
  "$dest_script" "$plist_body"
check_lacks 'ProgramArguments does not name a path inside this checkout' \
  "$here" "$plist_body"
check_contains 'the plist carries the LaunchAgent label' "$label" "$plist_body"

check_contains 'the calls log recorded a bootout' 'bootout' "$(cat "$calls")"
check_contains 'the calls log recorded a bootstrap' 'bootstrap' "$(cat "$calls")"
first_call=$(sed -n '1p' "$calls")
second_call=$(sed -n '2p' "$calls")
check_contains 'bootout ran before bootstrap' 'bootout' "$first_call"
check_contains 'bootstrap followed it' 'bootstrap' "$second_call"

# --- reinstall is idempotent, not a duplicate -----------------------------

printf '\nreinstall\n'

before_bytes=$(wc -c <"$dest_script")
: >"$calls"
run_installer >/dev/null
check 'a second install exits 0' '0' "$(run_installer >/dev/null 2>&1; echo $?)"

plist_count=$(find "$home/Library/LaunchAgents" -name "$label.plist" | wc -l | tr -d ' ')
copy_count=$(find "$home/.kiteloop/bin" -name control-forwarder.py | wc -l | tr -d ' ')
check 'exactly one plist remains' '1' "$plist_count"
check 'exactly one copy remains' '1' "$copy_count"
after_bytes=$(wc -c <"$dest_script")
check 'the copy was overwritten in place, not appended to' "$before_bytes" "$after_bytes"

check_contains 'the second install also recorded a bootout' 'bootout' "$(sed -n '1p' "$calls")"
check_contains 'before a bootstrap' 'bootstrap' "$(sed -n '2p' "$calls")"

# --- --dry-run touches nothing ---------------------------------------------

printf '\ndry-run\n'

home="$tmp/home-dry-run"
mkdir -p "$home" || exit 1
: >"$calls"

dry_out=$(run_installer --dry-run)
check 'a dry run exits 0' '0' "$(run_installer --dry-run >/dev/null 2>&1; echo $?)"
check 'it creates no ~/.kiteloop directory' 'no' "$([ -e "$home/.kiteloop" ] && echo yes || echo no)"
check 'it creates no LaunchAgents plist' 'no' "$([ -e "$(plist_path_for "$home")" ] && echo yes || echo no)"
check 'it invokes launchctl not once' '' "$(cat "$calls")"
check_contains 'and says what it would have written' "$label" "$dry_out"

# --- --tailnet-only ----------------------------------------------------------

printf '\ntailnet-only\n'

home="$tmp/home-tailnet-only"
mkdir -p "$home" || exit 1
: >"$calls"

check_lacks 'a plain dry run leaves --tailnet-only out of the arguments' '--tailnet-only' "$dry_out"
tailnet_out=$(run_installer --tailnet-only --dry-run)
check_contains 'a --tailnet-only dry run shows the flag in the arguments' '<string>--tailnet-only</string>' "$tailnet_out"
run_installer --tailnet-only >/dev/null
plist_body=$(cat "$(plist_path_for "$home")")
check_contains 'a --tailnet-only install writes the flag into the plist' '<string>--tailnet-only</string>' "$plist_body"
if command -v plutil >/dev/null 2>&1; then
  check 'plutil -lint accepts the tailnet-only plist' '0' \
    "$(plutil -lint "$(plist_path_for "$home")" >/dev/null 2>&1; echo $?)"
fi
run_installer >/dev/null
check_lacks 'installing again without it goes back to both addresses' '--tailnet-only' "$(cat "$(plist_path_for "$home")")"

# --- --uninstall -------------------------------------------------------------

printf '\nuninstall\n'

home="$tmp/home-uninstall"
mkdir -p "$home" || exit 1
: >"$calls"
run_installer >/dev/null
plist_path=$(plist_path_for "$home")
dest_script=$(dest_script_for "$home")
check 'the fixture install actually landed the plist' 'yes' "$([ -e "$plist_path" ] && echo yes || echo no)"

: >"$calls"
check 'uninstall exits 0' '0' "$(run_installer --uninstall >/dev/null 2>&1; echo $?)"
run_installer --uninstall >/dev/null
check 'the plist is gone' 'no' "$([ -e "$plist_path" ] && echo yes || echo no)"
check 'the copy is gone' 'no' "$([ -e "$dest_script" ] && echo yes || echo no)"
check_contains 'a bootout was recorded' 'bootout' "$(cat "$calls")"

# Uninstalling nothing is not an error.
home="$tmp/home-uninstall-empty"
mkdir -p "$home" || exit 1
check 'uninstalling with nothing installed exits 0' \
  '0' "$(run_installer --uninstall >/dev/null 2>&1; echo $?)"

# --- --uninstall --dry-run touches nothing ----------------------------------

printf '\nuninstall dry-run\n'

home="$tmp/home-uninstall-dry-run"
mkdir -p "$home" || exit 1
run_installer >/dev/null
plist_path=$(plist_path_for "$home")
dest_script=$(dest_script_for "$home")
: >"$calls"

check 'exits 0' '0' "$(run_installer --uninstall --dry-run >/dev/null 2>&1; echo $?)"
check 'the plist is left in place' 'yes' "$([ -e "$plist_path" ] && echo yes || echo no)"
check 'the copy is left in place' 'yes' "$([ -e "$dest_script" ] && echo yes || echo no)"
check 'it invokes launchctl not once' '' "$(cat "$calls")"

# --- --help --------------------------------------------------------------

printf '\nhelp\n'

help_out=$("$installer" --help)
check_contains '--help prints the usage lines' '--dry-run' "$help_out"
check_lacks '--help prints no shell code as though it were documentation' \
  'set -u' "$help_out"

printf '\n'
if [ "$failed" -eq 0 ]; then
  printf 'test-install-control-forwarder: all cases passed.\n'
  exit 0
fi
printf 'test-install-control-forwarder: %s case(s) failed.\n' "$failed" >&2
exit 1
