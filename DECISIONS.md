# Decisions

Append-only log of choices, findings, disproven assumptions and rules for this
repo, newest at the bottom. Only things that outlive the change itself — git
already records what changed.

**Public repo:** no client names, no financial detail, no half-formed opinions —
this file is visible to anyone.

Entry format:

```markdown
## [YYYY-MM-DD] Short title
**Kind:** decision | finding | disproven | rule
**What:** one or two sentences.
**Why:** the reason, not the mechanics.
**Evidence:** command output, number, PR or file.
**Status:** holds | superseded by [YYYY-MM-DD] <title>
```

## [2026-09-20] A landed item branch is removed
**Kind:** decision
**What:** After a merge lands — a run's own, an approval's, `POST /v1/backlog/land` — the item branch is deleted, and the project-open sweep removes every `kiteloop/*` branch the base already holds. A branch with a commit the base cannot reach is never deleted.
**Why:** The branch was kept as the audit trail of what ran, but once every commit on it is in the base the ref is the only thing left of it, and 345 such refs had accumulated on one project in three weeks. The item's Notes carry `Landed: merged as <sha>`, which is the trail.
**Evidence:** 345 local `kiteloop/*` branches on one project after three weeks; `WorktreeManager.removeMergedBranch` and `removeLandedItemBranches`.
**Status:** holds — supersedes the "keep the branch" rule the orphan sweep carried since 2026-08.

## [2026-09-20] Signal drafts carry the project's own verify
**Kind:** rule
**What:** A hotspot, flake, red-suite or escaped-defect draft runs the project's effective merge-verify; a project with none and no verify map has its findings left undrafted, with a log line saying so. `SignalDrafting.defaultVerify` is Kiteloop's own and a fallback for callers with nothing better.
**Why:** Seven of seven hotspot items on a non-Swift project carried Kiteloop's `xcodebuild` line and were unrunnable on arrival, each burning a diagnostic start.
**Evidence:** Seven of seven hotspot items unrunnable on arrival; `CoordinatorQueueRefill.withSignalDrafts`.
**Status:** holds

