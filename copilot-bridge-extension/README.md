# copilot-bridge-extension

A small VS Code extension that exposes GitHub Copilot's chat models over a
local socket, so Kiteloop's experimental `CopilotBridgeRuntime` can drive
them as an agent backend. It needs VS Code 1.90 or later (`engines.vscode`
in `package.json`) and a GitHub Copilot subscription signed in to that VS
Code — the models it exposes are Copilot's.

## Build

```bash
npm install
npm run compile     # emits out/ (gitignored)
```

Install the compiled extension into VS Code (`code --install-extension` on a
packaged .vsix, or run it from the Extension Development Host), then add a
Copilot agent from the quick-add presets in the sidebar's **+** menu next to
the AGENTS header — the preset is greyed out ("not running") until the
bridge's socket answers. See `SECURITY.md` at the repo
root for the socket's trust model.

## Protocol

One JSON object per line, over the Unix socket.

- `{"id", "type": "ping"}` answers `{"type": "pong", "models": [...]}` — the
  ids of every chat model Copilot offers.
- `{"id", "type": "chat", "messages", "model"?, "maxTokens"?}` streams
  `{"type": "delta", "content"}` frames and ends with
  `{"type": "done", "content", "model", "vendor", "family"}`, naming the model
  that answered. `model` in the request is a family (`gpt-4o`) or an id from
  the `ping` list. Left out, Copilot's first model answers. A name that
  matches neither is an `{"type": "error", "message"}` listing what is
  available — it is never replaced by another model.

In Kiteloop, an agent whose model is `copilot` names no model, and
`copilot-<name>` asks for `<name>`.

## Limits

The runtime is text-only. The model gets the conversation and nothing else:
it cannot open files, run commands or call tools (`sendToolResult` and
`sendMCPToolResult` are no-ops in `CopilotBridgeRuntime`), and each reply is
capped at 4096 tokens. A Copilot reviewer therefore judges only what is in
its prompt — it has not read the diff unless the prompt contains it.
