#!/bin/bash
# make-mobile-release — archive the iOS companion and upload it to TestFlight.
#
# Until this script the companion could only be installed by pressing Run in
# Xcode with the phone on a cable, under whatever team Signing.local.xcconfig
# named. With a paid Apple Developer team the same build can go to TestFlight as
# an internal build — no App Store review — and install on any of your phones
# from the TestFlight app.
#
# Three steps, each printed before it runs:
#   1. xcodebuild archive — Release, generic iOS device, automatic signing under
#      the team, the build number stamped in.
#   2. An ExportOptions.plist written into the output folder: method
#      app-store-connect, destination upload.
#   3. xcodebuild -exportArchive, which signs for distribution and uploads.
#
# The upload authenticates with an App Store Connect API key — the same kind of
# key docs/release-runbook.md sets up for notarizing the Mac app. It is read from
# the environment, because it belongs to a person and not to this repository:
#
#   KITELOOP_ASC_KEY_ID      the key's id
#   KITELOOP_ASC_ISSUER_ID   the issuer id shown beside it
#   KITELOOP_ASC_KEY_PATH    the AuthKey_<id>.p8 file
#
# The team comes from KITELOOP_MOBILE_TEAM, else the DEVELOPMENT_TEAM line in
# KiteloopMobile/Signing.local.xcconfig.
#
# With any of those missing it names every missing one and exits non-zero before
# it builds anything. --dry-run needs none of them: it prints the plan and runs
# nothing, so it is safe anywhere.
#
# The build number is the commit count of HEAD, so two uploads from different
# commits never collide (TestFlight refuses a build number it has seen). The
# version is MARKETING_VERSION, which KiteloopMobile/project.yml and the pbxproj
# must agree on.
#
#   ./scripts/make-mobile-release.sh --dry-run        # print the plan only
#   ./scripts/make-mobile-release.sh                  # archive, export, upload
#   ./scripts/make-mobile-release.sh --output dist    # where the archive lands

set -u

KEY_ID_VAR="KITELOOP_ASC_KEY_ID"
ISSUER_VAR="KITELOOP_ASC_ISSUER_ID"
KEY_PATH_VAR="KITELOOP_ASC_KEY_PATH"
TEAM_VAR="KITELOOP_MOBILE_TEAM"

PROJECT_RELPATH="KiteloopMobile/KiteloopMobile.xcodeproj"
PBXPROJ_RELPATH="$PROJECT_RELPATH/project.pbxproj"
PROJECT_YML_RELPATH="KiteloopMobile/project.yml"
LOCAL_SIGNING_RELPATH="KiteloopMobile/Signing.local.xcconfig"
SCHEME="KiteloopMobile"
DEFAULT_OUTPUT_RELPATH="dist/mobile"

usage() {
  awk 'NR == 1 { next } /^#/ { print; next } { exit }' "${BASH_SOURCE[0]}" |
    sed 's/^# \{0,1\}//'
}

say() {
  printf '%s\n' "$*"
}

fail() {
  printf 'make-mobile-release: %s\n' "$*" >&2
}

quote_arg() {
  case "$1" in
    '') printf '""' ;;
    *[!A-Za-z0-9._/:=-]*) printf '"%s"' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

print_command() {
  local arg sep=""
  for arg in "$@"; do
    printf '%s' "$sep"
    quote_arg "$arg"
    sep=" "
  done
  printf '\n'
}

# Prints the command, then runs it unless this is a dry run.
run() {
  printf '+ '
  print_command "$@"
  [ "$dry_run" -eq 1 ] && return 0
  "$@"
}

# The one MARKETING_VERSION both sites agree on, or a report and non-zero.
resolve_version() {
  local yml_values pbx_values
  yml_values=$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "$1" | sort -u)
  pbx_values=$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \(.*\);[[:space:]]*$/\1/p' "$2" | sort -u)
  if [ -z "$yml_values" ] || [ -z "$pbx_values" ]; then
    fail "MARKETING_VERSION is missing from $PROJECT_YML_RELPATH or $PBXPROJ_RELPATH."
    return 1
  fi
  if [ "$yml_values" != "$pbx_values" ] || [ "$(printf '%s\n' "$yml_values" | wc -l | tr -d ' ')" != 1 ]; then
    fail "MARKETING_VERSION disagrees: $PROJECT_YML_RELPATH says $(echo $yml_values), $PBXPROJ_RELPATH says $(echo $pbx_values)."
    return 1
  fi
  printf '%s\n' "$yml_values"
}

