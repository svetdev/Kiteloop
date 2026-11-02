#!/bin/bash
# test-make-release — assert the readers and the refusals in
# scripts/make-release.sh: the version check across the three sites that must
# not drift, the CHANGELOG section a release ships as its notes, and the
# credential gate that has to stop a signed run *before* it builds.
#
# None of those can be checked by running the real thing. A release build takes
# minutes and the signed path needs a certificate and a network round-trip to
# Apple, so the one path anybody would actually exercise by hand is the dry run —
# which is precisely the path where a broken version check or a wrong notes
# extraction does not show. So the readers are driven directly, against synthetic
# files, and the refusals are driven end to end through a copy of the script in a
# throwaway checkout whose `xcodebuild` is a stub that records that it was called.
# That last part is the point of the credential case: "exits non-zero" is easy to
# get right by accident, "and built nothing" is the claim that matters, and only
# a stub can testify to it.
#
# It sources make-release.sh, which defines its functions and returns when
# sourced, so nothing here builds, signs, or talks to the notary service. It is
# safe to run at any time, including while Kiteloop is up.
#
#   ./scripts/test-make-release.sh

set -u

here=$(cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
# shellcheck source=make-release.sh
. "$here/make-release.sh"

tmp=$(mktemp -d -t test-make-release) || exit 1
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

# --- The version across three sites ------------------------------------------

printf '\nversion\n'

# A pbxproj with the two MARKETING_VERSION entries a build configuration pair
# has, written the way the real file writes them (tab-indented, trailing
# semicolon, unquoted).
write_pbxproj() {
  local path=$1
  shift
  : >"$path"
  local v
  for v in "$@"; do
    printf '\t\t\t\tPRODUCT_NAME = Kiteloop;\n' >>"$path"
    printf '\t\t\t\tMARKETING_VERSION = %s;\n' "$v" >>"$path"
  done
}

write_yml() {
  printf 'targets:\n  Kiteloop:\n    settings:\n      base:\n        MARKETING_VERSION: "%s"\n' \
    "$2" >"$1"
}

write_pbxproj "$tmp/agree.pbxproj" 0.3.0 0.3.0
write_yml "$tmp/agree.yml" 0.3.0
check 'three sites that agree resolve to the version' \
  '0.3.0' "$(resolve_version "$tmp/agree.pbxproj" "$tmp/agree.yml" 2>/dev/null)"

write_pbxproj "$tmp/pbx-drift.pbxproj" 0.3.0 0.2.9
write_yml "$tmp/pbx-drift.yml" 0.3.0
drift_out=$(resolve_version "$tmp/pbx-drift.pbxproj" "$tmp/pbx-drift.yml" 2>&1 >/dev/null)
check 'a Debug/Release pair that disagrees resolves to nothing' \
  '' "$(resolve_version "$tmp/pbx-drift.pbxproj" "$tmp/pbx-drift.yml" 2>/dev/null)"
check 'a Debug/Release pair that disagrees exits non-zero' \
  '1' "$(resolve_version "$tmp/pbx-drift.pbxproj" "$tmp/pbx-drift.yml" >/dev/null 2>&1; echo $?)"
check_contains 'the drift report names both pbxproj values' '0.2.9' "$drift_out"

write_pbxproj "$tmp/yml-drift.pbxproj" 0.3.0 0.3.0
write_yml "$tmp/yml-drift.yml" 0.2.9
yml_out=$(resolve_version "$tmp/yml-drift.pbxproj" "$tmp/yml-drift.yml" 2>&1 >/dev/null)
check 'a spec that disagrees with the pbxproj exits non-zero' \
  '1' "$(resolve_version "$tmp/yml-drift.pbxproj" "$tmp/yml-drift.yml" >/dev/null 2>&1; echo $?)"
check_contains 'the drift report names the spec and its value' \
  "$tmp/yml-drift.yml: 0.2.9" "$yml_out"

# A site that has gone missing passes any equality check on what is left, which
# is why the count is checked rather than only the values.
write_pbxproj "$tmp/one-site.pbxproj" 0.3.0
write_yml "$tmp/one-site.yml" 0.3.0
missing_site_out=$(resolve_version "$tmp/one-site.pbxproj" "$tmp/one-site.yml" 2>&1 >/dev/null)
check 'a pbxproj that lost one of its two entries is refused' \
  '1' "$(resolve_version "$tmp/one-site.pbxproj" "$tmp/one-site.yml" >/dev/null 2>&1; echo $?)"
check_contains 'and the refusal says what it expected to find' \
  'Debug and Release' "$missing_site_out"

check 'a pbxproj that is not there is refused' \
  '1' "$(resolve_version "$tmp/nope.pbxproj" "$tmp/agree.yml" >/dev/null 2>&1; echo $?)"

# The real files, read by the real readers: this is what keeps the check honest
# if the pbxproj is ever rewritten in a spelling these patterns do not match.
root=$(cd -- "$here/.." && pwd -P) || exit 1
check 'the checked-in tree resolves to a single version' \
  "$(sed -n 's/^[[:space:]]*MARKETING_VERSION: "\(.*\)"$/\1/p' "$root/Kiteloop/project.yml")" \
  "$(resolve_version "$root/Kiteloop/Kiteloop.xcodeproj/project.pbxproj" \
    "$root/Kiteloop/project.yml" 2>/dev/null)"

# --- The bundled resources ----------------------------------------------------

printf '\nresources\n'

# A spec with a `resources:` block naming the given paths, structured the way
# the real file is: `resources:` under `targets: Kiteloop:`, with `settings:`
# as the sibling key that ends the block — the thing project_yml_resources has
# to stop at rather than run past.
write_resources_yml() {
  local path=$1
  shift
  {
    printf 'targets:\n  Kiteloop:\n    resources:\n'
    local p
    for p in "$@"; do
      printf '      - path: %s\n' "$p"
    done
    printf '    settings:\n      base:\n        MARKETING_VERSION: "0.3.0"\n'
  } >"$path"
}

# A pbxproj fragment carrying just enough structure for the readers above: a
# Kiteloop app target (productType application) whose Resources phase builds
# the given names, each as a folder-typed file reference — the shape a real
# `resources: - path:` entry produces.
write_resources_pbxproj() {
  local path=$1
  shift
  local target_id="AAAAAAAAAAAAAAAAAAAAAAAA" phase_id="BBBBBBBBBBBBBBBBBBBBBBBB"
  local files="" buildfiles="" filerefs="" i=0 name buildfile_id fileref_id

  for name in "$@"; do
    i=$((i + 1))
    buildfile_id=$(printf 'C%023d' "$i")
    fileref_id=$(printf 'D%023d' "$i")
    files="$files"$'\t\t\t\t'"$buildfile_id /* $name in Resources */,"$'\n'
    buildfiles="$buildfiles"$'\t\t'"$buildfile_id /* $name in Resources */ = {isa = PBXBuildFile; fileRef = $fileref_id /* $name */; };"$'\n'
    filerefs="$filerefs"$'\t\t'"$fileref_id /* $name */ = {isa = PBXFileReference; lastKnownFileType = folder; path = $name; sourceTree = \"<group>\"; };"$'\n'
  done

  {
    printf '/* Begin PBXBuildFile section */\n%s/* End PBXBuildFile section */\n\n' "$buildfiles"
    printf '/* Begin PBXFileReference section */\n%s/* End PBXFileReference section */\n\n' "$filerefs"
    printf '/* Begin PBXNativeTarget section */\n'
    printf '\t\t%s /* Kiteloop */ = {\n' "$target_id"
    printf '\t\t\tisa = PBXNativeTarget;\n'
    printf '\t\t\tbuildPhases = (\n\t\t\t\t%s /* Resources */,\n\t\t\t);\n' "$phase_id"
    printf '\t\t\tname = Kiteloop;\n'
    printf '\t\t\tproductType = "com.apple.product-type.application";\n'
    printf '\t\t};\n/* End PBXNativeTarget section */\n\n'
    printf '/* Begin PBXResourcesBuildPhase section */\n'
    printf '\t\t%s /* Resources */ = {\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tfiles = (\n%s\t\t\t);\n\t\t};\n' \
      "$phase_id" "$files"
    printf '/* End PBXResourcesBuildPhase section */\n'
  } >"$path"
}

# resolve_resources only compares spec resources that exist relative to the
# yml's own directory — here that is $tmp, since the res-*.yml files below all
# live directly in it — so the paths under test need something on disk.
mkdir -p "$tmp/examples" "$tmp/Assets.xcassets" || exit 1

write_resources_yml "$tmp/res-agree.yml" examples Assets.xcassets
write_resources_pbxproj "$tmp/res-agree.pbxproj" examples Assets.xcassets
check 'a spec and a pbxproj that agree on resources resolve cleanly' \
  '0' "$(resolve_resources "$tmp/res-agree.pbxproj" "$tmp/res-agree.yml" >/dev/null 2>&1; echo $?)"

write_resources_yml "$tmp/res-lost-in-pbx.yml" examples Assets.xcassets
write_resources_pbxproj "$tmp/res-lost-in-pbx.pbxproj" examples
lost_in_pbx_out=$(resolve_resources "$tmp/res-lost-in-pbx.pbxproj" "$tmp/res-lost-in-pbx.yml" 2>&1 >/dev/null)
check 'a pbxproj missing a resource the spec lists is refused' \
  '1' "$(resolve_resources "$tmp/res-lost-in-pbx.pbxproj" "$tmp/res-lost-in-pbx.yml" >/dev/null 2>&1; echo $?)"
check_contains 'and names the missing resource' 'Assets.xcassets' "$lost_in_pbx_out"

write_resources_yml "$tmp/res-lost-in-yml.yml" examples
write_resources_pbxproj "$tmp/res-lost-in-yml.pbxproj" examples Assets.xcassets
lost_in_yml_out=$(resolve_resources "$tmp/res-lost-in-yml.pbxproj" "$tmp/res-lost-in-yml.yml" 2>&1 >/dev/null)
check 'a spec missing a resource the pbxproj builds is refused' \
  '1' "$(resolve_resources "$tmp/res-lost-in-yml.pbxproj" "$tmp/res-lost-in-yml.yml" >/dev/null 2>&1; echo $?)"
check_contains 'and names the missing resource' 'Assets.xcassets' "$lost_in_yml_out"

# A resource path with nothing on disk at that path is refused outright,
# named by the spec file and the entry — it cannot be bundled by either file,
# so a report framed as one-sided drift would be pointing at the wrong side.
write_resources_yml "$tmp/res-phantom.yml" examples nonexistent-resource
write_resources_pbxproj "$tmp/res-phantom.pbxproj" examples
phantom_out=$(resolve_resources "$tmp/res-phantom.pbxproj" "$tmp/res-phantom.yml" 2>&1 >/dev/null)
check 'a spec resource with no path on disk is refused' \
  '1' "$(resolve_resources "$tmp/res-phantom.pbxproj" "$tmp/res-phantom.yml" >/dev/null 2>&1; echo $?)"
check_contains 'and names the spec file' "$tmp/res-phantom.yml" "$phantom_out"
check_contains 'and names the offending path' 'nonexistent-resource' "$phantom_out"

# A resource named in *both* files, whose directory has since been deleted, is
# reported as a path that is missing — not as an entry only the pbxproj
# lists, which is what a comparison run over the unfiltered names would say.
write_resources_yml "$tmp/res-phantom-both.yml" examples gone-resource
write_resources_pbxproj "$tmp/res-phantom-both.pbxproj" examples gone-resource
both_out=$(resolve_resources "$tmp/res-phantom-both.pbxproj" "$tmp/res-phantom-both.yml" 2>&1 >/dev/null)
check 'a phantom resource named in both files is still refused' \
  '1' "$(resolve_resources "$tmp/res-phantom-both.pbxproj" "$tmp/res-phantom-both.yml" >/dev/null 2>&1; echo $?)"
check_contains 'reported as missing, not as pbxproj-only' \
  "$tmp/res-phantom-both.yml: gone-resource" "$both_out"
check_lacks 'and not as a pbxproj-only drift entry' \
  "$tmp/res-phantom-both.pbxproj: gone-resource" "$both_out"

# The real files, read by the real readers: this is what keeps the check honest
# if either file is ever rewritten in a spelling these patterns do not match.
check 'the checked-in tree agrees on its bundled resources' \
  '0' "$(resolve_resources "$root/Kiteloop/Kiteloop.xcodeproj/project.pbxproj" \
    "$root/Kiteloop/project.yml" >/dev/null 2>&1; echo $?)"

# --- The release notes -------------------------------------------------------

printf '\nchangelog\n'

cat >"$tmp/CHANGELOG.md" <<'CHANGELOG'
# Changelog

Some preamble that is not part of any release.

## 0.3.0 — unreleased

### Added

- A thing.

## 0.2.2 — 2026-08-11

### Fixes

- An older thing.

## 0.2.1 — 2026-08-01

- The oldest thing.
CHANGELOG

check 'the extracted section is exactly the tagged version, without its heading' \
  '### Fixes

- An older thing.' \
  "$(changelog_section "$tmp/CHANGELOG.md" 0.2.2)"

check 'the newest section stops at the next heading rather than running on' \
  '### Added

- A thing.' \
  "$(changelog_section "$tmp/CHANGELOG.md" 0.3.0)"

check 'the preamble above the first heading belongs to no version' \
  '- The oldest thing.' "$(changelog_section "$tmp/CHANGELOG.md" 0.2.1)"

check 'a version with no section extracts nothing' \
  '' "$(changelog_section "$tmp/CHANGELOG.md" 9.9.9)"

# `## 0.2` must not match `## 0.2.2` — the dot is a literal here, and a prefix
# is a different release.
check 'a version that is a prefix of another does not borrow its section' \
  '' "$(changelog_section "$tmp/CHANGELOG.md" 0.2)"

check 'the heading reader finds the unreleased marker' \
  '## 0.3.0 — unreleased' "$(changelog_heading "$tmp/CHANGELOG.md" 0.3.0)"
check 'and reads a dated heading as the dated one it is' \
  '## 0.2.2 — 2026-08-11' "$(changelog_heading "$tmp/CHANGELOG.md" 0.2.2)"

# --- The credentials ---------------------------------------------------------

printf '\ncredentials\n'

check 'with neither set, both are named' \
  'KITELOOP_SIGN_IDENTITY
KITELOOP_NOTARY_PROFILE' \
  "$(KITELOOP_SIGN_IDENTITY= KITELOOP_NOTARY_PROFILE= missing_credentials)"

check 'with only the identity set, the notary profile is named and it alone' \
  'KITELOOP_NOTARY_PROFILE' \
  "$(KITELOOP_SIGN_IDENTITY='Developer ID Application: Someone' \
     KITELOOP_NOTARY_PROFILE= missing_credentials)"

check 'with only the profile set, the identity is named and it alone' \
  'KITELOOP_SIGN_IDENTITY' \
  "$(KITELOOP_SIGN_IDENTITY= KITELOOP_NOTARY_PROFILE=kiteloop-notary missing_credentials)"

check 'with both set, nothing is named' \
  '' \
  "$(KITELOOP_SIGN_IDENTITY='Developer ID Application: Someone' \
     KITELOOP_NOTARY_PROFILE=kiteloop-notary missing_credentials)"

# An empty variable is not a credential, and `export FOO=` is how a CI runner
# spells "this secret is not configured" — so it has to read as unset here.
check 'a variable set to the empty string counts as missing' \
  'KITELOOP_SIGN_IDENTITY' \
  "$(export KITELOOP_SIGN_IDENTITY=''
     export KITELOOP_NOTARY_PROFILE=kiteloop-notary
     missing_credentials)"

