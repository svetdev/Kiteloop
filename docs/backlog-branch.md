# The shared backlog branch

Where a team's backlog lives: on an **orphan git branch** (`kiteloop/backlog`)
of the project's own repository — the `gh-pages` pattern applied to work
items. The branch holds `BACKLOG.md` (and, in future, `backlog/` detail
files) with no code history. Kiteloop keeps a private checkout of it under
`.kiteloop/backlog-tree/` and never checks it out into the project's working
tree.

## The problem it solves

A team backlog has four requirements that pull against each other:

1. **Shared across the team** — everyone sees the same items and statuses.
2. **Shared across machines** — your laptop and your desktop agree.
3. **Survives a clone** — a fresh checkout of the repo brings the backlog.
4. **Never in the repo's working tree** — the autopilot's merge gate refuses
   a dirty tree, and the app writes the backlog constantly (status flips,
   notes), so a committed `BACKLOG.md` would block every merge or generate a
   commit per status change.

Committing the backlog satisfies 1–3 and breaks 4. Keeping it outside the
repo (the [vault](backlog-format.md#where-the-file-lives)) satisfies 4 and
breaks 1 and 3. The branch satisfies all
four: it rides the remote the team already shares (1, 2), a clone brings the
branch (3), and the working tree never contains it (4). Bonus: every backlog
change is a commit, so who-changed-what-when history comes free.

## Resolution order

When a project opens, `BacklogViewModel.loadForProject` looks for a backlog
in this order — each layer a strict fallback of the one before:

1. **Project-local `BACKLOG.md`** in the repo root. Self-contained, travels
   with the repo, right for a solo project that doesn't mind the tree churn
   (or doesn't run the autopilot merge gate).
2. **The shared branch.** If `kiteloop/backlog` exists — as a local branch or
   a remote-tracking ref the clone brought — the app materializes the private
   checkout and uses its `BACKLOG.md`. This is the team default: a teammate
   clones, opens the project, and the backlog is simply there.
3. **The vault** (Settings → General), via the registry mapping — the
   cross-project personal layer.

The detection at step 2 is deliberately offline: it reads
`refs/remotes/origin/kiteloop/backlog` from the clone's own knowledge, never
`ls-remote` over the network.

## Lifecycle

**Creating.** Backlog tab → empty state → *"Create shared team backlog (git
branch)"*. The app runs `git worktree add --orphan` for the branch, writes a
starter backlog, commits, and pushes to `origin` (best-effort — no remote or
no network leaves a working local branch that pushes on a later sync).

**Adopting.** Nothing to do. Opening a cloned project finds the
remote-tracking ref and materializes the checkout automatically.

**Writing.** Every backlog write the app makes becomes a commit on the branch
(`kiteloop: backlog update`). Pushes are rate-limited (at most one per
minute per project) so a burst of status flips costs one round-trip.

**Syncing.** On project open the app fetches and fast-forwards, then pushes
anything local. The file watcher picks up whatever the fast-forward brings,
same as any external edit.

## What this design deliberately does not do

- **No semantic merge.** If the branch *diverges* — two machines committed
  while apart — the app logs it loudly, keeps using the local copy, and
  leaves resolution to a human (`git` in `.kiteloop/backlog-tree/`). A wrong
  automatic resolution of a team's backlog is strictly worse than a loud
  manual one. The planned fix is an app-level merge that understands the
  format (items union; newest status wins; collisions become Notes).
- **No cross-machine claim on items.** Two machines running autopilot against
  one backlog can pick up the same ready item — the one-run-per-project guard
  lives inside a single app instance. Until a claimed-by field exists, run
  the autopilot for a given project from one machine at a time; other
  machines can groom, review and approve freely.
- **No monorepo namespacing.** One repo, one backlog at the branch root. A
  repo hosting several Kiteloop projects (sub-roots opened separately) would
  need per-path folders on the branch, which this design does not provide.

## Operational notes

- The branch appears in `git branch -a` as `kiteloop/backlog` — expected, and
  the name is the explanation.
- Branch-protection rules that restrict pushes may need the `kiteloop/*`
  pattern allowed for whoever runs Kiteloop.
- Single-branch shallow clones don't bring the remote-tracking ref; a plain
  `git fetch origin kiteloop/backlog` makes the project adoptable.
- The private checkout lives inside `.kiteloop/`, which projects seeded by
  Kiteloop already gitignore. It is a real git worktree — anything `git` can
  do in it works, including hand-editing the backlog and committing.
