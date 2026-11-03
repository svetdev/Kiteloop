#!/bin/bash
# make-release — turn a version into a zipped Kiteloop.app someone can download.
#
# There was no way to hand Kiteloop to a person who does not build Xcode
# projects: no artifact, no process, and the only instructions for producing one
# lived in whatever the last person to do it remembered. So this script is the
# process, in one invocation with two outcomes.
#
# --dry-run needs no credentials at all. It reads the version, extracts that
# version's release notes from CHANGELOG.md, builds Release, packages
# Kiteloop.app into Kiteloop-<version>.zip, and prints — command by command —
# what the signed path would have done instead of stopping there. Everything a
# machine with only Xcode can do, it does; the zip it produces is real and runs
# locally, it is just ad-hoc signed, so Gatekeeper on someone else's Mac will
# refuse it. That is the whole difference, and it is why the dry run is worth
# having: it exercises the build, the version check, the notes and the packaging,
# which is where a release breaks, rather than the two API calls it cannot make.
#
# The full path is the same run with `codesign`, `xcrun notarytool submit --wait`
# and `xcrun stapler staple` in the middle of it. Those need a Developer ID
# certificate and a notary credential, which belong to a human and not to this
# repository, so the script reads them from the environment:
#
#   KITELOOP_SIGN_IDENTITY   the Developer ID Application identity to sign with
#   KITELOOP_NOTARY_PROFILE  the `notarytool store-credentials` profile name
#
# With either missing it names the missing ones and exits non-zero **before it
# builds anything**. A half-signed app is worse than no app — it installs, it
# launches for the person who built it, and it is rejected on the machine of the
# person you sent it to — so there is no partial path through here. Setting them
# up is a one-time human job: docs/release-runbook.md.
#
# Before any of that it checks that the three places MARKETING_VERSION is
# written agree — the Debug and Release entries in project.pbxproj, and the
# XcodeGen spec in Kiteloop/project.yml. CLAUDE.md has said "bump it in three
# places that must not drift" for as long as there have been three; this is that
# invariant, machine-checked at the moment it would otherwise ship. A drifted
# version is not a cosmetic problem: it is what /health reports, what the About
# panel shows, and what names the zip, so shipping one means the artifact and
# the app inside it disagree about which release this is. --expect adds the tag
# as a fourth site, which is what the release workflow passes: a `v0.3.1` tag on
# a tree that still says 0.3.0 is caught before the build rather than after the
# upload.
#
# The app's bundled resources are the same kind of hand-kept-in-step pair: a
# `resources:` entry in the spec and a file reference plus a build file in the
# pbxproj's Resources build phase for the Kiteloop target. Losing either is
# silent the same way a version mismatch used to be — the build succeeds, the
# tests pass, and the shipped app is just missing whatever the resource was —
# so this is checked right alongside the version, before anything is built.
#
# Release notes come out of CHANGELOG.md — exactly the tagged version's section,
# from its `## <version> — <date>` heading to the next heading. That discipline
# already exists and is already enforced by review, so a release note is
# something the repository has rather than something someone writes twice.
#
#   ./scripts/make-release.sh --dry-run            # build and zip, no credentials
#   ./scripts/make-release.sh                      # sign, notarize, staple, zip
#   ./scripts/make-release.sh --expect 0.3.0       # refuse unless the version matches
#   ./scripts/make-release.sh --notes-only         # write the release notes, build nothing
#   ./scripts/make-release.sh --install-local      # Release build signed here, into /Applications; no notarizing
#   ./scripts/make-release.sh --output dist        # where the zip and the notes land

set -u

SIGN_IDENTITY_VAR="KITELOOP_SIGN_IDENTITY"
NOTARY_PROFILE_VAR="KITELOOP_NOTARY_PROFILE"

# The order these are named in when they are missing, which is the order you
# would set them up in.
CREDENTIAL_VARS=("$SIGN_IDENTITY_VAR" "$NOTARY_PROFILE_VAR")

