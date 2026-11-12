# Kiteloop companion

A phone companion for a Mac running Kiteloop: a native iOS client for the Mac
app's control API, for checking on the fleet — the scheduler that runs your
projects unattended — and pulling its levers from wherever you are. It talks to
the Mac over the Tailscale network (tailnet) or the local network with a
bearer token of its own, which it gets by trading the one-time code in the
pairing sheet's QR (`POST /v1/pair`); the sheet and the pairing
forwarder it relies on are described in `docs/autopilot-runbook.md` at the repo
root, under "The pairing forwarder".

## Prerequisites

- Xcode 16 and `xcodegen` (`brew install xcodegen`) — `xcodegen generate`
  writes the pbxproj, then build the `KiteloopMobile` scheme
- A Mac with Kiteloop running, its control API enabled, and the pairing
  forwarder installed (the runbook section above)
- The simulator needs no signing. A device needs your Apple team id in
  `Signing.local.xcconfig` beside `Signing.xcconfig` (gitignored; the
  tracked file says what to put there). The first device build from the
  command line needs `-allowProvisioningUpdates`, so Xcode registers the App
  IDs with Push Notifications; the wildcard team profile has no push, and the
  build fails on it without that flag

## The control API it uses

Every call the companion makes, and the screen that makes it. The full reference
for each is `docs/control-api.md` at the repo root; this list is what has to keep
answering for the app to work. Add a row when a screen starts calling something
new.

| Method | Path | Screen | For |
|---|---|---|---|
| POST | `/v1/pair` | Connect | The pairing QR's one-time code, traded for this phone's own token |
| GET | `/v1/projects` | Projects | The chip row, each project's run and queue depth, in the Mac's tab order |
| POST | `/v1/projects/reorder` | Projects | A chip dragged to a new place — the same move as a tab drop on the Mac |
| GET | `/v1/autopilot?project=` | Projects | The status card: state, item, phase, session spend |
| POST | `/v1/autopilot/pause` | Projects | The one lever while running or idle |
| POST | `/v1/autopilot/resume` | Projects | The one lever while paused |
| GET | `/v1/backlog?project=` | Projects, Queue | Gates waiting on you; the queue list |
| GET | `/v1/backlog/detail?project=&item=` | Gate review, Queue | An item's detail file |
| GET | `/v1/backlog/diff?project=&item=` | Gate review | The diff an item's branch carries |
| POST | `/v1/backlog/approve` | Gate review | Approve or reject an item at the gate |
| POST | `/v1/backlog/groom` | Queue | Lift a blocked item to draft or ready |
| POST | `/v1/backlog/move` | Queue | Move an item ahead of another |
| POST | `/v1/backlog/lane` | Queue | Flip an item between the now and later lanes |
| POST | `/v1/backlog/items` | Queue | File an idea as a draft, groomed on request |
| POST | `/v1/backlog/release` | Queue | Release a retired item for autopilot |
| GET | `/v1/grooming?project=` | Queue | What grooming an item still needs |
| GET | `/v1/report?hours=` | Gate review | The portfolio report behind the gates waiting on you |
| GET | `/v1/agents?project=` | Projects | The agent list and who is working |
| GET | `/v1/agents/transcript?project=&agent=` | Chat | The conversation, one line per tool call |
| POST | `/v1/agents/message` | Chat | A message to an agent |
| GET | `/v1/agents/events?project=&agent=` | Chat | The chat as it happens: each reply as it streams, and the agent's working state |
| GET | `/v1/quick-replies` | Chat | The one-tap replies above the composer |
| POST | `/v1/agents/interrupt` | Chat | Stop: ends the agent's turn; what the Mac had queued comes back to the draft |
| POST | `/v1/agents/plan` | Chat | A plan card's answer: build in Auto or Accept Edits, or keep planning with what should change |
| POST | `/v1/agents/answer` | Chat | An answer to the question the agent stopped to ask |
| POST | `/v1/agents/permission` | Chat | A permission card's answer: allow once, deny, or allow and remember one of its offers |
| POST | `/v1/agents/choices` | Chat | Answers to the questions the agent put with choices, one each |
| POST | `/v1/agents/mode` | Chat | The agent's permission mode, changed as `/mode` changes it on the Mac |
| GET | `/v1/agents/tasks?project=&agent=` | Chat | The subagents and background shells the agent's session has running |
| POST | `/v1/agents/tasks/stop` | Chat | Stop one of them and leave the session going |
| POST | `/v1/agents` | Projects | Hire an agent into the project |
| GET | `/v1/workspace/changes?project=` | Chat, Projects | What the agents have changed so far, before any gate |
| GET | `/v1/workspace/file?project=&path=` | Chat, Projects | A file a tool line names, or a folder of the project, read-only |
| GET | `/v1/preview/screenshot?project=` | Projects | The Mac's web preview, as a picture |
| POST | `/v1/devices/push` | (launch) | This phone's push token, so the Mac can tell it when something needs it |
| POST | `/v1/devices/activity` | Chat | A turn's Live Activity token, so the Mac moves the lock screen on while the phone sleeps |
| GET | `/v1/fleet/quiesce` | Fleet | Whether the fleet is taking work |
| POST | `/v1/fleet/quiesce` | Fleet | Stop taking new work |
| POST | `/v1/fleet/resume` | Fleet | Take work again |
| GET | `/v1/usage` | Fleet | The rate limit closest to reached, and the day's spend per project |
| GET | `/v1/coordinator/refill` | Fleet | The Planner's passes today and its ceiling |
| PUT | `/v1/coordinator/refill` | Fleet | A new pass ceiling |
| GET | `/v1/coordinator/scheduling` | Fleet | The shared daily budget and the last decision |

`../scripts/check-companion-api-list.py` keeps this table honest: every path the
app's sources call is a row here, every row is a path the sources call, and
every path is a route the Mac's `ControlRouter.table` serves. It runs in the
unit suite's preflight.
