#!/bin/bash
# test-make-mobile-release — make-mobile-release.sh's refusals and its dry-run
# plan, against a stub xcodebuild that only records that it was called.
#
# Each case runs a copy of the script inside a throwaway git repo holding just
# the files it reads, so the build number (HEAD's commit count) can be moved by
# committing, and nothing here can reach the real project or App Store Connect.

set -u

here=$(cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
source_script="$here/make-mobile-release.sh"
failures=0

check() {
  if [ "$2" = "$3" ]; then
    printf '  ok    %s\n' "$1"
  else
    printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"
    failures=$((failures + 1))
  fi
}

check_contains() {
  case "$3" in
    *"$2"*) printf '  ok    %s\n' "$1" ;;
    *) printf '  FAIL  %s\n        missing: %s\n        in: %s\n' "$1" "$2" "$3"; failures=$((failures + 1)) ;;
  esac
}

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p "$repo/scripts" "$repo/KiteloopMobile/KiteloopMobile.xcodeproj" "$tmp/bin" || exit 1
cp "$source_script" "$repo/scripts/" || exit 1
printf 'targets:\n  KiteloopMobile:\n    settings:\n      base:\n        MARKETING_VERSION: "0.2.0"\n' \
  >"$repo/KiteloopMobile/project.yml"
printf '\t\t\t\tMARKETING_VERSION = 0.2.0;\n\t\t\t\tMARKETING_VERSION = 0.2.0;\n' \
  >"$repo/KiteloopMobile/KiteloopMobile.xcodeproj/project.pbxproj"
git -C "$repo" init -q && git -C "$repo" add -A &&
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m one || exit 1

calls="$tmp/xcodebuild-calls"
: >"$calls"
cat >"$tmp/bin/xcodebuild" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$calls"
exit 0
STUB
chmod +x "$tmp/bin/xcodebuild"

# No credential variables, the stub first on PATH.
run_script() {
  ( unset KITELOOP_ASC_KEY_ID KITELOOP_ASC_ISSUER_ID KITELOOP_ASC_KEY_PATH KITELOOP_MOBILE_TEAM
    PATH="$tmp/bin:$PATH" "$repo/scripts/make-mobile-release.sh" "$@" )
}

printf 'dry run without credentials\n'
out=$(run_script --dry-run 2>&1); status=$?
check 'exits 0' '0' "$status"
check 'runs xcodebuild not once' '' "$(cat "$calls")"
check_contains 'prints the archive step' 'xcodebuild archive' "$out"
check_contains 'prints the export and upload step' 'xcodebuild -exportArchive' "$out"
check_contains 'names the version and build number' 'KiteloopMobile 0.2.0 (1)' "$out"
check_contains 'says what a real run would refuse' 'a real run would refuse: KITELOOP_ASC_KEY_ID' "$out"
check 'writes no export options' 'no' "$([ -e "$repo/dist/mobile/ExportOptions.plist" ] && echo yes || echo no)"

printf '\na real run without the key\n'
out=$(KITELOOP_MOBILE_TEAM=ABCDE12345 run_script 2>&1); status=$?
check 'exits non-zero' '1' "$status"
check_contains 'names the missing key id' 'KITELOOP_ASC_KEY_ID' "$out"
check_contains 'names the missing key file' 'KITELOOP_ASC_KEY_PATH' "$out"
check_contains 'says nothing was built' 'Nothing was built' "$out"
check 'runs xcodebuild not once' '' "$(cat "$calls")"

printf '\nthe team from Signing.local.xcconfig\n'
printf 'DEVELOPMENT_TEAM = XYZ9876543\n' >"$repo/KiteloopMobile/Signing.local.xcconfig"
out=$(run_script --dry-run 2>&1)
check_contains 'is read when the variable is unset' 'for team XYZ9876543' "$out"
rm "$repo/KiteloopMobile/Signing.local.xcconfig"

printf '\nbuild numbers\n'
first=$(run_script --dry-run 2>&1 | sed -n 's/^KiteloopMobile .*(\([0-9]*\)).*/\1/p')
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two || exit 1
second=$(run_script --dry-run 2>&1 | sed -n 's/^KiteloopMobile .*(\([0-9]*\)).*/\1/p')
check 'the first commit is build 1' '1' "$first"
check 'another commit is another build number' '2' "$second"

printf '\na drifted version\n'
printf '\t\t\t\tMARKETING_VERSION = 0.2.1;\n' >>"$repo/KiteloopMobile/KiteloopMobile.xcodeproj/project.pbxproj"
out=$(run_script --dry-run 2>&1); status=$?
check 'is refused' '1' "$status"
check_contains 'naming both sites' 'MARKETING_VERSION disagrees' "$out"

printf '\n'
if [ "$failures" -eq 0 ]; then
  printf 'test-make-mobile-release: all cases passed.\n'
else
  printf 'test-make-mobile-release: %d failed.\n' "$failures"
  exit 1
fi
