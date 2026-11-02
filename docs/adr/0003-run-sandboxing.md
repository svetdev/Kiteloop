# ADR-0003: Run sandboxing — what enforcement below the prompt is worth building

- **Status:** Accepted (2026-08-24) — decision only, no enforcement code shipped
- **Since (2026-09-08):** the advisory layer this ADR measures — the in-app
  permission prompt and the `PermissionClassifier` risk scoring it cites — is
  removed; the deny rules an unattended run is spawned with now live in
  `Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/UnattendedDenyRules.swift`.
  The decision below is unchanged: what is described as prompt-adjacent was
  never a boundary, and the boundaries that hold are still the worktree, the
  gate and a person.
- **Since (2026-09-25):** runs use Claude Code's auto mode — its classifier
  decides each tool call, with `--permission-prompts none` — and the deny list
  (`UnattendedDenyRules.swift`) is gone. The decision below still stands: the
  classifier inspects the call, as the removed layers did.
- **Deciders:** the maintainer
- **Related:** [ADR-0001](0001-autonomous-run-model.md) (the sandbox → PR →
  human-gate model this ADR sits inside), [`worktree-isolation.md`](../worktree-isolation.md)
  (the containment boundary that exists today), [`unattended-permissions.md`](../unattended-permissions.md)
  (the TCC trade-off this ADR directly answers)

## Context

The background-agent literature (Devin, Copilot coding agent, OpenHands,
Cursor background agents, and the incident write-ups that follow all of them)
has converged on one point: a system prompt, a `PreToolUse` hook, or a
risk-classifier reading a command string is *advisory*, not a boundary — an
agent that can construct or obfuscate its own tool calls can route around
anything that only inspects the call before it runs. Real enforcement has to
sit where the agent cannot argue with it: the kernel's file and network
permissions, or a credential that is too narrow to do the damage even if
handed over outright.

Today, a Kiteloop autopilot run has exactly one enforcement layer of that
kind — the worktree — and it bounds *where committed output lands*, not what
the run can do while it runs:

- **Filesystem: none, below the worktree convention.** `WorktreeSession`
  (`Kiteloop/Kiteloop/Services/WorktreeSession.swift`) moves the worker and
  reviewer into `.kiteloop/worktrees/<item-id>` and pins their `cwd` there, and
  `docs/worktree-isolation.md` says outright: *"Isolation is a containment
  boundary, not a security sandbox. An agent's `Bash` can still reach outside
  the worktree."* Nothing stops it from doing so — the worktree is a place
  agents are *steered* toward, not a place they are *confined* to. Kiteloop's
  own entitlements confirm there is no OS-level boundary either:
  `com.apple.security.app-sandbox` is `false` in
  `Kiteloop/Kiteloop/Kiteloop.entitlements`.
- **Credentials: the operator's own, handed over whole.**
  `ClaudeCodeCLIRuntime.provision` (`Kiteloop/Kiteloop/Runtime/ClaudeCodeCLIRuntime.swift:435-442`)
  spawns `claude` with `process.environment = Self.sessionEnvironment(spawnEnvironment(auth: auth, cwd: cwd), …)`,
  and `ClaudeAuthConfig.processEnvironment()`
  (`Kiteloop/KiteloopCore/Sources/KiteloopCore/Models/BedrockConfig.swift:94-111`)
  starts from `ProcessInfo.processInfo.environment` — the operator's full
  environment, `PATH`, `HOME`, `SSH_AUTH_SOCK` and all — and adds one of:
  an `ANTHROPIC_API_KEY` read out of `~/.kiteloop/tokens.json`
  (`Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/TokenStore.swift:27-36`,
  a **plaintext JSON file**, not Keychain-backed), or `AWS_PROFILE` +
  `AWS_REGION` for Bedrock SSO (`BedrockConfig.environmentVariables()`,
  same file, lines 141-151), which resolves against the operator's own
  `~/.aws/sso/cache`. Either way the credential is scoped to *the operator*,
  not to *the run* — an item's worker can read its own environment (`env`) or
  the SSO cache files directly, since it inherits the operator's `HOME`.
  There is no per-item token, no expiry, no scope narrower than everything the
  operator's own account can do.
- **Network: unrestricted.** Nothing in the spawn path sets `HTTPS_PROXY`,
  `NO_PROXY`, or any firewall rule. A run's `Bash` tool can reach any host the
  operator's Mac can.