# --- What the script does with all that, end to end --------------------------
#
# A throwaway checkout with the three version sites, a CHANGELOG, an
# entitlements file, and an `xcodebuild` that only records that it was called.
# `git init` because the script resolves the repo root from where it lives.

printf '\nthe script\n'

repo="$tmp/repo"
mkdir -p "$repo/scripts" "$repo/Kiteloop/Kiteloop.xcodeproj" "$repo/Kiteloop/Kiteloop" "$repo/bin" || exit 1
cp "$here/make-release.sh" "$repo/scripts/" || exit 1
git -C "$repo" init -q 2>/dev/null || exit 1

write_pbxproj "$repo/Kiteloop/Kiteloop.xcodeproj/project.pbxproj" 0.3.0 0.3.0
write_yml "$repo/Kiteloop/project.yml" 0.3.0
printf '<plist/>\n' >"$repo/Kiteloop/Kiteloop/Kiteloop.entitlements"
cat >"$repo/CHANGELOG.md" <<'CHANGELOG'
# Changelog

## 0.3.0 — 2026-08-11

### Added

- A thing.
CHANGELOG

calls="$tmp/calls"
: >"$calls"
cat >"$repo/bin/xcodebuild" <<STUB
#!/bin/bash
printf 'xcodebuild\n' >>"$calls"
exit 0
STUB
chmod +x "$repo/bin/xcodebuild"