PBXPROJ_RELPATH="Kiteloop/Kiteloop.xcodeproj/project.pbxproj"
PROJECT_YML_RELPATH="Kiteloop/project.yml"
CHANGELOG_RELPATH="CHANGELOG.md"
ENTITLEMENTS_RELPATH="Kiteloop/Kiteloop/Kiteloop.entitlements"
DEFAULT_OUTPUT_RELPATH="dist"
# Where --install-local puts the app; overridable so the guard suite installs
# into a temporary directory rather than the machine's /Applications.
INSTALL_DIR="${KITELOOP_INSTALL_DIR:-/Applications}"

# ${BASH_SOURCE[0]} rather than "$0" for the same reason run-unit-suite.sh uses
# it: under `source` those differ, and a sourced copy would print the header of
# whatever sourced it.
usage() {
  awk 'NR == 1 { next } /^#/ { print; next } { exit }' "${BASH_SOURCE[0]}" |
    sed 's/^# \{0,1\}//'
}

say() {
  printf '%s\n' "$*"
}

fail() {
  printf 'make-release: %s\n' "$*" >&2
}

# Print one argument the way you would have to type it, so a printed command is
# both a faithful record of what runs and safe to paste.
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

# --- The version -------------------------------------------------------------
#
# Three sites, and the only thing that matters is that they say the same thing.
# Each reader returns the values it found rather than the first one, so a
# pbxproj whose Debug and Release entries disagree is caught by the comparison
# below rather than by whichever one happened to be read.

pbxproj_versions() {
  sed -n 's/^[[:space:]]*MARKETING_VERSION = \(.*\);[[:space:]]*$/\1/p' "$1"
}

project_yml_versions() {
  sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "$1"
}

# The version all three sites agree on, on stdout — or a report on stderr naming
# each site and what it says, and a non-zero status. Callers get a version they
# can use or nothing at all; there is no "probably 0.3.0".
resolve_version() {
  local pbxproj=$1 yml=$2
  local -a pbx_values yml_values
  local value

  if [ ! -e "$pbxproj" ]; then
    fail "$pbxproj does not exist."
    return 1
  fi
  if [ ! -e "$yml" ]; then
    fail "$yml does not exist."
    return 1
  fi

  pbx_values=()
  while IFS= read -r value; do
    [ -n "$value" ] && pbx_values+=("$value")
  done < <(pbxproj_versions "$pbxproj")

  yml_values=()
  while IFS= read -r value; do
    [ -n "$value" ] && yml_values+=("$value")
  done < <(project_yml_versions "$yml")

  # A site that has gone missing entirely would pass an equality check on what
  # is left, so the count is checked too: two build configurations in the
  # pbxproj, one in the spec.
  if [ "${#pbx_values[@]}" -lt 2 ]; then
    fail "$pbxproj names ${#pbx_values[@]} MARKETING_VERSION, expected the Debug and Release entries."
    return 1
  fi
  if [ "${#yml_values[@]}" -ne 1 ]; then
    fail "$yml names ${#yml_values[@]} MARKETING_VERSION, expected one."
    return 1
  fi

  local first=${pbx_values[0]}
  local drift=0
  for value in "${pbx_values[@]}" "${yml_values[@]}"; do
    [ "$value" = "$first" ] || drift=1
  done

  if [ "$drift" -eq 1 ]; then
    fail 'MARKETING_VERSION disagrees across the three sites it is written in:'
    for value in "${pbx_values[@]}"; do
      printf '  %s: %s\n' "$pbxproj" "$value" >&2
    done
    printf '  %s: %s\n' "$yml" "${yml_values[0]}" >&2
    printf 'Bump all three, then run this again.\n' >&2
    return 1
  fi

  printf '%s\n' "$first"
}

# --- The bundled resources ----------------------------------------------------
#
# Same shape as the version check, for a different pair of hand-kept-in-step
# sites: a `path:` entry under the app target's `resources:` in the spec, and a
# file reference plus a build file entry in the pbxproj's Resources build phase
# for the Kiteloop target. A resource is bundled by its basename — `path:
# Kiteloop/Resources/Foo` becomes a `Foo` file reference relative to its
# group — so that is what both readers return.

