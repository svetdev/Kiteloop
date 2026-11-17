# Daily Brief

## Layout

One message. Keep it short enough to read in a minute; leave out a section that has nothing in it.

```
## Brief for <date>

<one line: the day in a sentence — e.g. "2 things wait on you, 1 routine was refused, $6.40 spent (token-equivalent)">

### Wrong
- <what> — <where it shows: the endpoint and the field> — <what clears it, and who does that>

### Waiting on you
- <project> · <kind> · <title> — waiting since <time> — answered by <the call or button the row names>

### What the agents did
| Project | Agent | Did | Cost |
|---|---|---|---|
| <project> | <agent> | <one line: landed, stalled, reviewed, idle> | <cost> |

### Spend
- Today: <total> (<billed dollars / token-equivalents>), <share of the rate-limit window used, when it resets>
- Coming: <the routines' next runs and the month, from the forecast; "no forecast yet" when there is none>
```

## What counts as wrong

- `GET /health` does not answer, or lists a routine as `refused`, `waiting` or `skipped`. Give the routine, the outcome and its reason. An `error` severity comes first.
- `GET /v1/events` carries an `error` event. Give its project, subject and title.
- `GET /v1/routines/runs` shows a run that started and never finished, or a routine refused for its budget.
- `GET /v1/autopilot/sitting-summary` lists stalled items. Give each with its reason and what clears it, as the summary states them.
- `GET /v1/report` shows work rejected. Give the reasons it records.
- `GET /v1/spend` shows a `rateLimit` whose status is anything but allowed. Give the window, the share used and when it resets.
- `GET /v1/attention` has a `stale` row, or a row carrying a `gateRefusal`. Give the item and the refusal as written.

Say what you saw and where. Do not guess a cause you did not read, and do not fix it.

## A quiet day

Nothing wrong and nothing waiting is one line:

```
Brief for <date>: nothing is wrong and nothing is waiting on you. $<total> spent (<basis>).
```

## Setting up the daily routine

Hiring the Watch agent does not start a routine. A person adds one and arms it — in the routine editor, choosing this agent, a time of day and a fresh chat for each run — or with one call of their own to `PUT /v1/routines/watch-daily-brief` with this body, the project's name in place of `<your project>`:

```json
{
  "name": "Daily brief",
  "project": "<your project>",
  "agent": "Watch",
  "prompt": "Write today's brief.",
  "trigger": { "at": "08:30" },
  "conversation": "fresh",
  "armed": false
}
```

- `armed` is `false`: the routine exists and does nothing until the person arms it, in the editor or by sending the body again with `"armed": true`.
- `conversation` is `fresh`, so each brief starts a new chat that opens with a note of the last one, and the context does not grow day after day.
- The routine's turns are charged to the day's budget like any other, and a `budget` on the routine caps what the brief itself may spend.
- To see a brief before arming anything, the person runs it once with `POST /v1/routines/{id}/run`, or simply asks in the chat.

The Watch agent does not make these calls. Asked to, it gives the person these steps.
