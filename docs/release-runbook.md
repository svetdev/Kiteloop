# Release runbook

How a Kiteloop version becomes a signed, notarized zip a stranger's Mac will
open. `scripts/make-release.sh` is the whole path — it does every step below
or refuses to do any of them. It runs on your Mac; nothing builds a release
on a hosted runner.

### What "publishable" means here

macOS will not open an app downloaded from the internet unless it is signed with
a Developer ID certificate, hardened-runtime enabled, notarized by Apple, and
stapled with the resulting ticket. Miss any one of those and the person you sent
it to gets *"Kiteloop is damaged and can't be opened"* — which is Gatekeeper's
wording for "unsigned", and reads to them as a broken download.

`scripts/make-release.sh` does all four, or refuses to do any of them. There is
no half-signed path through it, because a half-signed app launches for the person
who built it and fails for everyone else.

### One-time setup

You need an Apple Developer Program membership (the certificate below is not
available without one).

1. **Developer ID Application certificate.** In Xcode → Settings → Accounts →
   your team → Manage Certificates → **+** → *Developer ID Application*. Confirm
   it landed:

   ```bash
   security find-identity -v -p codesigning | grep 'Developer ID Application'
   ```

   The quoted name in that output — `Developer ID Application: Your Name
   (TEAMID)` — is `KITELOOP_SIGN_IDENTITY`.

2. **App Store Connect API key** for notarization, at
   [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → Users and
   Access → Integrations → **Team Keys** → **+**, with the *Developer* role.
   You get a `.p8` file that downloads exactly once, a **Key ID**, and an
   **Issuer ID**.

3. **Store the notary credential** under a profile name the script can pass to
   `notarytool`:

   ```bash
   xcrun notarytool store-credentials kiteloop-notary \
     --key ~/private_keys/AuthKey_XXXXXXXXXX.p8 \
     --key-id XXXXXXXXXX \
     --issuer aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
   ```

   That name — `kiteloop-notary` — is `KITELOOP_NOTARY_PROFILE`. It lives in your
   keychain; the `.p8` itself is not needed again, but keep it, because it cannot
   be re-downloaded.

4. **Export the two names** into the shell you release from (a shell profile is
   fine; neither is a secret on its own):

   ```bash
   export KITELOOP_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
   export KITELOOP_NOTARY_PROFILE=kiteloop-notary
   ```

Keep the `.p8` and the exported `.p12` **outside the repository** — a key
that lands in a commit is a key to revoke.

### Releasing

1. **Bump the version.** `MARKETING_VERSION` in the three places `CLAUDE.md`
   names — the Debug and Release entries in
   `Kiteloop/Kiteloop.xcodeproj/project.pbxproj`, and `Kiteloop/project.yml`.
   Patch for fixes, minor for new capability. The script refuses to build if they
   disagree, so a missed one costs you seconds rather than a bad artifact.


   ```bash
   cd "$(git rev-parse --show-toplevel)"
   grep -n 'MARKETING_VERSION' Kiteloop/project.yml Kiteloop/Kiteloop.xcodeproj/project.pbxproj
   grep -n '^## ' CHANGELOG.md | head -3
   ```

2. **Date the changelog.** Turn `## <version> — unreleased` in `CHANGELOG.md`
   into `## <version> — <date>`. That section, verbatim, is what the release
   notes will be. Read it first:

   ```bash
   ./scripts/make-release.sh --notes-only --output /tmp/kiteloop-notes
   ```

3. **Rehearse.** This needs no credentials, and catches everything except the two
   Apple calls:

   ```bash
   ./scripts/make-release.sh --dry-run
   ```

   It writes `dist/Kiteloop-<version>.zip` and
   `dist/Kiteloop-<version>-notes.md`, then prints the signing commands it did
   not run. Read the notes file: it is what everyone will see.

4. **Build the real one.**

   ```bash
   ./scripts/make-release.sh
   ```

   It builds, signs, submits to Apple and waits — notarization usually takes a
   few minutes and occasionally much longer — staples the ticket, repackages, and
   asks Gatekeeper for its verdict on the result. A failure at any step leaves
   you without an artifact rather than with a bad one.

5. **Tag and push.** Take the version from the tree rather than retyping it —
   the script has already checked that all three sites agree on it:

   ```bash
   VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' Kiteloop/project.yml)
   echo "$VERSION"
   git tag -a "v$VERSION" -m "Kiteloop $VERSION" && git push origin "v$VERSION"
   ```

6. **Publish.** Create the GitHub Release from the tag with the zip you built
   in step 4 and the version's `CHANGELOG.md` section as its notes:

   ```bash
   gh release create "v$VERSION" "dist/Kiteloop-$VERSION.zip" --title "Kiteloop $VERSION" --notes-file <notes.md>
   ```

### Verifying an artifact

What the person downloading it will experience, on a Mac that has never seen your
certificate:

```bash
spctl --assess --type execute --verbose=2 /Applications/Kiteloop.app
xcrun stapler validate /Applications/Kiteloop.app
```

`accepted / source=Notarized Developer ID` and `The validate action worked!` are
the two answers you want. Anything else means the download is broken for everyone
but you.

### The phone app on TestFlight

`scripts/make-mobile-release.sh` archives the iOS companion, signs it for
distribution under your team and uploads it to TestFlight as an internal build.
Internal builds need no App Store review, so a build is on your phone minutes
after the upload finishes processing.

One-time setup:

1. **The app record.** In App Store Connect → Apps → **+** → New App: platform
   iOS, bundle id `ai.kasatkin.kiteloop.mobile` (register it under Certificates,
   Identifiers & Profiles first if it is not offered), any name and SKU.
2. **Yourself as an internal tester.** The app → TestFlight → Internal Testing →
   **+** a group, add your Apple Account, and turn on automatic distribution.
3. **The API key.** The Team Key from step 2 of the one-time setup above works,
   given the *App Manager* role or higher; uploading needs more than the
   *Developer* role notarization does. Export the three values it came with:

   ```bash
   export KITELOOP_ASC_KEY_ID=XXXXXXXXXX
   export KITELOOP_ASC_ISSUER_ID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
   export KITELOOP_ASC_KEY_PATH=~/private_keys/AuthKey_XXXXXXXXXX.p8
   ```

4. **The team.** `DEVELOPMENT_TEAM` in `KiteloopMobile/Signing.local.xcconfig`,
   or `KITELOOP_MOBILE_TEAM` in the environment.
5. **Push notifications.** At developer.apple.com → Certificates, Identifiers &
   Profiles → Keys → **+**, enable *Apple Push Notifications service* and
   download the `.p8` (once only). In the Mac app, **Settings → Control API →
   Push to phones** takes its path, its Key ID and your Team ID. The phone app
   asks to notify after pairing and registers itself; its widget extension
   (`ai.kasatkin.kiteloop.mobile.widgets`, the Live Activity) is archived and
   uploaded with it.

Then, for each build:

```bash
./scripts/make-mobile-release.sh --dry-run   # the plan, and what is still missing
./scripts/make-mobile-release.sh             # archive, export, upload
```

The build number is HEAD's commit count, so commit before uploading again:
TestFlight refuses a build number it has already seen. The version is
`MARKETING_VERSION` in `KiteloopMobile/project.yml`, which the script checks
against the pbxproj.
