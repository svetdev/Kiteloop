# Changelog

All notable changes to Kiteloop. Newest first.

The version here is the app's `MARKETING_VERSION` (what `/health` reports and
what the About panel shows). Every build that ships a behavioural change gets an
entry — see the changelog convention in `CLAUDE.md`.

## 0.4.9 — unreleased

### Added

#### Chat
- An unfolded tool call's output shows a copy button on hover that copies the whole output, in both the bubble and the terminal look, and a plan waiting for approval has a copy button that copies the plan.
- File > New Chat (⌘N) starts a new chat with the selected agent, so a chat can be started with the sidebar hidden.
- A plan waiting for approval has a "What should change?" field: pressing Keep planning (or Return) with text in it sends that text to the agent so it revises the plan, after any running turn ends.
- A chat you have scrolled up in shows a Jump to latest button at the bottom of the message list, reading "New messages" when the agent posted more below; clicking it scrolls to the newest message and the chat follows again.
- The chat's find bar (⌘F) now finds words in a plan card and in a question an agent asked you, counting them and landing on them with Next and Previous.
- A chat holding an unsent message shows it in the sidebar's Sessions list: its row reads "Draft: " and the draft's first line in place of the last-message time.
- The sidebar's Sessions list has a filter field once an agent has more than one chat: it narrows the list to chats whose title contains the text, ignoring case (an untitled chat matches "New Chat"), says "No matching chats" when none do, and clears when you switch agent.
- A conversation branch can be deleted from the branch bar: right-click it, choose Delete Branch…, and confirm by its name.
- A conversation can be branched from any earlier message: right-click the message and choose Branch from Here to save a new branch holding the chat up to that point.
- A message a branch was made from shows a branch mark with how many branches start there, and its right-click menu offers Switch to Branch for each of them.
- A conversation branch can be renamed from the branch bar: right-click it and choose Rename Branch…; a blank name or one another branch has is refused with a line saying why.
- An image in the chat can be opened at full size: double-click it, or choose Open in Preview from its context menu, and it opens in your default viewer in its own format.
- A plan a Plan-mode agent leaves for your approval now files a notice — a bell row and a banner that open the agent's chat — so you hear about it from another chat or project; approving the plan or choosing Keep planning clears it.
- In the terminal-style chat, a click on one of a subagent's calls opens it to what it returned — a read as its line count, a failure as its error in red, "Running…" while it has not returned — and a click on its text shows the whole of it; the group folds from its own fold line.
- A chat with one agent in it now reads the way Claude Code reads in the terminal: one monospaced column with `>` before what you typed, `⏺` before each reply and tool call, and a call's outcome under `⎿` — "Read 84 lines", an error in red, or the first three lines of output with "… +N lines" (click a call for all of it). A chat holding replies from several agents keeps the bubbles, which name who said what.
- In the terminal-style chat an edit reads as what it changed — "Updated notes.txt with 2 additions and 1 removal", or "Wrote 14 lines to notes.txt" — with the first changed lines in red and green beneath it (click for the whole change), instead of the tool's "has been updated successfully".
- Chats in the sidebar's Sessions list can be renamed (Rename Chat…, the name survives new messages, relaunches and a late auto-title), deleted (Delete Chat… asks first and opens the next chat) and exported (Export Chat… saves the conversation as Markdown headed by sender and time, one line per tool call, leaving out thinking and anything typed into an MCP access card).
- `/mode` in a Claude agent's chat names its permission mode and the choices; `/mode plan`, `/mode accept edits` and the rest switch it and carry on the same conversation, as Shift-Tab does in Claude Code.
- A Claude agent in Plan mode that writes its plan ends the turn with the plan as a card: Approve and build (Auto) or (Accept Edits) switches its mode, carries on the same conversation and tells it to implement the plan; Keep planning leaves it as it is. The card keeps the choice made.
- A plan card closes as "Kept planning" once you type the agent a message or it writes a newer plan, so only the newest plan can be approved — never an old card after you've asked for changes.
- /undo puts the message it takes back in the chat input, so you can edit it and press Enter to send it again instead of retyping it.
- Hovering a message you sent shows a copy button in its top-right corner, in both the bubble and the terminal look, that copies its full text — as a reply's does — so a long prompt can be reused without selecting it by hand.
- Typing `/` lists the app's own commands — /clear, /model, /compact, /undo, /branch and the rest — with a one-line description, ahead of your skills; a skill named like a command is no longer offered.
- Each message says when it was sent: hover for its time (and date, if not today), with a Today / Yesterday / dated marker above the first message of each day.
- ⌘V with a copied screenshot, or files copied in Finder or dropped on the input, attach instead of typing paths; the paperclip now picks every text and picture type a drop accepts (CSV, TSV, YAML, HTML, XML, Markdown, HEIC, TIFF, BMP, SVG).
- Right-click inside a code block in a reply for Copy Code, which copies just the code; the find bar outlines the match it is on and moves the outline with Next and Previous.
- A subagent's tool calls now sit under the Agent call that started it (click to fold them), not among the agent's own, and the Agent row says how its subagent is doing — "general-purpose · 2 tools · 16k tokens · last: Bash", then completed or failed. A shell sent to the background reads "running in background" until it ends, then "finished · exit code 0", and a "Background: N running" strip above the input names what is still going.
- An empty thinking block (current models keep their reasoning to themselves) reads "Thinking… (201 tokens)" from the CLI's estimate, and the live ticker counts the tokens while the model thinks; a rate-limit warning or refusal gets a line in the chat, the routine "allowed" notice none.
- When a background shell or subagent finishes after the turn that started it, the agent's reply to it now appears in the chat as a turn of its own — working indicator, cost and all — instead of being lost; a message you type meanwhile waits for it, and an autopilot worker waiting on its background agent hands off on that reply without being nudged.
- What a subagent thinks and writes — its closing report included — now shows under its Agent call beside its tool calls (folded with them), never as the agent's own reply, and never counted into an answer another agent, a debate or a helper reads.

#### Backlog
- The backlog header has a search field: it matches titles and ids, ignoring case, finds finished items even with "Hide completed" on, and draws only the epics holding a match; clearing it restores your collapsed epics.
- Items and epics can be reordered and renamed in place: Rename Item…, Move Up and Move Down beside Move to top of epic, and Move Epic Up / Move Epic Down in each epic's menu.
- An item's page edits its `verify:` and `needs:` in place (a blank command, a `" | "`, an unknown id, the item itself or a cycle is refused with a message), and Add Note leaves a note for the next worker run without rejecting one.
- An item's page links what it needs, the item it was split from and the items split out of it, each with its current status; a ready item held back by an unmet `needs:` shows a "waiting" pill whose hover gives the reasons.
- Lanes: each open item is marked `now` or `later` with Run now / Back to later in its menu, a Now section lists now items in the order autopilot runs them, the phone's queue flips a lane with a swipe, and `GET /v1/backlog` / `POST /v1/backlog/lane` read and set it. An item the refill pass drafts is always `later`.