# The `- path: X` lines directly under `resources:`, up to the next line at the
# same indentation or shallower (the next key in the target, e.g. `settings:`).
# A sub-key of the path entry itself (`buildPhase:`, indented deeper) is not a
# resource and is skipped without ending the block.
project_yml_resources() {
  awk '
    match($0, /^[[:space:]]*/) { indent = RLENGTH }
    /^[[:space:]]*resources:[[:space:]]*$/ { in_res = 1; res_indent = indent; next }
    in_res && indent <= res_indent { in_res = 0 }
    in_res && /^[[:space:]]*- path:[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*- path:[[:space:]]*/, "", line)
      gsub(/[[:space:]]+$/, "", line)
      gsub(/^"|"$/, "", line)
      print line
    }
  ' "$1"
}

# The pbxproj build phase ID of the Kiteloop *app* target's Resources phase —
# not KiteloopTests' or KiteloopUITests', which have their own, and each of
# which can carry files (test fixtures) that are not app resources at all. The
# app target is the one PBXNativeTarget whose productType is "application";
# found by buffering each object in the PBXNativeTarget section and keeping the
# one that matches, since a target's `name =` and `buildPhases =` lines can
# appear before or after its `productType =` line.
pbxproj_app_target_resources_phase_id() {
  awk '
    /\/\* Begin PBXNativeTarget section \*\// { insec = 1; next }
    /\/\* End PBXNativeTarget section \*\// { insec = 0 }
    insec {
      if ($0 ~ /^\t\t[0-9A-F][0-9A-F]* \/\*/) { buf = $0 "\n"; next }
      buf = buf $0 "\n"
      if ($0 ~ /^\t\t\};$/) {
        if (buf ~ /productType = "com\.apple\.product-type\.application";/) { printf "%s", buf }
        buf = ""
      }
    }
  ' "$1" | sed -n 's#^[[:space:]]*\([0-9A-F][0-9A-F]*\) /\* Resources \*/,[[:space:]]*$#\1#p'
}

# The resource names that phase actually builds, restricted to folder-shaped
# ones (`lastKnownFileType` starting `folder` — a directory or an asset
# catalog): the ones a `resources: - path:` entry produces. A file swept into
# the same phase from a `sources:` path because it is not compilable (a
# `.js`, a test fixture `.json`) has no `resources:` entry to compare it
# against, and is not what this check is for.
pbxproj_resources() {
  local pbxproj=$1 phase_id
  phase_id=$(pbxproj_app_target_resources_phase_id "$pbxproj")
  [ -n "$phase_id" ] || return 0

  local buildfile_id name fileref_id filetype
  awk -v id="$phase_id" '
    $0 ~ "^\t\t" id " /\\* Resources \\*/ = \\{$" { in_phase = 1; next }
    in_phase && /^\t\t\};$/ { exit }
    in_phase { print }
  ' "$pbxproj" |
    sed -n 's#^[[:space:]]*\([0-9A-F][0-9A-F]*\) /\* \(.*\) in Resources \*/,[[:space:]]*$#\1|\2#p' |
    while IFS='|' read -r buildfile_id name; do
      fileref_id=$(sed -n "/^[[:space:]]*${buildfile_id} \\//s#.*fileRef = \\([0-9A-F][0-9A-F]*\\).*#\\1#p" "$pbxproj" | head -n 1)
      [ -n "$fileref_id" ] || continue
      filetype=$(sed -n "/^[[:space:]]*${fileref_id} \\//s#.*lastKnownFileType = \\([^;]*\\);.*#\\1#p" "$pbxproj" | head -n 1)
      case "$filetype" in
        folder*) printf '%s\n' "$name" ;;
      esac
    done
}

# The spec and the pbxproj, agreeing on the same set of bundled resources — or
# a report on stderr naming each one that is only in one of them, and a
# non-zero status. A spec resource whose path does not exist in the tree at
# all is refused before the comparison even runs: it cannot be bundled by
# either file, so a report that treats it as one-sided drift would name the
# wrong side, and a spec entry that names nothing has otherwise been carried,
# silently, for as long as this check has existed.
resolve_resources() {
  local pbxproj=$1 yml=$2
  local project_dir
  project_dir=$(dirname -- "$yml")

  if [ ! -e "$pbxproj" ]; then
    fail "$pbxproj does not exist."
    return 1
  fi
  if [ ! -e "$yml" ]; then
    fail "$yml does not exist."
    return 1
  fi

  # Plain newline-delimited strings rather than bash arrays: an array that
  # never gets an element is "unset" under the macOS system bash (3.2), and
  # `set -u` turns expanding it into a hard error — a resource set with
  # nothing missing on either side is the common case, not an edge case, so it
  # has to work.
  local yml_names="" pbx_names="" path name missing=""

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ ! -e "$project_dir/$path" ]; then
      missing="$missing$path