## [2026-09-20] The suite had not run since 2026-09-10
**Kind:** finding
**What:** Nine tests on `main` were red against code the 2026-09-12 to 2026-09-15 commits had changed (merge-gate default 30 minutes, the Landed note, reclaimed review checkouts, collapsed verify labels, backup refs before the object walk, a new file's line count), and `docs/suite-status.md` showed nothing after 2026-09-10. The suite script's preflight also refuses on an escapes baseline two force-unwrap fixes left looser than the code.
**Why:** The green row is the only evidence a change did not break a test, and a run that never happens leaves none.
**Evidence:** `docs/suite-status.md` last row 2026-09-10; `quality/tests/test-check-escapes.py` under `--strict`.
**Status:** holds — tightening the escapes baseline, with the command that check prints, is a person's commit.

## [2026-09-21] One WKWebView means one host, and the manager says which
**Kind:** rule
**What:** `WebPreviewWindowManager` owns whether the preview page is hosted inline or in the detached window: `isDetached` reports it and `closeDetachedWindow()` hands the page back. Any surface that is about to render `WebPreviewPanel` calls that first. There is still exactly one `WKWebView` and one `WebPreviewViewModel`.
**Why:** A view has one superview, so whichever host renders last silently steals the web view and the other goes blank. The fix is an owner of that fact, not a second web view.
**Evidence:** `Kiteloop/Kiteloop/Views/WebPreview/WebPreviewPanel.swift`; the presenter seam lets `WebPreviewWindowManagerTests` drive show and close with no `NSWindow`.
**Status:** holds

## [2026-09-21] A tool handler's refusals are a typed throw
**Kind:** decision
**What:** `web_scroll`'s argument reading is a typed-throwing parse (`throws(WebScrollRefusal)`) returning the one destination the call names, and `handleWebScroll` is left with the pane checks and the call. The refusal carries the exact sentence the agent reads back, as `MCPAuthorizationFailure` already does.
**Why:** The handler was cc 12 because every refusal was a return from the middle of it; a refusal that throws lets each argument be read by a piece small enough to hold one rule. Typed throws over an untyped one because the handler then needs no second `catch` for an error that cannot happen.
**Evidence:** `handleWebScroll` cc 12 → 6 and out of the complexity baseline; `Kiteloop/Kiteloop/ViewModels/ChatViewModel.swift`.
**Status:** holds

## [2026-09-21] Dismiss on the Interrupted Runs sheet reports like Resume does
**Kind:** rule
**What:** A Dismiss, or Dismiss All, either removes a run's checkpoints or leaves the row in `incompleteExecutions` with a `ResumeReport` saying why it could not. `WorkflowResumeService.dismiss` throws rather than swallowing the store's refusal, and a project with no resume service configured is reported, not silently ignored.
**Why:** A row vanishing is not a result. Checkpoints the delete never removed bring the run back at the next launch with no account of where it went — the same reason Resume reports every failure rather than clearing the row.
**Evidence:** `Kiteloop/Kiteloop/Services/WorkflowDismiss.swift`; `OrchestratorResumeTests.testDismissAllWithoutServiceReportsAndKeepsRows`.
**Status:** holds

## [2026-09-22] A hook forward is a success only once an agent has it
**Kind:** rule
**What:** `HookEngine` delivers a Forward to Agent rule through a handler the orchestrator installs, which resolves the rule's free-text target against the team by name and then by id and triggers that agent one chain-depth deeper. A target nobody answers to is a `.failed` record naming it, not a success.
**Why:** The action posted `.agentTriggered` with a nil object and the rule's *name* where the observer wanted the orchestrator and an *id*, so it reached nobody while the panel recorded every fire as delivered. A record that claims a delivery that did not happen is worse than the missing delivery. Carrying the firing context's depth through the handler is what keeps `maxChainDepth` biting once the action works.
**Evidence:** `Kiteloop/Kiteloop/Services/HookEngine.swift`; `HookEngineTests.testAForwardToAnAgentOnTheTeamTriggersThatAgent`, `…IsRecordedAsFailed`, `…StopsAtTheDepthLimit`.
**Status:** holds

## [2026-09-22] A hook's failure policy is one decision, offered only where it decides
**Kind:** rule
**What:** A failing, timed-out or non-zero-exit shell hook denies a turn only when its `failurePolicy` is `.deny` and the event supports blocking — one branch in `HookEngine.evaluate`, not two. The hooks panel draws the Allow/Deny on fail picker and the fail→deny badge only on events that can block, and leaves a stored policy on the other five untouched.
**Why:** A non-zero exit is exactly what `executeShell` records as `.failed`, so a second branch denying on the exit code alone fired for every failure the policy had just allowed: Allow on fail denied anyway. A control that cannot change an outcome is worse than no control — it reads as a promise the engine does not keep.
**Evidence:** `Kiteloop/Kiteloop/Services/HookEngine.swift`; `HookEngineTests.testANonZeroExitUnderAllowOnFailLetsThePromptThrough`, `KiteloopHookFailurePolicyTests.testThePanelOffersTheFailurePolicyExactlyWhereAHookCanBlock`.
**Status:** holds

## [2026-09-21] An avatar nobody picked is absent, not a placeholder name
**Kind:** rule
**What:** Every editor that writes an avatar carries it as `String?`, where `nil` is the picker's "Auto (by role)" state, and uses `AvatarPickerField`. No editor seeds its field with a name the pickers do not offer.
**Why:** `AgentAvatarView` draws an avatar it cannot resolve as text inside the circle, so a placeholder default is a user-visible defect the moment nothing maps the name to an image — which is what a hard-coded `bot_face_ui` was in both Settings editors.
**Evidence:** `Kiteloop/Kiteloop/Views/Settings/AgentCatalogView.swift`, `SpecialistRegistryView.swift`; `EditorAvatarDefaultTests`.
**Status:** holds

## [2026-09-25] Tool permissions are Claude Code's auto-mode call
**Kind:** decision
**What:** Every Claude session is spawned with `--permission-prompts none`; an agent with no mode set, and every unattended session (autopilot worker and reviewer, `HeadlessAgentRunner`'s helpers), runs with `--permission-mode auto`, so Claude Code's classifier decides each tool call. Kiteloop's own deny list for unattended runs (`UnattendedDenyRules`) is removed; an agent's own `denied` tools still go to `--disallowedTools`.
**Why:** A `--print` session has nobody to answer a prompt, and a short pattern list over command text was a weaker judge than the classifier while being one more layer to keep in step with it. The trade-off is accepted knowingly: the classifier can allow a command the list refused.
**Evidence:** `claude -p --permission-mode auto --permission-prompts none --output-format stream-json --verbose` on CLI 2.1.281 reports `permissionMode: "auto"` at init; a live probe showed the classifier allowed `sudo -n rm -rf <nonexistent path>` when explicitly asked to run it. `ClaudeCodeCLIRuntime.permissionArguments`.
**Status:** holds

## [2026-09-25] An unchanged backlog item is written back as it was read
**Kind:** rule
**What:** A BACKLOG.md write-back reuses an item's `sourceLine` whenever that line, re-read in the same file, still gives the item as it stands; only a changed item is re-rendered, and a re-rendered item whose line had no `verify:` of its own writes none while its command still equals `verify_default`.
**Why:** Re-rendering every line on each write made one status flip rewrite the whole file and copied `verify_default` onto every item, so a later change to the default reached none of them.
**Evidence:** `BacklogSerializer.line(for:verifyDefault:)`; `BacklogWriteBackTests`.
**Status:** holds

## [2026-09-25] A subagent's stream lines nest under its call; subagent text is not forwarded
**Kind:** decision
**What:** A tool call or result the CLI tags with `parent_tool_use_id` is kept on the transcript as a child of that `Agent`/`Task` call (`Message.ToolCall.parentToolUseID`), and the task, background and thinking-estimate notices fold into `AgentActivity`. The `rate_limit_event` line rides `StreamEvent.system` under its own type. Notices about background work that arrive after a turn's `result`, when no turn is listening, are held and open the next turn instead of being dropped. `--forward-subagent-text` is not passed.
**Why:** Without the parent id a subagent's calls were drawn as the main agent's. A background task outlives the turn that started it, so its end arrives between turns. `.assistantText` carries no parent, and every consumer that sums it into a turn's answer (headless runner, debate, consult) would take in the subagent's prose; forwarding it needs a parent on text first.
**Evidence:** CLI 2.1.281 stream `Kiteloop/KiteloopCore/Tests/Fixtures/stream-json/cli-2.1.281-subagent-background-thinking.jsonl`: the shell's `task_notification` and `background_tasks_changed: []` follow the first `result`. `AgentActivityTests`, `ClaudeCodeCLIRuntimeTests.testANoticeAboutBackgroundWorkBetweenTurnsOpensTheNextTurn`.
**Status:** holds, except that `--forward-subagent-text` is now passed — superseded on that point by [2026-09-25] A subagent's text and thinking are forwarded, nested and never an answer

## [2026-09-25] A turn the CLI starts by itself is a turn of its own
**Kind:** decision
**What:** After a turn's `result`, the stdout reader keeps routing lines (`UnpromptedTurnTracker`): notices about background work are held, a `system`/`init` or assistant line opens an unprompted turn whose lines through its `result` go to a stream of their own, handed via `AgentRuntime.unpromptedTurns(of:)` and `Orchestrator.installSession` to the agent's chat, which runs it like a sent turn (messages, cost, transcript, working state, watchdog) with no human message. A send made while such a turn is open is held by the runtime until its `result`; in the chat, a message typed meanwhile is queued as during any turn. A turn from a session the agent no longer has (cleared, restarted, switched, stopped) is dropped, and one cleared mid-way stops writing at its next event. For a workflow node the unprompted turn counts only when the node is waiting on a background-agent launch: it then goes through `finishTurn` and hands off, as the nudge's turn would; otherwise it is shown and marks the turn done, completing nothing. An agent with no chat has its unprompted turns run unheard, sends still waiting for their `result`.
**Why:** The CLI answers background work finishing with a turn nobody sent, and dropping it lost the agent's reaction; worse, a send made while it ran got its `result` and ended before the reply. Counting it for a node only when the node waits on a launch keeps a background shell's late report from completing the next node the worker is on.
**Evidence:** `Kiteloop/KiteloopCore/Tests/Fixtures/stream-json/cli-2.1.281-subagent-background-thinking.jsonl` lines 26–34: notices, then a second `init`, text and `result`. `ClaudeCodeCLIRuntimeTests.testATurnTheCLIStartsByItselfAfterTheResultArrivesAsATurnOfItsOwn`, `…testASendMadeDuringTheCLIsOwnTurnWaitsForItsResult`, `ChatViewModelUnpromptedTurnTests`.
**Status:** holds — a Kiteloop MCP tool call inside an unheard unprompted turn gets no answer until the bridge's own timeout.

## [2026-09-25] A subagent's text and thinking are forwarded, nested and never an answer
**Kind:** decision
**What:** Every session is spawned with `--forward-subagent-text`. `.assistantText` and `.thinking` carry an optional `parentToolUseID`, as tool calls do, and so do the chat messages made from them (`Message.parentToolUseID`, absent from chats saved before). The chat draws a subagent's text and thinking under its `Agent` row with its calls, never at the top level. Every consumer that sums `.assistantText` into an agent's answer — `HeadlessAgentRunner`, the debate, a consulted specialist's reply, `message_agent`, `broadcast_agents` — takes only text with no parent.
**Why:** The subagent's own report and reasoning were invisible. Forwarding them waited only on text having a parent, without which a subagent's prose would leak into answers machines read: a verdict, a proposal, a teammate's reply.
**Evidence:** `claude -p --forward-subagent-text --output-format stream-json --verbose` on CLI 2.1.281: the subagent's thinking and closing text arrive as `assistant` lines with `parent_tool_use_id` set (`Kiteloop/KiteloopCore/Tests/Fixtures/stream-json/cli-2.1.281-forward-subagent-text.jsonl`). `ChatViewModelSubagentTextTests`, `HeadlessAgentRunnerTests.testASubagentsTextIsLeftOutOfTheReply`, `DebateOrchestratorTests.testASubagentsTextIsLeftOutOfTheProposal`.
**Status:** holds

## [2026-10-02] What runs before a merge is said in one place: the verify map, tracked in the repo
**Kind:** decision
**What:** The verify map — which changed paths require which checks, each rule carrying the command that runs it — becomes the one place a project says what stands between a diff and its base. It moves out of the gitignored `.kiteloop/` into the tracked repo; the per-project `autoMergeVerifyCommand` becomes a rule matching every path; the backlog's `verify_default` goes; an item's `verify:` is optional and holds only checks particular to that item. The merge gate runs the rules the diff's paths match plus the item's own checks.
**Why:** Four sources decided it and drifted apart: 361 distinct `verify:` lines in one backlog, mostly copies of one standard chain that hand-grooming kept getting wrong; a `verify_default` still naming the plain `build` that never compiles the tests; and a map that already runs the checks an item left out, but which nobody reviews because it is not in git and a fresh clone does not have it.
**Evidence:** `grep -oE '\| verify: [^|]*' BACKLOG.md | sort -u | wc -l` → 361 on 2026-10-02; `VerifyCoverage` runs a gap on the branch since 2026-09-25 (`e501b1b`); `git ls-files .kiteloop/verify-map.json` → nothing.
**Status:** holds

## [2026-10-02] The Specialist Registry and Kiteloop's own hooks are removed
**Kind:** decision
**What:** The Specialist Registry (its settings page, `CrossProjectConsult`, and the @mention lookup it backs) and Kiteloop's own hooks (`HookEngine`, its settings page and the project config's `hooks` fields) are removed. Agents for hiring stay in the Agent Catalog; hooks are Claude Code's own, edited on the one Hooks page and enforced by the CLI.
**Why:** Neither was used. Each duplicated something that is: the registry, the Agent Catalog; Kiteloop's shell hooks, Claude Code's hooks. Two of thirteen settings pages, a service and a hook engine went to features nobody had configured. Forward-to-agent, the one Kiteloop-only hook action, is lost; nothing used it.
**Evidence:** on 2026-10-02 `~/.kiteloop/specialists.json` did not exist; across the four projects Kiteloop hooks configured: 0, Claude Code hooks: 5 (`.claude/settings.json`).
**Status:** holds

## [2026-10-12] One sidebar drawer is open at a time
**Kind:** decision
**What:** The Coordinator, Fleet and Waiting on you drawers are mutually exclusive: opening one closes the others. Their three saved open flags stay; when more than one is saved as open, the leftmost (Coordinator, then Fleet, then Waiting on you) is the one shown.
**Why:** Two drawers side by side left the center column a strip and nobody reads two at once. The flags never recorded which drawer was opened last, so a fixed left-to-right order is the only deterministic answer for flags saved before this.
**Evidence:** `SidebarDrawer` in `KiteloopCore/Sources/KiteloopCore/Models/SidebarDrawer.swift` and `SidebarDrawerTests`.
**Status:** holds

## [2026-10-25] The control API listens on a BSD socket, not NWListener
**Kind:** disproven
**What:** `NWListener` with `requiredLocalEndpoint` 127.0.0.1 binds only the loopback address. It fails with `EADDRINUSE` whenever any other socket holds the same port on any address, so the control API could not come up while the pairing forwarder ran. `HTTPServer` now listens through `bind(2)` on 127.0.0.1 (`LoopbackListener`), which coexists with the forwarder's sockets. A second listener on 127.0.0.1 itself is still refused.
**Why:** The forwarder starts at login and keeps running whenever Kiteloop is quit, so every relaunch lost the port. Starting the app before the forwarder by hand was the workaround, and it kept being needed.
**Evidence:** With a socket held on 192.168.1.5:4599 or 0.0.0.0:4599, three `NWListener` variants (reuse on, reuse off, loopback interface required) failed with errno 48, while `bind` on 127.0.0.1:4599 succeeded. `HTTPServerTests.testListenerComesUpBesideASocketHoldingThePortOnOtherAddresses`.
**Status:** holds

## [2026-11-02] No hosted CI
**Kind:** decision
**What:** The repository carries no GitHub Actions workflows, and Actions is turned off on the GitHub repository. Every check (the unit suite, the phone companion's tests, releases) runs on a Mac, as `CONTRIBUTING.md` lists under "Before you open a pull request".
**Why:** The maintainer does not want CI running on GitHub for this repo. A workflow file left in place while Actions is off would read as a check that runs, and pushing one needs a token with the `workflow` scope.
**Evidence:** `gh api repos/svetdev/Kiteloop/actions/permissions` answers `"enabled": false`; `.github/` holds only the issue and pull-request templates.
**Status:** holds

## [2026-11-02] The Planner and the Fleet share one drawer
**Kind:** decision
**What:** The Coordinator drawer is gone. The Fleet drawer carries the fleet's state and Pause, then the Planner's state, controls and recent passes, then one Projects table with the Planner's last-24h report as a column. The sidebar's Fleet row opens it at the top and its Planner row at the Planner section; the daily budget is shown once, in the sidebar.
**Why:** The owner asked on 2026-10-13 to uncrowd the Autopilot with the Planner and Fleet open. Running work unattended is one question split over two drawers, each with its own projects table.
**Evidence:** `FleetDrawer` (`Kiteloop/Kiteloop/Views/Portfolio/FleetDrawer.swift`), `CoordinatorPanel.plannerOnly`, the `last 24h` column in `FleetBoard`; `FleetDrawerPlannerTests`.
**Status:** holds

## [2026-11-10] A run that lands its own work always takes the gate path
**Kind:** rule
**What:** With `approvalGate: land`, a review-passed run goes to `awaiting-approval`, merges and then approves itself, even when the Backlog Flow's "Require human approval before Done" is off. That toggle marks an item Done on the spot only when the run will not merge (a `propose` project, or a run salvaged by its own `verify:`), and such an item's Notes name the unmerged branch.
**Why:** The merge hangs off the gate. Marking Done before it left every review-passed run `done` with its commit on a branch and no merge attempt, and each following item forked from a base one item behind.
**Evidence:** GitHub issues #2 and #3; `BacklogAutopilot.marksDoneWithoutGate`, `BacklogAutopilotAutoApprovalTests`.
**Status:** holds

## [2026-11-10] Grounding reads the tree a run forks from
**Kind:** decision
**What:** When `baseBranch` names a local branch the project folder is not on, the grounding check indexes that branch's tree (archived out of git into a scratch directory); the checkout still answers for paths as a second corpus.
**Why:** A check that reads one tree and gates a run that forks from another refuses true items. The checkout is kept for paths because files git does not track are real there, and this check errs towards a missed refusal.
**Evidence:** GitHub issue #1; `GroundingCheck.BaseTree`, `GroundingCheckBaseBranchTests`.
**Status:** holds

## [2026-11-10] A red project-wide verify is asked of the base once per tip
**Kind:** decision
**What:** When a verify-map or merge-verify step fails on the merged tree, the gate runs the same command on the base tip alone and says so in the refusal when the base fails it too. The item's own `verify:` is never asked of the base, nor is a step the deadline killed; the answer is remembered per project, tip and command for the life of the process.
**Why:** A base that is already red was being attributed to each branch in turn. An item's `verify:` is expected to fail without the item's change, so its failing on the base says nothing.
**Evidence:** GitHub issue #4; `WorktreeManager.attributingToBase`, `WorktreeManagerTests`.
**Status:** holds

## [2026-11-10] `copilot` names the runtime, not a model
**Kind:** rule
**What:** An agent whose model is `copilot` sends the bridge no model and takes Copilot's first; `copilot-<name>` asks for `<name>`. The bridge matches a name as a family, then as an id, and answers an unknown one with an error listing what is available. Its `done` frame names the model that answered.
**Why:** `copilot` matched no Copilot family, so every such agent was answered by whichever model VS Code listed first, and nothing recorded which.
**Evidence:** GitHub issue #5; `CopilotBridgeRuntime.bridgeModel(for:)`, `copilot-bridge-extension/src/copilotBridge.ts`.
**Status:** holds

## [2026-11-10] In-app updates are Sparkle, fed from kasatkin.ai
**Kind:** decision
**What:** The app updates itself through Sparkle 2, reading `https://kasatkin.ai/kiteloop/appcast.xml` (`SUFeedURL`); the zips stay on GitHub Releases and `make-release.sh` writes the feed entry. The build number is the version (`CURRENT_PROJECT_VERSION = $(MARKETING_VERSION)`). The earlier notify-only check against GitHub's `releases/latest` is removed.
**Why:** A notice with a download link left every other Mac to be updated by hand, and only told a copy at launch that never comes for an app left running. The feed sits on a domain we own because its address is in every shipped copy and can never change, while the host behind it can; the main site rather than a subdomain for one less thing to run. Sparkle orders releases by build number, which was a constant `1`.
**Evidence:** `Services/SoftwareUpdater.swift`, `Kiteloop/Kiteloop/Info.plist`, `scripts/make-release.sh` (`run_appcast`), `docs/release-runbook.md`.
**Status:** holds

## [2026-11-10] The update relaunch has no run-awareness of its own
**Kind:** decision
**What:** Nothing postpones Sparkle's relaunch while runs are in flight. Sparkle quits the app the way Cmd-Q does, so `AppDelegate.applicationShouldTerminate` asks its existing fleet question, and an update whose quit was cancelled installs at the next quit.
**Why:** A second mechanism deciding when the app may quit would have to agree with the first forever.
**Evidence:** `AppDelegate.applicationShouldTerminate`, `FleetQuitPrompt`.
**Status:** holds — not yet observed end to end; no release with Sparkle in it has been published.
