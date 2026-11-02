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