"
      continue
    fi
    yml_names="$yml_names${path##*/}
"
  done < <(project_yml_resources "$yml")

  if [ -n "$missing" ]; then
    fail 'a bundled resource in the spec names nothing in the tree:'
    while IFS= read -r m; do
      [ -n "$m" ] && printf '  %s: %s — nothing at %s\n' "$yml" "$m" "$project_dir/$m" >&2
    done <<EOF
$missing
EOF
    printf 'Remove the entry from the spec, or restore what it names.\n' >&2
    return 1
  fi

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    pbx_names="$pbx_names$name
"
  done < <(pbxproj_resources "$pbxproj")

  local only_yml only_pbx
  only_yml=$(comm -23 <(printf '%s' "$yml_names" | sort -u) <(printf '%s' "$pbx_names" | sort -u))
  only_pbx=$(comm -13 <(printf '%s' "$yml_names" | sort -u) <(printf '%s' "$pbx_names" | sort -u))

  if [ -n "$only_yml" ] || [ -n "$only_pbx" ]; then
    fail 'bundled resources disagree between the spec and the pbxproj:'
    if [ -n "$only_yml" ]; then
      while IFS= read -r y; do
        [ -n "$y" ] && printf '  %s: %s — %s does not build it\n' "$yml" "$y" "$pbxproj" >&2
      done <<EOF
$only_yml
EOF
    fi
    if [ -n "$only_pbx" ]; then
      while IFS= read -r p; do
        [ -n "$p" ] && printf '  %s: %s — %s does not list it\n' "$pbxproj" "$p" "$yml" >&2
      done <<EOF
$only_pbx
EOF
    fi
    printf 'Add the missing resource to whichever file lost it, then run this again.\n' >&2
    return 1
  fi

  return 0
}

# --- The release notes -------------------------------------------------------
#
# The section CHANGELOG.md already carries for this version, and nothing else:
# from its heading to the next `## ` heading, with the heading line itself left
# off — the release is already titled with the version — and the blank lines at
# either end trimmed.

changelog_heading() {
  local file=$1 version=$2
  [ -e "$file" ] || return 1
  grep -m 1 -E "^## ${version//./\\.}( |$)" "$file"
}

changelog_section() {
  local file=$1 version=$2
  [ -e "$file" ] || return 1
  awk -v version="$version" '
    # The dots in a version number are literal dots, not any-character.
    BEGIN { gsub(/\./, "\\.", version) }
    !seen && $0 ~ "^## " version "( |$)" { seen = 1; next }
    seen && /^## / { exit }
    seen { print }
  ' "$file" |
    awk '
      /[^[:space:]]/ { started = 1; while (held-- > 0) print ""; held = 0; print; next }
      started { held++ }
    '
}

# --- The credentials ---------------------------------------------------------
#
# Named, not counted: "set KITELOOP_NOTARY_PROFILE" is actionable and "missing
# credentials" is not.

missing_credentials() {
  local name
  for name in "${CREDENTIAL_VARS[@]}"; do
    [ -n "${!name:-}" ] || printf '%s\n' "$name"
  done
}

refuse_missing_credentials() {
  local -a missing=("$@")
  local name
  {
    printf 'make-release: the signed path needs credentials this environment does not set:\n'
    for name in "${missing[@]}"; do
      case "$name" in
        "$SIGN_IDENTITY_VAR")
          printf '  %s   — the Developer ID Application identity to sign with\n' "$name" ;;
        "$NOTARY_PROFILE_VAR")
          printf '  %s  — the `xcrun notarytool store-credentials` profile name\n' "$name" ;;
        *)
          printf '  %s\n' "$name" ;;
      esac
    done
    printf '\n'
    printf 'Nothing was built: an app signed with some of these and not the others\n'
    printf 'launches here and is refused on the machine you send it to. Set them up\n'
    printf 'once (docs/release-runbook.md), or run --dry-run, which needs none of them.\n'
  } >&2
}

