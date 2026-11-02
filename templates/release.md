---
description: Ship a Kiteloop build — the three MARKETING_VERSION sites that must not drift, then the CHANGELOG heading.
epic: Releases
variables:
  - name: version
    description: The version being shipped, e.g. 0.3.0. Patch for fixes, minor for new capability.
    required: true
    pattern: ^\d+\.\d+\.\d+$
---

Kiteloop's ship-a-build checklist, from `CLAUDE.md` → Common Tasks. The
frontmatter above is the template header `BacklogTemplate` (`Kiteloop/Kiteloop/Services/BacklogTemplate.swift`)
decodes: `description`, `epic` (the epic stamped items are filed under, when
the backlog has one by that name) and `variables`, each with `name`, an
optional `description`, `required` (default true) and an optional `pattern`
the supplied value must match whole. The version
lives in three places that must not drift, and the CHANGELOG heading has to stop
saying `unreleased`. Ordered by `needs:`, because the pbxproj is generated from
the XcodeGen spec: bumping it first would be undone by the next
`xcodegen generate`.

Stamp it with `POST /v1/backlog/templates/stamp` (`$H` and `$B` as set in
`docs/autopilot-runbook.md`'s headless section):

```
curl -s -H "$H" -d '{"project":"kiteloop","template":"release",
                     "variables":{"version":"0.3.0"},"apply":true}' \
  $B/backlog/templates/stamp
```

## Item

- [ ] release-{{version}}-spec | Bump MARKETING_VERSION to {{version}} in the XcodeGen spec | size:XS | verify:grep -q 'MARKETING_VERSION: "{{version}}"' Kiteloop/project.yml

## What

`Kiteloop/project.yml` declares `MARKETING_VERSION: "{{version}}"` for the
Kiteloop target.

## How

Edit the `MARKETING_VERSION` line under the Kiteloop target's base settings in
`Kiteloop/project.yml`. This is the spec `xcodegen generate` regenerates the
pbxproj from, so it goes first — bumping the generated file ahead of it would be
reverted by the next regeneration.

## Validation

- [ ] `Kiteloop/project.yml` declares version {{version}}
- [ ] Nothing else in the spec changed

## Out of Scope

- Running `xcodegen generate` — it rewrites every id in the pbxproj, which is a
  whole-file diff nobody can review. The next item edits the pbxproj in place.
- The pbxproj and the CHANGELOG; each is its own item.

## Item

- [ ] release-{{version}}-pbxproj | Bump MARKETING_VERSION to {{version}} in both pbxproj build configurations | size:XS | verify:grep -c 'MARKETING_VERSION = {{version}};' Kiteloop/Kiteloop.xcodeproj/project.pbxproj|grep -qx 2 | needs:release-{{version}}-spec

## What

Both build configurations in `Kiteloop/Kiteloop.xcodeproj/project.pbxproj` — the
Debug one and the Release one — read `MARKETING_VERSION = {{version}};`. This is
what the built app reports as `CFBundleShortVersionString`, and so what
the /health endpoint and the About panel show.

## How

Edit the two `MARKETING_VERSION` lines in place. There are exactly two, and they
must not drift from each other or from `Kiteloop/project.yml`: a build whose two
configurations disagree reports a different version depending on how it was
built.

## Validation

- [ ] Both configurations read `MARKETING_VERSION = {{version}};`
- [ ] The two agree with `Kiteloop/project.yml`
- [ ] No other line of the pbxproj changed

## Out of Scope

- Regenerating the project from the spec.
- The CHANGELOG heading; that is the next item.

## Item

- [ ] release-{{version}}-changelog | Turn the unreleased CHANGELOG heading into {{version}} | size:XS | verify:grep -q '^## {{version}} — [0-9]' CHANGELOG.md | needs:release-{{version}}-pbxproj

## What

`CHANGELOG.md`'s top heading names the release date instead of the word
unreleased, so the notes say the day they shipped.

## How

In `CHANGELOG.md`, replace the word unreleased in the topmost heading for this
version with today's date, written YYYY-MM-DD. Read what is under the heading while you are
there: every entry should describe what changed for someone using the app.

## Validation

- [ ] The heading for {{version}} is followed by a date, not the word unreleased
- [ ] The version in the heading matches the two bumped files
- [ ] No entry text was rewritten

## Out of Scope

- Writing new entries. An entry is written by the item that changed the
  behaviour, not at release time.
- Tagging, building or publishing; this template covers the version bump only.