#### Menu bar, notifications and windows
- A project tab shows an orange raised hand when something there is waiting on you — an item at the approval gate or an agent's question — over the busy spinner, and it stays until the gate is cleared, not when you click the tab.
- The Software Update window has a Skip This Version button: the launch check then stays quiet about that release and only speaks up for a newer one, while Check for Updates… still shows it and says it was skipped.
- The menu bar names what every open project is running, counts the approvals and questions waiting on you (its icon fills while any are) and lists up to five of them; clicking one opens where it is cleared.
- Every notice in the bell popover says when it arrived.
- ⌘1…⌘9 switch to the first nine project tabs, and ⌘⇧] / ⌘⇧[ step through them, wrapping.
- Hovering a project tab or a Portfolio card's name shows the project's folder, and both right-click menus offer Show in Finder and Copy Path.
- When a newer Kiteloop is out, the Software Update window shows its release notes.

#### Agents, settings and memory
- App Preferences has an "Automatically check for updates" toggle, on by default: with it off, Kiteloop makes no update request at launch, and Check for Updates… still checks when you choose it.
- Agents run in Claude Code's auto mode by default — its classifier decides each tool call — and every permission picker offers Auto; autopilot runs and background helpers always use it instead of bypassing permissions with Kiteloop's own deny list, and anything that would ask for permission is refused.
- The New Agent and Edit Agent Model pickers list the models you have pulled in Ollama, labelled "local", and mark built-in Ollama models you have not pulled.
- Settings → Backend can remove a saved API key (Remove…, after a confirmation).
- Settings → Control API has a Copy Token button beside the bearer token's path that puts the current token on the clipboard, or says the token file could not be read.
- Project MCP servers, Claude Code hooks and Kiteloop hooks each have a trash button (removed on Save), and each installed plugin has one that opens its delete confirmation.
- An archived fact in the Memory tab can be restored to the agent's memory index; a full index, a covering fact or a live fact of the same name refuses it.
- An archived fact in the Memory tab can be deleted for good: its Delete button asks first, warning that the text is removed permanently and cannot be restored.
- A pending Merge, Delete or Archive proposal in the Memory tab shows the current text of each fact it replaces, deletes or archives, and says when the agent no longer has one.
- A fact in the Memory tab can be corrected in place: its edit button opens the fact's text, and saving rewrites it under the same topic and position, dated today.
- A fact can be written into an agent's memory by hand: the Memory tab's Add fact button opens an editor, and saving records the text as a new fact dated today; a full index or a fact already covered refuses it with the reason, keeping your text in the editor.

#### Console and web preview
- The console's Activity tab has a Search field, and each turn in the Traces tab shows its prompt and output tokens, cache hit rate and model.
- While a page loads in the web preview, the reload button becomes Stop.
- The web preview has an Open in Browser button that opens the page it is showing in your default browser, with your own devtools, extensions and sign-ins.
- When the web preview refuses a site in Trusted mode, its banner has a Load in External button that switches the pane to External and loads that site, without retyping the address.
- The web preview can be zoomed from 50% to 300% with ⌘= and ⌘-; its control bar shows the zoom, and clicking the percentage puts the page back to 100%.
- The web preview has a Copy Screenshot button that puts a PNG of the page on the clipboard, whether or not an agent is selected.
- The web preview has a Find button that opens a find field: Return or the arrows step forward and back through matches on the page, wrapping at either end, and it says “Not found” when the page has none.
- The web preview's address bar remembers the last address loaded in Trusted mode across relaunches, so pressing Return loads your dev server again without retyping it; nothing loads by itself.
- A popped-out Web Preview window is titled with the page it shows — “Web Preview — <page title>” — and follows the title as the page changes, so two previews can be told apart in Mission Control and the Window menu.
- A popped-out Web Preview window opens at the size and place you last left it, on whichever display, including after a relaunch; it opens at 900×700 in the middle of the screen only the first time.
- The web preview has a Console button that lists what the page wrote to its console and every uncaught error and unhandled promise rejection, errors in red, with the error count on the button; the list starts empty with each new page.
- An agent you have selected with the web preview open can read the page's console — its log, warning and error lines and uncaught errors, with their times — through a new web_console tool, so it can see why a page is blank.
- The web preview's Console, and what an agent reads through web_console, now include the page's console.info and console.debug lines (such as Vite's "[vite] connected."), labelled info and debug; they do not add to the error count.
- The web preview's Console has Clear, which empties the list and the error count on the button without reloading the page, and Copy All, which puts every line on the clipboard as time, level and text, one per line.
- The web preview's Console has a level picker — All, Warnings & Errors, Errors — that narrows the list, and Copy All, to the lines at or above that level; warnings are drawn in orange.
- Once the web preview's Console has let its oldest lines go to keep the newest 200, the top of its list says how many were not kept (“312 earlier lines not kept”), Copy All starts with the same line, and Clear or a new page resets it.
- The web preview's Console, and what an agent reads through web_console, fill in a line's format string as a browser does — console.log('%s has %d items', 'cart', 3) reads "cart has 3 items" — and a %c style is dropped instead of printed as text.
- A session in the Traces tab shows the title of the chat it belongs to, on its row and above the session id, so an agent's chats can be told apart.

#### Autopilot and control API
- A run stopped by your Claude subscription's usage limit is parked instead of failed: the item goes back to Ready with a note saying when the limit resets, no retry is charged, its work is kept on its branch, the run ends without starting the next item into the same wall, and scheduled runs across every project hold until the reset and then pick the item up again.
- Kiteloop itself is onboarded for the QA flow: a `flow:qa` item's QA agent runs the item's UI test against a separate QA copy of the app, launched with its own home folder so it never reads or writes your real `~/.kiteloop`, and judges the screenshots each step left.
- An item marked `flow:qa` runs through a QA flow for UI features: a specifier writes acceptance scenarios and a QA procedure first, the project's clean and mutation commands run after the worker, and a QA agent runs the app, opens every screenshot and judges each step before the item can be done — its report and storyboard are written on the item. A project opts in with a `kiteloop-qa.json` at its root; without one a `flow:qa` item is refused and told why.
- `POST /v1/backlog/land` merges a done item's branch that never landed — approved with auto-merge off, under a half-set dial or by hand — through the same gate as an approval, with the operator's own token.
- A worker's turn budget grows with the project: once five runs have recorded a turn count it is their 95th percentile plus half again, between 50 and 150, reported by `GET /v1/autopilot` as `workerMaxTurns` and `workerMaxTurnsSource`.
- An item's cost cap is now read off the project's own runs — their p95 cost plus half again, never below the item's predicted cost — instead of a flat cap and margin set by hand; `GET /v1/autopilot` reports it as `itemCostCapUSD` with its source.
- What happens to a review-passed run is one setting, `approvalGate` — `propose` waits for a person, `land` approves and merges — so the two old switches can no longer be half-set; an old config or `PUT /v1/autopilot` with both switches on reads as `land`, anything else as `propose`.
- The half-set autonomy warning is gone, along with `autonomyMismatch` on `GET /v1/autopilot` and the warning a run logged at start; the one case left — unattended runs off with the gate at `land` — is said under the Autonomy dial: a run started by hand still lands itself.
- The quality judge no longer blocks a run: it scores every finished run and writes any scope deviation it names to the item's Notes as advisory, and its switch, `qualityJudgeEnabled`, is gone from the autopilot config and `/v1/autopilot` (an old config or `PUT` naming it is accepted and the key ignored).
- Autopilot starts with only a worker assigned: with no reviewer, a run goes from the worker straight to the merge and approval gates instead of refusing to start, and an empty run is still turned back.
- With no reviewer assigned, the autopilot worker reads its own diff against the item's Validation and Out of Scope before handing off, fixing what is unmet or saying plainly what is.
- The autopilot settings page offers "No separate reviewer" for the reviewer, `PUT /v1/autopilot` clears the reviewer with `null`, and a project with no autopilot config yet starts with no reviewer.
- The verify map is read from `kiteloop-verify.json` at the repository root, so it can be committed and reviewed; a project with only the old `.kiteloop/verify-map.json` still has it applied, and the log says once that it was read from the old path.
- Kiteloop's own repository now ships its verify map as `kiteloop-verify.json` at the root, and the docs say that is where a project's map lives.
- Reject on the phone's gate screen asks for an optional reason before it sends, and a reason given is written to the item's Notes for the next run to read; Cancel sends nothing.
- With a verify map, the merge gate runs the item's own `verify:` plus each check whose rule matches a path the branch changed, each once, instead of one project-wide command; a set merge-verify command still runs on every merge, and a project with no map runs what it ran before.
- An item with no `verify:` is no longer refused at pickup when the project's verify map has a rule matching every path (`"glob": "**"`); without such a rule it is refused as before.
- The merge-verify command is no longer a setting — the settings page drops its field and `GET /v1/autopilot` no longer reports `autoMergeVerifyCommand`; a verify-map rule matching every path (`"glob": "**"`) takes its place. A command stored by an earlier release still runs for this release while the map has no such rule, and the autopilot log names the rule to add.
- On the phone, a project's Queue row shows how many ready items can start ("1 of 5 can start") when that is fewer than are ready, and the queue list says under a ready item why the Mac would not start it and marks a retired one, instead of showing it as plain ready.
- In the Autopilot console, a worker or reviewer pane past 60 rows shows a "Show N earlier" button above them: each click shows up to 60 older rows without moving your place, until the run's first rows are back; a new run starts from the newest 60 again.
- In the Autopilot console, clicking a call's headline in a worker or reviewer pane — on its own or inside an expanded shell burst — unfolds its full output beneath it as selectable text, red for an error, and clicking again folds it.
- An item waiting for your approval after a QA run has a Storyboard button beside Approve, which opens the screenshots QA judged, step by step with each step's caption and failed steps marked, so you can see what QA saw before approving.

#### Phone companion
- A conversation with an agent opens as its own screen under a solid top bar, with a back button, instead of a pop-up sheet.
- Swiping down the conversation, or the keyboard button beside the message field, puts the keyboard away so a long reply can be read.
- The phone app stays in portrait.
- The pairing forwarder can run tailnet-only (`install-control-forwarder.sh --tailnet-only`), so on a work laptop it never listens on office Wi-Fi.
- `scripts/make-mobile-release.sh` archives the phone app and uploads it to TestFlight, so it installs from the TestFlight app instead of from Xcode on a cable.
- The phone app remembers every Mac it has paired with: Fleet → Macs switches between them (the home Mac and a work laptop, say) and forgets one with a swipe, instead of re-pairing each time. The Mac's pairing code now carries its name.
- A message sent through the control API is answered as soon as it is in, and `GET /v1/agents/events` streams the agent's chat as it happens — each reply as it grows, and the agent starting and finishing turns — instead of the request being held open for the whole turn (`"wait": true` keeps the old answer with the reply).
- The phone's chat is live: a reply appears word by word as the agent writes it, and the Working indicator follows the agent's own turn. If the live connection drops, the chat says so and reloads every few seconds until it reconnects.
- The phone can stop an agent mid-turn: while it works, the send button is a Stop button, and what you had queued comes back to the draft (`POST /v1/agents/interrupt`).
- A Plan-mode agent's plan reaches the phone as a card with the Mac's three answers — build in Auto, build in Accept Edits, or keep planning with what should change — so you can plan from the phone and let the Mac build (`POST /v1/agents/plan`).
- A question an agent stops to ask shows on the phone with an answer field, and answering it there resumes the agent's turn (`POST /v1/agents/answer`).
- The phone can hire an agent into a project (Projects → Agents → Hire an agent) and start a fresh conversation with one (the pencil in the chat, which sends /clear after asking).
- A photo or screenshot can go to an agent from the phone: the photo button in the chat attaches one, scaled to what a model looks at, and the control API's message endpoint takes images as `attachments`.
- The phone can see the code: Projects → Workspace (and the ± button in a chat) shows the agents' uncommitted changes as a colored diff; a file tool's line in the chat, a changed file or the Files browser opens the file read-only with line numbers; and Web preview shows what the Mac's preview pane shows. Files git ignores, `.git` and anything outside the project are refused (`GET /v1/workspace/changes`, `/v1/workspace/file`, `/v1/preview/screenshot`).
- The Mac can push to the phone, straight to Apple's push service: when an item reaches the approval gate, an agent asks you something or has a plan ready, a background project finishes, or a turn you started from the phone ends. Set an APNs key (developer.apple.com → Keys) under Settings → Control API → Push to phones; phones register through `POST /v1/devices/push`, and a phone Apple says is gone is forgotten.
- The phone app asks to send notifications once paired, registers with whichever Mac is current, and a tapped notification opens its project — and the agent's chat for a question or a finished turn.
- A message sent from the phone starts a Live Activity: the lock screen and Dynamic Island show the agent working, its newest line, a question or plan waiting on you, and Done — kept current by the Mac's pushes while the phone sleeps (`POST /v1/devices/activity`).
- **Pair a phone** shows a one-time code instead of a token: the phone trades it for a token of its own (`POST /v1/pair`), it works once, and closing the sheet withdraws it — so a photo of the QR is worthless afterwards, a sheet closed without a scan leaves no unused phone in the list, and the sheet says which phone paired.
- Each phone paired through **Pair a phone** gets a token of its own instead of the shared control token. Settings → Control API → Paired phones lists them, with when each was paired and last used, and **Revoke** stops one phone without re-pairing the others or touching the control token scripts use.
- Every control API request is logged to `~/.kiteloop/logs/control-access.log` — when, what, by which token or paired phone, and the answer — so what was done from the phone can be read back. No bodies, query strings or tokens are written.
- `/health` reports an `apiVersion`, and the phone checks it: a Mac whose Kiteloop is older than the phone app gets a banner on the Projects screen saying to update Kiteloop there, and a newer one says to update the phone app — instead of screens failing with a bare 404.
- The phone's Fleet screen has a Usage section: how close the agents are to their rate limit — the one nearest it, with its window, share used and reset time, in orange once it warns — and the last 24 hours' spend per project (`GET /v1/usage`).
- An idea can go into the backlog from the phone: the + in a project's queue files it as a draft in Inbox, with what it is about as its What, and **Groom it on the Mac** has the Mac write its verify, size and detail the way the Groom button does — it stays a draft until you promote it (`POST /v1/backlog/items`).
- Quick replies: the phone's chat shows a row of one-tap replies above the composer — Continue, Yes, go ahead and Run the tests to start with, edited under Settings → Control API → Quick replies. A tap sends the reply while the agent is idle, and adds it to the draft while the agent is working or something is already typed (`GET /v1/quick-replies`).
- The phone's chat draws an agent's Markdown — headings, bullet and numbered lists, quotes, code blocks, bold, italic, inline code and links — instead of showing the asterisks and fences as typed.

### Fixes

#### Chat
- Export Chat… writes a chat's branches too — the main line first, then each branch under its name from the message it was branched at — and exporting the chat you have open includes everything it shows, not only what was last saved.
- A message that names a specialist with @ now takes the files in the attachment tray with it: the summoned specialist's first message carries them, every specialist named gets the same files, and the tray empties once, instead of the files silently disappearing.
- The context gauge and `/context` measure against the window the model actually has, as Claude reports it after each turn, instead of assuming 200k for every model; a 1M-window session no longer reads five times fuller than it is. Until the first turn reports, the gauge says the window is not known.
- A code block in a reply is drawn in the code font throughout: an untagged block that looked like Markdown came back with _careful_ in italics.
- A reply written with underscore emphasis — _careful_, __never__ — is drawn italic and bold without its underscores, while names like snake_case_name, __init__ and some_file.swift keep theirs.
- The chat's find bar now says “No matches” beside the field when nothing in the conversation matches, instead of going blank as if nothing had been typed.
- When an agent keeps Claude's own task list, the Agent Tasks panel now follows it — deleted tasks disappear, an update without a status still changes the task — and the agent's turn keeps going instead of stopping at the call and being answered a second time.
- A chat turn the agent's turn limit, per-turn spend cap or an error stopped now ends with a line saying why — for the turn limit, how many turns it used and to send "continue" or raise the limit — instead of looking as if the agent had finished.
- Pressing Return in a plan card's empty “What should change?” field no longer closes the card as Kept planning; the plan stays open with its buttons, and Return with text in the field still sends it.
- An answer to an agent's question that is only blank lines is no longer sent: Reply stays disabled and the question stays open, and the chat's send button likewise stays disabled for a message of only line breaks.
- The chat's line for a retried API call now says how long until the next try and the HTTP status when there is one ("Retrying in 12s (attempt 2 of 10) — rate_limit, HTTP 429"), and a run of retries shows one line with the latest attempt instead of one per attempt.

#### Models
- An agent set to Fable now runs the current Fable (5.1) instead of staying pinned to Fable 5, and turns on Claude Opus 5.5 and Fable 5.1 — what the `opus` and `fable` aliases launch today — show their cost instead of reading as unmeasured.

#### Slash commands
- Commands that only apply to Claude now say so on an Ollama or Copilot agent and leave it as it was: `/fork`, `/fork aside`, `/compact`, `/effort`, `/thinking` and `/fast` (which no longer moves the agent onto Opus), and the `/` popover no longer offers them there.
- `/cost`, `/context` and `/doctor` on an Ollama or Copilot agent report that runtime: nothing charged for a local model, no context percentage measured against Claude's window, and whether Ollama or the Copilot bridge is reachable instead of the Claude CLI.
- `/model` refuses an unknown name (listing the choices) or a model from another runtime instead of restarting the agent on something that cannot start, saves catalog names in lowercase, and `/model` or `/effort` alone shows the current value.
- Read-only commands (`/loop status`, `/goal status`, `/cost`, `/context`, `/history`, `/model`, `/effort`, `/branch list`, `/doctor`) and `/loop stop`, `/loop cancel`, `/goal cancel` answer at once during a turn instead of waiting in the queue; a message typed during `/recap`, `/compact`, `/loop` or `/goal` is sent the moment it finishes.
- A message or `/recap`, `/compact`, `/loop`, `/goal` sent to an agent you stopped starts it first, and says why if it cannot.
- `/compact` actually compacts the running session; thinking is passed to the CLI as `--thinking enabled` with a budget, so it no longer stops the agent starting; `/thinking 0` or a negative budget is refused.
- `/clear` resets the cost and context counters; `/undo`, `/clear` and branch switches are saved at once and survive a relaunch, and `/undo` and switching branch say the agent still remembers the earlier conversation.
- `/branch` without a name gives its usage, a name in use is refused, a bare `/branch` picks a free name, and a branch stays in the chat it was made in.
- `/branch switch main`, in any letter case, goes to the main line the way `/branch main` does instead of saying there is no branch named main, and `/branch delete main` says the main line cannot be deleted.
- `/branch switch` and `/branch delete` find a branch typed in another letter case, and a new or renamed branch whose name differs from an existing one only by case is refused as a duplicate.
- `/branch rename <name>` renames the branch you are on, refusing the names the branch bar's Rename refuses, instead of saving a new branch called "rename <name>"; on the main line it says the main line cannot be renamed.
- Commands work whatever their case; a word that only starts like a command (`/goals`, `/goal-review`) reaches the skill or the agent; skills that cannot run from the chat are no longer offered.
- `/goal` and `/loop` report what their own turns cost, and `/history` names the model and mode the agent really runs with and says what it shows.

#### Chat input
- Tab after a relative path in the chat input (docs/gu, ./Sources/Ap) completes it from the project's folder, where the agent runs, and keeps it relative — instead of looking it up from the root of the disk.
- The @-mention suggestions no longer show an orange warning triangle beside every agent.
- Tab after a path ending in `/` lists and completes what is inside that folder, instead of offering the folder itself again.
- A file dropped on the chat input, or pasted after copying it in Finder, that is too large or cannot be read is no longer typed into the message as its path: the chat says why it could not be attached, as it does for the paperclip, and the other files in the same drop are still attached.
- When a reply is cut off and the agent reconnects, the message you sent is put back in the input box, ahead of anything you typed since, so you can send it again without retyping it.
- Messages you queued during a reply that is cut off are no longer sent to the disconnected agent: they come back to the input box, oldest first, after the cut-off message, and a teammate's queued messages wait until the agent has reconnected.
- A message you send while the agent is still replying now shows in the queued strip above the input, one line each, and a button beside it takes that one message back into the input box with its attachments, without stopping the turn; the strip no longer counts messages the app queued itself, such as a plan-card answer.
- A chat holding an unsent draft is no longer deleted when Kiteloop starts because another chat was newer; only chats with no messages and no draft are cleared away.
- Stop hands the messages you queued during the turn back to the input box with their attachments; a queued message keeps its own attachments, and a message that is only an attachment is sent.
- A half-typed message stays in its agent's box across switching agents, tabs and projects, and Up recalls the conversation on screen.
- Each chat keeps its own unsent message: it is still there after Kiteloop quits or restarts, switching chats in SESSIONS brings back that chat's own text instead of carrying yours into the next one, and sending clears it.
- Keys: Return and the arrows go to a Japanese, Chinese or Korean input method while it composes; Enter in the `/` or `@` popover inserts the highlighted entry; Esc keeps a dismissed popover closed while you edit that token; Ctrl+R search takes the cursor; Ctrl+K, Ctrl+U and Ctrl+W no longer overwrite the clipboard and Ctrl+Y brings their text back; `!$` expands only standing alone.
- Attachments: HEIC, TIFF and BMP are converted to PNG, SVG goes as markup, text with a non-UTF-8 byte is sent with a replacement character, files over 10 MB or unreadable ones are named in the chat instead of vanishing.
- A large image — a pasted Retina screenshot, a big photo or a web preview screenshot — is scaled down to 1568 px on its long edge, and sent as JPEG if it is still over 5 MB, instead of failing the whole message.
- ⌘F opens find from every view of the chat, Return / Shift-Return / Esc work, the count covers only what the chat shows, and it says when older messages were not searched.

#### Chat transcript
- A subagent's own subagent is drawn under the Agent call that started it, one step further in and inside its fold, instead of flat under the outer Agent row.
- The app's own notes in the chat — a saved branch, the branch list, a goal set, the hint to use `/clear` — show their bold and code as formatted text in both chat looks, instead of printing `**` and backticks.
- When a crashed agent cannot be reconnected, the chat's error and the crash bar now say why the last restart failed (a missing CLI, an expired login, a bad model) instead of only that the process terminated unexpectedly.
- A chat's title is one line taken from the start of your first message: a message that opens with a blank line or pasted code no longer leaves a blank or backticks-only title, and a generated title keeps only its first line.
- The Agent Tasks panel under the chat now scrolls to the task the agent is working on — or, with none running, the next pending one — when it opens and each time the agent moves on, instead of leaving it out of sight below the first few rows.
- Branch from Here now appears when you right-click the text of an agent's reply, not only its margin.
- A plan the agent revises with an edit, rather than writing it afresh, now comes back as a new card showing the revised plan, ready to approve; a card from a turn that writes a plan and then edits it shows the plan as edited.
- Markdown in replies renders as intended: formatting in table cells and headings (bold in a cell is bold again), escaped pipes, `####`–`######` headings, quotes with any spacing and lists or headings inside them, nested and wrapped bullets, task-list checkboxes, strikethrough and rules, italics, bare URLs, images, code fences under list items, backslash escapes, and links or code inside bold and italic.
- The chat and transcript mode follow a streaming reply only while you are at the bottom, transcript mode opens on the newest message and keeps your selection, and long chats redraw faster.
- Tool rows tell the truth: a refused or failed call shows a red cross with its error, a shell row shows the command as run, a delegated call is drawn as delegation, paths are not cut, a diff ends in an ellipsis only when it was cut, and the activity ticker names what a call touched.
- An agent's question stays in the chat marked Answered with your reply below it (also after a relaunch), is saved the moment it appears, renders its formatting, and answering clears it from the inbox; Reply answers the question you are looking at.
- The chat an agent opens on at launch shows its history — leaving it or sending in it used to write an empty transcript over it — and a chat over 500 messages keeps its oldest ones on disk.
- A chat you leave before its generated title arrives now gets that title instead of keeping its cut-off first message in the Sessions list; a rename in the meantime still wins.
- Filter text left in the Sessions list no longer hides an agent's last chat once the filter field goes away: a list without the field shows every chat.
- The Sessions list highlights the chat you have open and moves a chat you send in to the top; the Agent Tasks panel resets with the chat, shows a full description on hover or click, and refuses a status it does not know.
- Agents are named as you named them everywhere: replies, notifications, "Forwarded from", the Activity feed, Traces, the Memory tab, the bell and Waiting on you.
- Errors and notices can be selected and copied, the reply button says "Copy reply", images are copied and saved in their real format, a failed Save As says why, and preview screenshots are named after the page and time.
- MCP access cards: a token you type is no longer kept in the chat history, "Authorized" appears only once the server is saved, and a card from an ended turn can no longer answer a newer request.
- A message sent with files attached is followed by a line naming them ("Attached: shot.png, notes.txt"), kept with the chat, so scrolling back shows what the agent was given.
- Transcript mode now includes the plan a Plan-mode agent wrote, with what you chose once you answer it, and the question an agent asked you, in the order they came in the chat.
- The model and permission-mode chips under a chat's header use the names the rest of the app uses ("Opus", "Accept Edits", "Plan (read-only)") instead of the stored ids.
- A reply cut off by a dropped connection no longer ends the chat on a bare "Reconnecting…" line: once the agent is back, a line kept with the chat says it reconnected and that your last message needs sending again.
- A chat you leave while on a conversation branch reopens as you left it — on the same branch, with every branch in the branch bar, after switching chats, starting a new one or relaunching — and `/branch main` brings back the main line; its main-line messages used to be lost.
- Clicking the branch you are already on in the branch bar, or `/branch switch` to it, no longer throws away every message said on it since you arrived.
- `/branch list` starts with main, marks the line you are on "(you are here)" and gives its message count as it stands now, instead of the count from when you arrived on it.
- Clicking main or a branch in the branch bar now says, like `/branch main` and `/branch switch`, that only the transcript changed and the agent still remembers the earlier conversation (`/clear` starts it fresh).
- Renaming a conversation branch to main, in any letter case, is refused with a line saying main is the conversation's main line, instead of leaving two main buttons in the branch bar.
- Branches can no longer be switched while the agent is still replying — the branch bar's line buttons wait for the turn, and a switch (or deleting the branch you are on) says to wait for the reply or stop the turn — so a reply can no longer overwrite the last message of another line.
- With many conversation branches, the branch bar scrolls sideways instead of squeezing their names into ellipses, and keeps the branch you are on (or main) in view.

#### Backlog and items
- Bad input is refused out loud: a title with `" | "`, a blank or taken epic name, an epic description line that would split the epic; a refused edit shows a banner instead of replacing the list; removing an item or an epic asks first; a new item never reuses a removed item's id.
- An item's page keeps up with a run while open and renders its groomed markdown; Apply on a grooming no longer reports success over nothing, Set Status on a blocked item sticks, and collapsed epics stay collapsed per project.
- The AI backlog bar has a Stop button, shows the assistant's real error, says how many items an epic removal takes, and names the proposed changes that did not land.
- A grooming refusal about a `verify:` executable says where it actually looked.
- A `verify:` that `cd`s into a subdirectory and then runs a script like `./scripts/run-core-tests.sh` is checked from that subdirectory, so an item whose script only exists at the repo root is refused at grooming, with a note saying where the script is and how to re-root the command, instead of being filed as ready and failing when it runs.
- Changing one item no longer rewrites every other line of BACKLOG.md: untouched items are written back exactly as they were, and an item with no `verify:` of its own keeps following `verify_default` instead of having it copied onto its line.
- An item line with no `verify:` no longer picks up the backlog's `verify_default`, so it has no command until one is written for it; the `verify_default:` line itself stays in BACKLOG.md as written.
- An item whose line in BACKLOG.md could not be updated — the new line would read back as a different item, so the old one was kept and its status never changed — now says so with an error in the inbox naming the item, once.

#### Autopilot, merges and branches
- A QA run's storyboard and screenshots are kept under `~/.kiteloop/storyboards/` after the run ends, and the note on the item points at that copy instead of a path that was deleted with the run.
- A `flow:qa` run's worker and QA agent are handed the specifier's acceptance scenarios and QA procedure; they used to receive an empty placeholder when the specifier answered in prose.
- The Autopilot header names the worker and reviewer in one button that opens Autopilot settings, instead of two pickers that crowded the run status out of a narrow window; the pickers are on the settings page.
- The Autopilot's right column is one full-height transcript pane with Worker and Reviewer tabs instead of two stacked panes, one of them always the idle agent: it shows whichever agent's stage is running and switches as the run moves on, a tab you pick holds for the rest of that run, and a tab with output you have not seen carries a dot.
- A `flow:qa` run whose QA stage answers without a verdict stops as blocked, with a note saying so, instead of passing on the earlier checks' result and going on to be merged.
- A `flow:qa` run's QA stage fails when the UI flow fails, whatever its screenshots show, and the storyboard ends on the failing step marked FAILED, with the assertion that failed; a red flow used to leave only the steps that passed, and QA passed it.
- A QA run no longer asks for access to your Documents folder for the QA copy it builds: the copy is built outside ~/Documents and does not look for agent packages in the source checkout, so an unattended run has no prompt to wait on.
- The QA smoke check fails, saying what to fix, when a macOS privacy dialog is over the QA copy's window or its start screen lists your own recent projects; it used to pass over both.
- A `flow:qa` run moves on from its clean and harden stages when their commands finish, instead of sitting on the clean stage until the stall timeout ended the run.
- A worker that runs out of turns ends saying so ("worker cut short"), not as a verify failure.
- Nothing a run wrote is lost: a cancelled run keeps its branch, a branch with unmerged commits is never deleted (its tip is kept under `refs/kiteloop/backup/`), landed branches are removed — including at project open — and emptiness is judged against the configured base branch.
- A finished run is no longer thrown away over a check its verify forgot to name: the check the verify map asks for is run on the run's branch — also once the run's worktree is gone, which is where every finished run's check used to block unrun — and only a check that fails or times out blocks.
- The merge gate stops calling a reproducible gate failure flaky, checks the base's health once as a warning, records the commit a merge became in the item's Notes, and judges "nothing to merge" against the base.
- A refused merge is not shown as waiting on you (`queue.refusedAtGate` on `GET /v1/projects`); half-set autonomy switches are warned about in the Autonomy section and as `autonomyMismatch`; run records carry `merged`.
- The arming popover says how many Ready items can start, or how to set a project up; the Autopilot panel's ticks follow the autopilot's selection; its worker and reviewer panes keep your scroll position.
- The worker is told to make no change beyond the item, and two blocked runs with the same reason are named as a defect in the item.
- Signal-drafted items carry the project's own merge-verify, and a function under the project's complexity ceiling is no longer a hotspot.
- In a project whose verify map has a rule matching every path, drafted items no longer carry a copy of the project's whole verify chain: signal drafts have no `verify:` and drafts are not widened with the map's rules, since the merge gate runs them on any diff.
- Dismiss and Dismiss All on Interrupted Runs ask first and report checkpoints they could not delete.
- Task Insights shows rework per size and epic, leaves refused starts out of Estimate vs actual, and finds a project opened with a trailing slash.
- A run that wrote into the project's checkout instead of its worktree is blocked again: its own writes are told apart from anyone else's edits, which are only noted.
- The refute round is gone: a rejected run goes straight back to the worker, `refuteRoundEnabled` is no longer reported by `GET /v1/autopilot`, and a `PUT` or a config file that still names it is accepted and ignored.
- Worktree isolation is no longer a setting: a project that is a git repository always runs its items in a worktree, even if its config turned isolation off; `useWorktree` is no longer reported by `GET /v1/autopilot`, and a `PUT` or a config file that still names it is accepted and ignored.
- Protected paths are no longer a setting: a run is never stopped for changing one, `protectedPaths` is no longer reported by `GET /v1/autopilot`, and a `PUT` or a config file that still names it is accepted and ignored.
- The settings file no longer keeps the queue-refill loop's retired `coordinatorRefillMode` and `coordinatorRefillDailyBudgetUSD`: a grooming budget stored there becomes the daily budget when none is set, and the next save drops both keys.
- The fleet board says "paused by hand" only for a project parked with its paused switch; a project whose autopilot run is paused — by its spend cap, for one — reads "run paused", and its tooltip points at the Autopilot tab for the reason and Resume.

#### Control API
- The control API now turns on while the phone pairing forwarder is running; before, the forwarder holding the same port on the Mac's network addresses kept it from ever listening.
- When the control API is not listening, Settings → Control API says why and names the process holding its port, and the inbox notice names that process too.
- When the control API stops trying to listen because another process holds its port, the inbox now says so, naming the port and the failure, and Settings → Control API has a Retry button beside "Not currently listening" — no more quitting and reopening the app to get it back.
- On the phone, the queue offers Release on a retired ready item, where it lets autopilot start the item again, and no longer on a blocked item, where it changed nothing.
- On the phone, the gate screen says the item has no branch only when the Mac says so; a diff that failed to load says it could not be loaded and why, and a What and Validation that failed to load say so instead of going missing.
- On the phone, an open chat whose transcript or agent list could not be refreshed says so with the reason and stops showing its Working… spinner until a refresh succeeds, and an item page whose detail failed to load says why instead of showing only its header.
- On the phone, an approval the Mac refuses keeps the gate screen open with the Mac's reason, an approval that skipped the merge says why, and a chat message that failed to send says why beside the restored draft.
- A read that finds an inconsistent run claim clears it; `GET /v1/backlog` caches the stranded-work sweep; promoting to `ready` asserts the Definition-of-Ready (`force: true` overrides); demoting to `draft` is noted; a refused `POST /v1/autopilot/reset` names `POST /v1/runs/{runId}/cancel`; unparseable headers get `400`.

#### Menu bar, notifications and windows
- Check for Updates… says what actually happened when it finds no release: GitHub couldn't be reached, no release has been published yet, GitHub is limiting requests, or its answer couldn't be read — instead of calling every one of them "Couldn't reach GitHub".
- The sidebar's Planner, Fleet, Waiting on you and Daily budget are one compact block of four one-line rows instead of four boxed cards, leaving room for more sessions; each row opens what its card did, keeps its warning colour, and shows its full status on hover.
- The menu bar has Open Kiteloop, its rows work with the main window closed, and agent states read in plain words.
- Clicking a banner opens what it names; the finished banner names the project and the reply's first line; switching away banners every unannounced gate and question.
- The bell's badge and list update live, a long notice expands, a question opens the asking agent's chat, and a resolved notice is kept for a week after it was resolved.
- Reopening the main window adopts running projects instead of starting them twice; closing a tab mid-run asks first; a project whose folder is gone is refused instead of recreated empty; the hover cursor no longer sticks; the Inspector's preview no longer goes blank.
- An agent with a plan waiting for approval reads as waiting on you in the sidebar, the menu bar and `GET /v1/agents`, and has a row in the Waiting on you drawer until the plan is answered or replaced.
- An agent that crashes and cannot be reconnected while you are in another app now raises a banner naming the agent, the project and why the restart failed; clicking it opens that chat.
- Only one of the Coordinator, Fleet and Waiting on you drawers is open at a time: opening one closes the other, so the Autopilot beside it is no longer squeezed into a strip.

#### Agents and settings
- Choosing a knowledge folder in the setup wizard no longer deletes the installed one first: the new copy is put in place before the old one goes, a failed copy leaves the old one exactly as it was, and the wizard says why it failed.
- Editing an agent template in Settings › Team offers every model the app offers and opens on the template's own model — Fable, a local model, Copilot or a Bedrock profile's family — instead of a three-way choice that a Save then wrote over; a new template starts on the app's default model.
- Project Settings → MCP Servers says when .claude/settings.json can't be read instead of showing an empty list, and Save refuses to write over that file rather than replacing it — permissions, hooks and everything else in it included.
- A Custom Agent in the New Agent sheet, and an agent hired through the control API without a model, now start on the project's model, else Settings → Default Model, instead of always on Opus.
- Settings' Default Reasoning Effort and Project Settings' Effort and per-turn budget now reach every agent the project starts, including one hired from New Agent or `POST /agents` while the project is open — the project's effort if set, else the app's — instead of only agents started by reopening the project, and the app's effort reaching none.
- Renaming an agent in Edit Agent now carries the new name into every teammate's Cross-Agent Access, so a teammate allowed to message it still can instead of being refused with "access denied".
- An agent's Cross-Agent Access list and Operator Tools setting from Edit Agent now survive a relaunch instead of reverting to an empty list and Operator Tools off.
- An agent's cross-agent access list now reads `*` and `all` alike as every agent, for both messaging other agents and recalling their knowledge; before, `*` opened only messaging and `all` only recall.
- Settings no longer has a Specialists page, and @-mention completion and routing in the chat offer only your agents — the cross-project specialist registry they read was never populated.
- New Agent and Edit Agent refuse a blank or duplicate name, a catalog agent keeps its package's prompt, tools and runtime, saving Edit Agent restarts the agent, and a failed restart is named.
- Agents added to `team.json` appear without switching chats, Ollama and Copilot agents keep their runtime and MCP list across restarts and catalog edits, and model names read as the rest of the app shows them, including a model the list does not have.
- Avatars: Upload Image… works in both sheets and never keeps an old image under a taken name, untouched Settings editors store "Auto (by role)", and the info popover draws the sidebar's avatar. Remove Agent asks first.
- Settings pages show errors in full, never report a key saved that was not, and keep a per-turn budget on a typo; Project Settings asks before discarding unsaved edits; the Git page handles detached HEAD, `|` in subjects and odd paths; the Hooks page keeps config it cannot read or does not model.
- MCP servers in Settings can be edited, are written only on Save, reach every open project's next session and actually reach agents; empty environment values and quoted arguments survive; invalid rows are refused; an unreadable agent MCP file is reported.
- Specialists: removing one asks first, Discover says what it found, edits to a discovered one are kept, Add names a taken handle, and an @mention of a moved one says so. Deleting a task agent or a plugin asks first, and the skills badge counts only real skills.
- Ollama and Copilot availability is re-checked when menus open, a Paused switch that cannot be saved goes back to what is on disk, and the Missing Repos popover updates when a clone lands and says why one failed.
- Project Settings' permission mode, now labelled "Default mode for new agents", is the mode agents added to that project start in — from New Agent, quick add, `POST /v1/agents` without a mode, and team agents that name none — instead of being saved and never read.
- Saving an MCP key in an agent's Configure… sheet now restarts the agent when it is idle, so the key takes effect right away; an agent mid-turn is left alone and the sheet says the change applies at its next start.
- An agent that asks you a question shows as waiting on you — the sidebar badge, the menu bar and `GET /v1/agents` — until it is answered, cleared or its session stops, instead of never.
- Installing a plugin from Settings › Plugins works: it runs `claude plugin install`, and the field asks for a plugin as `name@marketplace`, instead of failing every time with an unknown-option error.
- Project Settings › MCP Servers can be saved while it lists a remote (url) server, which it now shows as its type and url, and Save keeps a server's keys the page does not edit (such as `cwd` or `headers`) and an env holding a number or a boolean instead of dropping them.
- Settings › General's optional vault folder has a Clear button that turns the vault back off, and a vault folder that was moved or deleted reads "folder not found" instead of showing as set.
- An agent you stop from the sidebar now reads "Stopped · <model>" under its name, and its menu offers Start Agent to bring it back instead of offering Stop Agent again; a start that fails is named in an alert.

#### Hooks
- Project Settings no longer has a Kiteloop Hooks page and Kiteloop's own hooks no longer run, so a message reaches the agent exactly as typed; Claude Code's hooks, on the Hooks page, are unchanged.
- The chat header no longer shows a count of Kiteloop hooks, and a project's `config.json` drops the old Kiteloop hook rules the next time it is saved; a file still holding them loads as before.
- Allow on fail allows, a `*` works anywhere in a pattern, Forward to Agent delivers, Notify User shows your title even with Kiteloop in front, and a hook that did not run says so in the chat.
- Source and Target fields narrow Message Forwarded and Agent Triggered hooks, `TOOL_OUTPUT` and `STOP_REASON` reach hooks, the list's order is the order hooks run, and a deny with nothing on stderr gives stdout or the exit code as its reason.

#### Memory
- An agent's Memory page lists only its own proposals, Pending names each agent once with a count, the badge updates at once, a write error belongs to its page, an unsaved Project Context edit is kept, and a proposal says when it was filed.
- `save_knowledge` in the shape the tool describes (`content` and a known `category`) saves.
- A memory proposal you edited and saved stays open with your text when the save is refused, so you can fix it and try again, and Save is disabled while the text is blank.
- An unsaved Project Context or fleet-knowledge edit in the Memory tab can be thrown away: a Revert button beside Save drops the edit and shows the file as it is on disk.
- Saving Project Context or fleet knowledge in the Memory tab no longer silently overwrites what was written to the file since you started editing — such as lessons runs learned meanwhile: the save refuses and says the file changed, Revert shows the new text, and Save again replaces it.
- A fact correction left open in the Memory tab stays with the agent it was opened under: another agent's fact with the same name no longer shows your text, Save writes to the right agent from any page, and going back shows the editor with your text still in it.
- A fact that a later fact replaced no longer lingers where recall still finds it: every topic in the Memory tab's Topics list has an archive button, and a topic with no line in the index is marked "not in index".

#### Console, diagnostics and web preview
- The Web Preview console now shows console.count, countReset, time/timeLog/timeEnd and console.trace the way a browser does — "label: 3", "label: 12.345 ms", a warning for a timer that was never started, and a trace's call stack — in the pane and in what the agent reads.
- Traces updates while open, totals each turn's own cost, reads durations in minutes, dates earlier turns, shows the whole session id, explains an empty list and clears a session its filter hides.
- Activity rows wrap up to four lines, Clear holds, earlier days show their date; Diagnostics explains an empty list, disables Copy with nothing shown and keeps your scroll position.
- The web preview says why a page failed, loads `localhost` over http and `~/` as your home folder, opens new-window links in the pane, and Inspect head says when it could not read the page.
- A page's alert, confirm and prompt in the web preview show a sheet you answer, instead of being swallowed or answered Cancel, and a file-upload button opens an open panel whose files reach the page.
- The web preview's address bar and Back button follow a single-page app's in-page route changes (`pushState` or a `#fragment`), instead of staying on the last full page load.
- The web preview comes back at the zoom you last set with its zoom buttons after a relaunch, instead of at 100%.
- The web preview's “Not found” goes away as soon as you edit the search or a new page starts loading, instead of staying up over text it no longer describes.
- Reload in the web preview after a page failed to load retries the address that failed, and the address bar keeps showing it, instead of reloading the page before it or doing nothing.
- The web preview's Find puts the cursor in the “Find on page” field as soon as it opens, and Shift-Return in it goes back a match, instead of making you click the field and the up arrow.
- A failed console.assert on the page now shows in the web preview's Console, and in what an agent reads through web_console, as an error reading “Assertion failed:” and its message, and adds to the error count.
- An uncaught error in the web preview's Console, and what an agent reads through web_console, now ends with the script, line and column that threw it, and an Error passed to console.error or any other level shows its stack under the message.
- The web preview's Console opens at its newest line, and while it is open follows new lines the page logs if you are at the bottom, staying put if you scrolled up to read; changing the level picker lands on the newest line at that level.
- The web preview's Console keeps following new lines for a reader at the bottom after the page has logged more than 200, instead of sitting still while the newest lines arrive below the fold.
- The web preview's Console, and what an agent reads through web_console, show a logged element as its tag and attributes (`<div id="app"></div>`), a Map as `Map(1) {"a" => 1}` and a Set as `Set(2) {1, 2}`, instead of `{}`.
- What an agent reads through web_console now starts with how many earlier lines were not kept once the page has logged more than 200, as the web preview's Console already does, so a missing error is not taken for one the page never threw.
- Durations past an hour read in hours and days, and counts of one read in the singular.
- Once the Diagnostics Logs tab holds its full 2,000 lines, its footer says it shows only the latest lines and that older ones are in the log file Reveal opens, instead of reading as the whole log.

#### Files and robustness
- A non-UTF-8 byte or a cut-off character no longer makes a file or command output read as empty — backlogs, chat history, memory, knowledge, `.gitignore`, logs and the rest keep everything around it.
- Creating a shared team backlog no longer freezes the window, the reviewer counts new files correctly, the phone's gate review says when its diff was cut, and the branch chip clears when the project leaves a branch.

## 0.4.8 — 2026-09-12

### Added
- A backlog item can be promoted without leaving its epic. Writing `lane:now` on an item's line runs it ahead of everything not marked, across every epic; within a lane the file still decides the order, epics top to bottom and items within them. `later` is the default and is never written, so a backlog nobody has promoted anything in runs exactly as it did. A project that spelled this as an epic called `Now` has those items marked once, in place, the next time the backlog is loaded — the epic is now only the map of which area the work is about.
- The merge gate's deadline now measures itself on every project, not just the ones that merge. A project running under `propose` parks each passed run at the approval gate and so never reaches the merge gate — but it runs the item's own `verify:` before every review, held to that same clock, and that reading now counts. Five runs of it derive the deadline exactly as five merge verifies would, so a cold build that takes longer than fifteen minutes stops being killed by the default it could never grow out of; a run that measured both verifies contributes the longer of the two.
- A test that simply fails now gets an item drafted for it. When a project's queue runs dry, the refill pass reads the newest run recorded in `docs/suite-status.md` alongside the flake ledger and the hotspot report, and files a bug for each test that row names as failing — or as never having come back, on a run ended at its time limit — quoting when the run was, which commit it was taken at and what its tally said. Until now only a test that flipped between passing and failing at one commit was ever drafted, so a test failing run after run was left for a person to notice.
- Kiteloop now runs an item's own `verify:` itself, on the run's tree, before the reviewer ever reads the diff — and a run whose verify comes back non-zero ends there instead of going on to review and the approval gate. What it answered is written down either way: the exit status, the command as it was run, the directory it ran in and the last 40 lines of its output land in the item's Notes and on the run's metric record, and `GET /v1/runs/{id}/result` reports the status, the command and the output tail. Until now the only account of the one thing the gate stands on was the worker's own.
- The two run timeouts set themselves. The stall timeout and the merge-verify timeout have left the autopilot page: a project's worker deadline is now its own p95 worker-phase duration plus half again (at least 15 minutes, at most 60) and its merge gate's deadline the same over its own gate phase (at least 10 minutes), each read off that project's own runs that measured the phase in question — so a project whose runs stop at the approval gate, measuring no gate phase, still measures its worker deadline. A clock with fewer than five runs behind it keeps today's 20 or 15. `GET /v1/autopilot` reports both with a `runTimeoutSource` saying, per clock, whether it was measured, and a `PUT` naming either is answered with the derived value instead of an error. Worktree isolation now starts on wherever the project root is a git repository.
- Kiteloop can tell you when a newer version exists. **Check for Updates…** in the app menu compares this copy against the latest release published on GitHub and opens a window with a download link; the same check runs quietly at launch, at most once a day, and says nothing when you are already up to date or cannot reach GitHub. Nothing is downloaded or installed for you.
- The fleet can run several projects at once. A **Runs at once** stepper in the Fleet drawer (and `maxConcurrentRuns` on the scheduling API) lets the scheduler start another project's run while one is still in flight; each project still runs one item at a time, and the default stays one.
- The approval gate is a visible step. An item at the gate says whether the merge gate is verifying the merged tree, waiting on you, or refused with the reason, on the Mac's item page, in the control API and on the phone; a run's own gate shows as the merge step on the phase rail for as long as it verifies; and an item's run list reads a run still going as in progress instead of one that never recorded an ending, and no longer shows the same run twice.
- A project that never set a merge-verify command or a worktree setup command gets the ones its repository implies: the verify map's widest rule gates merges, and a lockfile or a generator's spec means an install or a generate in that directory before anything runs in a fresh worktree. The autopilot API reports both effective commands with where each came from; a value a person set still wins.
- A project's autopilot page is down to eight controls: an autonomy dial (off / propose / land) replaces the three separate switches for unattended work, auto-approval and auto-merge; one budget replaces the per-item cap, session cap, cost margin and daily budget (the per-item ceiling is now the ledger's own measured cost for the item's size, once there's enough history for one); worker, reviewer, priority, the verify map file, the merge-verify command and the worktree setup command round out the eight. Worktree isolation, the quality judge, review rounds, the refute round, the merge-verify command, the worktree setup command, the base branch and protected paths stay configurable through `PUT /v1/autopilot` or a hand-edited `.kiteloop/autopilot-config.json`, just off the page. The three retired switches (`autonomousWorkEnabled`, `approveReviewPassedRuns`, `autoMergeOnApproval`) still work individually on the control API for one release, deprecated in favour of the dial.
- Rejecting a run at the approval gate now reaches further than the item's Notes: the reason opens the next run's worker and reviewer prompt verbatim under a "Rejected last time" heading, naming a ref (`refs/kiteloop/rejected/<item>`) that keeps the rejected run's branch tip even after the next pickup deletes the branch itself, and the reviewer is told that leaving the named defect in place is blocking regardless of Validation. The recorded rejection clears once a run of the item passes review.
- The phone companion's Fleet tab carries the fleet's **Runs at once** stepper (1…8) beside the daily pass ceiling, so how many projects may run together can be read and raised from the phone; while runs are in flight it names the projects underneath.
- The phone companion shows a spinner on the Now tab's Fleet header and on every project with a run up, with the item and the step it is on, and re-reads the dashboard every 15 seconds while the tab is open; the Runs tab spins beside a running run.
- The phone companion is two tabs: one per open project (state, one lever, what needs you, the queue and the agents) and the fleet; the Runs and Levers tabs are gone. An agent's conversation reads as prose, each tool call one quiet line, with a spinner while the agent thinks.
- The phone companion's Projects tab opens with a sideways-scrolling row of project chips, the selected one filled and a spinner beside every project with a run up; tapping a chip switches the screen below.
- A long press picks a project chip up on the phone and a drop reorders it; the order is the Mac's own tab order, kept on the Mac through a new `POST /v1/projects/reorder`, and `GET /v1/projects` now lists projects in that order rather than alphabetically.
- The phone companion says whether to wait or to pull: a line under the project row reads "Updated 12s ago · refreshes every 10s", "Refreshing…", or names what failed — "Can't reach the Mac at …", a rejected token, an older Mac — with what to do and a Try now button. The project's state is a card with a coloured pill, the item in flight, the run's phase rail, session spend against its cap and the one lever as a single prominent button; agents and the fleet header come alive while working.
- The quality judge's verdict now carries a scope-deviation field, and a run whose judge names one is blocked before it can merge or auto-approve — the same as a reviewer's own blocking finding — instead of merging anyway with the deviation left as a rationale nobody acted on; the item's Notes name the judge as the source. The reviewer prompt itself now also reads the item's How and Out of Scope and answers, before checking a single Validation line, whether the diff does what How says by the means How names.

### Fixes
- A project that ignores only parts of `.kiteloop/` no longer ends up with a permanently dirty working tree. The shared backlog branch's private checkout (`.kiteloop/backlog-tree/`) is now forced into such a project's `.gitignore` alongside the worktrees and web scratch directories, so it stops showing as untracked — which had been enough to make every auto-merge refuse with "working tree not clean" and park each finished run at the approval gate.
- One bad byte no longer empties your inbox. A notifications log cut mid-character by an unclean shutdown used to read back as completely empty — every notice in it, a pending approval included, vanished from the app, and the next resolve or dismiss deleted them from disk for good. Each line is read on its own now, so the notices around the damaged line all load and the damaged line itself is kept.
- One bad byte no longer resets the coordinator's grooming. A refill or pass ledger cut mid-character by an unclean shutdown used to read back as empty, so the next pass re-proposed items it had already filed and the day's grooming ceiling started again from zero. Each line is read on its own now, so every other entry still loads and the damaged pass-ledger line is kept.
- One bad byte no longer empties the activity log. An event log cut mid-character by an unclean shutdown used to load no events at all on every launch — nothing to backfill, no missed events replayed to agents — and old events stopped being dropped, so the file grew without bound. Each line is read on its own now: the events around the damaged line load, retention runs again, and the damaged line is kept as it was.
- A red core-package test run says which tests were red. `./scripts/run-core-tests.sh` now names the failing cases, suite-qualified, on the same FAIL line that carries the exit status — and says plainly when a run failed without naming any test at all, such as a compile error — instead of leaving that to be read out of forty tail lines that need not reach back to the first failure.
- An isolated run's reviewer is now told, in its own prompt, the path the item's branch is already checked out at, and that the diff and the verify commands are read there — so a reviewer that reaches for a shell no longer checks the same branch out somewhere of its own and judges a tree the work never happened in.
- One corrupt byte in a ledger no longer wipes the whole ledger. A JSONL ledger cut mid-character by an unclean shutdown — the retry counts behind gate retries, the rescue history — used to read back as completely empty, so every record written before the damaged line was lost; each line is now read on its own and only the damaged one is skipped.
- A gate rejection you left on an item, and the finding overrides a project has accumulated, survive an unclean shutdown that cut the ledger's last line mid-character. Both files used to read back as completely empty in that case, so a standing rejection went unread by the next run and the distiller saw no overrides to learn from; each line is now read on its own and only the damaged one is skipped.
- The measurements Kiteloop takes of its own runs survive an unclean shutdown. The task metrics, estimates, approvals and merges ledgers used to read back as completely empty when a kill cut their last line part-way through a character, so cost predictions had no history, retry counts reset and the first-pass and escaped-defect rates were computed over nothing — with no sign anything had been lost. Each line is now read on its own, every record before the damaged one is kept, and the damaged line is counted as the one line that went.
- The coordinator's record of autonomous starts and its blocked-item triage counts survive a line cut mid-character. The start log used to read back empty and its next compaction erased every start on disk, and triage forgot how often it had retried each blocked item, so it could send one back to ready that it had already given up on. Each line is now read on its own; the damaged start-log line is kept, and the damaged triage line is skipped.
- The escaped defects a refill pass files no longer depend on the approvals ledger being byte-perfect. A ledger whose last line was cut mid-character by an unclean shutdown used to fail the whole read, so the pass reported the ledger unreadable and drafted nothing for any item that had come back after approval; every complete line before the damaged one is now read and files what it carries. A project that has never approved anything, and so has no ledger at all, is no longer announced as a read failure.
- A worktree nobody's run made can no longer keep an item from starting. When a run's setup finds the item's branch checked out somewhere other than the project's own `.kiteloop/worktrees` — a review checkout left behind, a directory a merge forgot — Kiteloop unregisters that checkout and deletes the branch, so the run goes ahead, and names the path it took away in the item's Notes. A checkout git will not release, the project's own among them, still refuses the start in git's own words.
- `./scripts/run-unit-suite.sh --flakes` now says how much of `docs/suite-status.md` it actually read. A line under the ledger header counts the rows it passed over and why — a dirty tree, no verdict to read, a red row naming no test — against the rows the record holds, so its `none` can no longer be mistaken for "no test flipped" when the truth is that no row was readable at all.

- An item parked at the approval gate for longer than the stale window is one row in the "Waiting on you" drawer, not two. It shows as the approval it is — the thing you can actually clear — and the footer counts it once.
- Kiteloop no longer quits when a session's CLI goes away mid-write. A message, a tool result or an interrupt sent to a session whose Claude Code process has just exited — or that is being stopped as the send goes out — used to abort the whole app, taking every other session down with it; the write now reports that it did not land, says so in the log against that session, and the app stays up.

- The "Waiting on you" drawer's stale flags always show the newest reading of the backlog. Every write to the backlog reloads it, and during a run that is every status change and every appended note, so two staleness sweeps were routinely reading git at once — whichever finished last won, which could be the older one, and the drawer then flagged items against a backlog that had already moved. A superseded sweep now stops reading git and drops its answer.

- Running the core test suite no longer fills the day's log in your Kiteloop home. Those tests open no project, so the lines they logged — thousands of ring-buffer probes, and the fixture errors from stores that were made to fail on purpose — were appended to the same file the running app writes to, tens of thousands of lines per run, and reading it to debug Kiteloop became impossible. A test now logs under a temporary directory of its own.
- A run that has ended says when it ended without waiting for a restart. `GET /v1/runs/{id}/result`, `GET /v1/runs/{id}` and `GET /v1/runs` all report `endedAt` — the wall clock the run closed at, read off the run's own record, so the reading before a restart and the one after it are the same instant. The listing never reported it at all. A run still working, and one a restart ended, still report none.
- The app no longer freezes when a run's judge releases its CLI runtime mid-read. The runtime's stdout and tool-request readers hold one reference per chunk instead of one per statement, so its teardown can no longer run inside a locked region on the reader's own thread and wait on the lock that thread already holds.
- Two suite runs of one commit are one commit to the suite readouts again. `docs/suite-status.md` records the commit as a git abbreviation whose width moves with the repository, so one commit could be written down two ways, and `--flakes`, `--last`'s earlier-measurements line and the flaky line beside it each read the two spellings as two commits — a test that decided both ways across them showed up as nothing, as a single measurement, or as a test somebody had fixed. The three now group rows by the commit a cell names however wide it is, and a new row asks git for a fixed width so the record stops collecting new ones.

- `GET /v1/runs` no longer grows without bound on an app left running for weeks. It still lists every run in flight whatever `limit` says, but it now keeps only the 50 most recently finished runs in memory alongside them; older finished work is listed from its durable record instead, marked `historical`, and still answers `GET /v1/runs/{id}/result` with the outcome, duration and cost it always did.
- A ledger of measurements Kiteloop could not write now says so where you would see it. When an append to the task metrics, estimates, approvals or merges ledger fails, a row lands in the inbox naming the file and what went wrong — one row for the disk, not one per failed write — instead of only a line in Diagnostics; until now a `~/.kiteloop` that had stopped being writable just left the numbers quietly not moving. A record the encoder refuses outright is now counted as a lost write too, rather than disappearing with nothing to show for it.
- The safeguard that stops a test run from taking a running Kiteloop down no longer fires when Kiteloop is closed. It asked the process list for the app using a pattern that also described the shell asking the question, so it found itself and answered "Kiteloop is running" on a quiet machine — refusing every test run with nothing to protect. It now sees only real Kiteloop processes, and still refuses while one is up.
- One unreadable line in the run history no longer costs the whole history. A crash part-way through recording a run used to leave bytes that stopped the file being read at all, so every finished run answered 404 and a night's work read as an install that had never run anything; each line is now read on its own, so a broken one costs itself and the runs around it still answer. And a history file the app genuinely cannot open now says so, with a row in your inbox naming the file, instead of quietly reporting no runs.
- A run's result now says whether its `verify:` was killed by the deadline or answered, and which tree it ran in. `GET /v1/runs/{id}/result` carries `verifyTimedOut` and `verifyDirectory` beside the exit status, live and after a restart, so a blocked run that ran out of clock can be told from one whose command could never start — both used to report the same exit status of -1 and nothing else.

- A rescue run's reviewer constraint names the conflicted paths in the acceptance criteria themselves, not only in the description above them.
- An unattended run is written down once. A run the autonomous scheduler started and the app then noticed starting used to leave two entries — `GET /v1/runs` listed one night's run twice, /health counted it twice, and both records were closed from the same result. There is now one record, and it carries the workflow execution the run turned out to be, so a finished night's run can be joined to its transcript and its cost.
- A start the pickup gates refused is no longer recorded with the previous run's ending. An item run once and then targeted again was, when the second start was refused, given the earlier attempt's outcome, duration, branch and pull request — counting one failure twice toward the breaker that stops a project, or clearing it on the strength of a run that had already finished. A refused start now reads as did-not-run everywhere, with the gate's own words for why.
- A run read back after a restart, or with its project closed, now still reports what the item's own `verify:` answered — the exit status, the command and the last lines of its output. Until now the verdict lived only in the running app, so `GET /v1/runs/{id}/result` answered a night's finished runs with no verify at all, which reads as a verdict never taken.
- A run history that has stopped reaching disk now says so in the inbox you already watch. When Kiteloop cannot write `~/.kiteloop/control-runs.jsonl` — a folder that has stopped being writable, a full disk — a row naming the file appears instead of the failure being discovered at the next launch, when runs that had merged answered 404.
- An item's run list no longer loses a run the pickup gates refused. A refusal was joined to the run that started seconds after it, so the refusal vanished from the list and the measured run showed the refusal's reason as its own; a refused start now keeps its own row, and a record with no execution id is read by the run whose start it is nearest and by only one run.
- `GET /v1/runs` now says how a run ended as soon as it has ended. A run that finished while the app was still up was listed as `finished` with no outcome, reason, duration or quality score until the app was restarted, so the morning after an unattended night the listing was a column of finished runs with nothing to read off it. A run now reads the same before and after a restart.
- A driver holding one run id can now find that run's transcript from the endpoint it is already polling. `GET /v1/runs/{id}/result` and `GET /v1/runs/{id}` report `executionId` — the workflow execution the run turned out to be, and what its transcript directory and its metric row are keyed by — while the run is in flight and the moment it finishes, not only after the app has been restarted. A run that never got an execution still leaves the field out entirely.
- A run's result and its saved record now carry the quality score, judge dimensions and verify verdict *that run* measured. An item that ran twice in one session — rejected, put back in the queue, run again — reported the second attempt's reading on the first run too, so anyone reading the earlier run saw a score and a verify taken on a tree that run never produced. A run with no reading of its own now says nothing rather than borrowing another's.
- A run is no longer mistaken for a stalled worker while Kiteloop is building it. The phase rail's **verify** step is now what a run is on for as long as the app runs the item's own `verify:` — a build that can take the whole of the verify deadline — so the fleet board, the Autopilot tab and the phone show it verifying with the worker behind it, and its clock no longer ages towards "stale" while the build is working.
- A run salvaged by its own `verify:` — one that ended early on the cost cap, a stall or the retry ceiling and was accepted because the verify still passes — now records that verify like every other: the exit status, the command, the directory and the output tail land in the item's Notes and on the run's record, whether the re-check salvaged the work or blocked the item. It also runs under the same deadline the pre-review verify does, so a project whose build outgrew fifteen minutes no longer has its work discarded by a command that was killed rather than answered.
- The OpenAPI document Kiteloop serves now describes the verify verdict on a run's result. `verifyExitStatus`, `verifyCommand` and `verifyOutputTail` were returned by `GET /v1/runs/{id}/result` but missing from the advertised schema, so a client generated from the spec silently dropped the one field saying whether the item's own `verify:` passed.
- The verify Kiteloop runs before the reviewer now builds into the project's own build directory rather than the DerivedData the launching Xcode shares, so a run on the live tree is judged on the tree it is sitting in and not on whatever the IDE last built. A verify that names its own build directory keeps it.
- Typing `/` on its own and sending it no longer crashes the app; a slash that names no command or skill goes to the agent as ordinary text.
- A pause now holds the project until you resume it. Pausing while an item is in flight still lets that item reach its gate, but the finishing run no longer lifts the hold with it, so the fleet does not start one more run you did not ask for; `GET /v1/autopilot` and `GET /v1/projects` report the project as paused between items as well as during one, and Stop still ends the hold along with the queue.
- Auto Mode and the per-project permission rules are gone. The Auto Mode toggle on the agent editor, the Auto-Approved Tools field and Auto Mode Threshold in project settings, and the `/permissions` and `/automode` chat commands configured a risk classifier that nothing consulted; an agent now carries just its permission mode and its allowed and denied tools, which is what Claude Code actually enforces. Existing project and agent files keep loading — the settings that no longer exist are simply ignored.
- An item page's "ledger and git disagree" list no longer claims a run was recorded as having produced no work when nobody measured it. A run that stalled, timed out, hit its cost cap or ended on a verdict nothing could read says nothing either way, so it raises no disagreement over a branch that carries commits; a run actually recorded as empty still does.
- With the fleet running several projects at once, the slot a finished run frees now starts the next project straight away instead of waiting out the check interval — a full fleet draining a slot no longer idles for up to five minutes with runnable work waiting.
- The Ollama line in Settings > Backend asks the local server once per refresh instead of twice, and that one request gives up after two seconds — an Ollama that accepts the connection and then goes quiet no longer leaves the status line hanging.
- Chat agents no longer show an Allow / Always Allow / Deny prompt. Nothing was routing a tool call to it, so the prompt could only ever appear stale: a tool is now simply allowed or refused by the agent's permission mode and its denied-tools list, which Claude Code enforces, and a refusal still shows in the conversation.
- A knowledge repository chosen in Settings > General takes effect straight away. Picking one now rescans for agent packages in the same session, so the agents under it are offered by the sheets that list them instead of only appearing after quitting and reopening Kiteloop.
- The Software Update window no longer sits on "Checking for updates…" forever. Opened from the Window menu, or restored when the app launches, it now starts a check itself and ends on an answer — a newer release, up to date, or that GitHub couldn't be reached.
- A project's priority is now just a paused switch. High and normal are gone — the fleet runs whichever project has been idle longest, which is the only ordering several projects at once actually need — and the fleet board and project card carry a Paused toggle in place of the priority picker (the autopilot page's Priority row is gone entirely). A project you had already paused stays paused. A scheduler start now says "idle 20m, 9 ready" rather than leading with a priority word.
- A merge that could not land is no longer re-verified for the wrong reason: the gate now re-runs its verify only when the base branch actually moved underneath it, and says which tip it moved from and to. A merge refused because the checkout was dirty, or because the base was checked out elsewhere, is refused once with git's own reason instead of paying for a second full merge-verify and then reporting a base that never moved.
- A run whose merge is queued behind another merge on the same project now says so — its own **Q** step on the phase rail (and `waitingForGate` on the control API) plus an event on the bus — instead of reading as a merge already verifying the merged tree.
- A hotspot the signal pass finds in a Python or TypeScript file is filed once and stays one item: its id is now built from the declared function's name — `def marathon`, `function activate` — the way a Swift one already was, instead of from the line it happened to sit on, so code shifting above the declaration no longer files the same function again.
- The repository's hotspot instrument no longer comes back empty on a Kiteloop launched from Finder or the Dock: both children the signal pass spawns now get the app's own search path, which reaches Homebrew, so a `report-hotspots.py` that used to fail its SwiftLint lookup and report nothing now contributes findings.
- A pickup the grounding check or Definition-of-Ready refuses for how an item is written now sends the item back to Draft with the refusal written to its Notes, instead of leaving it `ready` to be refused the same way again; it no longer counts against the retry ceiling, so a citation nobody has fixed yet cannot retire an item with no run ever having started. An item withheld only by an unmet `needs:` is untouched.
- A merge gate's scratch worktree no longer lives where the worktree sweep looks: once a merge lands in it the scratch has a clean tree and no branch of its own, which the sweep reads as an abandoned worktree and reaps — deleting it out from under a verify that's still running, so the gate reported a verify failure on paths that no longer existed. The scratch now lives in its own directory the sweep never walks, and a gate whose scratch is removed out from under it anyway reports that the worktree vanished rather than relaying the verify command's garbled failure.
- An item at the approval gate whose branch was rebased since a sibling's merge cached a conflict is no longer refused on a stale verdict: the approval now checks the branch's live tip against the one the cached verdict was computed for, and a gate refresh round recomputes the cache itself once it finishes rather than leaving it to the next merge into the base.
- The two guards against running the app-hosted test suite while Kiteloop is up now see the app from a shell Kiteloop itself spawned; a worker inside a run could run the suite past both.
- A worker whose turn ends on a launched background agent is no longer left to sit until the stall watchdog kills it: after a minute of quiet, and then every five minutes until the agent reports, it's given a nudge turn asking it to continue. A worker that never answers a nudge at all still stalls at the usual timeout.
- Stopping an agent, removing one, or quitting with sessions open pauses the window for half a second rather than a full one: tearing down a session's process tree gives its root process and everything it forked the same single grace period, instead of waiting one out for the roots and then another for their children. Everything it ended before is still ended.