# Run the copy with the stub ahead of the real thing on PATH, from outside the
# checkout, so the root resolution is exercised too.
run_release() {
  : >"$calls"
  (
    cd "$tmp" || exit 1
    PATH="$repo/bin:$PATH" "$repo/scripts/make-release.sh" "$@" 2>&1
  )
}

unset KITELOOP_SIGN_IDENTITY KITELOOP_NOTARY_PROFILE

signed_out=$(run_release --output "$tmp/out")
check 'the signed path with no credentials exits non-zero' \
  '1' "$(run_release --output "$tmp/out" >/dev/null 2>&1; echo $?)"
check_contains 'and names the signing identity variable' \
  'KITELOOP_SIGN_IDENTITY' "$signed_out"
check_contains 'and names the notary profile variable' \
  'KITELOOP_NOTARY_PROFILE' "$signed_out"
check 'and starts no build: a refusal that half-signs is the failure this prevents' \
  '' "$(cat "$calls")"

# The other side of that gate: an environment that *has* the credentials is not
# stopped by it. This run gets as far as the build — which the stub answers
# without producing an app, so it stops there — and the point is which of the two
# it stopped at.
configured_out=$(KITELOOP_SIGN_IDENTITY='Developer ID Application: Someone' \
  KITELOOP_NOTARY_PROFILE=kiteloop-notary run_release --output "$tmp/out")