# --- The build ---------------------------------------------------------------
#
# One build command for both paths, ad-hoc signed. The signed path re-signs the
# bundle afterwards with --force, so the dry run exercises the same build that
# ships rather than a second, easier one that might not compile the same way.
#
# CODE_SIGN_IDENTITY is overridden because a developer's Signing.local.xcconfig
# may set it to "Kiteloop Local Signing", a self-signed identity that exists in
# that one keychain and on no CI machine; the override makes the release build
# independent of whatever the building machine's local file says.
#
# ARCHS is spelled out because -destination "platform=macOS" resolves to the
# architecture of the machine doing the building, and a release built that way
# on an Apple Silicon Mac is an arm64-only app: it will not launch at all on an
# Intel one. "Hand it to someone" is the whole point of this script, and you do
# not get to ask which Mac they have.
xcodebuild_argv() {
  local project=$1 derived=$2
  printf '%s\n' \
    xcodebuild \
    -project "$project" \
    -scheme Kiteloop \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "$derived" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= \
    build
}

# Everything inside the bundle that carries code, deepest first, then the bundle
# itself. `codesign --deep` is deprecated and signs nested code with the outer
# entitlements, which is not what any of these want.
nested_code() {
  local app=$1
  find "$app/Contents" \
    \( -name '*.framework' -o -name '*.dylib' -o -name '*.bundle' -o -name '*.appex' \) \
    -print 2>/dev/null | awk '{ print length($0), $0 }' | sort -rn | cut -d' ' -f2-
}

# The signed path, as commands. This is one list so that what --dry-run prints
# and what the signed run executes cannot drift: the same function produces
# both.
signing_commands() {
  local app=$1 entitlements=$2 zip=$3 identity=$4 profile=$5
  local nested

  while IFS= read -r nested; do
    [ -n "$nested" ] || continue
    print_command codesign --force --timestamp --options runtime \
      --sign "$identity" "$nested"
  done < <(nested_code "$app")

  print_command codesign --force --timestamp --options runtime \
    --entitlements "$entitlements" --sign "$identity" "$app"
  print_command codesign --verify --deep --strict --verbose=2 "$app"
  print_command ditto -c -k --keepParent "$app" "$zip"
  print_command xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
  print_command xcrun stapler staple "$app"
  print_command ditto -c -k --keepParent "$app" "$zip"
  print_command spctl --assess --type execute --verbose=2 "$app"
}

# Run what signing_commands describes. Each step is fatal: a notarization that
# came back rejected must not be stapled, and an app that failed to staple must
# not be zipped over the one that did.
run_signing() {
  local app=$1 entitlements=$2 zip=$3 identity=$4 profile=$5
  local nested

  while IFS= read -r nested; do
    [ -n "$nested" ] || continue
    say "Signing $(basename "$nested")"
    codesign --force --timestamp --options runtime \
      --sign "$identity" "$nested" || return 1
  done < <(nested_code "$app")

  say "Signing $(basename "$app")"
  codesign --force --timestamp --options runtime \
    --entitlements "$entitlements" --sign "$identity" "$app" || return 1
  codesign --verify --deep --strict --verbose=2 "$app" || return 1

  say 'Packaging for notarization'
  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip" || return 1

  say 'Submitting to the notary service (this waits, and can take minutes)'
  xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait || return 1

  say 'Stapling the ticket'
  xcrun stapler staple "$app" || return 1

  say 'Repackaging the stapled app'
  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip" || return 1

  say 'Assessing as Gatekeeper would'
  spctl --assess --type execute --verbose=2 "$app" || return 1
}

# --- Installing on this Mac --------------------------------------------------
#
# The everyday copy, for the machine that built it: the same Release build,
# signed with the Developer ID identity so macOS keeps the copy's permissions
# (Full Disk Access, the prompts already answered) from one install to the next,
# and not notarized — notarization is for other people's Macs and needs Apple's
# minutes. Xcode's Debug build is no substitute: every test run and rebuild
# replaces it under the running app.

