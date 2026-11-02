<!--
This mirrors Kiteloop's Definition of Done — the same bar its own agents are
held to. The full rubric is in CLAUDE.md; CONTRIBUTING.md has the build and
test commands.
-->

## What changed

<!-- One or two sentences, plus the issue or backlog item id if there is one. -->

## How it was verified

<!--
Paste the command you ran and its outcome. The standing check compiles the app
and the test bundles without launching anything:

    cd Kiteloop
    xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination "platform=macOS" build-for-testing

For the full unit suite, quit Kiteloop first (it hosts the tests) and run
`./scripts/run-unit-suite.sh`.
-->

```
```

## Checklist

- [ ] The build passes — `build-for-testing`, or the item's `verify:` command.
- [ ] Only the files this change implies are touched; no unrelated edits.
- [ ] Tests added or updated for any change in behaviour. A docs-only or
      comment-only change has no behaviour to assert — its bar is accuracy
      against the code instead.
- [ ] `CHANGELOG.md` has a one-line entry under the current
      `## <version> — unreleased` heading, if a user would notice this change.
      Say what changed for someone using the app — not the files touched.
- [ ] Docs this change invalidates are updated — `docs/control-api.md` for API
      surface, `docs/features.md` for a new capability.
- [ ] `docs/suite-status.md` is untouched. It is written only by
      `scripts/run-unit-suite.sh`; a row in a PR diff is a measurement nobody
      took.
- [ ] Nothing left half-done; no TODOs standing in for the acceptance criteria.
