# Web Preview: the `web_*` agent tools

What an agent can do with Kiteloop's web preview pane, and the trust model that
bounds it. (Diátaxis: this is a *reference*. For the permission flags that
gate ordinary tools see [`architecture.md`](architecture.md);
for how Kiteloop-provided MCP tools reach a session at all see
[`architecture.md`](architecture.md#kiteloop-provided-tools-mcp).)

The pane is the **Preview** tab of the inspector drawer
(`Views/Inspector/InspectorDrawer.swift:5`), which can be popped out into its own
window. It is a `WKWebView` owned by `WebPreviewViewModel`
(`ViewModels/WebPreviewViewModel.swift`) with an ephemeral data store — no shared
cookies, nothing persisted between launches — and **one script message
handler**, through which an injected script reports what the page writes to its
console (log, warn, error, uncaught errors and unhandled rejections) for the
pane's Console list. Nothing else is pushed in; everything else Kiteloop learns
about a page it pulls out via WebKit APIs.

Eight tools are wired to it. Every one is dispatched in
`ChatViewModel.handleWebActionTool` (`ViewModels/ChatViewModel.swift:1925`) and
declared in `Runtime/KiteloopToolSchemas.swift:181`.

## The tools

| Tool | Arguments | Returns |
| --- | --- | --- |
| `web_navigate` | `url` — URL, bare host, or absolute file path | Whether the page loaded, is parked awaiting approval, or was refused |
| `web_screenshot` | — | The **path** of a PNG written under `.kiteloop/web/`; the agent `Read`s that path |
| `web_read_text` | — | The page's visible text (`document.body.innerText`), fenced as untrusted |
| `web_inspect_head` | — | `<head>` metadata — title, `meta`/Open Graph, `rel` links, JSON-LD — as JSON, fenced as untrusted |
| `web_list_elements` | — | Every interactive control, numbered with a ref, label and state; fenced as untrusted |
| `web_click` | `ref` | What was clicked and what the page did; every ref is now stale |
| `web_type` | `ref`, `text` | What the field actually holds afterwards (a `maxlength` or input mask can eat some of it) |
| `web_scroll` | `direction` (`down`/`up`/`top`/`bottom`) **or** `ref` | Where the page now sits — visible band, total height, whether this is the bottom |

Reads that return page-authored text are capped at 20 000 characters
(`UntrustedWebContent.characterLimit`); a listing is capped at 150 elements
(`WebElementInventory.elementLimit`). Both say how much they left out rather than
returning a silent prefix.

### Element refs

`web_list_elements` numbers the page and hands back rows beginning with a ref
like `e3g2` — element 3 of snapshot generation 2 (`WebElementRef`,
`ViewModels/WebPreviewViewModel.swift:1226`). That ref is the only way to name a
control to `web_click`, `web_type` or `web_scroll`.

A ref is scoped to the snapshot that produced it. Navigating, clicking or typing
bumps the generation, and an older ref is refused with an instruction to list
again rather than resolved against a page that may have redrawn. Scrolling does
*not* invalidate refs, but content a scroll loaded in is only addressable after
listing again.

## The trust model

### 1. The gate

`WebNavigationPolicy.decide` (`KiteloopCore/Sources/KiteloopCore/Models/WebNavigationPolicy.swift:28`) is a pure
function over four inputs — pane mode, URL, who asked, and the session allowlist:

| | `file://`, `about:` | localhost / `127.0.0.1` / `::1` | any other host | non-HTTP scheme |
| --- | --- | --- | --- | --- |
| **Trusted** (default) | allow | allow | **deny** | deny |
| **External**, human typed the URL | allow | allow | allow | deny |
| **External**, agent asked | allow | allow | **confirm**, unless already allowlisted | deny |

`confirm` is not a refusal and not a load: the URL is parked in
`pendingExternalURL`, the pane shows a *Load external site "host"?* banner, and
`web_navigate` tells the agent the page has not loaded. Approving adds that host
to the pane's allowlist for the rest of the app's run — the allowlist is
in-memory only, so quitting Kiteloop clears it.

The gate also covers navigations the *page* starts — a link, a form submit, a
redirect. WebKit cannot tell a human following a link from `web_click`
dispatching one, so the pane answers for it: a click (or a type, or a scroll)
marks the pane agent-driven for the span of the action and any load it causes,
and `allowsInPageNavigation` (`ViewModels/WebPreviewViewModel.swift:1135`) decides
as `.programmatic` throughout. Without that, `web_click` would be a way around
the gate — ask for `evil.com`, get a confirmation prompt, then load a page that
links there and click the link instead. Outside a click span the pane is the
human browsing, treated as `.user`, so switching to External and clicking around
by hand is not gated.

Note what the gate is *not*: these tools are not decided by the session's
permission mode. Kiteloop's own MCP tools are added to `--allowedTools` when the
session is spawned (`allowTools`, `Runtime/ClaudeCodeCLIRuntime.swift:1271`), so a `web_*` call
does not raise an approval prompt. The navigation gate is the control, and it
gates *destinations*, not calls.

### 2. No `web_eval`

There is deliberately no tool that runs agent-supplied JavaScript, and none that
takes a CSS selector or an XPath. Those are open-ended: whatever the agent writes
runs against the page. A ref is two integers, checked against a snapshot Kiteloop
itself built, and there is nothing in it to smuggle anything through. Kiteloop
does evaluate JavaScript against the pane, but only its own — fixed source with
`Int` interpolations, and in `web_type`'s case a `callAsyncJavaScript` body so the
agent's text arrives as a parameter value rather than as source.

This is why the surface is eight narrow verbs instead of one general one. Adding
an eval tool would make the other seven pointless and the gate porous.

### 3. Page content is untrusted

Anything read off a rendered page is authored by whoever controls that page,
which makes it hostile input: it can carry text shaped like a system prompt, a
message from the human, or a request to call a tool. So `web_read_text`,
`web_inspect_head` and `web_list_elements` never return page content bare. It
comes back wrapped by `UntrustedWebContent.wrap`
(`ViewModels/WebPreviewViewModel.swift:1761`) — a preamble saying the block is
data, then a per-kind fence (`untrusted-page-text`, `untrusted-page-head`,
`untrusted-page-elements`).

Two details do the load-bearing work. Any closing-fence string inside the body is
neutralised (`defuse`), because a page that prints its own `</untrusted-page-text>`
would otherwise land everything after it back outside the fence. And the source
URL and any truncation note sit *outside* the fence, where a crafted page cannot
forge them.

Click, type and scroll reports are Kiteloop-authored; the only page-written spans
in them — an element's label, a field's resulting value — are flattened to a
single bounded line first, so neither can turn a one-line report into something
that reads as more than one.

### 4. Opt-in via `agent.tools`

An agent is offered a `web_*` tool only if its `tools` list names it:
`KiteloopToolSchemas.schemasForAgent` (`Runtime/KiteloopToolSchemas.swift:416`)
filters the common set down to what the agent asked for, and only those names are
registered with the tool bridge. An agent without them cannot see the pane at all.

Of the bundled templates (`Models/PredefinedTemplates.swift`), the full set ships
enabled on **Claude** (the default generalist), **Frontend**, **QA** and
**Designer** — the roles that have a rendered page to look at. The rest — Coder,
Reviewer, Researcher, Infra, Data, Copilot Critic — do not carry them. Add or
remove them per agent in the agent editor's tools field.

### 5. Selection-scoped (the v1 limit)

Only the **currently selected** agent can reach the pane. `MainWindow` calls
`webPreviewVM.retarget(to:agentName:)` on every selection change
(`Views/MainWindow.swift:1889`); `retarget` clears the previous target's
back-reference before setting the new one, so exactly one `ChatViewModel` holds a
`webPreview` at a time. For everyone else it is `nil`, and every web tool answers:

> Error: no web preview pane is attached — ask the human to select you and open
> the preview pane

Three consequences follow, and they are the honest limits of the current design:

- **A background agent cannot drive the pane.** Neither can an autopilot worker
  or reviewer, unless a human happens to have it selected — so a `verify:` step
  cannot depend on `web_*`.
- **A delegated agent cannot either.** The `web_*` cases are deliberately absent
  from `handleToolForTarget` (`ViewModels/ChatViewModel.swift:1948`), the path a
  `message_agent` call runs on: a delegated agent is not the selected one, so it
  has no business steering — or reading off — the human's pane.
- **Switching agents mid-task takes the pane away.** The tool starts failing with
  the message above; the loaded page, the mode and the allowlist stay put, since
  they belong to the pane and not to the agent.

There is one pane per window, shared by whichever agent is selected. Per-agent
panes, and a headless pane an unattended run could drive, are not in v1.

### 6. Screenshots go by path

`web_screenshot` writes a PNG under the project's `.kiteloop/web/` and returns
the path; no image bytes cross the tool protocol. The file is named after the
page and the capture time, never overwriting an existing name, and the directory
is pruned to the 50 most recent PNGs (`screenshotRetentionLimit`) — nothing else
cleans it, so an unattended run screenshotting in a loop would otherwise fill the
disk. Only `.png` files are considered, and only they are deleted.

## A typical loop

```text
web_navigate  {"url": "http://localhost:3000"}     → loads (Trusted mode is fine for local)
web_list_elements                                  → e1g1 link "Home", e2g1 textbox "Email", …
web_type      {"ref": "e2g1", "text": "a@b.com"}   → reports what the field holds now
web_list_elements                                  → refs from g1 are stale after the click below
web_click     {"ref": "e5g2"}                      → "Submit"; every ref now stale
web_read_text                                      → fenced page text: did the success state render?
web_screenshot                                     → .kiteloop/web/localhost-20260806-141233.png
Read          .kiteloop/web/localhost-20260806-141233.png
web_scroll    {"direction": "down"}                → next screenful, plus whether this is the bottom
```

Local dev servers and `file://` pages need no approval at all: Trusted mode
covers them, which is the case these tools were built for. External mode is for
inspecting a real site, and it is there that the agent's first request for a host
stops for a human.