# Why --install-local cannot run here, or nothing when it can.
install_local_refusal() {
  local dest=$1
  if pgrep -x Kiteloop >/dev/null 2>&1; then
    printf 'Kiteloop is running. Quit it first: the copy in %s is replaced in place.\n' "$dest"
    return
  fi
  if [ -z "${!SIGN_IDENTITY_VAR:-}" ]; then
    printf '%s is not set — the identity the installed copy is signed with, so its\n' "$SIGN_IDENTITY_VAR"
    printf 'macOS permissions survive the next install (docs/release-runbook.md).\n'
  fi
}

# The local install, as commands — what --install-local --dry-run prints and
# what run_local_install executes.
local_install_commands() {
  local app=$1 entitlements=$2 identity=$3 dest=$4
  local nested
  while IFS= read -r nested; do
    [ -n "$nested" ] || continue
    print_command codesign --force --options runtime --sign "$identity" "$nested"
  done < <(nested_code "$app")
  print_command codesign --force --options runtime --entitlements "$entitlements" --sign "$identity" "$app"
  print_command codesign --verify --deep --strict --verbose=2 "$app"
  print_command rm -rf "$dest/Kiteloop.app"
  print_command ditto "$app" "$dest/Kiteloop.app"
}

run_local_install() {
  local app=$1 entitlements=$2 identity=$3 dest=$4
  local nested
  while IFS= read -r nested; do
    [ -n "$nested" ] || continue
    codesign --force --options runtime --sign "$identity" "$nested" || return 1
  done < <(nested_code "$app")
  say "Signing $(basename "$app")"
  codesign --force --options runtime --entitlements "$entitlements" --sign "$identity" "$app" || return 1
  codesign --verify --deep --strict --verbose=2 "$app" || return 1
  say "Installing into $dest"
  rm -rf "$dest/Kiteloop.app" || return 1
  ditto "$app" "$dest/Kiteloop.app" || return 1
}

# Sourcing this file defines its functions and does nothing else, which is how
# scripts/test-make-release.sh drives the readers above without a build, a
# keychain or a network. Executing it falls through to the options.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

dry_run=0
notes_only=0
install_local=0
expect_version=""
output_dir=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --notes-only) notes_only=1 ;;
    --install-local) install_local=1 ;;
    --expect)
      shift
      if [ "$#" -eq 0 ]; then
        fail '--expect needs a version.'
        exit 2
      fi
      expect_version=$1
      ;;
    --expect=*) expect_version=${1#--expect=} ;;
    --output)
      shift
      if [ "$#" -eq 0 ]; then
        fail '--output needs a directory.'
        exit 2
      fi
      output_dir=$1
      ;;
    --output=*) output_dir=${1#--output=} ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option $1"; usage >&2; exit 2 ;;
  esac
  shift
done

# The repo root is resolved from where the *script* lives, not from the caller's
# directory, so this works from the root, from a subdirectory, or from outside
# the checkout.
script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null)
if [ -z "$root" ]; then
  fail "$script_dir is not inside a git checkout."
  exit 1
fi

version=$(resolve_version "$root/$PBXPROJ_RELPATH" "$root/$PROJECT_YML_RELPATH") || exit 1
resolve_resources "$root/$PBXPROJ_RELPATH" "$root/$PROJECT_YML_RELPATH" || exit 1