## 0.4.7 — 2026-09-06

### Added
- The quality gates are cleat, vendored: `quality/` is cleat's template refreshed from its checkout, `quality.json` is in its schema, and the suite's preflight runs cleat's twenty-six suites and its one gate runner in place of the nine home-grown checks — the same ratchets (complexity, layering, hygiene, doc size, guard suites) plus doc-citations and reachability where the features-map check was, every debt baselined once with its provenance. `quality/bin/check-complexity.sh` and `quality/bin/check-features-map.py` keep answering under their old names, so the verify map, the chat tool's clean command and every ready item's `verify:` line run unchanged.
- Three more of cleat's gates judge the tree: escapes (a new force try, force cast, disabled lint or skipped test, keyed by site), duplication (a copied block in the lines a diff changed), and conventions, whose first rule is CLAUDE.md's "never block the main actor with synchronous I/O" caught at the site — each baselined once with its provenance.
- After a green suite row the runner writes one LCOV file from the run's coverage — the app's from the result bundle, the package's from its profile data — and cleat's changed-coverage gate then names the lines the diff changed that no test executed, beside CRAP.
- cleat's two hooks are in the agent's loop: a Stop hook runs the gates over the files an agent changed and hands a failure back as its next task, and a PreToolUse guard refuses a baseline write or an edit to the quality config, the gates or the hooks — policy changes are a person's, in a reviewed commit. Every firing is logged, and the runner's `--stats` reports firings, fail rate and refusals.
- An item can state its premise (`## Premise`); the worker checks it against the tree before building, and a run that refutes it with a measurement ends as an investigation — parked at the approval gate with the report, and scored by the quality judge on the measurement rather than on the diff it rightly did not produce.
- An unattended run's worker and reviewer now run with permission prompts bypassed — a prompt nobody is watching only ever timed out into a denial — and carry the critical command shapes (sudo, a force push, a recursive delete of root or home, mode 777, writes to credential paths) as deny rules the CLI enforces in every mode; the boundaries a run answers to are its worktree, the gate and a person, stated on the autonomy ladder and per project in `GET /v1/projects`. A chat agent still asks.
- A project can name the branch its runs fork from and merge into (Autopilot tab → Base branch, or `baseBranch` on `PUT /v1/autopilot`), so running on a branch no longer means switching the checkout or registering the project twice; the approval gate's merge and its freshness check land on the same base, a base checked out in another worktree refuses the merge naming it, and `GET /v1/projects` reports each project's effective base.
- A blocked item can be unblocked: `POST /v1/backlog/groom` lifts it to draft or ready, and its page has an Unblock button that sends it back to Draft; the reason it was blocked for is kept as a line in its Notes. Previously `blocked` could only be cleared by editing the backlog file by hand.
- Item worktrees share a project's build output: a project with a `Cargo.toml` or `package.json` exports one `CARGO_TARGET_DIR` / `npm_config_cache` under `.kiteloop/build/` into every verify and agent spawn, so a Rust or Node item no longer starts from a cold build in each worktree; a `buildEnvironment` map in `.kiteloop/config.json` adds or overrides exports, and `/health` and the Diagnostics window list them per project beside the verify tools.
- The app looks for a project's tools in one place — the login shell's PATH, the usual toolchain homes including `~/.cargo/bin`, plus `extraExecutablePaths` from Settings and from the project's `.kiteloop/config.json` — and the same list is what verify commands, agents and the grounding check run with. `GET /v1/health` and the Diagnostics window's Health tab list every tool the project's verify commands need and where each resolved, or the directories searched when one did not; a grounding refusal names them too.
- A branch that no longer merges cleanly because a sibling landed on the base first now gets one automatic rebase-and-retry before the item is parked: if replaying the branch's own commits onto the current base resolves the conflict, the merged tree is still verified and the merge lands with nobody asked. Only a rebase that itself conflicts parks the item, and the reason then says both that the merge conflicted and that the rebase attempt did too.
- With auto-merge and review-passed approval both on, an item parked at the gate on a merge conflict or a base race is retried automatically every time the base moves again — oldest first, one at a time — instead of waiting for a person; a merge that lands approves the item the same way a human's click does. An item parked on its own failing verify is never retried, and an item that exhausts its retry ceiling stops there — both say why in the item's Notes, once.
- An item's page now lists each run's review rounds — reject, refute, pass — one line per round with its verdict as a coloured pill and its finding counts, collapsed when a run passed on its first round; reading which round of a retried run failed on what no longer means opening the transcript.
- A review finding whose file is named nowhere in the item and never touched by the run's diff is flagged as scope drift: it is dropped from the feedback the next worker pass reads and instead recorded on the item's `## Notes` with a `drift:` prefix, so an operator reading a rejected run can see which findings pulled the work off the item. Advisory only — it never changes the verdict.
- Approving an item at the gate over a review's unresolved blocking finding now records the override to a project ledger, and once a class of finding has been overridden five times at a 60%-or-higher rate, `coordinator-knowledge.md` — and so the reviewer's own prompt — carries a line naming the class and the count, so a reviewer that keeps blocking on something the human keeps waving through starts to learn it is noise.
- A draft item's page now offers Groom: one agent pass reads the repo and proposes a `verify:`, a size and a What/How/Validation/Out of Scope, checked against the Definition-of-Ready and the grounding check and previewed before anything is written. Applying it writes the detail file and the line's verify and size; a Promote to Ready button appears once the Definition-of-Ready passes, whether that came from a groom pass or a hand-written detail file.
- An item the gate's automatic retry has given up on — a content conflict past the rebase, or a merged tree whose own verify stays red — now gets one capped, measured rescue run before it is left for a human: the worker and reviewer resolve it in a fresh worktree built from the failure's own reason, and a landed rescue goes through the same reviewer rubric and merge/verify every ordinary run does. Only one rescue is ever spent per item, and none is spawned unless the project has consented to autonomous work. The run is recorded with its own outcome — `rescued`, or `blocked:rescue-failed` — so it is never counted as an ordinary `done`/`blocked` run or silently folded into a human rescue.
- The fleet board's state cell for a running project now shows a five-step rail — worker → verify → review → merge → gate — with finished steps ticked, the current one ringed, the attempt count once it's above one, and the time since the run's last output, in a warning colour past half the stall timeout; the Autopilot tab's in-flight row draws the same rail, and `GET /v1/projects` and `GET /v1/autopilot` report it as `run.phaseRail`.
- When the reviewer's follow-up ask (asked only when its first verdict wasn't machine-readable) runs out its own 120-second clock, the run is no longer blocked: it is handed the verdict as it stood — approved if it already read that way, sent back to the worker otherwise — and a note on the item and in the run's log says the clarification timed out. A worker or reviewer round that runs out its own clock still blocks exactly as before.
- A project can now set how long its merge gate's verify may run (Autopilot tab → Merge verify timeout, or `autoMergeVerifyTimeoutMinutes` on `PUT /v1/autopilot`, clamped to 1…240 minutes, default 15) — a project whose merge-verify is its whole CI can raise the deadline instead of racing a fixed 900 seconds shared with every other machine load.
- A merge gate whose base gains a commit while its verify is still running no longer parks the item over a lost fast-forward: it rebuilds the merged tree on the base's new tip and verifies it again, once, before landing — recorded on the merge row as a retry rather than an ordinary merge. A base that moves a second time is still refused, but by name rather than by relaying git's own fast-forward hint text. Two gates on the same project — the autopilot's own auto-merge, an approval, a merge from an item's page — now also wait for each other instead of racing the same base.

