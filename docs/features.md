# Capability-to-test map

Feature-to-test mapping. Each capability should have a corresponding test before shipping.

Legend: `[x]` = implemented + tested, `[~]` = implemented, no test, `[ ]` = planned

---

## Claude Code cockpit

### Runtime Layer

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [x] | Stream event parsing (JSON from stdout) | `Runtime/ClaudeCodeCLIRuntime.swift` | `Runtime/ClaudeCodeCLIRuntimeTests.swift` |
| [x] | Line framing across read boundaries (partial/split lines, split UTF-8) | `Runtime/LineBuffer.swift` | `Runtime/LineBufferTests.swift` |
| [x] | Stream event model + decoding | `Models/StreamEvent.swift` | `Runtime/StreamEventParsingTests.swift` |
| [x] | Multimodal attachments (image + text) | `Runtime/ClaudeCodeCLIRuntime.swift` | `Runtime/ClaudeCodeCLIRuntimeAttachmentTests.swift` |
| [~] | Agent runtime protocol (spawn/stream/interrupt/stop) | `Runtime/AgentRuntime.swift` | — |
| [~] | Session resumption (`--resume`) | `Runtime/ClaudeCodeCLIRuntime.swift` | — |
| [~] | Session forking (`--fork-session`) | `Runtime/ClaudeCodeCLIRuntime.swift` | — |
| [x] | Permission prompts read and answered on the session's own pipes (`control_request` / `control_response`): a call waiting on leave, a question taken back, mode change, one task stopped | `Runtime/PermissionPrompt.swift` | `Runtime/PermissionPromptTests.swift` |
| [x] | Prompts routed to the session's listener, not a turn's stream — between turns and before anyone listens included | `Runtime/ClaudeCodeCLIRuntime.swift` | `Runtime/ClaudeCodeCLIRuntimePermissionPromptTests.swift` |
| [x] | Permission cards: a call (allow once / always / deny), the model's questions with choices, an offered plan — open, answer once, lapse | `Services/PermissionCards.swift` | `Services/PermissionCardsTests.swift` |
| [x] | A session's prompts become chat cards and the agent waits on you until answered; a subagent's call names its task; live `/mode`; stop one running task | `ViewModels/ChatViewModel.swift` | `ViewModels/ChatViewModelPermissionPromptTests.swift` |
| [x] | Permission and choices cards in the chat | `Views/Chat/PermissionCard.swift` | `Views/PermissionCardTests.swift` |
| [x] | Remembered "Always allow…" rules listed in Project Settings, each removable (the CLI's `.claude/settings.local.json`) | `Services/RememberedPermissions.swift` | `Services/RememberedPermissionsTests.swift` |
| [x] | Context compaction (the CLI's `/compact` sent to the live session) | `ViewModels/ChatViewModel.swift` | `ViewModels/ChatViewModelSlashCommandTests.swift` |
| [~] | Hook event capture (`--include-hook-events`) | `Runtime/ClaudeCodeCLIRuntime.swift` | — |

### Models

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [~] | Message model (text/thinking/toolCall/toolResult/approval/image/error) | `Models/Message.swift` | — |
| [~] | Agent model (state machine, tools, permission mode — `auto` by default, skills, effort, budget) | `Models/Agent.swift` | — |
| [~] | AgentTemplate (reusable configs, 13 avatars, backward-compat decoder) | `Models/AgentTemplate.swift` | — |
| [~] | KiteloopProject (.kiteloop/ directory structure) | `Models/KiteloopProject.swift` | — |
| [~] | KiteloopEvent (14 event types for inter-agent coordination) | `Models/KiteloopEvent.swift` | — |
| [~] | ChatAttachment (image/text files, MIME detection) | `Models/ChatAttachment.swift` | — |
| [~] | StreamEvent (system/thinking/text/toolUse/toolResult/image/hook/mcpToolCall/result) | `Models/StreamEvent.swift` | — |
| [x] | Skill (frontmatter parser, source detection) | `Models/Skill.swift` | `Models/SkillTests.swift` |
| [~] | ProjectConfig (model, permission mode, denied tools, effort, budget, OTLP, Bedrock) | `Models/KiteloopProject.swift` | — |
| [~] | MCPConfig (per-agent MCP server definitions) | `Models/MCPConfig.swift` | — |
| [~] | OTLPConfig (tracing export config) | `Models/OTLPConfig.swift` | — |
| [x] | BedrockConfig (AWS Bedrock proxy config) | `Models/BedrockConfig.swift` | `Models/BedrockConfigTests.swift` |

### UI — Chat

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [~] | Chat view (streamed messages + scroll) | `Views/Chat/ChatView.swift` | — |
| [~] | Message bubble (markdown, images, errors) | `Views/Chat/MessageBubble.swift` | — |
| [~] | Selectable markdown (NSTextView, drag-select) | `Views/Chat/SelectableMarkdownView.swift` | — |
| [~] | Tool call view (collapsible with diffs/output) | `Views/Chat/ToolCallView.swift` | — |
| [~] | Input bar (send, stop, attach, local-text perf) | `Views/Chat/InputBar.swift` | — |
| [~] | Slash command autocomplete (`/` popover) | `Views/Chat/SlashCommandPopover.swift` | — |
| [~] | Ask-human bubble (agent questions) | `Views/Chat/AskHumanBubble.swift` | — |
| [x] | Syntax highlighting (Highlightr) | `Views/Chat/MarkdownRenderer.swift` | — |
| [~] | Image content rendering | `Views/Chat/ImageContentView.swift` | — |
| [~] | Copy button (code blocks) | `Views/Chat/CopyButton.swift` | — |
| [~] | Search bar (message search) | `Views/Chat/SearchBar.swift` | — |

### UI — Navigation & Settings

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [~] | Main window (project context, sidebar) | `Views/MainWindow.swift` | — |
| [~] | Project sidebar + picker | `Views/Sidebar/KiteloopSidebar.swift`, `Views/MainWindow.swift` | — |
| [~] | Menu bar status indicator | `Views/MenuBar/MenuBarView.swift` | — |
| [~] | Settings view | `Views/Settings/AppPreferencesView.swift` | — |
| [~] | New agent sheet | `Views/NewAgentSheet.swift` | — |
| [~] | Team settings | `Views/Settings/ProjectSettingsView.swift` | — |
| [~] | Template editor/list | `Views/Settings/AgentCatalogView.swift` | — |
| [~] | Agent avatar view (Rive + fallback initials) | `Views/Components/AgentAvatarView.swift` | — |
| [~] | Project picker view (recents on the home screen) | `Views/MainWindow.swift` | — |
| [~] | Project menu (open, recents, tab reorder) | `Views/MainWindow.swift` | — |
| [x] | Waiting on you — cross-project approval gates and unanswered questions in one drawer, each row opening where it is cleared | `Services/WaitingOnYou.swift`, `Views/Portfolio/WaitingOnYouDrawer.swift` | `Services/WaitingOnYouTests.swift` |
| [x] | Stale item sweep — an open backlog item nothing has touched in 28 days is flagged in the Waiting on you drawer, read from the shared backlog branch's own git history; never moves, demotes or archives anything | `Services/StaleItemSweep.swift` | `Services/StaleItemSweepTests.swift` |
| [x] | Backlog lanes in the epic view — each open item shows `now` or `later` and its menu flips it ("Run now" / "Back to later") without leaving its epic; a Now section above the epics lists every now item in run order, tagged with its epic, and says so when nothing is marked | `Views/Portfolio/EpicBacklogView.swift`, `ViewModels/BacklogViewModel.swift` | `ViewModels/BacklogViewModelLaneMigrationTests.swift` |

---

## Multi-agent team

### Multi-Agent Orchestration

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [~] | Orchestrator (route messages, manage agents, compose prompts) | `Services/Orchestrator.swift` | — |
| [~] | Agent state machine (idle/working/waitingForHuman/crashed) | `Models/Agent.swift` | — |
| [~] | Agent catalog (8 predefined: Coder, Reviewer, Researcher, Frontend, Infra, QA, Designer, Data) | `Models/PredefinedTemplates.swift` | — |
| [~] | hire_agent / fire_agent tools (dynamic team composition) | `ViewModels/ChatViewModel.swift` | — |
| [~] | Tool interception (publish_event, propose_memory, ask_human) | `Services/ToolInterceptor.swift` | — |
| [~] | Agent-triggered notifications | `Services/Orchestrator.swift` | — |

### Event System

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [x] | EventBus (pub/sub, JSONL persistence, replay) | `Services/EventBus.swift` | `Services/EventBusTests.swift` |
| [x] | SubscriptionEngine (auto-trigger agents on events) | `Services/SubscriptionEngine.swift` | `Services/Sessions/SubscriptionEngineTests.swift` |
| [~] | 14 event types (prReady, reviewComplete, taskComplete, etc.) | `Models/KiteloopEvent.swift` | — |

### Memory & Context

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [x] | MemoryManager actor (compose prompts with memory + context + skills) | `Services/MemoryManager.swift` | `Services/Agents/MemoryManagerTests.swift` |
| [x] | Per-agent memory (`.kiteloop/agents/{id}/memory.md`) | `Services/MemoryManager.swift` | `Services/Agents/MemoryManagerTests.swift` |
| [x] | Shared project context (`.kiteloop/context.md`) | `Services/MemoryManager.swift` | `Services/Agents/MemoryManagerTests.swift` |
| [x] | Memory proposals (human approval workflow) | `Services/MemoryManager.swift` | `Services/Agents/MemoryManagerTests.swift` |
| [~] | Memory browser UI | `Views/Memory/MemoryBrowserView.swift` | — |
| [~] | Memory proposal UI (approve/reject/edit) | `Views/Memory/MemoryProposalView.swift` | — |
| [~] | Memory view model | `ViewModels/MemoryViewModel.swift` | — |
| [x] | Librarian consolidation pass (proposes merges/deletions/archival, applies nothing) | `Services/MemoryLibrarian.swift`, `Services/MemoryLibrarianPass.swift` | `Services/Agents/MemoryLibrarianTests.swift` |
| [x] | Project context auto-seeding (README, stack, structure) | `Services/ProjectContextSeeder.swift` | `Services/ProjectContextSeederTests.swift` |

### Cross-Project & Specialists

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [x] | @mention parsing (invoke specialists inline) | `Services/MentionParser.swift` | `Services/MentionParserTests.swift` |

---

## Workflows, skills and sessions

### Workflows

| Status | Feature | Source | Test |
|---|---|---|---|
| [x] | Clean-code loop: specify → implement → verify → clean → harden → review → qa → human gate, tool failures looping back to the coder (`start_clean_code_loop`) | `Services/CleanCodeLoopBuilder.swift` | `Services/CleanCodeLoopBuilderTests.swift` |
| [x] | Improvement loop: implement → test → review → done with back-edges (`start_improvement_loop`) | `Services/ImprovementLoopBuilder.swift` | `Services/ImprovementLoopBuilderTests.swift` |
| [x] | QA flow for a `flow:qa` item: specify → worker → clean → harden → reviewer → qa → done around the autopilot's run, driven by the project's `kiteloop-qa.json`, failures back to the worker and the QA report on the item | `Services/QAFlowStages.swift` | `Services/QAFlowTests.swift` |

### Skills & Commands

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [x] | Skill model (YAML frontmatter parser) | `Models/Skill.swift` | `Models/SkillTests.swift` |
| [x] | SkillRegistry (scan plugins/user/project dirs) | `Services/SkillRegistry.swift` | `Services/SkillRegistryTests.swift` |
| [x] | Skill injection into system prompts | `Services/MemoryManager.swift` | `Services/Agents/MemoryManagerTests.swift` |
| [~] | `/command` invocation (rewrite message with skill body) | `ViewModels/ChatViewModel.swift` | — |
| [~] | Slash command autocomplete popover | `Views/Chat/SlashCommandPopover.swift` | — |

### Slash Commands (Built-in)

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [~] | `/clear` — reset conversation | `ViewModels/ChatViewModel.swift` | — |
| [~] | `/cost` — show session cost/tokens | `ViewModels/ChatViewModel.swift` | — |
| [~] | `/model [name]` — switch model | `ViewModels/ChatViewModel.swift` | — |
| [~] | `/effort [level]` — set effort | `ViewModels/ChatViewModel.swift` | — |
| [~] | `/fork` — branch session from checkpoint | `ViewModels/ChatViewModel.swift` | — |
| [x] | `/compact` — compact the context in-session | `ViewModels/ChatViewModel.swift` | `ViewModels/ChatViewModelSlashCommandTests.swift` |
| [~] | `/thinking [on\|off\|N]` — toggle extended thinking | `ViewModels/ChatViewModel.swift` | — |
| [~] | `/context` — show context window usage | `ViewModels/ChatViewModel.swift` | — |
| [~] | `/recap` — ask agent for conversation summary | `ViewModels/ChatViewModel.swift` | — |
| [~] | `/doctor` — run environment diagnostics | `ViewModels/ChatViewModel.swift` | — |
| [~] | `/fast` — toggle sonnet ↔ opus | `ViewModels/ChatViewModel.swift` | — |
| [~] | `/history` — show session history | `ViewModels/ChatViewModel.swift` | — |
| [~] | `/goal <condition>` — autonomous loop until condition met | `ViewModels/ChatViewModel.swift` | — |
| [~] | `/loop [instruction]` — autonomous loop (manual stop) | `ViewModels/ChatViewModel.swift` | — |
| [~] | `/undo` — remove last conversation turn | `ViewModels/ChatViewModel.swift` | — |

### Session Management

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [~] | Session resume (`--resume`) | `Runtime/ClaudeCodeCLIRuntime.swift` | — |
| [~] | Session fork (`--fork-session`) | `Runtime/ClaudeCodeCLIRuntime.swift` | — |
| [~] | Context compaction | `ViewModels/ChatViewModel.swift` | — |
| [~] | Message persistence (`.kiteloop/agents/{id}/messages.json`) | `ViewModels/ChatViewModel.swift` | — |

### Observability

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [x] | Trace store (in-memory + JSONL persistence) | `Services/TraceStore.swift` | `Services/Metrics/TraceStoreTests.swift` |
| [x] | Trace view model | `ViewModels/TraceViewModel.swift` | `ViewModels/TraceViewModelRefreshTests.swift` |
| [x] | Trace viewer (timeline, cost) | `Views/Traces/TraceListView.swift` | `ViewModels/TraceViewModelRefreshTests.swift` |
| [~] | Trace detail view | `Views/Traces/TraceDetailView.swift` | — |
| [x] | Cost tracking (per-agent, per-day, JSONL) | `Services/CostTracker.swift` | `Services/CostTrackerTests.swift` |
| [x] | Status line (polls command, shows model/cost/context%) | `Services/StatusLineService.swift` | `Services/StatusLineServiceTests.swift` |
| [~] | Context window % indicator (live from stream events) | `ViewModels/ChatViewModel.swift` | — |
| [x] | Notification store (pending/resolved/dismissed, 7-day prune) | `Services/NotificationStore.swift` | `Services/NotificationStoreTests.swift` |
| [x] | macOS notifications (task complete, errors) | `Services/NotificationService.swift` | `Services/Sessions/NotificationServiceTests.swift` |
| [~] | Notification list view | `Views/Notifications/NotificationListView.swift` | — |
| [~] | Notification badge (unread count indicator) | `Views/Notifications/NotificationBadge.swift` | — |
| [x] | Store read/write failure reporting (error row + Diagnostics line, one row per store+operation) | `Services/StoreProblemReporter.swift` | `Services/StoreProblemReporterTests.swift` |
| [x] | Undecodable JSON store quarantined aside (`<name>.unreadable-<timestamp>`) and reported instead of overwritten | `Services/QuarantiningJSONFile.swift` | `Services/QuarantiningJSONFileTests.swift` |

### Templates & Configuration

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [~] | Agent templates (save/load/instantiate) | `Services/TeamConfigManager.swift` | — |
| [x] | Template store (CRUD persistence layer) | `Services/AgentCatalogStore.swift` | `AgentCatalogStoreTests.swift` |
| [x] | Agent catalog store (task specialists) | `Services/AgentCatalogStore.swift` | `AgentCatalogStoreTests.swift` |
| [~] | Agent catalog UI | `Views/Settings/AgentCatalogView.swift` | — |
| [~] | Template editor UI | `Views/Settings/AgentCatalogView.swift` | — |
| [x] | Multi-project support (recent projects, switching) | `Services/ProjectStore.swift` | `Services/ProjectStoreTests.swift` |
| [~] | Per-agent effort level | `Models/Agent.swift` | — |
| [~] | Per-agent max budget USD | `Models/Agent.swift` | — |

---

## CLI parity

### CLAUDE.md & Context

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [~] | CLAUDE.md auto-loading (global + project + .claude/) | `Services/MemoryManager.swift` | — |
| [~] | Extended thinking support (`--thinking`, `--thinking-budget`) | `Runtime/ClaudeCodeCLIRuntime.swift` | — |

### Hooks

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [~] | Hook configuration UI | `Views/Settings/HookConfigView.swift` | — |
| [~] | Read/write `.claude/settings.json` hooks section | `Views/Settings/HookConfigView.swift` | — |

### MCP Server Management

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [~] | MCP server config UI (add/remove/edit servers) | `Views/Settings/MCPServerConfigView.swift` | — |
| [~] | Read/write `.claude/settings.json` mcpServers section | `Views/Settings/MCPServerConfigView.swift` | — |

### Plugin Management

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [~] | Plugin scanner (discover installed from ~/.claude/plugins/cache) | `Views/Settings/PluginManagerView.swift` | — |
| [~] | Plugin install (invoke claude CLI) | `Views/Settings/PluginManagerView.swift` | — |
| [~] | Plugin remove (delete from cache) | `Views/Settings/PluginManagerView.swift` | — |

### Git Integration

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [~] | Git status panel (branch, working tree, recent commits) | `Views/Settings/GitIntegrationView.swift` | — |

### Prompt Caching

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [~] | Cache metrics in stream events (creation/read tokens) | `Models/StreamEvent.swift` | — |
| [~] | Cache hit rate display in /context and /cost | `ViewModels/ChatViewModel.swift` | — |

### Task Tracking

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [~] | AgentTask model (parsed from tool calls) | `Models/AgentTask.swift` | — |
| [~] | Task panel view (progress display) | `Views/Tasks/AgentTaskPanelView.swift` | — |
| [~] | TaskCreate/TaskUpdate tool interception | `ViewModels/ChatViewModel.swift` | — |

### Session Branching

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [~] | ConversationTree model (branches, switch, rollback) | `Models/ConversationTree.swift` | — |
| [~] | /branch command (create/list/switch/delete) | `ViewModels/ChatViewModel.swift` | — |
| [~] | Branch indicator views | `Views/Chat/BranchIndicatorView.swift` | — |

### Web Preview & Agent Vision

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [~] | Web preview pane (control bar, back/forward/reload, trusted/external mode picker, pop-out window) | `Views/WebPreview/WebPreviewPanel.swift`, `Views/WebPreview/WebView.swift` | `WebPreviewUITests.swift` |
| [x] | Navigation policy gate (trusted = local-only; external = user nav allowed, agent nav needs allowlist or confirmation) | `Models/WebNavigationPolicy.swift` | `Models/WebNavigationPolicyTests.swift` |
| [x] | `web_navigate` tool (loads a URL, gated by navigation policy) | `Runtime/KiteloopToolSchemas.swift`, `ViewModels/WebPreviewViewModel.swift` | `ViewModels/WebNavigateToolTests.swift` |
| [x] | `web_screenshot` tool (PNG capture, disk retention with pruning, one-way send to the current agent) | `Runtime/KiteloopToolSchemas.swift`, `ViewModels/WebPreviewViewModel.swift` | `ViewModels/WebScreenshotToolTests.swift` |
| [x] | `web_read_text` / `web_inspect_head` tools (page text and head metadata, fenced and defused as untrusted content) | `Runtime/KiteloopToolSchemas.swift`, `ViewModels/WebPreviewViewModel.swift` | `ViewModels/WebReadToolTests.swift` |
| [x] | `web_list_elements` tool (interactive-element inventory addressed by stable refs) | `Runtime/KiteloopToolSchemas.swift`, `ViewModels/WebPreviewViewModel.swift` | `ViewModels/WebListElementsToolTests.swift` |
| [x] | `web_click` tool (click an element by ref, gated by navigation policy on same-page nav effects) | `Runtime/KiteloopToolSchemas.swift`, `ViewModels/WebPreviewViewModel.swift` | `ViewModels/WebClickToolTests.swift` |
| [x] | `web_type` tool (type into an input/textarea/contenteditable by ref) | `Runtime/KiteloopToolSchemas.swift`, `ViewModels/WebPreviewViewModel.swift` | `ViewModels/WebTypeToolTests.swift` |
| [x] | `web_scroll` tool (scroll the pane by direction or bring an element ref into view) | `Runtime/KiteloopToolSchemas.swift`, `ViewModels/WebPreviewViewModel.swift` | `ViewModels/WebScrollToolTests.swift` |
| [x] | Preview-target bridge (which agent's tool calls drive the pane) | `ViewModels/WebPreviewViewModel.swift` | `ViewModels/WebPreviewTargetBridgeTests.swift` |

---

## Team deployment

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [x] | Claude Code version detection + pinning | `Services/ClaudeVersionManager.swift` | `Services/ClaudeVersionManagerTests.swift` |
| [~] | Bedrock config support | `Models/KiteloopProject.swift` | — |
| [x] | Per-item git worktree isolation ([model](worktree-isolation.md)) | `Services/WorktreeSession.swift`, `Services/WorktreeManager.swift` | `Services/Autopilot/WorktreeSessionTests.swift`, `Services/Autopilot/WorktreeManagerTests.swift` |
| [~] | Shared team templates (`.kiteloop/team.json`) | `Services/TeamConfigManager.swift` | — |
| [x] | Bundled sample project ("Try a Sample Project" — a groomed demo backlog with worker/reviewer pre-assigned) | `Services/SampleProjectService.swift` | `Services/Agents/SampleProjectServiceTests.swift` |
| [x] | In-app updates (Sparkle: **Check for Updates…** in the app menu and a scheduled check while the app runs, against the appcast at `SUFeedURL`; a newer version is downloaded, its EdDSA signature verified, installed and relaunched — the relaunch goes through the same quit prompt as Cmd-Q, so runs in flight are asked about; App Preferences switches automatic checking and automatic download; Debug builds and test hosts do not update themselves) | `Services/SoftwareUpdater.swift`, `Services/LegacyUpdatePreferences.swift`, `Info.plist` | `Services/SoftwareUpdaterTests.swift`, `Services/LegacyUpdatePreferencesTests.swift` |
| [ ] | MDM / internal distribution | — | — |

---

## Autonomous Loop: Backlog Runner & Control API

The unattended run loop `CLAUDE.md`'s Autonomy section describes: a worker/reviewer
cycle over `ready` backlog items, gated at pickup and at done, driven and observed
through the local control API.

### Run Loop

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [x] | Worker/reviewer autopilot over `ready` backlog items (run graph, retries, review rounds) | `Services/BacklogAutopilot.swift` | `Services/Autopilot/BacklogAutopilotBusyStateTests.swift`, `Services/Autopilot/BacklogAutopilotReviewRoundsTests.swift` |
| [x] | Coordinator queue refill (drafts items when a project's queue runs dry, gated the same way a human-groomed item is; a drafted item is always born `later`, even under an epic named Now) | `Services/CoordinatorQueueRefill.swift` | `Services/Coordinator/CoordinatorQueueRefillTests.swift` |
| [x] | Refill pass files signal-drafted items too — a flaky test, a test the newest recorded suite row names as failing or hung, a hotspot or an escaped defect the repo's own instruments found, gated and filed the same way a model draft is | `Services/CoordinatorQueueRefill.swift`, `Services/SignalDrafting.swift`, `Services/SuiteFailureReader.swift` | `Services/Coordinator/CoordinatorQueueRefillSignalDraftingTests.swift` |
| [x] | Coordinator blocked-item triage (retries/escalates/retires a stuck item on a lifetime ceiling) | `Services/CoordinatorBlockedTriage.swift` | `Services/Coordinator/CoordinatorBlockedTriageTests.swift` |
| [x] | Pull request opened for a finished run (`openPullRequest`), skipped rather than failed when a remote, `gh`, or its login is missing | `Services/PullRequestPublisher.swift` | `Services/PullRequestPublisherTests.swift` |
| [x] | Pull request checks followed to green, handing a failing check back to the worker for a bounded number of fix rounds before the human gate opens | `Services/PullRequestChecks.swift` | `Services/PullRequestChecksTests.swift`, `Services/Autopilot/PullRequestChecksAutopilotTests.swift` |
| [x] | One pass over a pull request's review threads — each fixed or answered before the human is summoned | `Services/PullRequestComments.swift` | `Services/PullRequestCommentsTests.swift` |
| [x] | Autonomous scheduling loop (the timer that looks on a cadence, at launch and when a run finishes; the kill switch that arms it) | `Services/CoordinatorRunScheduler.swift` | `Services/Coordinator/CoordinatorRunSchedulerTests.swift` |
| [x] | The start decision itself (which project and which item, or a hold saying why nothing started) | `Services/RunScheduling.swift` | `Services/Coordinator/RunSchedulingTests.swift` |
| [x] | Runs at once (how many runs the fleet may have in flight across projects — clamped to its range, persisted, read back at launch) | `Services/CoordinatorRunScheduler.swift` | `Services/Coordinator/CoordinatorRunSchedulerTests.swift` |
| [x] | Per-project holds on repeated failed runs, expiring when that project's queue changes rather than on a timer | `Services/RunScheduling.swift`, `Services/CoordinatorRunScheduler.swift` | `Services/Coordinator/RunSchedulingTests.swift`, `Services/Coordinator/CoordinatorRunSchedulerTests.swift` |
| [x] | Durable start log (every start and finish appended, read back at launch with an unfinished start as `interrupted`, compacted to its count and age bounds) | `Services/CoordinatorRunScheduler.swift` | `Services/Coordinator/CoordinatorRunSchedulerTests.swift` |
| [x] | Draft, approve, send: an agent's always-ask rules stop the matching call on a card in every permission mode (refused where nobody attends), and the card's text fields can be reworded before allowing — what runs is what was sent | `Services/PermissionCards.swift`, `Runtime/ClaudeCodeCLIRuntime.swift`, `Views/Chat/PermissionCard.swift` | `Services/PermissionCardsTests.swift`, `Runtime/ClaudeCodeCLIRuntimeScopeTests.swift`, `Views/PermissionCardTests.swift` |
| [x] | A question a chat ends on survives a restart (`ask_human` and the model's choices): still open, still waiting on you, answered by saying the answer to the resumed conversation | `Services/CarriedQuestions.swift`, `ViewModels/ChatViewModel.swift` | `Services/CarriedQuestionsTests.swift`, `ViewModels/ChatViewModelCarriedQuestionTests.swift` |
| [x] | A project's pinned document (a project setting and `POST /v1/projects/pin`; listed with the project and shown first on the phone) | `Models/KiteloopProject.swift`, `Services/Control/KiteloopControlServer.swift` | `Services/Control/KiteloopControlServerHireAgentTests.swift` |
| [x] | Routines: a prompt sent to one agent on a schedule (a time of day or an interval within hours, on chosen weekdays), kept in `~/.kiteloop/routines.json` with a ledger of every firing | `Models/Routine.swift`, `Services/RoutineStore.swift` | `Services/RoutineStoreTests.swift` |
| [x] | What a routine owes (a daily one missed while the Mac slept runs late; a missed poll lapses when the next would have come; nothing from before it was armed) | `Services/RoutineSchedule.swift` | `Services/RoutineScheduleTests.swift` |
| [x] | The routine loop (one sleep to the next occurrence; a check that can skip the turn; the daily budget refuses a scheduled turn and is charged for it; an unreachable agent leaves the occurrence waiting until its project opens; Run now) | `Services/RoutineRunner.swift` | `Services/Coordinator/RoutineRunnerTests.swift` |
| [x] | A project's routines on its Autopilot tab (arming switch, schedule in words, last outcome, Run now) | `Views/Backlog/AutopilotRoutinesRow.swift` | `Views/AutopilotRoutinesRowTests.swift` |
| [x] | Routines over the control API (`/v1/routines`: list, put, delete, run now, the ledger) | `Services/Control/RoutineEndpoints.swift` | `Services/Control/KiteloopControlServerRoutinesTests.swift` |
| [x] | Daily spend ceiling, portfolio-wide and per-project (refuses an autonomous start, never a human one) | `Services/DailyBudget.swift` | `Services/DailyBudgetTests.swift` |
| [x] | Fleet quiesce (holds every project's queue and gates new starts; a quit waits out the drain and is called off by a resume) | `Services/FleetQuiesceControl.swift` | `Services/Coordinator/FleetQuiesceControlTests.swift` |
| [x] | Autonomy dial (`off` / `propose` / `land`: `propose` parks a review-passed run at the human gate, `land` approves and merges it; one control over the three deprecated switches) | `Services/BacklogAutopilot.swift`, `Views/Settings/AutopilotRunSettingsForm.swift` | `Services/Control/KiteloopControlServerAutopilotTests.swift` |
| [x] | `approvalGate` on `GET`/`PUT /v1/autopilot` (one value — `propose` or `land` — for what happens to a review-passed run; the two switches it replaced map onto it) | `Services/BacklogAutopilot.swift` | `Services/Control/KiteloopControlServerAutopilotTests.swift` |
| [x] | Derived run timeouts and worker turn budget (worker deadline p95 × 1.5, floor 15 min, cap 60, default 20; merge gate default 30 min; worker turns floor 50, cap 150 — read off the project's landed runs, not set by hand) | `Services/RunTimeouts.swift` | `Services/RunTimeoutsTests.swift` |
| [x] | Autonomy arming (a switch that would arm unattended work or grooming against no ceiling is refused, naming what is missing — the panel's toggles and the `PUT` handlers both ask here) | `Services/AutonomyArming.swift` | `Services/AutonomyArmingTests.swift` |
| [x] | Trust ladder (five rungs — by hand, projects that can run, grooming, and up — each met or not by the switches, gates and holds that already exist, with the control that advances the first unmet one) | `Services/AutonomyLadder.swift` | `Services/AutonomyLadderTests.swift` |

### Pickup Gates

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [x] | Definition-of-Ready (groomed What/How/Validation, a `verify:` command, size ≤ M, `needs:<id>` done) | `Services/DefinitionOfReady.swift` | `Services/DefinitionOfReadyTests.swift` |
| [x] | Grounding check (refuses a draft whose backticked paths/symbols, or `verify:` command, name nothing in the repo) | `Services/GroundingCheck.swift` | `Services/GroundingCheckTests.swift`, `Services/GroundingCheckHardeningTests.swift` |
| [x] | Retry ceiling (bounds no-work attempts on an item across runs, not per run) | `Services/RetryCeiling.swift` | `Services/Autopilot/RetryCeilingTests.swift` |

### Done Gates

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [x] | Run work evidence (whether a finished run left a branch and a non-empty diff behind, read from git) | `Services/RunWorkEvidence.swift` | `Services/Autopilot/RunWorkEvidenceTests.swift` |
| [x] | Empty-diff handoff (tells the worker, before handoff, that it changed nothing) | `Services/EmptyDiffHandoff.swift` | `Services/Autopilot/EmptyDiffHandoffTests.swift` |
| [x] | Diff rules (an unrelated item touching `docs/suite-status.md` blocks; an undocumented behaviour change is advisory) | `Services/DiffRules.swift` | `Services/DiffRulesTests.swift` |
| [x] | Review findings (blocking vs. advisory verdict routing, lenient on anything unreadable) | `Services/ReviewFindings.swift` | `Services/ReviewFindingsTests.swift` |

### Control API

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [x] | Control server (loopback HTTP, bearer-token auth; in-process and socket transports answer alike) | `Services/Control/KiteloopControlServer.swift` | `Services/Control/KiteloopControlServerInProcessTests.swift`, `Services/Control/KiteloopControlServerAuthTests.swift` |
| [x] | Routing table (every documented endpoint resolves to the handler it names) | `Services/Control/ControlRouter.swift` | `Services/Control/ControlRouterTests.swift` |
| [x] | OpenAPI document, generated from the routing table rather than written alongside it | `Services/Control/ControlAPISpec.swift` | `Services/Control/ControlAPISpecDocumentTests.swift` |
| [x] | Durable run records (survive an app restart; a run in flight at kill time answers `interrupted`) | `Services/Control/RunRecordStore.swift` | `Services/Control/RunRecordStoreTests.swift` |
| [x] | `POST /v1/backlog/land` (merges a done item's branch that never landed; a human-gate endpoint beside the two approve endpoints, 403 for the operator token) | `Services/Control/ControlRouter.swift`, `Services/Control/KiteloopControlServer.swift` | `Services/Control/KiteloopControlServerBacklogApproveTests.swift`, `Services/Control/KiteloopControlServerAuthTests.swift` |

---

## Phone Pairing

Pairing a phone to a Mac's control server: a QR sheet in Settings, the
addresses it offers, and a check that something is actually listening before
the phone scans.

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [~] | Pairing sheet (`kiteloop://connect?base=…&code=…` QR with a one-time code, network picker, reachability banner) | `Views/Settings/AppPreferencesView.swift` | — |
| [x] | Pairing address candidates (tailnet vs. LAN classification, phone-facing label) | `Services/PairingAddresses.swift` | `Services/PairingAddressesTests.swift` |
| [x] | Pre-scan reachability probe (races an unauthenticated `/health` check against a timeout) | `Services/PairingReachabilityProbe.swift` | `Services/PairingReachabilityProbeTests.swift` |
| [x] | Reachability banner text (`.unreachable` names the toggle or the forwarder script depending on whether the server is running) | `Services/PairingRemedy.swift` | `Services/PairingRemedyTests.swift` |

---

## Phone Companion

`KiteloopMobile`, the iOS app that pairs to a Mac's control server and drives
it remotely: connect and scan, two tabs (Projects and Fleet), and the approval
gate. `KiteloopMobileTests` (`KiteloopMobile/Tests/`, five files) runs on a
simulator with the command under "Before you open a pull request" in
`CONTRIBUTING.md`; no standing check runs it, so the rows below are what is
covered.

| Status | Feature | Source | Test |
|--------|---------|--------|------|
| [~] | Connect flow and QR scan (paste or scan a `kiteloop://connect?…` URL) | `Sources/Views/ConnectView.swift`, `Sources/Views/ScannerView.swift` | — |
| [~] | Bearer token storage (Keychain) | `Sources/Services/Keychain.swift` | — |
| [x] | Connection gate (`configured` is true only once both base URL and token are set) | `Sources/Services/ConnectionStore.swift` | `Tests/ConnectionStoreTests.swift` |
| [x] | Control API query-string building (percent-encoding, param joining) | `Sources/Services/ControlClient.swift` | `Tests/ControlClientTests.swift` |
| [~] | Control API transport (requests, SSE event stream) | `Sources/Services/ControlClient.swift` | — |
| [~] | Tolerant decoding of control API responses | `Sources/Models/ControlModels.swift` | — |
| [x] | The gate as a step on the phone: a verifying gate is shown as such and not as waiting on you; a refused gate carries its reason | `Sources/Models/ControlModels.swift`, `Sources/Views/ProjectView.swift` | `Tests/ControlModelsTests.swift` |
| [x] | Refresh state: whether to wait or pull, and what failed (unreachable Mac, rejected token, older Mac, server error) with the fix | `Sources/Models/RefreshState.swift`, `Sources/Views/RefreshStatusBar.swift` | `Tests/RefreshStateTests.swift` |
| [~] | Status card: state pill, item in flight, phase rail, spend against cap, the one lever | `Sources/Views/StatusCard.swift` | — |
| [~] | Project chip row: every open project in the Mac's tab order, spinning while it runs; a long-press drag reorders on both the phone and the Mac | `Sources/Views/ProjectChipRow.swift`, `Sources/ViewModels/ProjectViewModel.swift` | — |
| [x] | Projects tab: one project at a time — state, the one lever it offers, what waits on you, the queue, the agents | `Sources/ViewModels/ProjectViewModel.swift`, `Sources/Views/ProjectView.swift` | `Tests/ProjectStateTests.swift` |
| [~] | Approval gates surfaced per project | `Sources/ViewModels/NowViewModel.swift` | — |
| [~] | Queue list (backlog items, pushed from the project): now items first under their own header, each tagged with its epic, and a swipe that flips an item's lane through `POST /v1/backlog/lane` | `Sources/ViewModels/QueueViewModel.swift`, `Sources/Views/QueueListView.swift` | — |
| [~] | Agent conversation as prose, tool calls one line each, spinner while the agent works | `Sources/ViewModels/AgentsViewModel.swift`, `Sources/Views/ChatView.swift` | — |
| [~] | Fleet tab (quiesce state and its one lever, planner passes, daily budget, connection) | `Sources/ViewModels/LeversViewModel.swift`, `Sources/Views/FleetView.swift` | — |
| [~] | Approval gate review | `Sources/Views/GateReviewView.swift` | — |
| [~] | App entry and tab bar | `Sources/KiteloopMobileApp.swift` | — |