# A tag is a fourth site, and the one a human typed. Strip a leading v so both
# `--expect v0.3.0` and `--expect 0.3.0` mean the tag they came from.
if [ -n "$expect_version" ]; then
  expected=${expect_version#v}
  if [ "$expected" != "$version" ]; then
    fail "asked for $expected, but the tree says MARKETING_VERSION is $version."
    printf 'Bump the three version sites to %s, or tag the commit that has %s.\n' \
      "$expected" "$version" >&2
    exit 1
  fi
fi

# The credential gate comes before the build, not after it: a run that is going
# to refuse should refuse in a second rather than twenty minutes.
# The local install's own gate, before the build for the same reason: the app
# running, or no identity to sign with, refuses in a second.
if [ "$install_local" -eq 1 ] && [ "$dry_run" -eq 0 ]; then
  refusal=$(install_local_refusal "$INSTALL_DIR")
  if [ -n "$refusal" ]; then
    fail 'cannot install locally:'
    printf '%s\n' "$refusal" >&2
    exit 1
  fi
fi

if [ "$dry_run" -eq 0 ] && [ "$notes_only" -eq 0 ] && [ "$install_local" -eq 0 ]; then
  missing=()
  while IFS= read -r name; do
    [ -n "$name" ] && missing+=("$name")
  done < <(missing_credentials)
  if [ "${#missing[@]}" -gt 0 ]; then
    refuse_missing_credentials "${missing[@]}"
    exit 1
  fi
fi

if [ -n "$output_dir" ]; then
  case "$output_dir" in
    /*) ;;
    *) output_dir="$PWD/$output_dir" ;;
  esac
else
  output_dir="$root/$DEFAULT_OUTPUT_RELPATH"
fi
mkdir -p "$output_dir" || exit 1

zip_path="$output_dir/Kiteloop-$version.zip"
notes_path="$output_dir/Kiteloop-$version-notes.md"

notes=$(changelog_section "$root/$CHANGELOG_RELPATH" "$version")
if [ -z "$notes" ]; then
  fail "$CHANGELOG_RELPATH has no ## $version section — the release would ship with no notes."
  printf 'Add the section, or fix the heading so it starts `## %s`.\n' "$version" >&2
  exit 1
fi
printf '%s\n' "$notes" >"$notes_path" || exit 1
say "Release notes  $notes_path"

# An `unreleased` heading is not an error — it is exactly what the tree looks
# like right up to the commit that ships — but a zip built from one is a
# preview, so say so rather than letting it pass silently.
heading=$(changelog_heading "$root/$CHANGELOG_RELPATH" "$version")
case "$heading" in
  *unreleased*)
    say "Note: the $version section is still marked unreleased. Turn its heading into"
    say "      '## $version — <date>' before publishing."
    ;;
esac

if [ "$notes_only" -eq 1 ]; then
  exit 0
fi

derived="$output_dir/DerivedData"
build_argv=()
while IFS= read -r arg; do
  build_argv+=("$arg")
done < <(xcodebuild_argv "$root/Kiteloop/Kiteloop.xcodeproj" "$derived")

entitlements="$root/$ENTITLEMENTS_RELPATH"
app="$derived/Build/Products/Release/Kiteloop.app"

if [ "$install_local" -eq 1 ] && [ "$dry_run" -eq 1 ]; then
  say 'A local install would run these — no notarizing, no stapling:'
  printf '\n'
  { print_command "${build_argv[@]}"
    local_install_commands "$app" "$entitlements" "\$$SIGN_IDENTITY_VAR" "$INSTALL_DIR"; } | sed 's/^/  /'
  exit 0
fi

say "Building Release $version"
print_command "${build_argv[@]}"
if ! "${build_argv[@]}"; then
  fail 'the Release build failed; nothing was packaged.'
  exit 1
fi

if [ ! -d "$app" ]; then
  fail "the build reported success but $app is not there."
  exit 1
fi

if [ "$install_local" -eq 1 ]; then
  if ! run_local_install "$app" "$entitlements" "${!SIGN_IDENTITY_VAR}" "$INSTALL_DIR"; then
    fail 'the local install did not complete.'
    exit 1
  fi
  say "Installed      $INSTALL_DIR/Kiteloop.app"
  exit 0
fi

if [ "$dry_run" -eq 1 ]; then
  rm -f "$zip_path"
  ditto -c -k --keepParent "$app" "$zip_path" || exit 1
  say "Artifact       $zip_path"
  printf '\n'
  say 'This zip is ad-hoc signed: it runs on this machine and Gatekeeper will'
  say 'refuse it on anyone else'"'"'s. With the credentials set, the signed path'
  say 'would have run these instead of packaging it directly:'
  printf '\n'
  signing_commands "$app" "$entitlements" "$zip_path" \
    "\$$SIGN_IDENTITY_VAR" "\$$NOTARY_PROFILE_VAR" | sed 's/^/  /'
  exit 0
fi

if ! run_signing "$app" "$entitlements" "$zip_path" \
  "${!SIGN_IDENTITY_VAR}" "${!NOTARY_PROFILE_VAR}"; then
  fail 'the signed path did not complete; the artifact is not publishable.'
  exit 1
fi

say "Artifact       $zip_path"
say "Release notes  $notes_path"
