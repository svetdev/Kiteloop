# Unattended Permissions (macOS TCC)

The one-time setup that stops macOS privacy dialogs from firing during an
unattended run. (Diátaxis: this is a *how-to*. For running the autopilot see
[`autopilot-runbook.md`](autopilot-runbook.md); for where an item's files live
see [`worktree-isolation.md`](worktree-isolation.md); for the execution model see
[ADR-0001](adr/0001-autonomous-run-model.md).)

A TCC prompt is modal and waits for a human. In an attended session that costs
you a click; in an unattended queue it stalls the item until the watchdog kills
it. Do §A once and the dialog never appears again.

## Why it happens here

Kiteloop is **not sandboxed** (`com.apple.security.app-sandbox` = `false` in
`Kiteloop/Kiteloop.entitlements`), so it is subject to the ordinary
user-consent rules for the protected folders: `~/Documents`, `~/Desktop`,
`~/Downloads`, iCloud Drive, network and removable volumes, and other apps'
data under `~/Library`. Everything else in your home directory — `~/code`,
`~/Developer`, `~/.kiteloop` — is unprotected.

Each agent is a `claude` subprocess spawned directly by the app
(`ClaudeCodeCLIRuntime.provision`, `Kiteloop/Kiteloop/Runtime/ClaudeCodeCLIRuntime.swift:461`,
with `Process()` on the line after), using whichever binary
`KiteloopCore/Sources/KiteloopCore/Services/CLIResolver.swift` resolved. macOS attributes the access
request to the **responsible process**, which for that spawn is Kiteloop
itself — you can watch it decide:

```
tccd: Handling access request to kTCCServiceSystemPolicyAllFiles,
      from Sub:{ai.kasatkin.kiteloop}Resp:{… /Kiteloop.app/Contents/MacOS/Kiteloop},
      ReqResult(Auth Right: Allowed …)
```

Launched any other way — from a terminal, from an editor extension — `claude`
carries its own signing identity, `com.anthropic.claude-code`, and is asked
separately. Both identities can end up gated, so §A grants both.

**Why you cannot just pre-approve the three folders:** System Settings →
Privacy & Security → *Files and Folders* only lists clients that have already
asked, so there is nothing to switch on ahead of time. *Full Disk Access* is the
only one of these lists with a **+** button, which is what makes it the
unattended answer.

## A. Grant Full Disk Access

1. Open the pane:

   ```bash
   open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
   ```

2. Click **+** and add **Kiteloop.app**. A dev build lives in DerivedData, not
   `/Applications` — the file picker takes a pasted path with <kbd>⌘⇧G</kbd>:

   ```bash
   ls -d ~/Library/Developer/Xcode/DerivedData/Kiteloop-*/Build/Products/Debug/Kiteloop.app
   ```

3. Click **+** again and add the **`claude` binary**. <kbd>⌘⇧G</kbd> →
   `~/.local/bin/claude`. That path is a symlink into
   `~/.local/share/claude/versions/<version>`; the picker follows it, which is
   fine — see *What the grants are bound to* below.

   ```bash
   which claude          # confirm which one Kiteloop will resolve
   ```

4. **Quit and relaunch Kiteloop.** A process caches its TCC decisions, so the
   already-running app and its live agent sessions keep the old answer.

5. **If you use the QA flow** ([`qa-flow.md`](qa-flow.md)), add the **QA copy**
   too. It is a separate app — `ai.kasatkin.kiteloop.qa`, built by
   `scripts/qa/run-ui-flow.sh` — so it has its own grants, and an unanswered
   prompt sits over the window and fails the flow's next step:

   ```bash
   ls -d ~/Library/Caches/kiteloop-qa/DerivedData/Build/Products/Debug/Kiteloop.app
   ```

   It is signed with the same **Kiteloop Local Signing** certificate, so the
   grant survives the rebuild every QA run does. A prompt Full Disk Access does
   not cover (Apple Music and the media library have been seen) needs answering
   once, with either button: the answer is kept the same way.

The result is two entries:

| Entry | TCC client | Covers |
|---|---|---|
| `Kiteloop.app` | `ai.kasatkin.kiteloop` | every agent spawned by the app, and the app's own project reads |
| `claude` | `com.anthropic.claude-code` | `claude` run outside Kiteloop (terminal, editor extension) |

### What the grants are bound to

Not to a path and not to a build. TCC stores the client's code-signing
requirement, so for Kiteloop the entry is `identifier "ai.kasatkin.kiteloop"`
plus the leaf hash of the **Kiteloop Local Signing** certificate:

```bash
codesign -d -r- ~/Library/Developer/Xcode/DerivedData/Kiteloop-*/Build/Products/Debug/Kiteloop.app
# designated => identifier "ai.kasatkin.kiteloop" and certificate leaf = H"7b34…"
```

So rebuilding, or moving the `.app`, keeps the grant — but **regenerating the
local signing certificate silently invalidates it**, and the next unattended run
prompts again. Re-add the app if that happens. The identity is set in
`Kiteloop/Signing.local.xcconfig`, a gitignored file the tracked
`Signing.xcconfig` includes; without it a build is ad-hoc signed, and an ad-hoc
signature is a new certificate every build, so the grant never survives one.

