# knowledge/

Agent packages live here. `agents/` starts empty on purpose — the app also
loads the two bundled examples from `Kiteloop/examples/agents/`, so a fresh
clone has a working pair without anything in this directory.

This `knowledge/` is the repo's own; it is not inside any project you open.
The app scans (`KnowledgePathResolver`) the knowledge repository you configure in
Settings → Knowledge Repository (this checkout when running unpackaged), `~/.kiteloop/agents` and
`~/.kiteloop/knowledge` under your home, and the examples bundled with the app —
your own packages go in whichever of those you point it at.

## Layout

```
knowledge/
├── agents/
│   └── <name>/
│       ├── agent.json      # handle, version, template (name, model, systemPrompt, …), knowledge
│       ├── profile.md      # system prompt: who the agent is, how it works
│       └── knowledge/      # optional *.md — the ones agent.json names are offered to the agent
└── schema/
    └── agent-schema.json   # the agent.json contract (decoded on load)
```

## Adding an agent

Create `knowledge/agents/<name>/` with an `agent.json` and a `profile.md`,
then restart Kiteloop or re-scan from the agent roster. `agent.json` follows
[`schema/agent-schema.json`](schema/agent-schema.json), and four keys are
required: `handle` (`@name`, matching `^@[a-z0-9-]+$`), `version` (semver),
`template` — itself requiring `name`, `model` (a family: `opus`, `sonnet`,
`haiku` — concrete IDs resolve per backend) and `systemPrompt` (the prompt
file's path, e.g. `profile.md`) — and `knowledge`, with its `critical`, `files`
and `imports` lists. There is no `id`; the handle is the identity. `avatar`,
`group`, a one-line `description` and the rest are optional. The app decodes
the file on load and refuses one missing a required key; the schema's patterns
and enums are documentation for you, not something the app checks. What the
agent sees is what `knowledge` declares: `critical` files are inlined into its
context and `files` are linked for on-demand reading (a package that names no
`files` gets every `*.md` in the directory linked instead).

The bundled examples are the reference: start by copying
`Kiteloop/examples/agents/example-coder/` and editing from there.

This directory is yours, not the app's: nothing here is written at runtime
(agents' learned state lives in each project's `.kiteloop/`), so it is safe
to keep under version control and share with a team.