check 'with both credentials set the signed path reaches the build' \
  'xcodebuild' "$(cat "$calls")"
check_lacks 'and says nothing about missing credentials' \
  'does not set' "$configured_out"
check_contains 'a build that produced no app is reported as that, not as success' \
  'is not there' "$configured_out"

# --expect is the tag as a fourth site. A mismatch is caught before the build for
# the same reason.
mismatch_out=$(run_release --dry-run --expect v0.3.1 --output "$tmp/out")
check 'a tag that does not match the tree exits non-zero' \
  '1' "$(run_release --dry-run --expect v0.3.1 --output "$tmp/out" >/dev/null 2>&1; echo $?)"
check_contains 'and says both what was asked for and what the tree says' \
  'asked for 0.3.1, but the tree says MARKETING_VERSION is 0.3.0' "$mismatch_out"
check 'and starts no build' '' "$(cat "$calls")"

check 'a tag that matches, with or without its v, is accepted' \
  '0' "$(run_release --notes-only --expect v0.3.0 --output "$tmp/out" >/dev/null 2>&1; echo $?)"

# --notes-only is the whole of the notes path without the build behind it.
notes_out=$(run_release --notes-only --output "$tmp/out")
check 'the notes run starts no build' '' "$(cat "$calls")"
check 'the notes file carries exactly the tagged section' \
  '### Added