- **What exists is prompt-adjacent, by design and by admission.** The
  `PreToolUse` hook in `.claude/settings.json` reads `tool_input.command` as
  text and pattern-matches it (via `jq` + `grep -E`) to block one specific
  shape of command — `xcodebuild … test` while Kiteloop is running — and
  `PermissionClassifier` did the same in-process for auto-mode approval:
  pattern rules over `toolName`/`input`, falling back to a static `assessRisk`
  heuristic. (Removed in 0.4.8 with the in-app prompt; what stands in its place
  is the permission mode and the allowed/denied tool lists the spawn carries —
  `UnattendedDenyRules.swift` in the package — see *Since* above.) Both
  inspect the *call*, both run *before* the call executes, and both are
  exactly the shape the literature says an agent can route around — construct
  the same effect through a different tool, a subshell, base64, or a script
  file instead of an inline command.
- **The operational reality currently pulls the other way.**
  `docs/unattended-permissions.md` documents that running unattended requires
  granting Kiteloop.app and `claude` **Full Disk Access**, and says so in its
  own words: *"any agent command — any `Bash` tool call — can read every file
  the user can, including other apps' data, mail and browser stores. That is a
  real widening of what an autonomous run can reach."* The ODD calls for
  unattended endurance runs (`docs/success-metrics.md` SLI #1); the current
  answer to the TCC prompts that would otherwise stall them is to grant the
  single broadest permission macOS has.

The question this ADR answers: given a non-containerized macOS app driving
`claude` subprocesses, what is worth building below that line, and what is
not worth it yet.

## Mechanisms surveyed

### 1. `sandbox-exec` (Seatbelt) profile around the spawned `claude` process

Wrap the child in a `sandbox-exec -f <profile>.sb` (or `sandbox_init` from a
small launcher) that denies file writes outside the worktree and the paths the
toolchain needs, and denies network egress except an explicit allow-list.

- **Stops that the hook does not:** a kernel-enforced boundary, not a string
  match — an agent cannot argue its way past a denied `open()`/`connect()` by
  phrasing the command differently. Directly answers the exact cost
  `unattended-permissions.md` names: FDA grants the *process* broad TCC
  standing, but a Seatbelt profile can still deny that same process a write
  outside the worktree or a read of `~/Library/Mail` — the two are additive,
  not redundant. (Seatbelt does not bypass TCC for protected folders; the two
  compose, they don't substitute for each other.)
- **Cost per run:** authoring the profile is the real cost, not runtime
  overhead (Seatbelt adds negligible latency). `xcodebuild`/`swift build` read
  broadly — `Xcode.app`, the SDK, `~/Library/Developer`, module/derived-data
  caches — so a correct allow-list has to be built iteratively against denial
  logs (`log show --predicate 'sender == "Sandbox"'`), and a profile that's
  too tight fails the verify silently or with a confusing toolchain error, not
  a clear "denied" message.
- **What it breaks without explicit allowances:** the FIFO bridges
  (`mkfifo` under a session temp directory — `ClaudeCodeCLIRuntime.swift:290-291`)
  need their directory allow-listed for both processes; the loopback control
  API (operator tools, port `4517` by default) needs `127.0.0.1` allowed
  explicitly if network is otherwise denied; Keychain-backed subscription auth
  (if `claudeAuth == .subscription`) needs IPC to `securityd` allowed or that
  auth method breaks silently.
- **Deprecation risk:** `sandbox-exec(1)` has printed a deprecation warning
  since macOS 10.14 with no replacement CLI shipped and no removal announced
  as of this Mac's OS version — a real but currently theoretical risk to
  carry, not a reason to wait indefinitely.
- **Rejected sibling: sandbox the whole app (App Sandbox), not just the
  child.** `com.apple.security.app-sandbox = true` on Kiteloop.app itself
  would need one profile wide enough to cover every tool the app or any agent
  ever shells out to (`git`, `gh`, `xcodebuild`, `npm`, arbitrary project
  tooling) *and* the UI's own file access, with `com.apple.security.inherit`
  propagating the same profile to every child. One profile bug then has the
  blast radius of the whole app, not one run. A profile scoped to just the
  spawned `claude` process is smaller to author and smaller to get wrong.

### 2. Per-run scoped git/gh credentials

When `openPullRequest` is on, mint or reuse a token restricted to the target
repo and the `kiteloop/<item-id>` branch (a fine-grained PAT, or a GitHub App
installation token), injected via `GIT_ASKPASS`/`credential.helper` in that
session's environment only, instead of the operator's ambient `gh`/git
credential helper and SSH agent (`SSH_AUTH_SOCK`, inherited whole per the
Context above).

- **Stops that the hook does not:** a compromised or over-eager run pushing to
  a repo, or a branch, the item never named. Today nothing scopes this — the
  run's git identity is whatever the operator's machine is already
  authenticated as.
- **Cost per run:** one token-mint call per run (or per project, cached) if
  using a GitHub App; a fine-grained PAT needs manual rotation since GitHub
  has no short-lived-PAT API. Either way, a new small service/config surface
  Kiteloop doesn't have today.
- **What it breaks:** any workflow relying on the operator's own git identity
  showing up as the commit author (some `gh` flows, some CODEOWNERS setups)
  would need reconciling with a service identity instead.
- **Scope note:** this only matters on the `openPullRequest` path
  (`docs/control-api.md`) — off by default today. The base worktree flow never
  touches the network for git at all (`docs/worktree-isolation.md`: branches
  from the project root's local `HEAD`, no fetch).

### 3. Network allow-listing

Either a filtering proxy (`HTTPS_PROXY` forced in the child's environment,
allow-listing the configured auth backend's host and nothing else) or Seatbelt
network rules (`(deny network-outbound)` + explicit `(allow network-outbound
(remote ip "…"))`) as part of mechanism 1's profile.

- **Stops that the hook does not:** exfiltration or unauthorized calls via
  `curl`/`npm install`/arbitrary network tools a `Bash` command can reach —
  the credential-theft path that matters most given the plaintext
  `ANTHROPIC_API_KEY` in `tokens.json` and the full environment every session
  inherits (Context, above): a run that can read its own env can still only
  *send* that key somewhere if the network allows it.
- **Cost per run:** a proxy needs TLS interception (a locally-trusted CA) to
  filter HTTPS by host, which is fragile against certificate pinning and
  against tools that ignore proxy env vars entirely; a Seatbelt network rule
  has neither problem and is authored once as part of the same profile as
  mechanism 1, not a second subsystem.
- **What it breaks:** any tool a project's own build needs that reaches the
  network legitimately (a package manager resolving dependencies, `git fetch`
  against a remote) has to be on the allow-list per project, which is exactly
  the kind of per-project configuration Kiteloop has otherwise avoided
  (`.kiteloop/autopilot-config.json` is deliberately small).
- **Decision:** fold into mechanism 1 rather than build as a separate proxy —
  same authoring cost, no TLS-interception fragility, one profile to reason
  about instead of two subsystems.

### 4. A separate, unprivileged macOS user account per run

Spawn `claude` as a dedicated low-privilege account (`sudo -u kiteloop-run …`
or an `Authorization.framework` helper), with that account's own `HOME`
holding only what a run needs — no operator Keychain, no operator SSH agent,
no operator `~/.aws/sso/cache`.

- **Stops that the hook does not:** ambient access to *everything else on the
  machine under the operator's account* — other projects, other apps' data,
  the operator's own SSH keys and Keychain items — reusing macOS's own
  discretionary access control instead of a bespoke profile.
- **Cost per run:** the heaviest option surveyed. Needs a one-time privileged
  setup step (create the account, grant it sudoers/Authorization rights — a
  real security-sensitive install step, not a toggle), and per-run
  provisioning of whatever credentials that account *is* allowed to use
  (reintroducing the same credential-scoping problem as mechanism 2, now
  solved twice). The FIFOs are `mkfifo(…, 0o600)`
  (`ClaudeCodeCLIRuntime.swift:290-291`) — owner-only — so cross-user access
  needs either relaxed permissions or a `chown` per session.
- **What it breaks:** the app itself still runs as the operator; every path
  that currently assumes "the agent runs as me" (Keychain-backed subscription
  auth in particular) needs an explicit bridge to the run account, or that
  auth method stops working for isolated runs.
- **Decision:** defer. `unattended-permissions.md` §B already gets most of
  this mechanism's filesystem benefit for free — projects live outside
  TCC-protected folders by convention, so there's little left under the
  operator's account that a Seatbelt profile (mechanism 1) doesn't already
  deny reading. The provisioning cost buys mainly Keychain/SSH-agent
  isolation, which is a real gap but a second-order one next to plaintext
  API keys reaching the run's own environment. Revisit if mechanism 1 proves
  insufficient against credential theft specifically (e.g., IPC to a
  system service that Seatbelt syntax can't restrict cleanly).

### 5. A container/VM runtime for the verify step only

Run just the item's `verify:` — for a `KiteloopCore` change,
`./scripts/run-core-tests.sh`; for anything reaching the app,
`xcodebuild … build-for-testing` — inside a container or a lightweight VM
(`tart`/OrbStack for a macOS guest, since `xcodebuild` needs a real Xcode
install; there is no Linux container story for it).

- **Stops that the hook does not:** contains a compromised or destructive
  build/test script to a disposable environment, no matter what it does
  beyond the worktree — the strongest containment surveyed, for the one
  command a run always executes unsupervised.
- **Cost per run:** the most impractical option surveyed for *this* verify
  shape. Apple's own tooling has no Linux-container path for `xcodebuild`;
  a macOS VM needs its own multi-GB Xcode/SDK image kept in lockstep with the
  host — the same DerivedData-drift risk a worktree run already guards
  against by pinning `-derivedDataPath` to the worktree, multiplied by a
  second toolchain copy — and its own code-signing identity, reproducing the
  same
  "**regenerating the local signing certificate silently invalidates it**"
  fragility `unattended-permissions.md` already documents for one certificate,
  now for two. Boot/sync latency alone risks exceeding the runtime of a
  size-M item this project runs in single-digit minutes.
- **What it breaks:** derived-data path assumptions this very item's
  "Build Output" instructions depend on; the local codesigning identity used
  to launch-and-verify Kiteloop.app.
- **Decision:** not worth building now. `verify:` here is Xcode-shaped by
  construction, and Xcode has no practical container story on macOS. Revisit
  only if a project's `verify:` stops requiring Xcode (a pure SwiftPM package,
  a script with no Xcode dependency) — that shape *does* have a viable
  container story and would be worth a narrow follow-up experiment, not a
  blanket "no."

## Decision

Build, as backlog items, in this order:

1. **A `sandbox-exec` profile wrapping the spawned `claude` process**
   (mechanism 1), scoped to: read/write within the worktree and the project
   root, the session's FIFO/temp directory, the Xcode toolchain and
   DerivedData paths a verify needs, and `securityd` IPC for subscription
   auth; deny writes everywhere else. Fold network allow-listing (mechanism 3)
   into the same profile rather than building a separate proxy — allow the
   loopback control API and the configured auth backend's host, deny
   everything else by default. This is the one mechanism that answers the
   cost `unattended-permissions.md` already names in its own words, reuses a
   kernel boundary instead of another pattern-matcher, and composes with (does
   not replace) the FDA grant that mechanism already requires.
2. **Scoped git/gh credentials for the `openPullRequest` path** (mechanism 2)
   — lower urgency since that path is opt-in and off by default, but worth
   doing before it becomes a default, since it is the one place a run's
   identity leaves the sandbox onto a shared service.

Do not build, for now, with the reason recorded:

- **A separate UNIX user per run** (mechanism 4) — the filesystem benefit
  mostly overlaps with what mechanism 1 already buys and what
  `unattended-permissions.md` §B already gets by convention; the provisioning
  cost (a privileged one-time setup, a second credential-scoping problem to
  solve) is disproportionate until mechanism 1 is shown insufficient
  specifically against Keychain/SSH-agent-shaped credential theft.
- **A container/VM runtime for the verify step** (mechanism 5) — `verify:` in
  this project is `xcodebuild`, which has no practical container story on
  macOS; the cost (a multi-GB toolchain image, a second code-signing identity
  to keep alive, boot latency comparable to the item's own runtime) is not
  worth the containment gained given the worktree and mechanism 1 already
  bound what the verify step can reach. Revisit if a project's `verify:` is
  ever Xcode-free.

No enforcement code lands in this change — the deliverable is this decision.
Items 1 and 2 above are the increments to queue next.

## Consequences

**Positive**
- The next increment (the Seatbelt profile) is scoped precisely enough to
  start from this ADR without further research: what it must allow is listed
  above, taken from the actual spawn path and FIFO paths in
  `ClaudeCodeCLIRuntime.swift`, not guessed.
- Turns "contained by convention" (`worktree-isolation.md`'s own words) into
  "contained by the kernel" for the filesystem, without a second identity or
  provisioning system.
- Directly closes the gap `unattended-permissions.md` names as a known,
  accepted trade-off today.

**Costs / follow-ups**
- The Seatbelt profile is real, ongoing authoring work — every new tool an
  item's verify needs (a new package manager, a new build system) potentially
  needs a new allow-list entry, a maintenance burden that grows with the
  variety of `verify:` commands items declare.
- `sandbox-exec` is a deprecated API with no announced replacement or removal
  date; the increment should be written so a future macOS removing it fails
  loud (profile fails to apply → run blocks) rather than silently running
  unsandboxed.
- The plaintext `ANTHROPIC_API_KEY` in `~/.kiteloop/tokens.json` and the full
  environment inheritance in `ClaudeAuthConfig.processEnvironment()` are not
  fixed by anything decided here — the Seatbelt profile denies where that key
  can be *sent*, not the fact that every session still has it in its own
  environment. Narrowing that credential itself (short-lived token, per-run
  scope) is a separate decision this ADR does not make.

## Alternatives rejected

- **Rely on `PreToolUse` hooks / `PermissionClassifier` alone, indefinitely.**
  This is the status quo, and it is exactly the shape the background-agent
  literature says does not hold under an agent that can vary its own tool
  calls — kept as the last line of defense for *known-bad single commands*
  (the app-hosted-test-host guard in `.claude/settings.json` is exactly that:
  one command shape, matched by text), not extended to carry sandboxing.
- **App Sandbox for the whole app**, covered under mechanism 1 above — bigger
  blast radius per bug than a profile scoped to the spawned child alone.
- **A MITM filtering proxy for network egress**, covered under mechanism 3 —
  Seatbelt network rules reach the same allow-list without TLS-interception
  fragility.
