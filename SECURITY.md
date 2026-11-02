# Security Policy

Kiteloop runs AI agents as local subprocesses with your credentials, on your
machine, against your code. That makes a few of its surfaces genuinely worth
scrutiny — and makes it worth being precise about which ones, so a report lands
somewhere useful.

## Reporting a vulnerability

**Email <andrey@kasatkin.ai>** with `[security]` in the subject. If the repo's
private vulnerability reporting is available to you, **Security → Report a
vulnerability** works too and keeps everything in one thread.

Please do **not** open a public issue for something exploitable.

Useful in a report: what an attacker gets, what they need to start with, and the
smallest reproduction you have. A proof-of-concept is welcome; a working exploit
against someone else's machine is not.

### What to expect

Kiteloop is maintained by one person, in the open, alongside other work. These
are honest numbers, not an SLA:

| | |
|---|---|
| Acknowledgement | within 7 days |
| First assessment — in scope, severity, likely fix | within 14 days |
| Fix | depends entirely on severity; you'll get the actual timeline with the assessment, not a placeholder |

If you haven't heard anything in 14 days, assume the mail went astray and ping
again rather than assuming it's being ignored.

Disclosure is coordinated: I'd like a fix released before details are public,
and I'll credit you in `CHANGELOG.md` and the release notes unless you'd rather
I didn't.

## Supported versions

Pre-1.0, so: **the latest release, and `main`**. Fixes land on `main` and go out
in the next release; there are no backports to older tags.

## Scope

The interesting surface is the **local control API** (the server in
`Kiteloop/Kiteloop/Services/Control/KiteloopControlServer.swift`; the routing table
and the OpenAPI spec, `ControlRouter.swift` and `ControlAPISpec.swift`, in
`Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/Control/`; documented in
[`docs/control-api.md`](docs/control-api.md)). It is off by default;
enabling it opens a loopback HTTP server that can open projects, start backlog
items, and approve their results — so anything that reaches it can make agents
run code. Its defences, and what a report about it should try to break:

- **Loopback binding.** The listener sets `requiredLocalEndpoint` to
  `127.0.0.1`, so it is meant to be unreachable off-device. Anything that gets a
  request in from another host is a vulnerability.
- **Bearer token.** `~/.kiteloop/control-token`, written `0600`, compared as an
  exact full string. Auth is checked *before* routing, so the route table isn't
  discoverable without the token. A path that answers, or that leaks route
  structure, without a valid token is a vulnerability.
- **Token rotation.** Regenerating from Settings must invalidate the old token
  immediately in the running server, not just on disk.
- **Path and project resolution.** A `project` value that escapes the set of
  projects actually open in the app, or reaches files outside them, is a
  vulnerability.

Also in scope:

- **Credential and token handling** — anything that writes a token, API key, or
  AWS credential somewhere world-readable, into a log file, or into an agent
  transcript that a user would reasonably paste into an issue.
- **The permission boundary** — the `--permission-mode`,
  `--permission-prompts none` and `--allowedTools`/`--disallowedTools` an agent
  is spawned with (`Runtime/ClaudeCodeCLIRuntime.swift`); an unattended run is
  always spawned in `auto` mode. A denied tool that runs anyway, or a spawn that
  drops the mode or the deny list it was configured with, is a report. What
  Claude Code's auto-mode classifier allows is Claude Code's decision, not
  Kiteloop's.
- **The tool bridge** — the named pipes carrying MCP tool calls between the
  `claude` subprocess and the app (`mkfifo(…, 0o600)` in
  `Runtime/ClaudeCodeCLIRuntime.swift`). Anything that lets another local user
  read or inject on them.
- **The experimental Copilot bridge** — the unix socket at
  `~/.kiteloop/copilot-bridge.sock` (`copilot-bridge-extension/`).
- **Autonomous run isolation** — an autopilot run escaping its git worktree, or
  the sandbox → PR → human-gate model of
  [ADR-0001](docs/adr/0001-autonomous-run-model.md) reaching a merge without the
  gate it claims to require.

### The iOS companion

`KiteloopMobile` ships with `NSAllowsArbitraryLoads` on: it talks plain HTTP
to the Mac's control API over a Tailscale address (100.64/10), which App
Transport Security does not treat as local, and the transport security is
WireGuard's — the tailnet — not TLS. The token still travels as a bearer
header and lives in the phone's keychain. A report that the companion reaches
anything other than the paired Mac is in scope.

## Out of scope

Not because they don't matter, but because they're known, documented, or not
Kiteloop's to fix:

- **An agent doing something destructive that you approved**, or that your
  permission rules allowed. An unattended run is never prompted by design — it
  runs in Claude Code's auto mode, whose classifier decides each tool call,
  bounded by a worktree, a gate and a person; that is the documented trade-off. The macOS
  side of it, the privacy prompts cleared once so a run does not stall, is in
  [`docs/unattended-permissions.md`](docs/unattended-permissions.md).
- **Kiteloop not being sandboxed.** `com.apple.security.app-sandbox` is `false`
  by design — the app spawns `claude` subprocesses that need to read and write
  your code. It's a stated property of the design, not an oversight.
- **Anything requiring local code execution as you already.** The token file and
  every `.kiteloop/` directory are protected by ordinary POSIX permissions in
  your own home directory. An attacker already running as your user has your
  credentials by an easier route.
- **Vulnerabilities in the Claude Code CLI, the Anthropic API, AWS Bedrock, or
  Ollama.** Report those to their maintainers — I'll gladly help route one.
- **A prompt-injected agent misbehaving inside the permissions it was given.**
  Untrusted content reaching an agent's context is a real risk and worth an
  ordinary issue; it is not handled as a vulnerability report unless it *escapes*
  a boundary above.
- **Missing hardening with no exploit path** — a header absent from a
  loopback-only server, a dependency with a CVE in a code path Kiteloop never
  calls. Still worth an issue; not worth a private one.

## A note on logs and transcripts

Kiteloop's logs (`.kiteloop/logs/`) and agent transcripts can contain source
code, file paths, and — if a tool call echoed one — a credential. They are local
files and never leave your machine on their own, but they are the thing most
likely to end up in a public issue by accident. Redact before pasting; see the
warning at the top of [the bug report template](.github/ISSUE_TEMPLATE/bug_report.md).
