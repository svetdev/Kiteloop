# Opening context

What a run's opening prompt costs, and where the figure the app reports comes
from.

## Where the number comes from

The per-run figure is recorded on every run so it can be watched rather than
re-derived:

- `OpeningContext` (`Models/OpeningContext.swift`) is the three input counters of
  a role's **first model call** — `promptTokens` for how big the context is,
  `billedTokens` for what it cost at full price.
- `TaskMetricRecord.openingContext` carries one per role (`worker`, `reviewer`),
  read off the first turn each role recorded in the run.
- `GET /v1/metrics` reports it per record, and `openingContextByRole` gives p50/p90
  over the page — see [the control API reference](control-api.md#get-v1metrics).

### Why the first *model call* and not the first turn

A `.turn` span covers a whole prompt leg: everything the CLI did between being
sent a prompt and emitting its `result`, which on a worker leg is up to the
worker's turn budget in model calls — derived from the project's own runs,
floored at 50 and capped at 150 (`RunTimeouts`) — with every tool result
folded into the counters. Reading the leg's
counters as an opening context reports the files the worker read as part of the
rules it opened with. One illustrative measurement, taken on this repository's
own runs in September 2026, put the worker's figure read that way at a p50 of
63k billed tokens and a p50 prompt of 1.7 *million*; it is that measurement,
not a general figure.

The CLI states the per-call figure once, on the first `assistant` line of the leg,
and nowhere else. `StreamEvent.assistantUsage` reads it there and
`ClaudeCodeCLIRuntime` hands it to that leg's `result`.

### Reading `promptTokens` against `billedTokens`

They answer different questions and diverge by an order of magnitude:

- **`promptTokens`** is how big the opening context is. It does not move when the
  cache happens to be warm, so it is the figure to compare against a slimming
  target.
- **`billedTokens`** is what that prompt cost to send — the uncached remainder
  plus what the call wrote to cache. On a cold session it is nearly the whole
  context; on a session resumed from the previous item it is a few thousand
  tokens for the same content.

A single figure would have made a cache hit look like a slimmer prompt. Note also
that a resumed session's first call carries the *previous* item's conversation as
well, so `promptTokens` on those runs is the opening context plus history — the
p50/p90 spread per role is where that shows up.