### Fixes
- A drafted item's verify now picks up every verify-map rule scoped to a tree its own How already names, not only the rules that apply to every path — a draft whose How cites a file under a scoped rule's tree gets that rule's command added the same way an unconditional rule's is, with a note naming the cited path and the command it brought in; a rule whose tree the How cites nothing under is left alone.
- A gate-refresh round no longer strands an item at the approval gate: it now leaves the item's status exactly as it found it — `awaiting-approval`, whether the round came out fresh or failed — and the autopilot's own status is restored too, so neither the scheduler nor `POST /v1/backlog/approve` is left waiting on a run that no longer exists. The round's result (refreshed, or why it failed) is recorded as a dated note on the item instead.
- A refill pass whose own drafts already fill the shortfall no longer runs the repo's flake and hotspot instruments first only to discard whatever they found: it now checks for room before spawning either one, so a full drafter pass no longer spends up to five minutes of its deadline on instrument output that was never going to be filed.
- A finding one of the repo's own instruments drafts now files under an id capped at 64 characters, the same cap a model-drafted item's id already had — the backlog no longer accumulates the longer ids the signal path used to file — and a finding already filed under its longer, pre-cap id is recognized as filed rather than drafted a second time under the shorter one.
- An escaped-defect item that is itself reopened now files onto the id already tracking its lineage instead of a deeper-nested twin: the escaped-defect prefix is applied idempotently, so a second, third or later escape of the same item folds onto the same one-level id rather than stacking `escaped-defect-escaped-defect-…` prefixes.
- A draft's Groom button now works on the drafts a grooming pass actually files: it was refused for any item that already had a detail file, and every draft a grooming pass parks carries one, so the button offered nothing on today's backlog. Applying a groom now overwrites that file with the proposal's What, How, Validation and Out of Scope, keeps the `## Notes` recording which gate parked it, and says so plainly if the write doesn't land instead of claiming the item groomed.
- A refill pass now files at most as many items as its shortfall calls for: the repo's own instrument findings (flaky tests, hotspots, escaped defects) are trimmed to fit alongside the model's drafts rather than filed on top of them uncapped, with the leftover findings picked up again on the next pass.
- A grooming pass that drafts two items naming each other's `needs:`, or an item naming its own id, no longer files both as unrunnable forever: the loop is broken at drafting time — the same way a `needs:` id naming nothing already was — and the dropped edge is written into the item's Notes.
- A diff that adds an Anthropic API key, an AWS access key id, a GitHub or Slack token, or a private key block now blocks the run before it reaches review, naming the file, the line and which kind it found — never the value itself; a diff that only removes such a line is untouched.
- Settings are organized by scope. Project Settings is a sidebar list instead of seven tabs, with the four integrations (MCP Servers, Hooks, Kiteloop Hooks, Git) under one heading, and a new **Autopilot** page holding everything the gear popover on the Autopilot tab used to: worker and reviewer, the run switches, the cost caps laid out under the portfolio ceiling they sit beneath, and the stages autopilot may pick up, which move there from Backlog Flow. The gear keeps the autonomy ladder, wears the count of unmet rungs as a badge, and opens the page in one click.
- A picker's Default entry now says what it would inherit and from where — "Default (app · Fable 5.1)" on a project's model and effort — and the agent editor shows the project's model and permission mode beside the agent's own. The per-turn budget on a project's General page says it bounds one turn of a chat agent, and autopilot's caps are on the Autopilot page.
- App Preferences' General tab is three: General (appearance, knowledge repository, vault, health), Backend (authentication, default model, default effort) and Control API (the server, its token, phone pairing) — three short forms in place of one that scrolled.
- Grooming: a creation or absence cue after a backticked name ("the policy file `quality.json`, which X creates") now excuses it within the same sentence, and a grounding refusal says how the reference was read and which cue would have excused it.
- A worker that hands off an uncommitted tree now leaves an advisory finding on the item — how many files teardown had to commit for it under the app's own `autopilot: <item-id>` subject — and the worker prompt says to commit with the repository's own subject convention before handing off; the reviewer's diff facts say how many files at handoff were uncommitted.
- A run request answered `starting` whose item the pickup gates then refused no longer vanishes: the refusal is closed as a did-not-run run in `GET /v1/runs` with the gate's reason, and written to the item's Notes, instead of appearing only when the item is posted a second time.
- A rejected item can be run again without git surgery. The previous run's checkout directory is cleared even when git had already pruned its registration (it used to fail the new run with "already exists"), and when the item's branch cannot be deleted because a person has it checked out to review it, the run is refused with git's own reason — the path of that checkout — instead of failing a step later on the branch name.
- The pairing sheet's unreachable banner now tells the two causes apart: with the control server toggle off it says so and points at the toggle, and only names `install-control-forwarder.sh` when the server is actually running and still nothing answers.
- A merged-tree verify that fails now keeps the tail of what it printed — on the merge ledger row and in the item's Notes — naming which attempt printed it; a step that failed once and passed on its retry keeps that first attempt's output too, marked recovered. A merge with nothing to retry writes none of this.
- The escaped-defect rate and the refill's escaped-defect signal no longer count the auto-merge/gate-retry loop's own churn: a reopen it re-approves within its own retry window is the same approval continuing, not a new escape. Previously a run parked at the gate that bounced between Done and Active a few times while its own retries ran could file several "Escaped defect" items against work nothing had actually reopened.
- A worker whose turn ends on the Agent tool's async-launch acknowledgement no longer hands its node to the reviewer right there: the node stays open until a turn that made no such launch of its own completes it, so a background agent's report — arriving as a later turn, never the one that launched it — becomes the closing message instead of "waiting for its report" being read as the finished work. A launch that never gets a next turn still ends the run at the stall timeout, as blocked.
- A finding class over both override thresholds now gets one line in `coordinator-knowledge.md`, dated from its own first override, instead of a fresh restatement with moved-on counts at the end of every run — a pattern that was crowding every other learning out of the file's capped auto section.
- That override lesson no longer gets aged out of `coordinator-knowledge.md`'s capped auto section by an unrelated run of ordinary learnings and then re-filed as if new: it now survives the section's 30-entry cap for as long as the pattern it names is still active, and only an ordinary bullet is evicted in its place.
- A merge conflict in a file whose name happens to contain "verify" (`VerifyCoverage.swift`, `MergeVerifyPlan.swift`, `scripts/kiteloop-verify.py`, and others) is now retried like any other conflict instead of being permanently excluded as a red merged-tree verify.
- The gate's automatic retry now recognises a project's own folder however it was opened: a failed merge attempt recorded under a trailing-slash spelling of the project's path is no longer read as no attempt at all, and the retry ceiling and the one-rescue-per-item cap now tally entries left under either spelling as one lifetime count instead of resetting to zero.
- `./scripts/run-unit-suite.sh --flakes` no longer counts a red row and a green row at one commit as a flip when either row's tree was recorded dirty — the uncommitted content it measured is unknown, so it is no reading of that commit and is passed over the same way a row with no verdict already is.
- `./scripts/run-unit-suite.sh --last` now applies that same dirty-row rule to its own `earlier` and `flaky` lines: a dirty row is left out of the disagreement count and its named tests, and a dirty row can no longer grant a test its "recorded ✘ at an earlier commit and ✔ since" — neither by naming it while dirty nor by dirtily standing in for the green reading it is said to have passed since.
- A drafted flaky-test item's second acceptance criterion no longer asks `./scripts/run-unit-suite.sh --flakes` to stop naming the test — a bar the append-only flip record could never let a diff clear. It now asks that the source of nondeterminism be named and pinned by a test or assertion, something a reviewer can check against the diff alone.
- The refill's escaped-defect signal no longer files a reopen the escaped-defect rate itself reports as a late return rather than an escape: a reopen more than seven days after its own approval — or one with no recorded approval at all — now yields no finding, matching the same seven-day, inclusive-boundary window `TaskMetricStore.escapedDefectRate` already draws between `reopened` and `lateReopened`.
- The escaped-defect rate served by `GET /v1/runs` and `GET /v1/metrics` now collapses auto-merge/gate-retry churn the same way the rate computed directly from the ledger does: the metric index backing those endpoints was counting every reopen and approval row on its own, so a run parked at the gate that bounced a few times on its own retries showed up there as extra escapes that the other path already folded away.
- Blocked triage now moves its window across a project's whole pile instead of re-reading the same head of it every pass: a project with more blocked items than one pass reads gets a moving cursor that resumes where the last pass left off, wrapping to the head once it runs off the end or once the item it stopped on is no longer blocked, so nothing past the bound sits unreachable forever.
- A worker start with `worktreeSetupCommand` configured (Autopilot tab, or `worktreeSetupCommand` on `PUT /v1/autopilot`) no longer freezes the app for the command's whole run: it now runs off the main actor the same way the merge gate's own setup step already did, and both run the command wrapped the same way a verify step is, so the setting behaves identically wherever it runs.

## 0.4.6 — 2026-09-02

### Added
- The autonomous run scheduler now holds a project (`gateFull`) once its approval gate holds more `awaiting-approval` work than the Planner keeps `ready` for it and its autopilot won't clear the gate itself — previously a project with `approveReviewPassedRuns` off kept starting new runs however far behind a human fell, stacking branches that were stale before anyone looked. The hold clears itself once an approval or a send-back drains the gate back under the floor. `GET /v1/projects` reports it per project; the fleet drawer and `GET /v1/coordinator/scheduling` report it wherever any other hold appears.
- A new "Try a Sample Project" entry in the project picker installs a bundled demo repo — a pre-groomed two-item backlog with the two example agents already assigned as worker and reviewer — so a fresh install can see its first autopilot run without bringing a repo or grooming an item first.
- A refill pass now files an instrument's own finding under a kind — bug or tooling — with its `## What` carrying the sentence that kind demands (a repro for a bug, the check or script it serves for tooling), instead of the same shape for every finding regardless of what it's about.
- Pausing a project is now one act: a queue held by the Autopilot tab's pause (or `POST /v1/autopilot/pause`) now also refuses `POST /v1/runs` and a human's own Run button with a 409 naming `POST /v1/autopilot/resume`, and stops the Planner's grooming and the autonomous run scheduler for that project the same way the fleet board's `paused` priority already did. `GET /v1/projects` now reports `paused` per project, and the fleet board's row shows "paused by hand · N at gate" for either cause.
- An item at the approval gate now carries a `freshness` verdict — whether its branch still merges onto the base, and which files conflict if not — checked when it reaches the gate and refreshed after every sibling's merge since, in `GET /v1/backlog` and the Waiting-on-you row ("stale · N files"). Approving a stale item now answers 409 with the conflict immediately, instead of only discovering it minutes later when the merge itself is attempted.
- A reviewer's prompt now carries a per-file list of what the run actually changed, with each file's added/deleted line counts, plus two explicit facts drawn from that list — whether any test file changed, and whether `CHANGELOG.md` did — instead of leaving a reviewer to notice those absences on its own after reading a large diff.
- An open backlog item nothing has touched in 28 days now shows up as a row in the "Waiting on you" drawer, naming the item, its status, and how long it's been since — read from the shared backlog branch's own git history. It only ever flags; nothing moves, demotes or archives the item on its own.

### Fixes
- A pull request's empty check list is now held for a couple of minutes before it's read as "this project has no CI" — a fresh PR, or one just pushed to after a fix round, no longer gets waved through to the approval gate before GitHub has registered its workflow run; a project that genuinely has no checks still reaches its human within a couple of minutes rather than at the full deadline.
- `POST /v1/backlog/templates/stamp` now takes a `kind` field (`bug`, `feature`, `tooling`) that parks a hand-stamped item lacking that kind's required `## What` sentence as `draft`, naming the missing clause — the kind-aware grooming gate previously had no caller. `GET /v1/backlog/templates` now also lists the three built-in kind skeletons alongside a project's own `templates/*.md`.
- `POST /v1/autopilot/resume` now lifts a project paused by fleet-board priority, not only one paused by `POST /v1/autopilot/pause` — previously it 409'd on a priority-paused project ("Autopilot is not paused"), leaving no call able to un-pause it despite `POST /v1/runs`'s own refusal naming resume as the remedy.
- A stale item at the approval gate now gets one bounded worker round to rebase itself — merging the project's current branch in, resolving conflicts and re-running its `verify:` — without leaving `awaiting-approval` or going back through review; autopilot starts it on its own once the project goes idle, or by hand through `POST /v1/backlog/refresh`. Three failed rounds in a row retire the item at the gate for a human to resolve.

## 0.4.5 — 2026-08-30

### Fixes
- A worker or reviewer round now gets the project's own `stallTimeoutMinutes` as its wall clock instead of a hard-coded 10 minutes, so a round whose verify runs the core suite is no longer killed mid-verify — and a round the breaker does end is reported with the breaker's own reason ("Node timeout … exceeded") instead of "max retries".
- An item's worker prompt and verify-coverage gate now use the union of the backlog line's `verify:` and the detail file's groomed commands, instead of the frontmatter silently winning whenever it was non-empty — previously widening the line to satisfy the verify map did nothing while a groomed list stayed in place, and the gate blocked on a command the operator could see plainly declared. Pickup now also leaves an advisory note on an item whose two verify sources disagree, naming both spellings, so an edit to one is noticed against the other before a run is spent.
- The Diagnostics footer and its Reveal action now always name the file the logger is actually writing to — switching projects updates the reported log directory under the same lock that guards it, instead of a stale reader occasionally naming the project opened before it, or `~/.kiteloop/logs`, while lines land elsewhere.
- Settings now reports the control server as running only while its listener is actually bound, and a failed or cancelled listener is restarted with a bounded backoff instead of leaving the toggle claiming a port that's gone dead — previously a listener that failed after startup left "Running on ⟨port⟩" showing indefinitely, with every headless driver and the phone forwarder silently unable to reach it.

## 0.4.4 — 2026-08-30

### Added
- `GET /health` now reports what the app has actually measured about itself — main-thread latency, recent hitch count, resident memory and live subprocess count — and answers `"degraded"` instead of `"ok"` when the main thread is not keeping up, so a headless driver can tell a wedged app from a busy one instead of waiting out a long no-progress window.
- The iOS companion now has a unit-test target (`KiteloopMobileTests`), with its first tests covering `ControlClient`'s percent-encoding of query values and `ConnectionStore`'s `configured` gate; CI now compiles it with `build-for-testing`.
- A refill pass now also files items from the repo's own instruments — a flaky test, a churn-times-complexity hotspot, or a backlog item that came back after approval — alongside whatever the coordinator model drafted, gated and deduped the same way.
- A refill pass now widens every draft's `verify:` with whatever commands the project's own `.kiteloop/verify-map.json` applies to every path before filing it, on the backlog line and in the detail file's frontmatter alike, with the item's Notes naming what was added — previously a draft that omitted a universally-applicable rule was filed as ready and only refused by `VerifyCoverage` after a worker and a reviewer had already spent a run on it.
- The sidebar now marks an agent waiting on a permission prompt with a loud, non-pulsing orange ring and badge, distinct from the pulsing green ring for one that's working.
- The Memory tab now has an archive control on each fact in an agent's memory index, so a full index (the refusal already named this remedy) can actually be pruned from the app instead of by hand-editing a file — archiving keeps the fact's full text, just takes its line out of the index.
- The Memory tab now lists an agent's archived facts, read-only, below its Topics — an archived fact's body used to be reachable only by finding it on disk in Finder.
- A run whose diff widens a quality ratchet's baseline (`Kiteloop/.swiftlint-baseline.json`, `Kiteloop/.crap-baseline.json`, `quality/complexity-lizard-baseline.json`) now leaves an advisory note on the item naming which baseline it touched, instead of that going unremarked once the gate is green.
- `check-test-hygiene.py` now also counts the iOS companion's test tree (`KiteloopMobile/Tests`) — a fixed sleep, a hand-built temp directory or a file-local wait helper copied in there now fails the preflight, the way one copied into the Mac app's or the package's test tree already did.