`claude` is Developer ID–signed by Anthropic PBC (team `Q6L2SF6YDW`, identifier
`com.anthropic.claude-code`), so an identity-keyed entry survives Claude Code's
auto-updates even though the versioned binary path changes underneath the
symlink. Confirm you got an identity-keyed entry rather than a path-keyed one —
`client_type` `0` is the identity form, `1` is a raw path that will break on the
next update:

```bash
sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "select client, client_type, auth_value from access
   where service='kTCCServiceSystemPolicyAllFiles';"
```

### The trade-off

Full Disk Access on these two clients means any agent command — any `Bash` tool
call — can read every file the user can, including other apps' data, mail and
browser stores. That is a real widening of what an autonomous run can reach. If
that is more than you want to hand an unattended queue, use §B instead, and note
that the two combine: relocate the projects *and* leave FDA ungranted.

## B. Alternative: move projects out of the protected folders

Nothing prompts for a project under an unprotected path, so relocating is a
complete fix for project reads with no permission widening at all.

1. Close the project in Kiteloop (its worktrees hold absolute paths).
2. Move it somewhere unprotected — `~/code`, `~/src`, `~/Developer`:

   ```bash
   mv ~/Documents/kiteloop ~/code/kiteloop
   ```

3. Repair any git worktrees. Autopilot creates them **inside** the project at
   `.kiteloop/worktrees/<id>` (`WorktreeSession.worktreesRoot(projectRoot:)`,
   `Kiteloop/Kiteloop/Services/WorktreeSession.swift`), so
   they travel with the move but their recorded paths go stale:

   ```bash
   cd ~/code/kiteloop && git worktree repair
   ```

4. Reopen at the new path — the app remembers projects by security-scoped
   bookmark, and the old Recents entry still points at the old location. In the
   app, or headlessly ([`control-api.md`](control-api.md)):

   ```bash
   TOKEN=$(cat ~/.kiteloop/control-token)
   curl -s -H "Authorization: Bearer $TOKEN" \
     -d '{"path":"~/code/kiteloop"}' http://127.0.0.1:4517/v1/projects/open
   ```

The home workspace (`~/.kiteloop/home`,
`KiteloopCore/Sources/KiteloopCore/Models/KiteloopProject.swift:26`) is already unprotected, as is
everything else under `~/.kiteloop`.

What this does **not** cover: an agent reading outside its project — a knowledge
file you keep in `~/Documents`, a repo you asked it to compare against on the
Desktop. Those still prompt. If your runs do that, you want §A.

## C. Verify no prompt fires

**1. The grants are recorded.** Full Disk Access lives in the system database,
the per-folder answers in the user one. `2` is allowed, `0` is denied. (Both
reads require the terminal you run them in to have Full Disk Access itself; an
`unable to open database file` error is that, not a missing row.)

```bash
sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "select client, auth_value from access where service='kTCCServiceSystemPolicyAllFiles';"

sqlite3 ~/"Library/Application Support/com.apple.TCC/TCC.db" \
  "select service, client, auth_value, datetime(last_modified,'unixepoch','localtime')
   from access where service like 'kTCCServiceSystemPolicy%' order by last_modified;"
```

The second query is also the record of what has been prompting you: each
`ai.kasatkin.kiteloop` row is a dialog someone clicked through, timestamped.

**2. Nothing is being asked during a run.** Leave this streaming while an item
runs — with the grants in place you see requests resolve, with no `Prompting`
and no `Denied`:

```bash
/usr/bin/log stream --predicate 'subsystem == "com.apple.TCC" AND category == "access"' --level info \
  | grep -iE "kiteloop|claude"
```

After the fact, the same predicate under `log show --last 1h`.

**3. End to end.** The acceptance test for this document: with a project inside
`~/Documents` (or `~/Desktop`, or `~/Downloads`), start a **fresh** agent — a
new session, so it is a newly spawned `claude` — and have it read a file in the
project directory. It returns the contents and no dialog appears.

## D. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Dialog still fires right after granting | The app was running when you added it; TCC decisions are cached per process | Quit and relaunch Kiteloop, and start a new agent session |
| Prompts came back after a rebuild | The **Kiteloop Local Signing** certificate was regenerated, so the stored requirement no longer matches | Re-add `Kiteloop.app` in the Full Disk Access list |
| Prompts came back after a Claude Code update | The `claude` entry was stored path-keyed (`client_type` `1`) and the versioned binary moved | Remove the stale entry and re-add `~/.local/bin/claude` |
| A QA flow's storyboard shows a macOS dialog over the window | The QA copy has no grant of its own (§A step 5) | Add it to Full Disk Access, answer any other prompt once, and run the flow again |
| `sqlite3: unable to open database file` | The terminal running the query has no Full Disk Access | Add it to the same list, or read the state from System Settings |
| Item ends `blocked` with no diff and no error | A prompt stalled the worker until the stall watchdog ended it (`autopilot-runbook.md` §D) | Do §A, re-`ready` the item |
| Want to start from a clean slate | — | `tccutil reset SystemPolicyAllFiles ai.kasatkin.kiteloop` (or `tccutil reset All ai.kasatkin.kiteloop`), then redo §A |