# The team: the environment first, then the gitignored local signing file.
resolve_team() {
  if [ -n "${KITELOOP_MOBILE_TEAM:-}" ]; then
    printf '%s\n' "$KITELOOP_MOBILE_TEAM"
    return
  fi
  [ -e "$1" ] || return 0
  sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\)[[:space:]]*$/\1/p' "$1" | tail -1
}

export_options_plist() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$1</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST
}

dry_run=0
output_relpath="$DEFAULT_OUTPUT_RELPATH"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --output)
      [ "$#" -ge 2 ] || { fail "--output needs a directory"; exit 2; }
      output_relpath=$2
      shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option $1"; usage >&2; exit 2 ;;
  esac
  shift
done

script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null) || {
  fail "$script_dir is not inside a git checkout."
  exit 1
}
cd "$repo_root" || exit 1

version=$(resolve_version "$PROJECT_YML_RELPATH" "$PBXPROJ_RELPATH") || exit 1
build_number=$(git rev-list --count HEAD) || exit 1
team=$(resolve_team "$LOCAL_SIGNING_RELPATH")

missing=()
[ -n "$team" ] || missing+=("$TEAM_VAR (or DEVELOPMENT_TEAM in $LOCAL_SIGNING_RELPATH)")
[ -n "${KITELOOP_ASC_KEY_ID:-}" ] || missing+=("$KEY_ID_VAR")
[ -n "${KITELOOP_ASC_ISSUER_ID:-}" ] || missing+=("$ISSUER_VAR")
if [ -z "${KITELOOP_ASC_KEY_PATH:-}" ]; then
  missing+=("$KEY_PATH_VAR")
elif [ ! -r "$KITELOOP_ASC_KEY_PATH" ]; then
  missing+=("$KEY_PATH_VAR (no readable file at $KITELOOP_ASC_KEY_PATH)")
fi

if [ "${#missing[@]}" -gt 0 ] && [ "$dry_run" -eq 0 ]; then
  fail "cannot upload without:"
  for name in "${missing[@]}"; do fail "  $name"; done
  fail "docs/release-runbook.md, \"The phone app on TestFlight\", sets these up. Nothing was built."
  exit 1
fi

output_dir="$repo_root/$output_relpath"
archive_path="$output_dir/KiteloopMobile-$version-$build_number.xcarchive"
options_path="$output_dir/ExportOptions.plist"

say "KiteloopMobile $version ($build_number) for team ${team:-<unset>}"
if [ "$dry_run" -eq 1 ]; then
  say "dry run: nothing below runs."
  for name in "${missing[@]+"${missing[@]}"}"; do say "  a real run would refuse: $name is not set"; done
fi

auth_args=(-allowProvisioningUpdates
  -authenticationKeyPath "${KITELOOP_ASC_KEY_PATH:-<key path>}"
  -authenticationKeyID "${KITELOOP_ASC_KEY_ID:-<key id>}"
  -authenticationKeyIssuerID "${KITELOOP_ASC_ISSUER_ID:-<issuer id>}")

say ""
say "1. archive"
run mkdir -p "$output_dir" || exit 1
run xcodebuild archive -project "$PROJECT_RELPATH" -scheme "$SCHEME" -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$archive_path" \
  "CURRENT_PROJECT_VERSION=$build_number" "DEVELOPMENT_TEAM=${team:-<team>}" "${auth_args[@]}" || exit 1

say ""
say "2. export options"
say "+ write $options_path"
if [ "$dry_run" -eq 0 ]; then
  export_options_plist "$team" >"$options_path" || exit 1
fi

say ""
say "3. export and upload to TestFlight"
run xcodebuild -exportArchive -archivePath "$archive_path" -exportOptionsPlist "$options_path" \
  -exportPath "$output_dir/export" "${auth_args[@]}" || exit 1

say ""
if [ "$dry_run" -eq 1 ]; then
  say "dry run complete."
else
  say "uploaded build $build_number; it appears in TestFlight once App Store Connect finishes processing it."
fi