### Fixes
- A run is now only refused as "wrote outside its worktree" for a path its own worker or reviewer actually edited — dirt left in the project's checkout by something else while the run was up (a human's own edit, a second Claude Code session, the approval gate's own verify) no longer blocks the item, and is instead recorded on it as an observation.
- `GET /health` now answers `"degraded"` while the main thread is actually wedged, instead of `"ok"` for the whole stall and `"degraded"` only for the one second after it recovers — a snapshot taken mid-stall now reports at least how long the outstanding latency probe has been waiting.
- The iOS companion now reports a refused keychain write on the Connect screen, beside the scan error, instead of looking paired for the session and coming back unpaired with nothing said at the next launch.
- CI now runs the iOS companion's `KiteloopMobileTests` bundle against a concrete simulator after compiling it, instead of only compiling it — a companion test that compiles and fails is now caught instead of merged.
- A day's spend that fails to save to disk is no longer silent: the daily budget now reports the write it couldn't make, refuses an autonomous start under a ceiling until a save succeeds again, and still lets a human start a run — the same treatment already given to a spend file that can't be read back.
- A drafted hotspot item's id is now built from the file and the function's declared name instead of the line it was found on, so the same hotspot no longer files a new item every time an unrelated edit shifts it a few lines down — previously the id embedded `file:line` and a function reported once already tracked would refile under a new id the next time its file changed.
- Opening a git repository that has no `.gitignore` now seeds one ignoring Kiteloop's runtime state, same as a repo that already has one — previously it was left alone, so a freshly `git init`'d project kept worktrees, screenshots, sessions and logs untracked until someone wrote a `.gitignore` by hand.
- The agent catalog and the specialists registry now save durably and report a write that fails, instead of an atomic `Data` write whose error was discarded: an unclean shutdown can no longer turn a save into a zero-length file that reads back as an empty catalog and seeds the defaults over it, and a save a full disk or a locked file refuses now surfaces in the inbox and Diagnostics instead of silently reverting the template or specialist the user just added.
- Each project's autopilot run history is now kept in that project's own `.kiteloop/autopilot-history.json` instead of one shared file under the home directory, so two open projects no longer overwrite each other's recent-runs list; a project opened without a path keeps its history in memory only.
- A project's `autopilot-history.json` that can't be decoded no longer gets silently overwritten with an empty list on the next finished run: it's now moved aside and reported, like the autopilot config, so the original runs survive to be recovered by hand; a write that fails outright is now reported too, instead of discarded.
- Grooming an item that cites a slashed prose abbreviation — `n/a`, `and/or`, `w/o`, `I/O`, `24/7` — no longer parks it as a missing repo path; a real repo-relative path is still checked exactly as before.
- Grooming an item that quotes a shell variable assignment — a `NAME=value` word like the search path a spawn is given — no longer parks it as a missing repo path; a real repo-relative path is still checked exactly as before.
- The quit confirmation prompt no longer blanks the control API while it's on screen: it now shows as a sheet on the main window instead of a blocking modal session, so `/health` and every other endpoint keep answering until a button is clicked.
- A project's `.kiteloop/config.json` that can't be decoded no longer silently resets its permissions, budget and priority and then gets overwritten with defaults on the next save: it's now moved aside and reported, exactly like the autopilot config, so the original bytes — a `paused` priority among them — survive to be recovered by hand.
- A project's `coordinator-knowledge.md` past the coordinator's read budget no longer loses its most recent learnings: the trim now keeps the human-curated head and drops whole bullets from the *oldest* end of the auto-learned section, instead of severing the file at a fixed byte count and losing whatever the last runs just wrote.
- Opening a project no longer leaves every earlier boot's generated agent workspace behind under `.kiteloop/workspaces` — only the current boot's directory survives, and this holds whether the team is loaded from packages or from inline templates.
- `scripts/run-core-tests.sh`'s closing tally now names how many XCTest cases were skipped, and that count is carried into `docs/suite-status.md`'s package-tally cell — a run on a machine missing a test's prerequisite (an absent `.kiteloop/` runtime state, an unavailable port) no longer reads exactly like one where every case ran, since XCTest counts a skipped case inside its own `Executed N tests` total.
- A worktree kept for inspection — a blocked item's, or one the open-time sweep votes to keep — no longer keeps its Xcode build output for ever: its DerivedData is deleted and any `.app` built into it is unregistered from LaunchServices, while the checkout, branch and diff a human came to inspect are left untouched.
- An `autopilot-config.json` that can't be read or decoded no longer fails silently and then gets overwritten: the autopilot logs why, keeps a `.unreadable` copy of the original bytes alongside the file, and the next settings change rewrites `autopilot-config.json` from defaults without touching that copy.
- The phone's pairing scanner no longer shows a black, uncloseable-feeling sheet when it can't see a camera: refused or restricted camera access, and a destination with no capture device (the simulator), each close the scanner and name the cause on the Connect form, with the manual URL and token fields still usable.
- `scripts/control-forwarder.py` now restarts when a tailnet or LAN address appears after it started, not just when one it bound disappears — the ordinary case at login, where Wi-Fi comes up before `tailscaled` finishes, no longer leaves the tailnet address unforwarded until someone restarts the job by hand.
- The companion no longer breaks the Queue, Now and Agents tabs on a project folder with a space or an `&` in its name — query values are percent-encoded before the request goes out, instead of splitting the URL or landing on the wrong project.
- The companion's Levers tab now pauses and resumes the project the operator has actually selected, with a picker to change it, instead of always posting the literal `"kiteloop"` baked into the source.
- The retry ceiling's reported attempt count no longer climbs every time a retired item is re-selected: the `did-not-run:retired` row that refusal itself writes is no longer counted as another no-work attempt, so an item retired after 3 attempts stays reported as 3 no matter how many more times autopilot re-selects it.
- An unreadable `autopilot-config.json`'s reported failure now names the `.unreadable` sibling that holds the preserved bytes and says plainly that the config file itself is rewritten from defaults on the next setting change, instead of the old, misleading "will not be saved over"; and when the sibling copy itself can't be written, the message says the original bytes could not be preserved and carries the reason, instead of reporting the same reassuring line either way.
- Watching a run's live tail on the companion now shows the Mac's own reason when the stream is refused — a run that's already ended, an unknown run id, or a token that no longer authorises — instead of a quietly empty tail indistinguishable from a run with nothing to say.
- The companion's Runs tab no longer shows a cancellation error after tapping "Stop watching", and switching the live tail to another run no longer hides the Live section a moment later — a stream this stopped no longer writes its own stale state over the one that replaced it.
- The companion's Queue, Agents and Levers project pickers now refresh on every visit to the tab instead of loading once at launch: a project opened on the Mac since appears, one since closed drops from the picker (moving the selection to the first project left), and a selection still open survives the refresh unchanged.
- `scripts/control-forwarder.py` no longer exits with a traceback when the Mac's own hostname briefly fails to resolve (Wi-Fi flapping, a VPN coming up, mDNS not answering) — the failure is logged and the forwarder keeps serving on the address its routing-table probe still finds.
- The companion no longer reports a merge gate approval as "timed out" when it's actually landing, or an agent chat send as failed mid-reply: approving a gate and sending a chat message now wait long enough for the Mac's real answer instead of giving up at 15 seconds, and a chat send that does fail puts the typed message back in the box instead of losing it.
- An agent's MCP server allowlist, shown in its info popover, is now enforced: a session only auto-allows the servers the agent's `mcpServers` names, instead of every server in its MCP config; an empty list or one containing `*` still allows all of them, unchanged from before.
- A project skill now shadows a personal skill of the same name instead of both registering under it, so which body an agent gets is no longer arbitrary.
- `scripts/verify-map-replay.sh` now reads a merge commit's first-parent diff instead of an always-empty plain diff, and refuses (exit 2) rather than silently prints `COVERED` when the changed-file list is empty for any reason — an empty file, empty stdin, or a commit that touches nothing.
- A structurally broken workflow file — an entry or terminal node naming no node, an edge pointing at a node that isn't there, or a node with neither an agent nor a sub-graph — is now skipped and logged instead of being registered and only failing once it runs.
- Settled workflow checkpoints are now swept as the app keeps writing new ones, at most once an hour, instead of only when a project reopens — a project left running for a day no longer piles up hundreds of stale execution directories that only get pruned at the next open.
- `scripts/run-core-tests.sh` now names the case (or cases) still open when it ends a hung `swift test` at the timeout — or says plainly none had started — and prints the same filtered log tail a red run does, instead of a bare "ended" line with nothing behind it.
- An item's Runs list now shows a run a pickup gate refused as `did-not-run`, matching the spelling every other outcome on that row uses, instead of the control record's wire spelling `did_not_run`.
- Daily log files older than 7 days are now pruned when the day rolls over, not only at launch or when a project opens — an install left running for weeks no longer keeps every daily log forever.
- The companion's Queue tab now badges an item with its own project's most recent refusal, not whichever of the twenty newest refusals across every open project happened to land on an item of the same id.
- `DirectoryWatcher` (used by the knowledge index and skill registry) now closes each watched directory's descriptor from the dispatch source's own cancel handler instead of right after asking it to cancel, closing a race where the descriptor number could be freed and handed to something else while an event handler was still reading from it.
- The setup wizard's repo-size lookup now finds `gh` in `~/.local/bin` instead of a malformed sibling of the home directory that never exists, so a machine with `gh` installed there reports repo sizes instead of showing none.
- Settings → Plugins now names the newest installed version of a plugin and counts that version's skills, instead of picking whichever version directory sorts last as plain text — a plugin at `1.10.0` no longer reads as `1.9.0` — and a stray file dropped beside the version directories is never mistaken for one.
- Choosing "Pause the Fleet and Quit When It's Quiet" no longer hangs forever once the fleet drains: the drained quit now finishes closing its run records before asking to terminate again, instead of finalizing on the same re-entrant pass that never gets a chance to reply.
- A librarian pass now sends at most a bounded number of memory bodies per agent, preferring the ones its index still names, and reports how many it left out — instead of building one unbudgeted prompt out of every topic body an agent has ever accumulated.
- Approving an archival, or a merge that archives its source facts, no longer reports success when the body's move into `memory/archive/` fails: the approval now throws, naming the fact, and leaves the index and the body exactly as they were, instead of silently dropping the fact from the index while its body stays where `recallMemory` keeps finding it.
- `scripts/run-core-tests.sh`'s closing tally, copied verbatim into `docs/suite-status.md`'s package-tally cell, now counts the package's swift-testing cases alongside its XCTest cases instead of only the latter, and only fails with no tally when neither framework printed one.
- `quality/bin/check-guard-suites.py` no longer demands a `PREFLIGHT` entry (or an `"exempt"` slot) for `scripts/core-package/test-move.py`, the tool that moves an app-hosted test into the package rather than a test itself: a new `"not_suites"` map in `quality.json` names it as not a guard suite at all, and the OK line reports that count separately from the exempt one.
- `check-features-map.py`'s reachability sweep now covers the iOS companion's `KiteloopMobile/Sources/Services/` alongside the Mac app's and the package's — previously a companion service reached by nothing the app runs passed silently, since only the two other roots were swept.
- The changelog advisory now fires for a diff that changes only the iOS companion's Swift, instead of staying silent while `CHANGELOG.md` goes untouched.
- Switching the web preview pane's mode picker back to Trusted now actually restores it: every external host the human had approved is revoked, a confirmation still waiting on the human is dropped, and a page already on screen that Trusted would refuse is navigated away from and reported as blocked — previously the picker only relabeled itself, and a page loaded and every host approved under External kept running unchanged.
- `check-features-map.py`'s reachability sweep now recognises a `package`-modifier declaration (`package struct`, `package final class`, and so on), so a service under the host-less package — every one of them declares this way — is actually judged instead of silently skipped for offering no name to look for; four services the sweep newly caught unreached are now recorded in `"exempt_services"`.
- The recent-projects list is now saved durably, and a save that fails is reported in the inbox as "Could not write Recent projects" instead of vanishing silently — matching the recents file's already-hardened read path.
- Grooming an item whose prose says a cited path is gone — "missing", "removed", "deleted", "dangling", "no longer" and the like — no longer refuses it as an invented reference; the refusal's remedy line now names this alongside the existing creation-cue escape.
- A signal-drafted item whose fix lands in the package or a test tree no longer gets refused after a whole run's work for a `verify:` that never runs the command covering it — every drafted item's `verify:` now also runs `./scripts/run-core-tests.sh` and `./quality/bin/check-test-hygiene.py`, alongside the app build and the two unconditional Swift checks it already ran.
- A single main-thread stall lasting several seconds is now recorded as one hitch, at its full length, instead of one shrinking hitch per second it lasted — the Health tab's latency reading and the Diagnostics hitch tally no longer overcount how often, and how badly, the app actually stalls.
- `report-hotspots.py` no longer ranks a function the complexity gate itself already accepts into its top rows: a `hotspots.min_cc` setting (default 0, and a matching `--min-cc` flag) drops any function under the floor from the ranking entirely, and the header now says how many rows the floor held back; Kiteloop's own `quality.json` sets it to 8, the same number `.swiftlint.yml` gates on.
- `check-complexity.sh` now names a SwiftLint baseline entry that matched nothing this run — a function since shortened, split, renamed or deleted — beside the count it already prints, instead of silently exempting whatever grows back in that function's place; a run right now names the stale `MemoryLibrarianPass.swift` entry this way.
- `quality/bin/mutate.py` no longer hangs the whole mutation run on a mutant whose suite never returns — a wall-clock ceiling (`MUTATE_TIMEOUT_SECONDS`, default 600s) now ends that run, reports the mutant as `timed-out` alongside `uncompilable`, restores the source, and moves on; a timeout on the green-before-mutation run now fails fast naming the ceiling instead of hanging.
- `check-crap.py` no longer waits forever on a hung swiftlint or xcrun xccov — each now runs within its own wall-clock ceiling (`SWIFTLINT_TIMEOUT_SECONDS`, `XCCOV_TIMEOUT_SECONDS`, default 600s each), and a child that runs past it fails the gate naming the tool and the limit instead of hanging the suite run's postflight.
- The Diagnostics Health tab's Main Thread gauge no longer carries its own copy of the hitch threshold: it now stays red at exactly the figure `GET /health` calls degraded, instead of reading green at that boundary while the endpoint already disagreed.
- A Copilot turn no longer hangs forever against a bridge that accepts the connection and then goes quiet: a silent socket now ends the turn with a system error naming the socket and the deadline, followed by a result, and Stop now lands on a silent turn too instead of only one that's streaming.
- The merge gate now retries a verify step once when it fails with a crash signature, a lock timeout, or a named test failure — a flake, a crashed test binary or a lock held by a concurrent run no longer refuses a merge outright; a step that fails the same way twice is still refused, now naming the class and that a retry was already spent.

## 0.4.3 — 2026-08-26

### Fixes
- Chat session cost, run spend and the daily budget no longer overcount: the CLI's reported cost is the session's running total, not a per-turn amount, and it was being summed as if it were — a multi-turn session's recorded cost could run 2–5x the real figure, and the inflated total drained the daily budget early, stopping autonomous work hours before the real ceiling.

## 0.4.2 — 2026-08-26

### Fixes
- `scripts/control-forwarder.py` now forwards to whatever port Settings → General → Local Control API is actually set to, instead of always 4517 — pairing a phone no longer fails silently after the port is changed. A one-off run can override it with `--port N`.
- `scripts/control-forwarder.py` now classifies addresses by octet instead of text prefix, matching the Mac's pairing sheet — a 172.16–172.31 Wi-Fi lease is bound instead of dropped, and a public 100.200.x.x address (mistaken before for Tailscale's CGNAT range) is no longer bound, including one the routing-table probe turns up.
- `quality/bin/check-guard-suites.py` now sweeps each root recursively instead of stopping at its top level, so a guard suite added one directory deeper is judged instead of passing unseen; a root listed both as a parent and as one of its own children still counts each nested suite once.

## 0.4.1 — 2026-08-25

### Added
- The iOS companion connects to your Mac, not to one address: a fresh install opens the connect screen and asks for a tailnet address instead of assuming one baked in, and any `http://100.x.y.z:4517` you type is trusted, not just the one that used to be hardcoded.
- Review before you approve, from anywhere: `GET /v1/backlog/diff` returns the item's unmerged branch as a unified diff with a `--stat` summary — the iOS companion's gate screen shows it beside the item's What/Validation, so clearing a gate from the phone is a read decision, not a blind one. The Runs tab lists every tracked run from `GET /v1/runs` with a tap-to-watch live tail, and the Now tab carries the last-24h report (merged ÷ filed, spend, rejection causes) from `GET /v1/report`.
- Same-Wi-Fi pairing: the Mac's pairing sheet offers every reachable network — tailnet first, Wi-Fi beside it — so the phone can connect over the local network when Tailscale is off; `scripts/control-forwarder.py` (kept alive by a LaunchAgent) listens on both addresses and survives reboots.
- Pair a phone by QR: Settings → General → Local Control API → "Pair a phone" shows a code the iOS companion scans — URL and token in one scan, nothing to copy.
- The control API can hold a conversation: `GET /v1/agents` lists a project's agents with their state, `POST /v1/agents/message` delivers a message into an agent's chat session exactly as if typed — queueing politely if the agent is mid-turn — and returns the reply, and `GET /v1/agents/transcript` reads the recent conversation back; `GET /v1/backlog/detail` returns one item with its groomed What/How/Validation, notes and verify commands. Together they are what the iOS companion's Agents tab and item drill-down speak.
- Backlog items can be reordered — the queue is document order, so position is priority: "Move to top" on an item's context menu, drag-free "move in front of" through the backlog editor's `moveItemBefore` op, and `POST /v1/backlog/move` headlessly; done items refuse, everything still in play may be prioritised.
- The Planner's grooming-pass ceiling is operable where it is read: a stepper on the Planner card's passes box changes it mid-day (raising it is how a spent day gets more passes), and the value persists across relaunches — set from the card or `PUT /v1/coordinator/refill`, it no longer resets to 12.
- `run-unit-suite.sh --flakes` lists every test the whole suite-status record has recorded red in one row and green in a later row at the same commit — the same question `--last`'s `flaky` line answers over its newest twenty rows, now over the whole file, so a test that flips only once a week no longer scrolls out of view before anyone reads it.
- `quality/bin/report-hotspots.py` ranks every function the complexity gate measures by churn (commits touching its file in `hotspots.window_days`, default 90) × complexity — a report, not a gate, so it names where a refactor pays off rather than blocking anything.
- The repository's own Python tooling (`quality/bin`, `scripts`) now has a `complexity_lizard` section in `quality.json`, so `quality/bin/check-complexity-lizard.py` judges it against the same cyclomatic-8/60-line gate as the Swift code, with today's 34 over-gate functions held in a baseline — run on demand for now, not yet in the preflight.
- `quality/bin/check-complexity-lizard.py` now reads the copilot bridge extension's TypeScript (`copilot-bridge-extension/src`) as well — a new function past cyclomatic 8 or 60 lines there now fails the same gate as one in `quality/bin` or `scripts`, with today's one over-gate function (`handleRequest` in `socketServer.ts`) held in the baseline.
- A hygiene habit in `quality.json` can carry an opt-in `floor_by` — a map of date to a lower ceiling — so `check-test-hygiene.py` enforces the lowest one whose date has passed, and a failure names the scheduled step that fired; no habit schedules one yet.
- `scripts/install-control-forwarder.sh` installs the LaunchAgent the pairing sheet depends on — copies `control-forwarder.py` to `~/.kiteloop/bin`, writes and loads `ai.kasatkin.kiteloop-forwarder.plist` — so pairing a phone no longer needs a plist made by hand; `--uninstall` reverses it and `--dry-run` previews it.
- The iOS companion's Swift (`KiteloopMobile/Sources`) is now judged by the same complexity and layering gates as the Mac app and the package — `check-complexity.sh` and `check-layering.py` read it too, with today's tree clean under both, so a new over-gate function or a layering violation there fails the preflight the way one in `Kiteloop/Kiteloop` already did.
- `check-target-membership.py` now also walks the iOS companion's `KiteloopMobile/Sources` against its own project and target, so a `.swift` file there missing from `project.pbxproj`, compiled by no target, built by the wrong one, or a stale reference to a file no longer on disk fails the preflight the way one in the Mac app already did.

