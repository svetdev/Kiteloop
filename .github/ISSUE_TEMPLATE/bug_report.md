---
name: Bug report
about: Something in Kiteloop behaves differently than it should
title: ''
assignees: ''
---

<!--
Before you paste anything: Kiteloop logs and agent transcripts can contain
secrets. Do NOT paste your control API token (`~/.kiteloop/control-token`), API
keys or AWS credentials, or transcript excerpts containing private code. Redact
first — a bug report is a public document.
-->

## What happened

<!-- What you saw, and what you expected instead. -->

## Steps to reproduce

1.
2.
3.

## What the agent was doing

<!--
Which surface: a chat message, an autopilot run, the control API?
If an autopilot run: the backlog item's size and `verify:` command, whether it
ran in a worktree, and whether it failed at the worker, the reviewer, or the
human gate.
-->

## Environment

| | |
|---|---|
| Kiteloop version | <!-- Kiteloop → About Kiteloop; or `curl -s http://127.0.0.1:4517/health` if the control API is on --> |
| macOS version | <!-- ⌘ → About This Mac, e.g. 15.3 (24D60) --> |
| Mac | <!-- Apple silicon or Intel --> |
| Claude Code CLI | <!-- `claude --version` --> |
| Backend | <!-- Claude account / Anthropic API key / AWS Bedrock / Ollama / Copilot bridge --> |

## Logs

<!--
Kiteloop writes a daily log to `<project>/.kiteloop/logs/kiteloop-YYYY-MM-DD.log`
— or `~/.kiteloop/logs/` for anything that happened before a project was opened.
Files older than 7 days are pruned automatically.

The View → Diagnostics window shows the same lines live, prints the current log
file's path in its footer, and has Copy and Reveal buttons.

Paste the relevant lines (redacted) or attach the file.
-->

```
```