- A thing.' \
  "$(cat "$tmp/out/Kiteloop-0.3.0-notes.md")"
check_contains 'and the run says where it wrote it' \
  "$tmp/out/Kiteloop-0.3.0-notes.md" "$notes_out"
check_lacks 'a dated heading draws no unreleased warning' 'unreleased' "$notes_out"

# The version in the artifact's name comes from the tree, so a bump moves it.
write_pbxproj "$repo/Kiteloop/Kiteloop.xcodeproj/project.pbxproj" 0.4.0 0.4.0
write_yml "$repo/Kiteloop/project.yml" 0.4.0
printf '\n## 0.4.0 — unreleased\n\n- Next.\n' >>"$repo/CHANGELOG.md"
bumped_out=$(run_release --notes-only --output "$tmp/out")
check 'the notes file is named for the version the tree carries' \
  '- Next.' "$(cat "$tmp/out/Kiteloop-0.4.0-notes.md")"
check_contains 'an unreleased heading is called out rather than passing silently' \
  'still marked unreleased' "$bumped_out"

# A version nobody wrote a section for would ship a release with an empty body.
write_pbxproj "$repo/Kiteloop/Kiteloop.xcodeproj/project.pbxproj" 0.5.0 0.5.0
write_yml "$repo/Kiteloop/project.yml" 0.5.0
no_notes_out=$(run_release --dry-run --output "$tmp/out")
check 'a version with no CHANGELOG section exits non-zero' \
  '1' "$(run_release --dry-run --output "$tmp/out" >/dev/null 2>&1; echo $?)"
check_contains 'and says which section is missing' \
  'no ## 0.5.0 section' "$no_notes_out"
check 'and starts no build' '' "$(cat "$calls")"

# Drift refusal, through the executed script rather than the reader alone.
write_pbxproj "$repo/Kiteloop/Kiteloop.xcodeproj/project.pbxproj" 0.5.0 0.5.0
write_yml "$repo/Kiteloop/project.yml" 0.4.9
drift_run=$(run_release --dry-run --output "$tmp/out")
check 'a tree whose version sites disagree exits non-zero' \
  '1' "$(run_release --dry-run --output "$tmp/out" >/dev/null 2>&1; echo $?)"
check_contains 'and says so in those words' 'disagrees across the three sites' "$drift_run"
check 'and starts no build' '' "$(cat "$calls")"

# --- --help ------------------------------------------------------------------

printf '\nhelp\n'

help_out=$("$repo/scripts/make-release.sh" --help)
check_contains '--help prints the usage lines' '--dry-run' "$help_out"
check_lacks '--help prints no shell code as though it were documentation' \
  'set -u' "$help_out"

printf '\n'
if [ "$failed" -eq 0 ]; then
  printf 'test-make-release: all cases passed.\n'
  exit 0
fi
printf 'test-make-release: %s case(s) failed.\n' "$failed" >&2
exit 1