### Fixes
- `complexity_lizard`'s guard-suite exclude (`*test-*`) no longer drops two production files it only matched by name — `quality/bin/check-test-hygiene.py` and `scripts/core-package/test-move.py` are now judged by the complexity gate through a new `exclude_except` list, and `check-test-hygiene.py`'s `main` (cyclomatic 13) is split so it clears the gate rather than joining the baseline.
- A `grounding-check` or `retry-ceiling` refusal recorded before an item's groomed detail file was last edited no longer counts against it — the Autopilot panel and the landing screen now both drop it from `heldAtPickup` once the item has been rewritten, instead of holding it against a queue that has already been fixed.
- The pairing sheet now warns, before the scan, when nothing answers on the address and port it is about to hand the phone — naming the address, the port, and `./scripts/install-control-forwarder.sh` to fix it — instead of leaving a first scan to hang silently on both ends.
- The pairing sheet now offers a Mac's 172.16.0.0/12 Wi-Fi address instead of showing "No network address found" — the reachability rule reads octets, not a text prefix, so it no longer drops that whole private range or mislabels a public `100.x.y.z` address as Tailnet.
- The iOS companion's live run tail no longer drops after about fifteen seconds of quiet — its stream deadline used to match the server's keepalive cadence exactly, so a healthy run with a quiet stretch read as a timed-out request.
- `quality/quality.example.json` — the documented example `quality.json` refuses naming when a section is missing — now matches `quality.json` again (a stale hygiene ceiling, five missing layering exemptions, an extra unused section), and `test-quality-config.py` now fails naming the first differing section if the two ever drift apart again.
- `check-doc-size.py` now prints a WARN line — even under `--quiet` — for a document within 2% of its word ceiling, so a passing run says the ceiling is close before the next small addition fails the preflight outright.
- The approval gate's merge verify builds in the project's own `.kiteloop/DerivedData`, not the DerivedData shared with Xcode — a merged tree is compiled as merged, never against the package products the IDE last built.
- The escaped-defect rate now counts a `done` item reopened straight into `active` or `in-review` — not just `ready` or `blocked` — so an item picked back up before anyone saw it sitting in the queue no longer disappears from the metric.
- `RunRecordStore` now writes a run whose `qualityScore`, `costUSD`, `costCapUSD` or a `judgeDimensions` value is not a finite number, with the offending field alone dropped and logged, instead of erasing the whole record — the default JSON encoder throws on NaN or infinity, which used to lose the run silently on both the append and the retention-rewrite path; a record `encode` still refuses for any other reason now counts against `failedWriteCount` on both paths as well, instead of only the append path's own write failure.
- A protected-path entry now covers its directory whether or not it was typed with a trailing slash, and the same rule reads a `touches:` declaration — previously `docs/adr` (no trailing slash) matched no path a diff could produce, so the gate protected nothing while still reading as protection.
- The quality judge now treats a non-finite score ("nan", "inf") in its reply as absent instead of passing it through the 0...1 clamp unchanged — a reply whose only score was unusable now reports as having no verdict, the same as a reply with no scores at all, rather than recording a run whose quality score is not a number.
- A grounding refusal now ends with the remedy that clears it — a creation cue ("add", "create", …) in the prose just before the citation — instead of only naming what didn't resolve, so a groomer no longer has to already know the check forgives a file or symbol the draft itself proposes.
- Blocked triage now widens an item's `verify:` with the commands the verify map said it never ran, instead of sending the item back to be refused by the same gate again; a map rule can name a `run` spelling for a command that is only a match prefix.
- The backlog AI editor's prompt now shows `moveItem` as a single well-formed JSON object instead of splicing `"moveItemBefore"` in beside its name — an operator asking to move an item between epics used to get a proposal the mapper couldn't parse, landing in the unreadable list instead of the preview.
- `TaskMetricStore` now counts and logs a write that never reaches one of its four ledgers (a read-only `~/.kiteloop`, a full disk) instead of silently discarding the row — the new `failedWriteCount` matches `RunRecordStore.failedWriteCount`; the record still shows in the live view, but a rate computed from `RetryCeiling`, `SizeCalibration` or `CostGovernor` no longer moves over a hole nobody could see.
- `GroomingLedger` now counts and logs a write that never reaches `~/.kiteloop/grooming.jsonl` (a read-only home directory, a full disk) instead of silently discarding the verdict — the new `failedWriteCount` matches `RunRecordStore.failedWriteCount`; the record still shows in the live view, but a lost `released` record no longer re-retires an item a human deliberately released with nothing in the file to say why.
- `core-move.py` now refuses before the first `git mv` when `swiftlint` isn't on PATH, and exits non-zero with swiftlint's own stderr when the baseline rewrite it runs at the end exits non-zero — previously both cases still printed the "N -> N entries (must be equal)" line as if the rewrite had run, so a swiftlint failure read as a clean move and only surfaced later as unexplained complexity violations at the next suite preflight.
- `core-move.py` now actually prunes the layering exemptions a move makes dead — it was reading a top-level `layering.exempt` key `quality.json` has never had (the lists live per root, under `layering.roots`), so a moved reference's exemption used to survive every move and left the operator to find and delete it by hand once `check-layering.py` failed on the dead entry.
- `core-move.py` no longer drops the layering exemption for a type it moves — a move relocates the declaration, not the reference or the reason someone wrote down for it, so an exemption naming a moved type now stays in place in every root; only an entry whose referencing file the move takes out of the app root is still dropped.
- `core-move.py` no longer crashes part-way through a move when the file being moved was never registered in the pbxproj (an extraction the mover itself just `git add`ed, for one) — its inline pbxproj-unregister, duplicated three times across `core-move.py` and `test-move.py`, is now the single `unregister` in `pbx-register.py`, which both movers call and which reports the file as unregistered instead of raising.
- `run-unit-suite.sh --flakes` no longer counts a test as flaky from a row where it was only skipped — a test named in a row's skipped-tests cell is now no reading for that row either way, so a test that is always skipped on a machine (the loopback-bind skip, for one) and failed once elsewhere no longer enters the ledger on the strength of runs that never executed it.
- `run-core-tests.sh` now fails instead of passing silently on two shapes of "green because it never measured anything": a `swift test` that exits 0 with no `Executed N tests` tally in its output, and a `swift test` ended at the wall-clock ceiling whose process happened to be reaped with status 0 — both used to exit 0 and read to `run-unit-suite.sh`'s preflight exactly like a real green run.
- `run-core-tests.sh` now ends a hung `swift test` at a wall-clock ceiling (`CORE_TEST_TIMEOUT_SECONDS`, 600s default) instead of waiting on it forever — previously a hang in `Kiteloop/KiteloopCore`'s own tests silently stalled the whole `run-unit-suite.sh` preflight and any autopilot run whose `verify:` touched the package, with nothing on the terminal to say why.
- A row `run-unit-suite.sh` appends to `docs/suite-status.md` now carries `Kiteloop/KiteloopCore`'s own tally beside the app-hosted one — previously a test moving out of `KiteloopTests` and into the package read as a test lost rather than relocated, since xcodebuild never builds the package's tests and the row never recorded them at all.
- `check-layering.py` now judges `KiteloopCore` alongside the app — previously a cross-layer reference inside the package went unchecked, and a file that crossed layers by moving into the package left the ratchet instead of being caught by it.
- `check-layering.py` now resolves a referenced type's owner across every configured root at once, instead of per root in isolation — previously a type that moved out of the app and into the package made every reference to it from the app disappear rather than fail, since the app's own owner index no longer declared the name and the package's was never consulted; five such references were exempted with their reasons once this made them visible again.
- `check-features-map.py`'s reachability sweep now covers `KiteloopCore`'s services alongside the app's, and its `[x]`-row check now judges a row citing a package service instead of silently dropping it — previously only the app target's `Services/` was swept and its success line still counted every row the map cited, so a package service reached by nothing read as coverage that had been checked.
- `check-crap.py` now names any `.crap-baseline.json` entry that matched nothing this run — a function that was covered, split, renamed or deleted but is still counted as accepted — with its file, declaration text and recorded score, and points at `--write-baseline` to drop it; staleness is reported after the verdict on both a pass and a fail, but never fails the gate on its own.
- `check-target-membership.py` now also reports a `project.pbxproj` file reference whose file is no longer on disk — previously a move that left a stale registration behind was invisible to the check, and surfaced later as a raw xcodebuild "build input file cannot be found", or not at all when the stale build file sat in no phase.
- `run-unit-suite.sh --help` now narrates all twenty of `PREFLIGHT`'s entries, in order, instead of nine of them, and its closing safety sentence no longer claims none of them starts a build — two now do — but that none launches the app-hosted test host or reads the process list, which is what actually keeps the preflight safe while Kiteloop is running; `test-run-unit-suite.sh` now fails, naming the entry, if a `PREFLIGHT` command ever goes unmentioned in `--help` again.
- `test-move.py` now creates a candidate's destination folder before handing it to `git mv`, so the first file moved into a package tests folder that doesn't exist yet (the tree currently holds only Extensions, Models, Runtime, Services and Support) no longer dies part-way through the move; and it now lands a root-level `KiteloopTests` file (there are four) directly in the package tests root instead of inside a directory named after the file itself, citing it in `docs/features.md` by its bare basename rather than that doubled path.
- `core-inits.py` no longer parses argv or rewrites the package the moment it's imported — its argument parsing and its rewrite loop now sit behind a `main()` and an `if __name__ == "__main__"` guard, like its sibling movers, and it no longer reads the whole app and test trees into a string it never used.
- `core-pick.py` no longer scans the app and package trees, resolves identifiers or prints the moment it's imported — its walk, its owner map and its three output modes now sit behind a `main()` and an `if __name__ == "__main__"` guard, take `--app`/`--package` like its sibling movers, and are covered by a new `test-core-pick.py`.
- Switching conversation branches no longer throws away what was said on the line you leave: `/branch main` and `/branch switch <name>` now save the outgoing transcript before switching, so returning to a branch shows what it last held instead of its state at creation, and `/branch main` shows main's own transcript instead of relabelling the branch's; `/branch delete <name>` on the branch you're standing on now returns you to main instead of leaving the deleted branch's messages on screen.
- `run-unit-suite.sh`'s preflight now runs the CRAP gate's own test (`quality/tests/test-check-crap.py`) — previously nothing standing ran it, so a reader that stopped scoring coverage correctly would only misjudge the postflight gate silently after a green suite instead of failing the run before a build starts; and the weekly mutation workflow now runs the mutation harness's own test (`quality/tests/test-mutate.py`) before it mutates anything, failing the job if it fails, instead of trusting an untested harness to judge five hours of mutants.
- The quality judge now scores a run's whole branch, not just its last commit — the diff it's handed is read against where the branch forked from `HEAD`, captured before auto-merge folds the branch back in, instead of always the single commit just before the branch tip; a run whose branch already carried more than one commit (teardown's own commit, a PR fix round, a review-comment pass) used to have its advisory score judged on a fragment of what it actually did.
- `GET /v1/backlog/diff` no longer runs its three gits (rev-parse, `diff --stat`, `diff`) on the main actor, and each now carries a 30s deadline — a slow diff on a large branch, or a git that never exits, used to be able to freeze the control API and the app's whole UI while a human at the gate waited for the patch; a timed-out or failed git now answers a plain error naming the timeout instead of a 200 carrying an empty, unmarked patch.

## 0.4.0 — 2026-08-23

### Added
- A clean-code loop workflow (`start_clean_code_loop` from any chat): specifier → coder → verify → clean → harden → review → QA → a person, each tool failure looping back to the coder with the tool's output

- An **Answer the review once** autopilot setting gives a rejected run one round to answer the reviewer before the rejection stands: the findings go to the worker's still-live session in the same worktree, which fixes or refutes each, and the reviewer re-judges once — that second verdict is final. It saves a whole cold re-run when the finding was answerable in a sentence, runs at most once per item, is charged to the item's cost cap, and writes the whole exchange to the item's Notes. Off by default.

- A **Waiting on you** drawer, opened from the sidebar footer, lists every open project's approval gates and unanswered agent questions in one place — longest-waiting first, with the project and item or agent on each row — so the question survives having a project tab open instead of living only on the start screen; selecting a row opens the Autopilot panel or the agent's chat where the decision is actually made.

- A **Portfolio** screen shows several projects' backlog items in one list — grouped by project, each row carrying its title, stage and size with finished work struck through, and one stage filter that narrows every project at once; selecting an item shows its groomed detail. Which projects it reads is a plain list of one project root per line in `~/.kiteloop/portfolio.md`, editable by hand and picked up as it changes, and a path with no `BACKLOG.md` is listed as skipped rather than silently dropped. It is read-only: no project's backlog is written to from this screen.

- `run-unit-suite.sh --last` now names tests that a recent run recorded red and a later run recorded green, so a test that does not decide the same way twice stays visible after the red row has scrolled out of view — previously the readout compared only runs at the same commit and said nothing about a test that failed at one commit and passed at the next.

- The advisory quality judge now sees each changed file's added/deleted line counts (`git diff --stat`) alongside the diff body it scores, so a large run whose test files fell outside the truncated body can still be recognised as having added tests. `GET /v1/metrics` now reports `qualityScoreDiffTruncated` on every scored run, so a score taken through a truncated diff window can be told apart — and excluded from an average — from one taken over the whole diff.

- With pull-request publishing on, a run now makes one pass over its pull request's unresolved review threads before summoning a human: each thread is either fixed and resolved, or answered with a written reply and left open, with the tally in the item's Notes and on the approval notification. A comment asking for something the item put out of scope is declined citing the item, a thread is only resolved off the back of a commit that was actually pushed, and the pass runs once — later comments wait for the human.

### Fixes

- A git command run on the worktree or auto-merge path — creating or removing a worktree, staging and committing, or the merge itself — no longer inherits the app's stdin and no longer runs without a deadline: a stuck hook or a git that stops to ask a question is now killed, with anything it forked, after 5 minutes instead of wedging every later worktree operation for the project behind it.
- The setup wizard's AWS and GitHub credential checks no longer inherit the app's stdin and no longer run without a deadline: a hung `aws sts get-caller-identity` or `gh auth status` is now abandoned after 15 seconds and reads as a failed check, instead of leaving the wizard on "Checking…" forever and blocking the agent list from ever loading.
- Session titling no longer loses a title it already has: a child that answered and exited was sometimes discarded as "no title" if the machine was busy enough to delay the closure that reads its output — the answer is now read off the child's own exit rather than raced against a separately scheduled timeout.
- Session titling now finds `claude` the same way the rest of the app does, honouring a configured `claudePath` override and the Homebrew/npm-prefix fallback candidates — it previously ran its own `which` lookup with only `/usr/local/bin/claude` as a fallback, so a session went untitled on a Mac where every other spawn worked.
- `scripts/make-release.sh`'s bundled-resources check now refuses when a `Kiteloop/project.yml` resource entry names a path that does not exist in the tree, instead of silently leaving it out of the spec-vs-pbxproj comparison — a stale entry for `Kiteloop/Resources/Avatars`, never present in this repository, had been passing that check unreported the whole time; the entry is removed from the spec.
- `./scripts/run-unit-suite.sh`'s preflight now runs `check-test-host-hook.sh` and `test-test-host-hook.sh` — the two checks guarding the PreToolUse hook that keeps an app-hosted test run from taking a running Kiteloop down mid-item existed and passed, but nothing ran them, so a hole reopening in that hook's pattern would have gone unnoticed instead of failing the suite.
- A Claude model id the price table has no row for — a retired legacy id, or any release newer than the table — now reports no derived cost, instead of silently being priced at the current flagship's rates; a bare family alias (`opus`, `sonnet`) still resolves to that family's flagship as before.
- A `@handle` consultation that hits a permission prompt no longer hangs on screen forever: the request is now answered on the spot — approved for the read-only tools the consultant is granted, refused otherwise, with the refused tool named in the chat.
- A project's autopilot settings — the worker/reviewer pair, cost caps, protected paths and behaviour flags — are now written durably, so an unclean shutdown can't leave a truncated `autopilot-config.json` behind and revert every setting to its default; a save that can't be written at all is reported in Diagnostics instead of failing in silence while the setting quietly reverts on the next launch.
- A project's `config.json` — its stated priority and goal — is now written durably, so an unclean shutdown can't leave it truncated and read the project back as unconfigured on the next save.
- `GET /v1/backlog`'s stranded-work sweep now also reports a worktree still on disk with uncommitted changes for an item nothing is coming back for — previously only a `done` item's unmerged branch was caught, so a worktree left dirty by a crashed or interrupted run for an item that was never marked done went unreported, undetected by `git fsck`, and would have been silently destroyed by an ordinary `git worktree prune`. A worktree dirty because its run is in flight, or kept on purpose for inspection after a blocked run, is not reported.
- The live cost figure on a running item no longer re-reads and re-decodes the project's whole trace history each time it is sampled, so a project that has been running for months samples spend as quickly as one that started today.
- Autopilot no longer spins a CPU core when its scheduler is prevented from starting the run it chose — quiescing the fleet, or a project going busy between the choice and the start, left the loop re-deciding without pause. It waits out its interval again in that case.
- A memory reading the kernel refused now shows as "—" in the Diagnostics Health tab, instead of reporting `0 MB` in green — the healthiest figure the gauge has, for the one case where there is no figure at all.
- A finished run is now written down within half a minute of ending, instead of staying open until something makes a control-API request: an unattended night that nobody polls no longer reads back as a list of `interrupted` runs if the app is force-quit or loses power. A run still in flight is left open, as before.
- A child process spawned for a git command, a `which` lookup, a Claude version check, or the `gh` size lookup no longer inherits the app's own stdin: a command that stops to ask a question — git wanting a credential, an askpass, a shim that prompts — now reads EOF and exits instead of blocking that call, and everything waiting behind it, for ever.
- Quitting the app no longer leaves finished runs reading `interrupted` in the run history: a run that had already ended is written down with the outcome it reached, so an overnight batch nobody was polling reads back the next morning as the work it actually did. A run still in flight when the app is quit still reads `interrupted`.
- An autopilot run that changes no files because the item is already built is no longer filed as a run that achieved nothing: a worker that names the existing code sends the item to the approval gate carrying its claim and evidence, and the run no longer counts towards retiring the item. A worker that changes nothing and names nothing still counts exactly as before.
- A saved provider token no longer overwrites a `tokens.json` the app could not read: the unreadable file is moved aside to a `tokens.json.corrupt-<stamp>` sibling first, so the API keys it held are still recoverable instead of gone the next time a token was saved.
- Linking a local clone to a repo no longer wipes the repo links the app could not read: a `repo-links.json` that won't decode is reported and moved aside to a `repo-links.json.unreadable` sibling, instead of being silently replaced by the one link just made and sending every other repo back to "missing".
- Filing a groomed item into a `BACKLOG.md` the filesystem won't take is now reported as a refusal naming what went wrong, instead of as a filing — the item was in no backlog, but grooming counted it as filed and said so.
- A line in the grooming ledger that can't be read — the half-written last line a crash leaves — is now kept when the ledger is trimmed, instead of being deleted the next time it filled up; a hand-written release lost that way quietly retired the item again.
- An agent whose chat-session index can't be read no longer loses its history in silence: the failure is reported in Diagnostics naming the agent and the file, and the unreadable index is moved aside to an `index.json.unreadable` sibling instead of being overwritten by the next chat that agent starts.
- An agent's chat-session list is now written durably, so an unclean shutdown can't leave a truncated `index.json` behind and cost that agent every chat it had; a save that can't be written at all is reported in Diagnostics instead of failing in silence while the app keeps showing sessions that are no longer saved.
- The Diagnostics window's Logs tab no longer risks taking the app down while an agent is running: a log line written on a background thread now reaches the tab on the main thread instead of refreshing the list from that thread.
- The day's grooming figures now survive a relaunch: passes, spend and abandoned passes are written down as they happen and read back at launch, so the daily pass ceiling still binds after a restart instead of handing the day a fresh twelve, and the Planner card reports the day's totals and passes rather than only what the running process had seen.
- An item the coordinator files under a different epic than it drafted now says so: its detail file's `epic:` names the section the line actually landed in, and its Notes record which epic was asked for and where it went, instead of the file going on naming an epic the backlog hasn't got.
- A `BACKLOG.md` frontmatter key the app has no use for — `owner:`, a docs link, anything beyond `project`, `repo` and `verify_default` — is kept when the file is written back, instead of being deleted the first time an item's status changed.
- A `## ` section or note a human hand-writes below an agent's memory index is kept the next time a memory proposal is approved, instead of being silently erased when the write rebuilt the file from its facts alone.
- A memory proposal edited before approval now records the text a human actually approved alongside what was originally proposed, instead of the proposal's JSON going on naming only the proposer's words after they were replaced.
- The Autopilot tab's Start button now refuses to begin a run while the fleet is quiesced, the same way the control API does — previously it started a fresh run into a fleet that was being held for a restart, which is exactly what quiescing exists to avoid.
- Compacting the autonomous start log now writes through the same durable path its appends already use, and reports "Compacted the autonomous start log" only when the write actually landed — previously an unclean shutdown during compaction could leave the whole night's history as a zero-length file, or the app could claim a compaction that never happened.
- Pressing Stop in a Copilot-backed chat now ends the turn in flight instead of throwing the session away: the reply stops arriving, but the chat stays usable, and it no longer answers every later message with "Session not found" until the agent is restarted.
- Deleting a plugin the app could not actually remove — a permission it lacks on `~/.claude/plugins/cache`, a file held open, a read-only volume — now keeps it in the Plugins list with an error naming it and why, instead of dropping it from the list while it is still installed and still loaded by every agent.
- Everything a `BACKLOG.md` carries above its first epic heading — an introduction, house rules, a link block, and a hand-written H1 that isn't the project name capitalised — is kept when the file is written back, instead of being silently deleted and replaced with a generated heading the first time an item's status changed.
- The replay-fixture recorder can now be switched on for a built app by setting `KITELOOP_RECORD_SESSIONS=1` in its environment, instead of only by editing a compiled-in constant and rebuilding — every other value, or the variable left unset, keeps recording off exactly as before.
- Quitting the app while the replay-fixture recorder held a still-live session no longer throws that session's captured interactions away: everything a recorder has captured is now written to disk before agent subprocesses are torn down, the same as a session that was stopped normally, and a session already written by a normal stop is not written a second time.
- Project Settings' Git tab now runs its branch/status/log commands on a deadline and off the cooperative pool, so a git that never exits — an index lock held by another process, a repo on a stalled network mount, a hook that stops to ask — no longer parks a pool thread for ever; the refresh button now recovers instead of staying disabled.
- Installing a plugin from Settings now finds `claude` the same way every other spawn in the app does, honouring a configured `claudePath` override, instead of shelling out through the minimal PATH a GUI app inherits from Finder; with no Claude CLI resolvable it now reports the setting to fix instead of spawning nothing useful, and a `claude` that hangs — stopping to ask for authentication, say — is now killed after a minute instead of leaving the Install button disabled for the life of the app.
- An item edited to a `verify:` (or any other field) containing `" | "` no longer has it silently split and truncated on write — a value that would not read back the same is refused, and the item's existing line is kept instead, with an error logged so the refusal is not silent either.

## 0.3.8 — 2026-08-21

### Added

- A run finishing anywhere — the Autopilot tab, the control API, the scheduler itself — now makes the autonomous scheduler look for the next one straight away, instead of leaving an idle fleet with runnable work waiting out the five-minute check.
- `POST /v1/projects/ask` asks the Planner a question about one named project's source — "is that file still there", "does this symbol exist" — reading it with search and file-read only: it cannot write, run a command or reach the network, it reads no project but the one named, the answer is capped and says when it was, it charges the portfolio's daily ceiling and a spent one refuses, and asked about something it did not read it still says so.
- Autopilot starts the next item as soon as the last one finishes, instead of idling up to five minutes first — and an armed scheduler takes its first look on launch rather than a full interval later. The periodic check still runs, for the changes no finished run announces.
- `GET /v1/metrics` now reports each run's `predictedCostUSD` and whether it went past its per-item cost cap (`overItemCap`), so which items outgrew their estimate is answerable the morning after instead of vanishing with the session that measured it.
- `GET /v1/backlog` now reports a groomed item the retry ceiling has retired as not ready, naming the retirement and how many of its attempts produced nothing, so a headless driver stops starting runs autopilot silently refuses.
- `GET /v1/runs` now carries each historical run's `reason`, so a listing says whether a `blocked` run was rejected by the reviewer, ran into its cost cap or ended without a recorded result — instead of costing one extra request per blocked run to find out.
- `kiteloop-verify.py --marathon --json` now carries the marathon scorecard as a `scorecard` object in the report it prints — wall clock, items run, completed, blocked, stalled, rescues, failed starts and the ids behind them, average quality — so an unattended night's metric-#1 numbers can be read by whatever ran it instead of regexed out of the narration.

### Fixes

- Queue refill no longer re-proposes an item the backlog already holds: a drafted candidate whose title matches an existing item is refused, whoever wrote that item, instead of being filed under a suffixed id and running again.
- A control API request whose query holds a nameless pair — `GET /health?=` — no longer crashes the app: the pair is ignored, and the request is answered as usual.
- A command that pipes a download into an interpreter — `curl … | sh`, `wget … | bash` — is now treated as critical and asked about in auto mode, instead of being approved on the agent's behalf because the guardrail only matched the exact text `curl | sh`.
- A run whose transcript aged out no longer reads as a run that never happened when its `pruned.json` marker cannot be decoded: it reports as pruned, dated from the marker itself, and the unreadable file is left on disk.
- A `daily-spend.json` the app cannot read no longer reads as a day on which nothing was spent: the file is kept, intact, beside itself as `daily-spend.json.unreadable-<timestamp>`, and autonomous runs are held while a daily budget is set and today's spend is unknown — a run you start yourself still runs.

## 0.3.7 — 2026-08-21

### Added

- The board now shows an item in review: with the Review stage enabled, an item moves to **In Review** while the reviewer agent judges it and back to **Active** when a rejection sends the work round again, instead of the column standing permanently empty.
- How many worker/reviewer rounds an item gets in one run is now a per-project setting — a **Review rounds** stepper on the Autopilot tab and a `maxRetries` field on `PUT /v1/autopilot`, saved with the project and restored by Reset — instead of a fixed 3 nothing could change.
- Autopilot now warns once when an item's spend crosses 80% of its effective cost cap, instead of the first signal being the cap firing — named in the run log and the activity feed, with the item, the spend and the cap.
- `GET /v1/memory/proposals` lists a project's pending memory proposals over the control API — an agent's `propose_memory` call, or a fact the librarian pass wants merged, deleted or archived, was previously visible only on the Memory tab, so a proposal filed during an unattended run was invisible to whatever was driving it.
- `POST /v1/memory/proposals/approve` and `/reject` answer a pending memory proposal over the control API, so an agent's memory can accumulate facts on a machine nobody opens the Memory tab on; a write the index turns away is refused with its reason and leaves the proposal pending.

### Fixes

- A run record the app fails to write — a `~/.kiteloop` that is not writable, or a full disk — is now reported as a failed write naming the run and the error, instead of returning as though it had been saved and leaving the next launch to answer 404 for work that had merged.
- An `agent-catalog.json` the app cannot read is no longer replaced by the built-in agents at launch: the file is kept, intact, beside itself as `agent-catalog.json.unreadable-<timestamp>`, and the app says where it went instead of destroying every agent you had added before the window opened.
- A backlog can no longer end up holding two items under one id: adding an item whose id is already taken is refused and says so, and the ids the Add Item button and the AI editor generate are now read off the ids in use rather than off how many items there are — after deleting an item, the next generated id used to be one that already existed, and the second item filed under it could never be edited, moved or deleted again.
- A workflow shell command that cannot be started at all — most often because its working directory has been removed under the run — now fails the node with the spawn error and a non-zero exit code, instead of leaving the workflow waiting on that node for the life of the app with nothing said about why.
- A `backlog-workflow.json` edited outside the app can no longer point autopilot at Done, Awaiting Approval or Draft: those stages are dropped when the config is loaded, so a hand-written pickup list stops re-running finished items and starting work parked at the approval gate.
- A request to the local control API declaring a negative `Content-Length` no longer takes the whole app down before the bearer token is checked; it is read as having no body, like any other length that will not parse, and answered like any other request.
- `scripts/run-unit-suite.sh` now holds the Mac awake for as long as its build runs, so an unattended suite on a machine that falls asleep is no longer ended at the time limit and recorded as a build that outran it.
- A note written under an epic after one of its items — between two items, or as a caveat at the end of the section — now survives the next write-back instead of being deleted from `BACKLOG.md` on the first status change.
- A field on a backlog item's line that the app cannot read — most often the tail of a `verify:` whose pipe was written with spaces — now survives the next write-back instead of being reported once and then deleted from `BACKLOG.md` on the first status change.
- A groomed item that cites a directory with its remainder elided — `Kiteloop/Services/…`, or the three-period spelling — is no longer refused as a file the repo does not have; a path with no elision in it is still checked and still refused when it resolves nowhere.
- `kiteloop-verify.py --marathon` now counts a run by what it ended as: one that was cancelled, and one a pickup gate refused before any work began, are each reported on their own scorecard line naming the items, instead of both landing in `completed` and passing "completed at least one item" on a night that delivered nothing.
- An agent's `mcp.json` now survives being edited by Kiteloop: a server it cannot model as a stdio command — a `type`/`url` entry with no command — no longer makes the whole file read as if the agent had no MCP servers at all, its tools are allowed at the CLI like any other server's, and keys Kiteloop does not model are still in the file after approving a server or saving a credential.
- A structured debate's grounding command now has a deadline: one that tails a file, waits on a network or stops to read input is killed — with anything it forked — and the debate carries on to the critic saying the command timed out, instead of the round and the agent's turn hanging on it for ever.
- A git command run for a shared backlog branch now has a deadline: a `fetch` or `push` that stalls on an unreachable remote, or an ssh that stops to ask for a passphrase, is killed and logged instead of hanging every later backlog operation — and the app's window with them.
- A Backlog Flow setting changed in Project Settings now takes effect in the project that is already open — switching "Require human approval before Done" back on stops agents marking items Done from that moment, rather than only after the project is closed and reopened.
- A project on the Fleet board that is running nothing while its queue holds work it could start now says so — "idle, 6 runnable", the reason the last start was declined, and links to the items that reason named — instead of reading as quietly finished; a project with a run in flight, a paused one, and one with nothing runnable are unchanged.
- An improvement loop started with `start_improvement_loop` now hands its agents the goal, the change summary, the files touched and the reviewer's feedback where its prompts say they will be, instead of the literal placeholder text with the values relegated to a context dump at the bottom.
- A tool call in the chat now reads as the sentence the agent wrote about it — "Read Kiteloop global config for registered projects" instead of forty characters of shell cut mid-token, and a launched agent's own description instead of a fragment of identical boilerplate result text; the command it stands in for is on the row's tooltip, and a label too long to fit is cut on a word boundary.
- Closing a project tab now releases its agents' event subscriptions and the tasks watching them, so opening and closing projects over a long session no longer accumulates a live subscription, a watch task and a retained event log per open.
- The served OpenAPI document and the control API reference now list `did_not_run` among the run outcomes and say a `reason` comes with it, so a driver validating the body of a run a pickup gate refused no longer fails on an outcome the server has always reported.
- The served OpenAPI document now describes the autopilot endpoints as they behave: `PUT /v1/autopilot` declares the `autonomousWorkEnabled` and `protectedPaths` fields it has always accepted, the configuration schema carries those two keys and no longer requires a `coordinator` no reply has ever sent, and the retired coordinator field is described as deprecated and ignored — so a generated client stops failing every autopilot read.
- A run whose reviewer verdict could not be read now counts against the retry ceiling even when the worker changed files, so an item whose reviewer keeps answering in a form nothing can route is eventually withheld instead of being re-run indefinitely; such a run is also no longer counted towards what its size costs.
- An item a pickup gate refuses — not groomed, not grounded, wrong status, already retired — is now recorded as an attempt, so the retry ceiling counts it and an item that is refused over and over is eventually withheld with a reason instead of being selected forever. An item merely waiting on an unfinished `needs:` is not counted, and a refusal costs nothing and moves no spend.
- A groomed item that cites a GitHub Action this repo's own workflows use — `actions/upload-artifact@v4`, or the bare `actions/upload-artifact` — is no longer refused as a missing file; an action reference nothing under `.github/workflows/` uses is still refused as before.
- A groomed item that proposes to add a file is no longer refused for naming that file again — in a later section, or in the `verify:` command that runs it. An item whose whole point is a new script has to verify by running it, and the grounding gate read that as a claim the script was already on disk; a path or an executable no draft proposed is still refused exactly as before.
- The setup wizard's repo clone can no longer hang forever: `git` is no longer given the app's own stdin (so it can't stop to ask an unanswerable question — an unknown host key, a passphrase) and is now bounded by a timeout, past which it and anything it forked are killed and the repo's status becomes a clear failure instead of sitting at "Cloning…" forever.
- A suite run ended at its time limit now records which test it hung on: the row `scripts/run-unit-suite.sh` appends names the cases that had started and never came back, and `--last` prints them under `hung` rather than `failing` — previously the row said only that the run had stopped.
- A groomed item that quotes a Swift path expression containing a string interpolation is no longer refused as a missing file — an interpolation names no one file, the same way a `<placeholder>` or a shell expansion doesn't, so an item about path-building can quote the code it is about; an ordinary repo-relative path is judged exactly as before.

## 0.3.6 — 2026-08-20

### Fixes

- A queued workflow step waiting on a busy agent can no longer be woken and claim that agent while a third, unrelated execution is still holding it — the queue previously tracked only which agents were busy at the moment a step first asked, so a later execution taking one of its agents went unnoticed and both ended up believing they held it.
- A run no longer merges its own branch into `main` while the human approval gate is on. Auto-merge ran before the gate was consulted and marked the item done itself, which consumed the state the gate reads — so with "approve review-passed runs" **off**, work still reached `main` with nobody accepting it, and the autonomy ladder's promise that every merge waits for a person was not true. The merge now happens only when the gate is going to clear itself; otherwise the branch waits at the gate for a person, whose approval merges it as it always did.

### Added

- The Memory tab now shows **what the fleet has learned** — `.kiteloop/coordinator-knowledge.md`, written by finished runs and read by the Planner, the worker and the reviewer. It shaped every run and had no surface at all, so a line that stopped being true could only be corrected by knowing the path.
- `POST /v1/backlog/groom` promotes a groomed draft to `ready`, or sends one back to `draft` — the one busy transition that had no headless verb, so grooming a night's work meant hand-editing the shared backlog branch. It moves only between those two statuses; everything else belongs to the machinery that earns it.
- The Autopilot tab's run-settings popover now has an "Auto-merge on approval" toggle and a merge-verify command field, so a project merging approved work unattended — previously settable only through the control API — shows that in the app, and can be turned on or off there too.

### Fixes

- `BACKLOG.md` — and the backlog's other on-disk writes, the initial scaffold and item detail files — now land through the same durable writer every other store uses, instead of a rename that can leave a zero-length or truncated file behind after an unclean shutdown.
- Project Settings → Direction no longer carries a second editor for the shared context. The Memory tab has edited that file all along; Direction keeps the goal, which had no other home, and points at where the context lives.
- The backlog hides completed items by default, with a "Hide completed" switch beside the counts and the counts themselves reporting both — 531 of this repo's 626 items are done, so the list was mostly strikethrough. It is a view filter: nothing is moved or removed, so `needs:` keeps resolving against finished items.
- The fleet box now says when the run scheduler will next look, the way the Planner's box already did. A freshly launched app sits up to five minutes before its first tick, and with nothing on screen saying so an armed scheduler read exactly like a broken one.
- The autonomy ladder in a project's Autopilot tab lays its rungs out beneath the row that discloses them, instead of indenting them into what looked like a second column with a large empty space beside it.
- The grooming loop no longer counts a queue as healthy just because it is deep. A project's `ready` items are now weighed against how many of them could actually start — the same figure the landing screen already shows — so a queue held up by unmet dependencies, ungroomed items or a gate's refusal gets drafted for instead of being read as full.
- Grooming no longer refuses an item for citing a member of a platform type this repo merely mentions — `Bundle.main.resourceURL` and the like. A dotted citation's root is now checkable only when this repo itself declares (or extends) a type of that name; citing an actual member this repo doesn't have is still refused.
- Project Settings → Direction no longer claims the Planner drafts backlog items against the shared context file — it doesn't; the Planner grooms against the project's goal, a separate field that now lives on this tab too, next to the shared context editor it actually pairs with.
- The protected-paths gate now stops a live-tree run (worktree isolation off, the default) from landing an undeclared change to a protected path, not only an isolated one — previously it only judged isolated runs, so a project could name `docs/suite-status.md` protected and still have an unattended run land a row in it with the reviewer never told.
- A backlog-flow config Kiteloop cannot read (`.kiteloop/backlog-workflow.json`) is now kept and reported, rather than being silently replaced by the built-in defaults on the next save. The unreadable file is moved aside next to itself so nothing is lost.
- A hook whose command outruns its `timeout` is now actually stopped at the deadline instead of being recorded as timed out while it keeps running for its full duration in the background.
- A merge-verify that hits its timeout now also kills whatever that command forked (e.g. the compiler processes under a killed `xcodebuild`), instead of leaving them running and holding CPU and DerivedData after the run that started them has already been reported as timed out.
- A `gh` or `git` command that outruns its timeout while opening or following a pull request now also kills whatever it forked, instead of leaving it running and reparented after the command has already been reported as failed.
- A backlog item's completed date, its trace day file, a cost entry and the metric database's day column are now the same Gregorian `yyyy-MM-dd` in Latin digits on every machine, instead of following whatever calendar and numbering system the Mac's region happened to use — previously a Japanese-calendar or Arabic-Indic-numbering region wrote a day key that wasn't the date it claimed to be.
- The daily log file (`kiteloop-YYYY-MM-DD.log`) is now named with the same Gregorian, Latin-digit day key as the rest of the app, instead of a `DateFormatter` that read the Mac's region — a Japanese- or Buddhist-calendar region named the file with an era year, and an Arabic-Indic-numbering region named it with non-Latin digits.
- Every line inside that daily log now carries its `HH:mm:ss.SSS` timestamp in Latin digits as well, regardless of the Mac's region — previously only the file's name was pinned to Latin digits, and an Arabic-Indic- or Devanagari-numbering region rendered the stamp on each line in that region's digits instead.
- The Diagnostics window's log rows, hitch list and copied text now render timestamps in the same Gregorian, Latin-digit `HH:mm:ss.SSS` the log file carries, instead of the Mac's own calendar and numbering region — previously an Arabic-Indic or Devanagari region showed one timestamp on screen and a different one in the file for the same event.
- `scripts/run-unit-suite.sh` now ends a wedged `xcodebuild` after 30 minutes instead of leaving it to run all night, and records the row as ended at its time limit rather than as an ordinary failure.
- A verify-coverage map that exists but can't be read (a directory in its place, a permission that was tightened, an I/O error) is now reported in the run log naming the file, instead of silently passing every run through unchecked exactly as a project with no map does.
- The setup wizard's "Install Knowledge" now actually populates the agent list. It copies the chosen repo to `~/.kiteloop/knowledge` and reports it installed, but nothing scanned that directory — the agent list stayed empty, before and after a relaunch. The scan now covers it, and installing re-scans immediately so the agents appear without restarting the app.
- `GET /v1/coordinator/refill` now reports `budget.day` as the local calendar day the counters describe (`"YYYY-MM-DD"`), instead of a UTC instant that named the wrong date for half of every day next to counters that were already zeroing at local midnight.
- `scripts/run-unit-suite.sh` now ends every process a timed-out build started, not just `xcodebuild` itself — previously ending a wedged run left its compiler children (and, for a run that reached the tests, the `Kiteloop.app` test host) still running and holding CPU after the watchdog had already reported the run as timed out.
- `scripts/kiteloop-verify.py`'s suite-record check now fails on a newest row the suite runner ended at its time limit, instead of reading it as a passing suite — such a row can carry the same `exit 0` a matched-nothing run does, and the check previously only recognised that second case.
- `/doctor` now reports the same Claude CLI and Node.js paths the app actually spawns through, honouring a configured override and a `which`-found install, instead of checking its own hard-coded list and reporting a working CLI as `NOT FOUND`. It also names the resolved Node.js path instead of just `found`.
- Grooming no longer refuses a draft for a backticked span that names no file at all, such as a bare `./` or `../` — that span is now treated as uncheckable prose, the same as a MIME type or a host, instead of being parked as a path that isn't in the repo.
- A merge refused for conflicting now names the conflicting file(s) (`merge conflict in: CHANGELOG.md`), instead of the bare `merge conflict` that left the operator to find out by hand.
- A recent-projects file Kiteloop cannot read is now kept and reported, rather than being silently read as "no recent projects" and overwritten by the next project you open. The unreadable file is moved aside next to itself so nothing is lost.
- A specialists file (`~/.kiteloop/specialists.json`) Kiteloop cannot read is now kept and reported, rather than being silently read as "no specialists" and overwritten by the next specialist you add, update or remove. The unreadable file is moved aside next to itself so nothing is lost.
- A settings file (`~/.kiteloop/global-config.json`) that can't be read or decoded at agent spawn time is now reported, instead of silently spawning the agent against the subscription backend or the default control-API port regardless of what Settings actually says.
- A shell hook that hits its timeout now also kills whatever that command forked, and escalates to a hard kill if the command itself ignores the stop signal, instead of leaving either running in the background after the hook has already been reported as timed out.
- Grooming no longer refuses a draft for citing a runtime file whose only spelling in the sources is a single quoted literal with its directory built in, such as `.kiteloop/repo-links.json` — the bare filename is now read out of that literal's last segment, the same as it already was for one written without a directory.
- The session-title watchdog now escalates to a hard kill and sweeps whatever the child forked when it ignores SIGTERM, instead of leaving it (and the thread draining its pipe) running for the life of the app.
- An agent starting a debate with zero or a negative `max_rounds` no longer crashes the app; the round count is now clamped to a sane range, and an absurdly large one no longer buys an unbounded number of agent turns.
- A turn driven by another agent — a delegated `@mention` reply or a broadcast — now refuses a permission request the risk assessment rates critical (`sudo`, `rm -rf`, a force-push, writing a credential file, and the like) instead of silently approving it, since there is no person there to ask.
- A cached plugin's skills are now scanned from its genuinely newest version — `5.10.0` now beats `5.9.0`, instead of losing to it under a plain text sort — and a stray file sitting beside a plugin's version directories can no longer be picked as the "version," which previously built a skills path that couldn't exist and silently contributed no skills at all.
- Stopping a session or quitting the app now also ends whatever the `claude` CLI forked — the node permission/tool bridges, and anything running under `Bash` such as an `xcodebuild` or `git` — instead of leaving that generation running and reparented after the CLI itself is gone. Quitting with several sessions open now pays one grace period for the whole batch rather than one per session.
- A `statusLine.command` that hangs — waiting on a network call, a stalled `git`, a script reading stdin — is now killed at a deadline instead of being waited on forever, and a refresh that arrives while one is still running starts no second process; previously each 10s tick piled another blocked shell on top of the last, for the life of the app.

## 0.3.5 — 2026-08-19

### Added

- A fresh install now offers agents. Kiteloop's built-in Coder and Reviewer packages ship inside the app bundle and are found there — previously the built-in path was resolved from the compile-time source location, so it worked on the machine that built the app and nowhere else, leaving first-run with an empty agent list and a file picker for a knowledge repo a new user has no way to obtain.
- A project's Autopilot tab now opens with the autonomy ladder: which rungs are met, and — for the first one that isn't — the exact control that advances it. It was previously reachable only through a link inside the fleet drawer, which is not where anyone setting a project up is looking. It collapses to a single line once every rung is met.
- Project Settings gains a **Direction** tab: what the project is for, in the file every agent already receives as part of its system prompt and the Planner drafts against. The file has been read since it was written and seeded from the README on first open; until now nothing in the app could edit it.
- The daily autonomy budget is now its own box in the sidebar, beside the Planner's and the fleet's rather than inside either — because one number bounds them both. Clicking it opens an editor with an explicit Save, so the ceiling can no longer be changed or cleared by focus merely passing through a field.

### Fixes

- The Planner and the fleet now say whose switches they are. Both are portfolio-wide — `Groom the backlog` and `Run work unattended` arm every project, not the one whose window you happen to be in — and neither said so; the Autopilot tab, the one per-project surface, now names its project in the same place. Turning grooming on from inside one repo had been arming it for all of them with nothing on screen to say so.
- The home workspace is no longer pinned open. It opens on a first run and whenever there is nothing else to open, instead of being inserted ahead of your projects on every launch and sitting in the tab bar, the fleet's board and the Planner's roster as an empty project with a queue, a priority and a consent switch. Reopen it from the + menu beside the project tabs.
- Setup no longer lists GitHub as required — nothing in the core loop needs it, and a fresh install looked broken to anyone who hadn't run `gh auth login`. It sits under Optional with a note about what it is for. The Jira check, which ran on every launch and was never displayed anywhere, is gone.
- Section headings in the Planner and the fleet no longer wear icons that look like buttons: a heading is a label, so it takes a glyph naming its subject and shows it in the quieter tint, while `power`, `pause` and the like are left to the switches and buttons that actually do something. "Fleet state" was headed with the same pause symbol as the Pause fleet button an inch below it.
- The Planner and the fleet now read as two views of one machine: same title bar with its state pill, same icon-and-title section headings, and the same order — state, then what it did, then the projects. The Planner's drawer no longer draws a bordered card that repeated its own name under the drawer's, and the fleet's state is no longer split either side of its history.

## 0.3.4 — 2026-08-19

### Added

- A project can now hold a set of protected paths: a run whose diff changes one, for an item that didn't declare it with `touches:` on its backlog line, is stopped before review instead of reaching a reviewer who has to remember the rule. Set them in the Autopilot tab; empty by default, and a config reset leaves them alone.

- "Coordinator" now means exactly one thing — the portfolio agent that grooms and knows. The per-project "Coordinator" picker in the Autopilot tab is gone (grooming always uses the built-in persona it already used everywhere), along with the retired run-supervisor's leftover documentation; the API tolerates and ignores the old field so existing callers keep working.

- The start screen leads with the Coordinator: its panel sits at the top of a top-aligned column instead of floating mid-screen below the approval strip, so the whole surface fits without scrolling on a laptop display.
- The fleet drawer's header now carries the same capsule the Coordinator's does — green "On — unattended" when the scheduler takes work, orange "paused" while the fleet is held, grey "manual" when every start is a person's.
- Every open project now appears exactly once: the fleet drawer's board is one table — priority (editable in place), the autonomous-work switch, what the project is running (click through to the item), and its queue — replacing the three lists that each repeated the projects for one facet, including the Coordinator panel's.
- A project whose backlog lives on the shared branch no longer reads "No backlog file — nothing to groom into" in the Coordinator's rows: the summary loader now checks the branch checkout between the project-local file and the vault, the same order the backlog itself resolves in.
- The fleet runs and the Coordinator knows: the fleet drawer now holds the Run work unattended switch with its arming confirm, the Daily autonomy budget, a consent roster of every open project's Include-in-autonomous-work switch, and the autonomous-starts history — while the Coordinator panel keeps grooming and awareness.
- A chat agent can now be granted "Operator Tools" in its settings (off by default): its environment then carries a scoped control-API token good for everything the operator's own terminal session can do — tweak configs, start runs, read the fleet's state — except resolving a human gate, which stays a person's call.

### Fixes

- The portfolio agent is now the **Planner** everywhere you read it — panel, drawer, sidebar box, autonomy ladder and help text — because after the chat and advisory retirements it grooms the plan and reports on it, coordinating nothing. Machine names are untouched: the `/v1/coordinator/*` API paths, stored keys and ledgers keep their spelling, the way `quiesce` did when the app started saying "Pause fleet".
- Advisory mode retired: the grooming switch is the whole choice — on files drafts that clear both gates within the shared daily ceiling, off doesn't. The mode picker, the Awaiting review inbox and its badge are gone, the scheduler starts or holds instead of proposing, the autonomy ladder is five rungs with grooming as one, and the proposals API endpoints answer 410 with a note while stored modes and a `mode` field on the refill PUT are tolerated and ignored.
- The Coordinator no longer carries its own chat: the "Discuss priorities…" conversation is gone from its drawer. Steering lives with a team agent granted Operator Tools, which reads the same fleet state, keeps its memory between conversations, and can apply what you decide.
- The fleet drawer's Daily autonomy budget field no longer clears the portfolio ceiling when focus leaves it before the field has ever shown the stored value, or when focus simply passes through without an edit — only a field that has synced and was then actually changed commits on blur.

## 0.3.3 — 2026-08-15

### Added

- The sidebar's fleet box now opens a drawer listing every open project — what each is running, as an item you can click through to, whether its queue is held by the pause and how much it is holding back — with the same Pause and Resume controls; the box itself stays the compact state line.
- `GET /v1/autopilot` now reports `sessionSpendUSD`, what the session has spent so far — the figure the session cost cap is measured against, which a headless driver could not get from any single run's cost.
- One ceiling per scope: the portfolio's daily budget now bounds grooming and unattended running together — grooming draws from the same daily ledger, the separate grooming budget field is gone (a stored one migrates into the shared number rather than vanishing), and the panel's one field says what it bounds. In a project's Autopilot tab the daily budget is the headline and the per-item cap, session cap and cost margin sit under Advanced with unchanged behavior.
- The Coordinator panel now opens the autonomy ladder: six rungs from "use it by hand" to "ships unattended", each ticked with the facts that meet it — and the first unmet rung says, in its gate's own words, exactly which control advances it.
- Autonomy is now off until armed deliberately, and arming shows what it will do: switching on grooming or unattended running is refused — in the panel and over the API, in the same words — until the matching daily budget exists, a project joins autonomous work only by its own new "Include in autonomous work" setting (off by default, cleared by a config reset; pressing Run yourself never asks), and the unattended-work switch now confirms with the opted-in projects, their next runnable items in queue order, and the ceiling it will run under. A fresh install runs nothing.

### Fixes

- An item's run totals now warn that they are a floor whenever a run is missing a cost *or* a duration, and name which figure went missing, instead of staying silent for a run that recorded one and not the other and leaving the spend on the page quietly short.
- `kiteloop-verify.py --marathon` now ends the night on a spent daily budget and names the ceiling that stopped it, instead of posting a doomed run for every remaining ready item and finishing with a line blaming those items.
- A run asked for over a spent session cost cap is now refused on the spot, naming the cap and what the session has spent, instead of being accepted and answered as a run that is spinning up — a queue held before its first item began looked exactly like one that was simply slow to start.
- A run in the Autopilot panel's History now names the item it ran instead of reading "1 items", and clicking the row opens that item's page; a run that covered several names the first plus how many more, and the chevron still opens the run's own detail.
- The fleet-wide safe-stop is now called Pause fleet instead of Quiesce, and says where it is in plain words — "pausing — 2 run(s) finishing", then "paused — all quiet" — with the quit dialog offering to pause the fleet and quit once it's quiet.
- The session cost cap now bounds the whole sitting rather than one item: the Autopilot panel's Session figure adds up every run since the app started instead of starting again at each one, and resuming a queue the cap paused is what opens a fresh session budget.
- A workflow node that runs past the turn or time limit its workflow declares now ends the run, which records which limit stopped it — those limits were declared and checked by nothing, leaving only the stall watchdog and the cost cap to stop a node that kept going.
- Repeated failed autonomous runs now hold only the project they happened in, and the hold lifts by itself once that project's queue changes — an item re-groomed or filed, a dependency finishing, the failing item retired — instead of stopping every project's runs until someone cleared it by hand; runs that never got past the pickup gate no longer count towards one at all, and the sidebar's red "runs halted" line now says which project and why, and offers a Resume runs control beside it. `GET /health` lists any active holds.
- A suite run that died before its tests finished now records that it measured nothing, instead of taking an inner suite's count — seven tests passing in a hundredth of a second — as the whole run's tally.
- A suite run whose tests failed without printing a per-case line now records which tests were red, read from xcodebuild's own trailing `Failing tests:` block, instead of a dash that sent you back to a four-minute re-run to find out.
- `run-unit-suite.sh --last` now reads whether an earlier run at the same commit was red from its recorded exit status rather than from the ✔/✘ on its tally, so a red run whose tally carries no glyph is counted in the comparison instead of being passed over and leaving the commit reading as simply green.
- `run-unit-suite.sh --last` now says outright when the run it is reporting matched no tests and measured nothing, instead of reading exactly like a green run because the `exit 0` beside that empty tally is xcodebuild's own.

## 0.3.2 — 2026-08-13

### Added

- An item now opens as a full page with a Back control instead of a floating sheet, and carries a Runs section: every run it has had, newest first, with when it started, how long it took, what it cost, how it ended, the recorded reason when it did not pass, its branch and its quality score — plus attempts, total spend and total run time above them. An item that has never run says so.
- An item is reachable from everywhere it is named: clicking a line in the Autopilot panel's run history — a failed one included, whose reason used to exist only in `control-runs.jsonl` — opens that item's page, as does clicking a queued item or picking Open Item… from a queue row.
- Item names elsewhere in the app now open the item's page too — the run in flight in the Execution box, an autonomous start in the Coordinator drawer, an approval notice in your notifications, the menu bar's running item, and the start screen's approval strip, which now names the items waiting for you instead of only counting them; the project is switched to, or opened, to land on the page, and a name whose item has left the backlog says so rather than doing nothing.
- The sidebar footer now has a fleet-wide Quiesce control beside the Coordinator box: it holds every open project's queue and refuses new runs, shows whether the fleet has drained and which projects are still finishing, and turns into Resume to lift the hold — what previously took a `POST /v1/fleet/quiesce` against the control API.
- The Coordinator drawer now shows the runs the app started by itself — newest first, with when, which project and item, why it chose them, the day's budget at the time and how each ended, including why a start that never reached the autopilot was refused — above a standing line saying what the scheduler is doing right now, or which hold is stopping it.
- Quitting with runs still in flight now names them and offers to quiesce and quit once they have drained, so the work finishes at its own gate instead of being interrupted and re-run from scratch; Quit Now still quits immediately.
- A run being driven headlessly can now be handed an operator note for its worker — the steering that until now meant clicking in the Autopilot tab, so a run going the wrong way no longer has to be either abandoned or left to burn its budget; the note is advice, reaches only the worker, and is recorded in the run log and the item's Notes just as one typed in the app is.
- A project can now approve review-passed runs without asking — a new run setting, off by default, that stops an unattended night stalling at the approval gate with everything waiting for you; a rejected or blocked run, and an item whose auto-merge failed, still wait, and every automatic approval is recorded as automatic in the run record and the item's Notes.

### Fixes

- An agent hired into a project that is already open is now triggered by the events it subscribes to straight away, instead of being subscribed to nothing until the app is restarted; an agent you remove stops being triggered the moment it leaves.
- A note that cannot reach an item's detail file — a rejection reason, a retirement note, an explanation of why an item went back to Ready — now says so, as an error notification naming the file and a line in Diagnostics, instead of vanishing and leaving the next run with nothing.
- A store problem found before any project is open — an unreadable settings file, an agent package that will not decode — now waits and lands in your notifications as soon as a project opens, instead of being a Diagnostics line and nothing else.
- A settings file Kiteloop cannot decode is now moved aside to `global-config.json.unreadable-<timestamp>` and reported — an error notification naming both paths, and a line in Diagnostics — instead of being read as no settings at all and overwritten by the next change you make.
- An agent package whose `agent.json` cannot be read or decoded now says so — an error notification naming the file and the error, and a line in Diagnostics beside it — instead of the agent simply never appearing in the roster; the rest of the packages still load, and a folder that has no `agent.json` at all stays silent.
- Grooming no longer refuses an item for citing a file the app itself writes at run time — the settings file, the day's spend file, the agent catalog, the run-record log — which no checkout holds.
- Grooming no longer refuses an item for naming the method it proposes to implement or override.
- Grooming no longer refuses an item for reusing a name it introduced, so a draft can say in its Validation what the thing it proposes has to do.

## 0.3.1 — 2026-08-13

### Added

- An item's detail view now shows the Definition-of-Ready verdict clause by clause — the detail file and its sections, the `verify:` command, the size, what the item is waiting for — so an item autopilot will skip at pickup no longer looks exactly like one it will run.
- With a project open, the Autopilot panel's queue now says how many of its ready items could actually start and what is holding the rest — the reading that until now existed only on the start screen.
- An empty main surface now says what fills it, naming the control that does: the agent roster, a chat with no messages, a backlog with no epics, the portfolio grid, an agent's memory and the notification list no longer open on a bare title or blank space.

### Fixes

- A setting that could not be saved now says so — an error notification naming the file and what the write failed with, and a line in Diagnostics beside it — instead of reverting on the next launch with nothing anywhere to explain it; a store failing every save keeps one row rather than filling the feed.

## 0.3.0 — 2026-08-12

### Added

- Autopilot's worker and reviewer now start each item holding what the project has learned from previous runs, so a lesson already written down is no longer re-learned at run cost; the run log says how many bullets went over.
- Each project on the start screen now says how many of its ready items could actually start and what is holding the rest, so a queue full of work nothing can pick up no longer reads as a healthy one.
- The sidebar footer now reads out how close the coordinator is to the ceiling that would stop it grooming — the nearer of its daily spend and pass caps, and the reason when grooming has already stopped.
- Kiteloop can now be handed to someone who doesn't build Xcode projects: `scripts/make-release.sh` turns a version into a signed, notarized, universal zip, and a `v*` tag publishes it as a GitHub Release.
- An agent's memory is now a capped index of one line per fact, with each fact's full text kept as a topic it reads back on demand.
- The Memory tab now shows both tiers — the index that goes into every prompt, and the topic bodies behind it.
- A librarian pass in the Memory tab now reads every agent's memory and proposes merging duplicates, deleting facts the code contradicts and archiving stale ones; it applies nothing, each proposal is approved or rejected as usual, and a tidy corpus reports "nothing to consolidate".
- The Coordinator's corner of the sidebar footer is now a visibly bounded box, so its badge, budget line and stall notice read as the Coordinator's state rather than blending into the project settings and version lines beside them.
- A team can now share a backlog through the repo's own remote without ever committing it to the code: the backlog lives on a `kiteloop/backlog` orphan branch (the gh-pages pattern), Kiteloop keeps a private checkout under `.kiteloop/backlog-tree/`, and a teammate who clones the repo and opens the project gets the backlog automatically. Every backlog change becomes a commit on that branch — history for free — with pushes rate-limited and a diverged branch left loudly for a human rather than merged by guesswork. Created from the Backlog tab's empty state; design and limits in docs/backlog-branch.md.
- Project Settings moved to where its scope is: a row in the sidebar's project section and a right-click menu on the project tab (which also gained Close Project). It leaves the footer to the Coordinator box and the version line — everything down there is now portfolio-global.
- The coordinator now learns from its rejections instead of repeating them. When a machine check refuses a draft, the reason goes into the next drafting attempt as a correction; and after three passes in a row that produce nothing runnable for a project, grooming for that project holds instead of trying a fourth time — the pass history says so, and it resumes the moment you engage (approve or dismiss one of its drafts, or groom it by hand, which always overrides the hold). One project spent 78 refusals in a night re-making the same mistakes; that night now costs three passes and a note asking for your judgment. The box also answers the standing questions at a glance: a mode chip (Advisory / Bounded / Off), when the next grooming look is due (a pass running now, or — once a daily ceiling has hit — that grooming resumes tomorrow and why, instead of promising a look that isn't coming), the day's tally of items filed and merged with the pass count against its daily cap, and — only while it's true — a red line saying autonomous runs are halted by the circuit breaker.

### Fixes

- A file attached to an agent running on Ollama or Copilot now reaches the model as text under its filename, and one the model cannot read — an image, or a file that isn't text — is named in the prompt as not sent, instead of both vanishing between the transcript and the request.
- Scanning for specialists now finds the agents in projects set up through the setup wizard, which used to come back empty however fully their team was configured.
- Naming the same specialist twice in one message now summons it once, instead of opening two tabs or running the same consult twice.
- A run waiting on a pre-review check that never answers is now ended by the stall watchdog like any other hang, instead of polling for ever and leaving the item stuck as active.
- Naming an untitled session no longer leaves a `claude` process and its pipes running for the rest of the app's life when the model answers at length, and gives up after a minute rather than waiting forever on a child that never finishes.
- A run whose distilled learnings could not be saved to the project's knowledge file no longer announces them as learned; the failure is logged and no `learned` count is published for a file that did not change.
- A project whose backlog is nothing but ungroomed drafts now says how many are waiting to be groomed, instead of reading exactly like a project whose queue is finished.
- A project whose only work is sitting on the reviewer or blocked now says how much of each, instead of reading exactly like a project whose queue is finished.
- The queue depth on `GET /v1/projects` now counts items under review and items that are blocked, so a project whose work is in flight or stuck no longer answers exactly like one whose queue has drained.
- A line of the autonomous start log the app cannot read back now survives the launch that skipped it, instead of being erased by that launch's own compaction, and the log says how many such lines it found.
- A notification the app could not read back — the half-written remnant of an unclean shutdown — now survives resolving, dismissing and clearing the feed instead of being deleted by the first of them, and a rewrite that fails leaves the notifications that were on disk rather than an empty file.
- The row a finished suite run appends now lands on a line of its own even when the record file's last line lost its newline, instead of being glued onto it — where `--last` read the older row's cells and reported the run before it as the last one taken.
- A metrics index that cannot write its schema stamp now says so in the log and is discarded and rebuilt, instead of silently dropping and replaying every table on that launch and on every launch after it.
- The project context written when a project is first opened now cuts a long README on a whole word and says which file the rest is in, and its Structure listing says how many root entries it left out — instead of stopping mid-word and mid-list with nothing to mark it.
- A librarian pass whose record of itself never reached disk now says so among its notes, instead of reporting success while the Memory tab keeps offering the same pass; the record is also written durably, so an unclean shutdown no longer leaves a truncated one that reads as never having run.
- An aged-out run transcript now keeps its records when the marker that would stand in for them cannot be written, and the sweep says how many runs it had to leave alone — instead of losing both and afterwards reading as a run that never recorded anything.
- A run's note now lands under a detail file's real `## Notes` heading, instead of being wedged into the middle of a heading like `## Notes for the reviewer` or into a mention of one in prose — where nothing read it back, so the same note was written again at every pickup.
- One coordinator grooming pass now tops up every project whose queue has run dry, emptiest first, instead of one project per pass — so a fleet no longer starves because each project's turn came round only every few passes — and how empty is empty, how full is full enough and how much of the fleet a pass serves can now be set through the control API.
- An agent that recalls a memory topic the way its own prompt tells it to — `recall_knowledge` with a `topic` — is now answered in chat as well, instead of being refused there and losing access to its memory for that turn.
- A memory proposal whose file never reached disk now says so — the agent that proposed it is told it was not recorded, a librarian pass names it among its notes, and an approval whose status could not be saved reports the write error instead of reading as approved.
- Rejecting a memory proposal whose status could not be saved now reports the write error, instead of leaving the card in the pending list with no word about why.
- Approving a merge that names the same fact twice no longer leaves the memory index without the fact it just recorded, or without an unrelated one beside it; a merge that really names one fact is refused, and a librarian proposing one now files nothing and says why.
- A coordinator grooming pass that stops answering is now ended at a deadline rather than blocking every later pass until the app is restarted; the sidebar footer says grooming has stalled, the pass history records how long it ran and what it was doing, and switching the loop off and on clears one by hand.
- The sidebar footer and the control API now report how many grooming passes were ended at their deadline today, so a night that hung repeatedly and recovered every time no longer reads exactly like one that never hung.
- A librarian pass now finds its proposals even when the reply wraps them in prose containing a brace, instead of reporting nothing from a pass that ran in full.
- A librarian pass whose model call fails now says so and leaves the memory as unconsolidated as it found it, instead of counting as a pass and hiding the Memory tab's "due" badge for a week.
- Saving the Project Context now says when the write failed and keeps the edit, instead of clearing the Save button and showing text that never reached disk.
- An agent whose `save_knowledge` update to an existing entry could not be written is now told so, with the entry named, instead of being answered "Updated existing entry" for knowledge that never reached disk.
- A new memory fact or coordinator learning now counts as a restatement of an existing one only when it repeats it as whole words, so an unrelated fact no longer takes a short one's place, or goes unrecorded itself, because those letters happen to sit inside a longer word.
- Recalling memory now hands back at most five topics — the ones matching the whole query first — and says how many further ones matched, instead of answering a common word with the agent's entire memory store.
- Recalling knowledge now hands back at most five sections and says how many further ones matched, instead of answering a broad query with the agent's entire knowledge package.
- Recalling knowledge now reads a query's punctuation the way the memory half of the same call already does, so a question mark or comma no longer costs an agent the sections that answer it.
- Autopilot's worker and reviewer no longer keep Claude Code's own memory directory, so one run's half-verified belief can no longer become the reviewer's prior on the next; chatting with an agent is unaffected.
- The published API now declares the coordinator refill loop's pass ceiling, and setting it is echoed back, so raising the daily budget is no longer the only ceiling an operator can see.
- The Workflows tab and its custom pipeline builder are gone from the sidebar; autopilot runs are unaffected.
- The Group Thread is gone from the sidebar; per-agent chats and the messages agents send each other are unaffected.
- The Evals console is gone from the sidebar; the quality score every run is judged on is unaffected.
- The Coordinator is now two surfaces rather than three: its sidebar tab is gone, and reviewing what advisory mode drafted — reading a proposal, approving or dismissing it — moved into the Coordinator drawer, alongside the portfolio panel on the start screen. Nothing about what the Coordinator does changed.
- The Coordinator drawer now opens on the left, beside the sidebar button that opens it, so opening it and the Inspector together squeezes the centre column from both sides rather than twice from the right.
- Grooming no longer refuses an item whose `verify:` starts a command with the shell's `!` negation, or one that cites a directory whose contents the source index skips.
- An agent's memory no longer grows into its prompt without limit: an approved write past the index cap is refused with a reason naming the fact to supersede, and the proposal stays pending so it can be edited and approved again.
- A memory file written before the index existed is now split into the two tiers the first time it is read, with the original kept beside it.
- A run now keeps following its pull request when `gh` prints anything after the check list — an upgrade notice, say — or enough bracketed advice before it, instead of ending the follow saying the checks could not be read.
- A run with pull-request publishing on now says in the log and the item's Notes that it opened none because the run left no branch to open one from, instead of reaching the approval gate in silence and reading exactly like a run with the setting off.
- An agent's workspace now lists only the knowledge files and shared references it actually holds, so an agent no longer spends a turn reading a path that was never linked; each file left out is named once in the log.
- Kiteloop no longer hangs on a command that writes a lot of output: detecting the Claude version, resolving `claude` and `node`, reading a repository's size and the setup wizard's AWS and GitHub checks all keep answering however chatty the command they run.
- An item whose isolated worktree could not be created now says what git refused with, rather than only naming the item, and a chatty checkout hook can no longer leave setup or teardown waiting on git forever.
- The stranded-work report now says "1 commit exists only there" rather than "1 commit exist only there".

## 0.2.2 — 2026-08-11

### Added

- A suite run that did not come back clean now keeps its full output, and the readout says where.
- A suite record now says how long the run took, and the readout prints it.
- `kiteloop-verify.py`'s smoke checks now report what the suite record last measured and how far HEAD has moved since, and fail when the newest recorded run was red.

### Fixes

- An item autopilot skipped because of its status now leaves the same trail as every other skip — a structured log row naming the item and the status it had, and its id in the reason a start records when nothing was runnable, instead of only a count.
- Editing a `team.json` written in the package-ref format outside the app now adds or removes the agent in the running project, instead of taking effect only at the next open.
- A project whose `team.json` is present but won't decode now reports the broken file instead of silently opening with the predefined agents as if no team had ever been configured, and both writers of that file now commit it to disk so an unclean shutdown can't truncate it in the first place.
- A ledger line written just before an unclean shutdown now survives, so a run that finished and merged no longer reads as interrupted at the next launch.
- A red suite record now says how many tests failed as well as how many failures were reported, so its tally no longer reads as disagreeing with the failing tests named beside it.
- `kiteloop-verify.py`'s suite-record check now says how many files are uncommitted under `Kiteloop/` or `scripts/`, so a checkout with modified source no longer reads exactly like one nobody has touched.
- `kiteloop-verify.py`'s suite-record check now says when the last measurement was itself taken on an uncommitted tree, so a run whose commit does not identify what it measured no longer reads like one that does.
- `kiteloop-verify.py`'s suite-record check now says when the same commit was recorded red earlier, and names those tests, so a suite that only went green on a retry no longer reads as simply green.
- `kiteloop-verify.py`'s suite-record check now fails when the newest run recorded no test tally, so a run that matched no tests no longer reads as a green suite.
- `kiteloop-verify.py`'s suite-record check now names the tests the last run skipped, so a green record says which coverage opted out rather than only how much.
- `kiteloop-verify.py`'s suite-record check now resolves the record's cells from the table's own header, so adding a column to the suite record no longer makes it report the cell next door.
- `kiteloop-verify.py`'s suite-record check now says how much of the drift since the last measurement touched `Kiteloop/` or `scripts/`, so backlog and docs commits no longer read as staleness in a suite reading.
- Two open projects whose folders share a name now keep separate blocked-triage retry ceilings and separate proposals, and an approved one is carried out against the project it was proposed for.
- A blocked-triage pass that read only part of the blocked pile now says how many items it did not read, instead of reporting a partial pass as a finished one.
- Blocked triage no longer returns an item to ready while it is still waiting on an item that isn't done — it leaves it blocked and names the dependency.
- A merge-gate verify killed by its timeout now says so — naming the seconds it waited — instead of reading like a build that failed.
- A workflow checkpoint saved just before an unclean shutdown now survives, so a resume finds either the previous checkpoint or the new one rather than nothing.
- Scratch files left behind by a crash before a restart are now cleaned up at launch, instead of being kept for ever because another process had taken over their process id.
- The control API token and the provider API keys are now created readable only by you, instead of landing world-readable for the moment before their permissions were tightened.
- A run recorded after the app was killed mid-write now keeps its history entry, instead of being glued onto the half-written line and lost.
- A task metric recorded after the app was killed mid-write now survives too, so the cost and retry history it feeds is no longer short a run after every unclean shutdown.
- A grooming release, a spend entry, a pending notification and an activity event written after the app was killed mid-write now survive as well, instead of being glued onto the half-written line and lost.
- The first entry written to a fresh history file now survives an unclean shutdown, and one written before its folder exists is no longer dropped in silence.
- A grooming filing, a blocked-item triage, an unattended run, a confirmed Coordinator action, a turn's trace span and a run transcript written after the app was killed mid-write now survive too, instead of being glued onto the half-written line and lost.
- The console's Activity tab no longer misses events published in the moment it opens.
- Closing a project tab now releases its knowledge-directory watcher, so a long session of opening and closing projects no longer runs the app out of file descriptors.
- Closing or switching a project no longer closes a file the app is still using: the team.json watcher released its descriptor twice, and whatever had been handed that number in between was shut under it.
- An event handed to a live subscriber is now recorded as delivered, so an agent that reconnects is no longer replayed events it has already seen.
- A project's event log now keeps 30 days rather than growing for ever, so an install left running for months stops carrying every event it ever published.
- The suite runner's `--help` now prints its whole header block, wherever that block ends, instead of a fixed range of lines.
- `kiteloop-verify.py` now refuses an approval flag passed to the mode that cannot act on it, instead of driving a whole run and dropping it.
- An overnight `--marathon --auto-approve` now reports the items whose approval never landed, instead of throwing the answer away.
- A `claudePath` or `nodePath` set in global-config.json is now the binary the app spawns and the path Settings reports.
- The whole fleet can now be held for a restart in one call, which waits and reports when the last run has finished.
- A hook on Message Forwarded now actually runs.
- With worktree isolation on, a run now writes only inside its worktree — nothing can move its agents back to your checkout mid-item, and an item that cannot be isolated is blocked instead of quietly building into your tree.
- A run whose work landed in your checkout instead of its branch is now blocked and names the files, rather than reaching the approval gate looking finished.
- Approving no longer marks an item done when its branch holds nothing and your checkout has uncommitted changes; it says the work is not where it should be and leaves the item at the gate.
- Stamping a template whose `needs:` names an item nothing in the backlog has now files a runnable item and writes down what it dropped, instead of one the queue withholds at every pass for ever.

## 0.2.1 — 2026-08-11

### Added

- The done-and-unmerged sweep now also finds the items whose branch is gone.
- `GET /v1/projects` now says what each project has left to run, not just what it is running.
- `GET /v1/backlog` now names the items marked done whose work never got merged.
- The suite readout now says when the tree has changes nobody has committed.
- A suite record now names the tests that skipped, not just how many.
- The suite readout now says when a commit was measured twice and the answers disagreed.
- The suite's drift line now says how much of the drift could have changed the answer.
- A recurring process can now be written down and stamped out.
- A groomed item can now be filed behind another one.
- What a run's opening context costs is now measured.

### Fixes

- A shell hook that prints a lot is no longer killed and written down as having timed out.
- A square bracket in the assistant's prose no longer costs an AI backlog edit its whole proposal.
- One malformed change in an AI backlog edit no longer throws away all the others.
- An item detail view no longer offers Run on an item autopilot will refuse to pick up.
- Asking AI to edit the backlog no longer quietly drops the changes it couldn't read.
- A coordinator proposal whose id is already in the backlog is no longer offered for ever.
- A grooming pass no longer files fewer items than it drafted without saying so.
- A suite record no longer calls the tree dirty over an edit that cannot change what a test reports.
- A smoke run that checked no backlog item no longer reports a clean bill of health.
- A repo the verify harness could not read no longer passes its isolation checks.
- An item whose branch was dropped over real work no longer reads as an item that produced nothing.
- A backlog nobody could read no longer reports as a drained queue.
- A control server that stops answering mid-run is no longer scored as an SLO #1 rescue.
- The guard that keeps the test suite from killing a running Kiteloop no longer fails open.
- Resuming a workflow now picks up from the checkpoint that was actually written last.
- An escaped defect is now counted even if the app was closed when it came back.
- The portfolio's "All projects" row now does portfolio arithmetic.
- An item's cost ceiling is no longer set by another project's runs.
- A metrics line the app can't read is no longer dropped in silence.
- A groomed verify command is now the one that runs.
- Proposals waiting on you now survive a restart.
- A drafted item no longer waits for something that was never written.
- A drafted item can no longer break the backlog file it is filed into.
- A drafted title is no longer quietly cut short.
- Approving a proposal no longer points at a source the API rejects.
- A draft the coordinator parks now says which gate refused it.
- A run record the app can't read is no longer deleted for being unreadable.
- An item that says it will *ship* a file is no longer refused for citing it.
- An item that cites a media type or a schemeless host is no longer refused as citing a file that isn't there.
- A detail file whose Validation criteria are written as ordinary bullets is no longer treated as having none.
- The backlog API now reports the lines it couldn't read, not just the items it could.
- A backlog line Kiteloop can't read is no longer deleted by the next write.
- A backlog line's unrecognised field is now reported instead of dropped in silence.
- A backlog line whose `size:` Kiteloop can't read now says so.
- `kiteloop-verify.py` now reports it when the app refuses the guardrails it was asked to set.
- `kiteloop-verify.py` no longer accepts a flag that shapes a run when there is no run to shape.
- `kiteloop-verify.py --run` now applies the guardrail flags it was handed.
- The portfolio report no longer says nothing merged, on every night it has ever been asked about.
- The recommended `cd` for a `verify:` no longer switches the grounding check off for the rest of the command.
- A drafted `verify:` written with a spaced pipe no longer files as ready and merges on half a command.
- How fast an emptied queue refills is now the operator's to choose.
- A restart no longer costs an overnight marathon twenty minutes an item and a false SLO violation.
- A suite run that executed nothing no longer exits green.
- A green suite row now says how many tests skipped themselves.
- A `verify:` command that points at a path it will never find is now refused before the run, not after it.
- One unstartable item no longer ends a marathon with the rest of the queue unrun.
- A verify map that checks nothing now says so in the run log.
- `kiteloop-verify.py --json` now emits JSON a program can actually read.
- A run that ends without its workflow ending no longer wedges the project until the app is restarted.
- An unclean shutdown no longer risks emptying the run history or the grooming ledger.
- A knowledge search no longer takes the app down when the index's saved vectors have gone missing or been truncated.

## 0.2.0 — 2026-08-10

### Fixes

- The merge gate no longer drops a long command as a duplicate of a different one.
- A finished prerequisite now actually releases the item waiting on it.
- A made-up symbol can no longer ground itself.
- Starting a run no longer reports it as never started.
- The verify-coverage gate now says when it couldn't check a run.
- The coordinator's daily grooming budget now bounds grooming.
- A finished run's record now reports the run it names, not a later attempt at the same item.
- A grooming pass now sees the whole backlog it must not duplicate.
- A grooming pass no longer quietly files fewer items than it was asked for.
- The Execution panel no longer reports delivered work as wasted spend.
- Releasing an item now survives a restart.
- A run you start from the Autopilot tab is now part of the run history.
- Notes you write below the coordinator's auto section are no longer erased.
- A cost overrun no longer reads as an aborted item in the run log.
- Coordinator learnings are no longer cut mid-word.
- A half-written coordinator learning can be corrected.
- A project tab keeps its spinner for the whole run.
- A run whose branch was dropped over real work is no longer filed as having produced nothing.
- A judge or coordinator reply that quotes code is read correctly again.

### One place to see what happened to a backlog item

- An item's history is now readable in one view
- Where a ledger and git disagree, both are shown.
- The actions the item's state permits are offered from the same view

### Run history keeps its 30-day bound in an app that never restarts

- Records older than 30 days now age out while Kiteloop is running

### The run listing says how long a run took and how it was judged

- `GET /v1/runs` now carries `durationSec` and the quality judge's verdict on a finished run.

### The half of the quality SLO nobody could read now has a number

- `GET /v1/metrics` reports the first-pass rate.

### An unattended run can be joined to its transcript again

- A run now reports the workflow execution it turned out to be, and remembers it.

### A reviewer can raise a nit without rejecting the run over it

- Reviews now carry findings, each marked `blocking` or `advisory`.

### Asking what's running no longer drags every project's history with it

- The run listing takes `?project=` and `?limit=`, like the other history endpoints.

### An unattended run follows its pull request until CI is green

- You are called to the pull request when it's green, not when it's open.

### Closing a project tab no longer rewrites its finished runs as interrupted

- A run that finished stays finished, even if you close the project after it.

### A run in flight can be steered instead of only watched

- You can hand a working agent a note without killing its run.

### A night of unattended work is now readable from the run surfaces

- The list of recent autonomous starts survives a restart.
- A run the Coordinator started on its own leaves a run record.

### The web pane no longer says a page stayed put when it moved

- A fast navigation is seen.

### An agent's tool list now bounds what it can reach

- A profile that lists four tools gets four tools.

### The control API no longer reads `1` and `0` as `true` and `false`

- A number sent where the API documents a boolean is now a 400, not a silent yes.
- The same fix covers every boolean the API takes
- A rejected body now changes nothing.

### The portfolio report is on the control API

- `GET /v1/report` answers what a period of unattended work produced.
- Every merge rate names its basis.

### A run id keeps answering after the app restarts

- Control-API run records now survive a restart.
- A run the app died under reads `interrupted`, not `finished`.

### The merge gate can no longer be weaker than the item's own verify

- A project's merge-verify command is now run *in addition to* the item's own `verify:`, not instead of it.
- A refused merge names the command that refused it

### Worktree teardown now really removes the DerivedData a run left behind

- Tearing down a worktree run again deletes the build output it minted in `~/Library/Developer/Xcode/DerivedData`.

### A run driven headlessly now shows what it is costing

- `GET /v1/runs` and a run's result now carry what the run has spent, the ceiling it is measured against, and where that ceiling came from.
- A cost nobody could attribute is reported as missing, not as `$0`.

### A finished run can open its own pull request

- Autopilot can now push a finished item's branch and open a GitHub pull request for it
- It opens the pull request and stops there.
- A missing prerequisite costs the pull request, not the run.

### Kiteloop now tells you when it is waiting on you

- A run parked at Awaiting Approval, and an agent stopped on a question, now post a macOS notification.
- Only the two things that block you get a banner.
- One banner per gate.

### An Apply in the Coordinator conversation now means it can be applied

- A suggestion that offers to file a draft nobody proposed is drawn disabled, with the reason.
- A draft filed or dismissed elsewhere disables the offer to file it again.

### Each project can have its own daily budget

- A busy project no longer spends everybody else's allowance.
- Both ceilings apply, and a refusal says which one stopped the run.
- Spend is attributed to the project that incurred it
- The Coordinator passes over a project that has spent its budget
- Neither ceiling refuses a run you start yourself.

### Both daily budgets can be set without the app open

- The portfolio budget is settable over the control API.
- A project's own budget reads and writes through `/v1/autopilot`
- A budget that can't be read is refused, not rounded down to "no ceiling".

### A review written as prose no longer ends the run

- An unreadable verdict is asked about once, instead of ending the item.
- "The reviewer found problems" and "nobody could read the verdict" are no longer the same outcome.
- This was the most expensive failure of the run.

### A refused merge now tells you why it failed

- The verify output survives the rollback.
- "Reject with this failure"

### A stray untracked file no longer blocks every approval

- One file nobody put there could stop the whole project merging.

### An item that mentions a URL is no longer refused for it

- A web address was being read as a file path.

### The Autopilot panel no longer starts a quarter of the way down the window

- A run in flight could push the whole panel down.
- The header is now always one row tall

### The web preview's navigation gate was never being asked

- A page could navigate the preview pane anywhere, in either mode, and nothing stopped it.
- The approval prompt now appears again
- Trusted mode is an invariant again

### Triage no longer unblocks an item the queue cannot start

- A retried or regroomed item used to go back to `ready` without anyone asking whether it could be picked up.
- Triage now checks the item against the same Definition-of-Ready the pickup gate applies.
- Nothing is groomed on your behalf

### Approving an item now delivers the work

- Approving used to mark an item done without merging anything.
- It now merges on the same terms as the automatic path
- A merge that fails leaves the item at the gate
- When there is nothing to merge, or auto-merge is switched off, it says so
- The Autopilot panel now has a "Waiting for you" section
- The panel and the API now share one implementation

### The interrupted-runs prompt now says which run it is asking about

- Every row used to read the same.
- Runs that cannot be resumed are no longer listed.
- Checkpoints are pruned.

### Rejecting an item without a reason no longer leaves an empty note behind

- A rejection with a blank reason used to append a dated `rejected:` line with nothing after it

### A project with no commits yet shows its real branch name

- The chat header used to read `HEAD` for a repository that has never been committed to

### The control API no longer reveals which routes exist to a caller with no token

- An unauthenticated request to any `/v1` path now answers 401
- `/health` still answers with no token

### The item being worked on is no longer offered as a pick

- The Autopilot panel stops listing the item in flight a second time.
- A finished run still releases its items.

### No review pass is spent on a run that changed nothing

- A run that produced nothing no longer reaches the reviewer.
- "Passed" can no longer be earned on an empty diff
- A run that can't be read still goes to review

### An agent that has changed nothing is told so, while it can still act

- The agent is asked git before it hands off.
- It either does the work, or says the item is already built.
- Asked once, not in a loop

### Items left mid-run no longer look stuck after a restart

- An item stranded as `active` is put back to `ready` at launch.
- The item says why it was reset
- Anything the interrupted run produced is left alone

### A run that commits its own work no longer loses it

- The branch survives when the agent committed for itself.
- A run that really changed nothing still tidies up after itself.
- The run log says which of the three happened.

### You can ask a project whether it is running anything

- "Is it stuck?" is now one call.
- The whole fleet answers at once.
- It cannot disagree with the thing that refuses your run.
- A project busy with nothing behind it says so.

### The grounding gate stops refusing items for citing real things

- An item that cites a file outside the repo is no longer turned away.
- It still catches the invention it exists for.
- A refusal now says why the token was checked at all.

### Run transcripts can be asked questions

- "Every no-work run this week, with what its worker said" is now one query.
- Nothing about it slows a run or risks losing a record.

### What a run did is now on disk, and says which run it was

- Each run keeps its own transcript.
- Every record names the run and the role that produced it.
- Transcripts are kept for seven days, then pruned — and a pruned one says so.
- The cost is bounded and known.
- The worker's last words are kept.

### Resume tells you what it did

- A resume that fails says so, and keeps its row.
- Errors during resume reach you.
- Workflows that already finished are no longer offered as resumable.

### A project can no longer be stuck "busy" with nothing running

- Busy now means a run exists.
- The refusal says what it thinks it is running.
- Opening a project clears a stale claim.
- Resume recovers a project instead of pretending to.
- An explicit run replaces a held queue rather than being refused by it

### A run that produced nothing no longer spends the day's budget

- A dead session costs $0.
- The stand-in is kept where it belongs.

### Correctly groomed items are no longer refused for how they quote things

- A package name is no longer looked up as a file.
- A word in capitals is no longer looked up as code.
- It still catches an invented name.

### An item autopilot has given up on can be brought back

- Re-grooming a retired item now actually revives it.
- Or release it by hand, without changing a word.
- The retirement note now describes something that can be done.

### A run that has ended now says so

- `activeRuns` can be trusted again as a concurrency signal.
- A run is closed on every way out, not just the successful one.
- A finished run can still say how it ended.

### Deleting the metrics database no longer takes metrics down until a restart

- The metrics index recovers from being deleted while the app is running.
- A row count taken straight after opening the index reported zero.

### The portfolio report can finally answer "was the grooming any good?"

- Every item the coordinator files is now written down as a filing.
- A filing is recorded as `ready` or `draft` by the status it was actually written at
- Only a filing that landed counts.

### A stalled run no longer buys an item another attempt

- A run that stalls without producing anything now counts against the retry ceiling.
- What a run left behind is now measured, not inferred.
- An outcome the app can't place is treated as unmeasured rather than productive

### Grooming records are readable over the control API

- `GET /v1/grooming` reports what was filed and what a pre-run check refused.
- Each record names the check that refused it and the clause that failed

### A refused auto-merge names the files that blocked it

- "Working tree not clean" now tells you which files are dirty.
- The run log and the merge phase-log row both carry the names

### The per-item cost cap now says what it actually does

- The tooltip you read before setting a per-item cap tells the truth.
- The session cap is now clearly the one that bounds the night.

### The control API token can be replaced without quitting the app

- Settings can now regenerate the local control API's bearer token.
- The new token works immediately and the old one stops working immediately.
- It says what it costs before it does it.

### The backlog listing says which items are actually runnable

- `GET /v1/backlog` now reports whether autopilot would pick each `ready` item up.
- Items in other statuses are untouched

### An item that produces nothing is stopped for good

- An item that comes back empty three times is not started a fourth.
- The count is read from the run history, so it survives a restart.
- Only empty attempts count.

### Observations are queryable

- A SQLite index over runs, turns, tokens and spend
- The JSONL logs remain the source of truth.

### An unknown @mention no longer swallows the message

- A message containing an `@` that names no agent is now sent normally.

### A citation with a line number is checked against the file

- `Services/Foo.swift:145` now resolves to `Services/Foo.swift`.

### The control API can describe itself

- `GET /v1/openapi.json` serves the control API as an OpenAPI 3.1 document

## 0.1.1 — 2026-08-08

### Unattended runs no longer lose work

- A blocked run now commits what it produced
- A run that produced nothing can no longer reach the human approval gate.
- Dead agent sessions are detected and recovered.

### Spend is measurable

- Cost is attributed when a turn is recorded
- Token usage and the model are recorded
- Cost per merged item and waste share

### Sizing became a forecast

- Per-size cost and duration bands are derived from recorded history

### Review signals say what they mean

- A quality judge that did not run now records "unavailable" instead of four failed dimensions.
- `verify:` can be required to cover the diff.

### Backlog and worktrees

- External edits to a backlog file are picked up while the app runs.
- Worktrees are pruned and orphans reaped
- Worktree builds no longer pollute DerivedData
