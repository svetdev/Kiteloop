# Release runbook

How a Kiteloop version becomes a signed, notarized zip a stranger's Mac will
open, and an entry in the update feed that offers it to every copy already
installed. `scripts/make-release.sh` is the whole path — it does every step below
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

5. **The update signing key.** Kiteloop updates itself through
   [Sparkle](https://sparkle-project.org), which only installs a download
   signed with a key the installed copy already trusts. Generate that key once,
   with the tool the package brings (any build resolves it):

   ```bash
   cd "$(git rev-parse --show-toplevel)"
   ./scripts/make-release.sh --dry-run   # resolves Sparkle into dist/DerivedData
   dist/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

   The private half goes into your login keychain. The public half is printed;
   put it in `Kiteloop/Kiteloop/Info.plist`, beside the feed address, and commit
   it:

   ```xml
   <key>SUPublicEDKey</key>
   <string>the base64 string generate_keys printed</string>
   ```

   **Back the private key up** — `generate_keys -x <file>` exports it, and
   `-f <file>` imports it on another Mac. A lost key cannot be replaced: every
   copy already installed trusts that key only, and would have to be updated by
   hand. The script refuses a signed release from a tree with no
   `SUPublicEDKey`, and from a keychain whose key is not that one.

6. **Where the feed is published.** Installed copies read
   `https://kasatkin.ai/kiteloop/appcast.xml` — `SUFeedURL` in the same
   `Info.plist`, and permanent: it is in every copy ever shipped. That file is
   `public/kiteloop/appcast.xml` in the site's checkout. Point the script at it
   so each release carries the earlier entries forward and writes the new feed
   back:

   ```bash
   export KITELOOP_APPCAST=~/path/to/site-checkout/public/kiteloop/appcast.xml
   ```

Keep the `.p8`, the exported `.p12` and an exported update key **outside the
repository** — a key that lands in a commit is a key to revoke.

### Releasing

1. **Bump the version.** `MARKETING_VERSION` in the three places `CLAUDE.md`
   names — the Debug and Release entries in
   `Kiteloop/Kiteloop.xcodeproj/project.pbxproj`, and `Kiteloop/project.yml`.
   Patch for fixes, minor for new capability. The script refuses to build if they
   disagree, so a missed one costs you seconds rather than a bad artifact. The
   build number (`CFBundleVersion`) is the same number — it is what Sparkle
   orders releases by — so there is nothing else to bump, and a version cannot
   be shipped twice.


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
   `dist/Kiteloop-<version>-notes.md`, then prints the signing and feed
   commands it did not run. Read the notes file: it is what everyone will see,
   on the release page and in the update window.

4. **Build the real one.**

   ```bash
   ./scripts/make-release.sh
   ```

   It builds, signs, submits to Apple and waits — notarization usually takes a
   few minutes and occasionally much longer — staples the ticket, repackages, and
   asks Gatekeeper for its verdict on the result. Then it writes the update
   feed: `dist/appcast.xml`, with this version's entry — the zip's address on
   the GitHub Release, its EdDSA signature, and the notes — above the entries
   `KITELOOP_APPCAST` already held, and copies it back over that file. A failure
   at any step leaves you without an artifact rather than with a bad one.

5. **Tag and push.** Take the version from the tree rather than retyping it —
   the script has already checked that all three sites agree on it:

   ```bash
   VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' Kiteloop/project.yml)
   echo "$VERSION"
   git tag -a "v$VERSION" -m "Kiteloop $VERSION" && git push origin "v$VERSION"
   ```

   `origin` is the remote of a fresh clone; push to whichever remote
   `git remote -v` shows for the public repository. Skipping this step still
   publishes — `gh release create` makes the tag on GitHub itself — but that
   tag is not annotated and is missing here until `git fetch --tags`.

6. **Publish.** Create the GitHub Release from the tag with the zip you built
   in step 4 and the version's `CHANGELOG.md` section as its notes — the script
   wrote that section to `dist/Kiteloop-<version>-notes.md`:

   ```bash
   gh release create "v$VERSION" "dist/Kiteloop-$VERSION.zip" --title "Kiteloop $VERSION" --notes-file "dist/Kiteloop-$VERSION-notes.md"
   ```

7. **Publish the feed — after the zip, never before.** The feed names the zip's
   address on the release, so it must not go live while that address is a 404.
   Commit and push `public/kiteloop/appcast.xml` in the site's checkout, wait
   for its deploy, and check what installed copies will now read:

   ```bash
   curl -sI https://kasatkin.ai/kiteloop/appcast.xml | head -1
   curl -s https://kasatkin.ai/kiteloop/appcast.xml | grep -c "Kiteloop-$VERSION.zip"
   ```

   `200` and `1`. From here every installed copy is offered the version at its
   next check. To pull a release, revert that commit in the site's checkout:
   copies that have not updated yet stop being offered it.

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

### Checking that copies update

The updater is Sparkle's, and what proves a release is a copy updating itself.
After step 7, on a Mac running the previous version, choose **Kiteloop > Check
for Updates…**: the window names the new version with its notes, and Install
downloads it, verifies it and relaunches into it — About and `/health` then
report the new version. With a run in flight, the relaunch asks the same
question Cmd-Q does.

The first release that carries Sparkle cannot be checked this way: no earlier
copy knows how to update, so it is installed by hand, and the release after it
is the first one a copy can fetch for itself.

Installing by hand over an older copy needs no uninstall: quit Kiteloop, unzip
the release, drag `Kiteloop.app` into Applications and choose Replace. Settings,
agents and projects live outside the bundle and are kept. If the older copy was
built locally rather than signed with the Developer ID, macOS sees a different
app and asks once more for the privacy permissions it had granted.

### The copy on your own Mac

For the app you use every day, install a Release build rather than running
Xcode's Debug build, which every test run and rebuild replaces under you:

```bash
KITELOOP_SIGN_IDENTITY="Developer ID Application: <you> (<team>)" ./scripts/make-release.sh --install-local
```

It builds the same Release app, signs it with your Developer ID identity — so
macOS keeps its permissions, Full Disk Access included, from one install to the
next — skips notarizing and stapling, and copies it to `/Applications`
(`KITELOOP_INSTALL_DIR` overrides where). It refuses before building while
Kiteloop is running, and with no identity set. `--install-local --dry-run`
prints what it would run. The copy is not notarized, so it is for this Mac,
not for sending to anyone.

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
