#!/usr/bin/env python3
"""test-kiteloop-verify — assert the harness's --json contract and its scoring.

`--json` is the mode that exists to be machine-read, and its first line of
stdout used to be `Smoke checks (read-only):` — so every reader of it failed on
the first byte, `jq` and `json.load` alike. The narration now goes to stderr and
`Report.finish` is the only writer of stdout; the cases here hold that line for
each path that narrates (smoke, --run, --marathon) and hold human mode to the
stream and the shape it has always printed on.

Nothing here needs a running Kiteloop: the paths are driven against a port
nothing listens on, so every request fails the same way on any machine, and the
marathon lines that only appear once items are moving are driven through the
real function with a stub client. No network, no server, no waiting — safe to
run while the app is up.

The same stub-driven marathon is where the scorecard's own arithmetic is held:
that a run the app died under ends its poll on the first read and is counted as
interrupted rather than as a rescue, and that one whose polls never reach the
server ends after the tolerated miss and is counted as unreachable — neither of
them the SLO #1 number the scorecard exists to report. It is also where a
backlog read that never came back 200 is held apart from a drained queue: both
answers carry no items, and only one of them measured anything — and where a
refusal about the moment, a spent daily budget, is held apart from one about the
item it names, since the first ends the night and the second only steps over one
item.

The same reading holds the smoke checks themselves: a run against an app with no
project open, or one whose backlog is empty, exercised the item contract not at
all, and used to report every check passed.

  ./scripts/test-kiteloop-verify.py
"""

import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse

sys.dont_write_bytecode = True  # leave no __pycache__ beside the script

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "kiteloop-verify.py")
# Nothing listens on port 1 (privileged, and no service claims it), so every
# request refuses instantly: the run is deterministic and takes no time.
DEAD = ["--port", "1", "--token", "x"]

failed = 0


def check(name, ok, detail=""):
    global failed
    if ok:
        print("  ok    %s" % name)
    else:
        print("  FAIL  %s%s" % (name, "\n          " + detail if detail else ""))
        failed += 1


def run(*args):
    p = subprocess.run([sys.executable, SCRIPT, *DEAD, *args],
                       capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


def load_module():
    spec = importlib.util.spec_from_file_location("kiteloop_verify", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


print("test-kiteloop-verify")

# --- JSON mode: stdout is one document, and only that ------------------------
#
# Each of the three paths narrates, and each used to narrate onto stdout. The
# assertion is json.loads over the *whole* stream, which rejects prose before it
# (the bug) and after it (the marathon scorecard) alike.
PATHS = [
    ("smoke", [], "Smoke checks (read-only):"),
    ("--run", ["--run", "proj", "item", "--timeout-min", "1"], "Run loop: proj / item"),
    ("--marathon", ["--marathon", "proj", "--hours", "0.01",
                    "--session-cap", "5", "--auto-merge"], "MARATHON SCORECARD"),
]

for label, argv, narration in PATHS:
    code, out, err = run("--json", *argv)

    # The regression itself: a leading header meant the first byte was not `{`.
    check("%s: --json stdout starts with the report object" % label,
          out.lstrip("\n").startswith("{"),
          "stdout starts: %r" % out[:60])

    try:
        doc = json.loads(out)   # raises on anything before *or* after the object
        parsed = isinstance(doc, dict) and "checks" in doc
    except ValueError as exc:
        doc, parsed = None, False
        check("%s: --json stdout parses" % label, False, str(exc))
    else:
        check("%s: --json stdout is exactly one JSON document" % label, parsed,
              "parsed, but not a report: %r" % (doc,))

    check("%s: narration still visible on stderr" % label,
          narration in err, "stderr: %r" % err[:200])

    # The mode reports failure through its exit status, not by refusing to
    # print — a caller that parses the report still needs the status to mean
    # what it did.
    check("%s: exit status still non-zero when checks fail" % label,
          code != 0, "exit=%d" % code)

# The report's own accounting survives the move: the smoke run against a dead
# port fails its check, and says so in the document rather than on stderr. The
# tally is asserted against the rows the document carries rather than against a
# fixed count — the suite-record row reads a file on disk, so how many rows pass
# is the checkout's business, and pinning the number here would make an ordinary
# red suite fail this contract case.
code, out, _ = run("--json")
try:
    doc = json.loads(out)
except ValueError as exc:
    check("the report still carries the checks and their tally", False, str(exc))
else:
    up = [c for c in doc["checks"] if c["name"] == "server up (/health)"]
    check("the report still carries the checks and their tally",
          doc["total"] == len(doc["checks"]) >= 1
          and doc["passed"] == sum(1 for c in doc["checks"] if c["ok"])
          and len(up) == 1 and not up[0]["ok"],
          "passed=%s total=%s" % (doc.get("passed"), doc.get("total")))

# --- Human mode: unchanged, on the stream it always used ---------------------
code, out, err = run()
lines = out.split("\n")
check("human mode: the header is still the first line of stdout",
      lines[0] == "Smoke checks (read-only):", "first line: %r" % lines[0])
check("human mode: the check line still carries its mark and name",
      lines[1].startswith("  \033[31m✗\033[0m server up (/health)"),
      "check line: %r" % lines[1])
# Same reading as the tally above: the footer is held to the marks that were
# actually printed, which is the stronger assertion anyway — it says the tally
# agrees with the rows above it, whatever the checkout's suite record says.
marks = [l for l in lines if l.startswith("  \033[32m✓") or l.startswith("  \033[31m✗")]
green = [l for l in marks if l.startswith("  \033[32m✓")]
tally = "%s%d/%d checks passed\033[0m" % (
    "\033[32m" if len(green) == len(marks) else "\033[31m", len(green), len(marks))
check("human mode: the footer is still the blank line and the tally",
      lines[-3] == "" and lines[-2] == tally and lines[-1] == "",
      "tail: %r  expected tally: %r" % (lines[-3:], tally))
check("human mode: nothing is diverted to stderr", err == "", "stderr: %r" % err)
check("human mode: exit status unchanged", code != 0, "exit=%d" % code)

# --- The marathon lines a drained queue never reaches -------------------------
#
# The per-item, busy-wait and backoff lines only print once items are moving, so
# they are driven through the real marathon() with a stub client rather than
# left unasserted. time.sleep is stubbed out too: the backoffs are 15s and 30s.
kv = load_module()
kv.time.sleep = lambda *_: None


class Stub:
    """A busy reply, then a hard start failure, then an item that runs to
    finish — one of each line marathon can narrate — and then a drained queue."""

    def __init__(self):
        self.starts = 0

    def request(self, method, path, body=None, **kw):
        if "backlog" in path:
            # The queue is finite, and an empty one is what ends the loop. Handing
            # back a fresh id every poll does not: marathon steps over an item that
            # refuses to start, so a queue that always has another one never
            # drains, and with time.sleep stubbed out above it spins at full tilt
            # until the wall-clock deadline — narrating into memory the whole way.
            if self.starts >= 3:
                return 200, {"items": []}
            return 200, {"items": [{"id": "itm-%d" % self.starts, "status": "ready"}]}
        if method == "POST" and path == "/v1/runs":
            self.starts += 1
            if self.starts == 1:
                return 409, {"error": "autopilot still busy"}
            if self.starts == 2:
                return 500, {"error": "boom"}
            return 200, {"runId": "r1"}
        if path.endswith("/result"):
            # `awaiting_approval`, not `completed`: the outcomes are the raw
            # values `PersistedRunRecord.Outcome` declares, and a fixture that
            # answers one the server cannot send tests the reading against a
            # night that cannot happen.
            return 200, {"state": "finished", "outcome": "awaiting_approval",
                         "itemStatus": "awaiting-approval", "qualityScore": 0.91}
        if path.endswith("/approve"):
            # What the server answers when the gate is resolved. Spelled out
            # rather than left to the fall-through below, so this fixture stays
            # the healthy marathon it is here to narrate: an approve answered
            # `200 {}` is one that did not land, and it belongs in the cases
            # that assert that, not under every line this stub drives.
            return 200, {"runId": "r1", "item": "itm-2", "resolved": "approved",
                         "status": "done"}
        return 200, {}


class RefusingStub:
    """A queue of one item that refuses to start and stays `ready` — what a real
    backlog looks like when the server won't take an item (no verify command,
    unmet `needs:`, oversized). marathon steps over it, finds nothing else
    startable, and leaves by the all-refused exit, which `Stub` above never
    reaches because its queue empties instead."""

    def request(self, method, path, body=None, **kw):
        if "backlog" in path:
            return 200, {"items": [{"id": "itm-refused", "status": "ready"}]}
        if method == "POST" and path == "/v1/runs":
            return 500, {"error": "boom"}
        return 200, {}


class UnreadableQueueStub:
    """A backlog read that never comes back 200: a connection-level failure by
    default, or whatever HTTP status it is handed. None of those answers carries
    an `items` list — which is exactly why an unread queue used to be
    indistinguishable from a drained one. Counts the reads: there is nothing to
    learn from a second."""

    def __init__(self, status=0, error="<urlopen error [Errno 61] Connection refused>"):
        self.status = status
        self.error = error
        self.reads = 0

    def request(self, method, path, body=None, **kw):
        if "backlog" in path:
            self.reads += 1
            return self.status, {"error": self.error}
        return 200, {}


class DrainedQueueStub:
    """The queue the drain message is actually for: answered, and empty."""

    def request(self, method, path, body=None, **kw):
        if "backlog" in path:
            return 200, {"items": []}
        return 200, {}


def drive_marathon(as_json, client=None, timeout_min=1):
    """Run the real marathon() against a stub and return what it wrote to each
    stream. What `Report.finish` returned — the status the harness exits with —
    is left on `drive_marathon.exit_code` for the cases that read it, rather
    than in a third return value every existing caller would have to unpack."""
    report = kv.Report(as_json=as_json)
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        kv.marathon(client or Stub(), report, "proj", 0.02, timeout_min, auto_approve=True)
        drive_marathon.exit_code = report.finish()
    return out.getvalue(), err.getvalue()


MOVING = ["autopilot busy", "did not start", "ran itm-", "MARATHON SCORECARD",
          "avg quality"]

out, err = drive_marathon(as_json=True)
try:
    json.loads(out)
    only_report = True
except ValueError as exc:
    only_report = False
    check("marathon with items moving: stdout is one JSON document", False, str(exc))
else:
    check("marathon with items moving: stdout is one JSON document", only_report)
check("marathon with items moving: every narrated line is on stderr",
      all(frag in err for frag in MOVING),
      "missing: %r" % [f for f in MOVING if f not in err])

out, err = drive_marathon(as_json=False)
check("marathon in human mode: the same lines are still on stdout",
      all(frag in out for frag in MOVING),
      "missing: %r" % [f for f in MOVING if f not in out])
check("marathon in human mode: nothing is diverted to stderr",
      err == "", "stderr: %r" % err[:200])

# --- The scorecard as a field, not as prose ----------------------------------
#
# Every metric-#1 number the block above narrates used to live only there, so
# reading an unattended night's SLO figures out of --json meant regexing stderr.
# The document carries them now, and they are asserted against the narration for
# the *same* run: the two are written off one set of variables, and a case that
# only pinned figures here would keep passing while the block and the field came
# apart. The figures are pinned as well, against the run the stub actually drove
# — `itemsRun` and `completed` are both 1 on this fixture, so agreement with the
# narration alone would not notice a field wired to the wrong variable.


def scorecard_block(text):
    """The narrated scorecard, as {label: the text after its colon}. Stops at the
    first line that is not one of its `  label:  value` rows — in human mode the
    check rows print onto the same stream directly below it."""
    lines = text.split("\n")
    start = next((n for n, l in enumerate(lines) if "MARATHON SCORECARD" in l), None)
    if start is None:
        return {}
    block = {}
    for line in lines[start + 1:]:
        if not line.startswith("  ") or not line[2:3].islower() or ":" not in line:
            break
        label, _, value = line.strip().partition(":")
        block[label] = value.strip()
    return block


out, err = drive_marathon(as_json=True)
try:
    card = json.loads(out).get("scorecard")
except ValueError as exc:
    card = None
    check("marathon --json carries a scorecard object", False, str(exc))
else:
    check("marathon --json carries a scorecard object", isinstance(card, dict),
          "scorecard: %r" % (card,))
narrated = scorecard_block(err)
check("the narrated block is still there beside it, on stderr",
      narrated.get("items run") is not None, "block: %r" % (narrated,))

if isinstance(card, dict) and narrated:
    EXPECTED = {"itemsRun": 1, "completed": 1, "blocked": 0, "stalled": 0,
                "cancelled": 0, "cancelledItems": [], "didNotRun": 0,
                "didNotRunItems": [], "rescues": 0, "interrupted": 0,
                "unreachable": 0, "failedStart": 1, "neverStarted": ["itm-1"],
                "ceilingStop": None, "avgQuality": 0.91, "wallClock": "0h00m"}
    wrong = {k: (card.get(k), v) for k, v in EXPECTED.items() if card.get(k) != v}
    check("the scorecard reports the night the stub actually drove", not wrong,
          "document vs expected: %r" % (wrong,))
    check("the wall clock is carried as seconds too",
          isinstance(card.get("durationSeconds"), int) and card["durationSeconds"] >= 0,
          "durationSeconds: %r" % (card.get("durationSeconds"),))

    # And each row of the block against the field beside it. The rows that are
    # one figure first.
    PLAIN = [("wall clock", "wallClock"), ("items run", "itemsRun"),
             ("completed", "completed"), ("rescues", "rescues"),
             ("interrupted", "interrupted"), ("unreachable", "unreachable")]
    mismatched = [(label, narrated.get(label), card.get(key))
                  for label, key in PLAIN if narrated.get(label) != str(card.get(key))]
    check("every plain scorecard row reads what the field beside it carries",
          not mismatched, "narrated vs document: %r" % (mismatched,))

    check("the blocked row and the stalled count inside it both match",
          narrated.get("blocked") == "%s  (stalled: %s)" % (card.get("blocked"),
                                                            card.get("stalled")),
          "narrated %r, document blocked=%r stalled=%r"
          % (narrated.get("blocked"), card.get("blocked"), card.get("stalled")))

    # The rows that print a figure and then name the items behind it: both halves
    # have to agree with the document, since the count is what a reader totals and
    # the ids are what they act on.
    for label, count_key, ids_key in [("failed start", "failedStart", "neverStarted"),
                                      ("cancelled", "cancelled", "cancelledItems"),
                                      ("did not run", "didNotRun", "didNotRunItems")]:
        text = narrated.get(label, "")
        ids = card.get(ids_key) or []
        check("the '%s' row matches the count and the ids beside it" % label,
              text.split(" ")[0] == str(card.get(count_key))
              and all(i in text for i in ids),
              "narrated %r, document %r / %r" % (text, card.get(count_key), ids))

    stop = card.get("ceilingStop")
    check("the ceiling-stop row and the field are read off the same stop",
          narrated.get("ceiling stop", "").split(" ")[0] == ("1" if stop else "0")
          and (stop is None or stop in narrated.get("ceiling stop", "")),
          "narrated %r, document %r" % (narrated.get("ceiling stop"), stop))

    avg = card.get("avgQuality")
    check("the avg-quality row is the 2-decimal rendering of the field's mean",
          isinstance(avg, float) and narrated.get("avg quality") == "%.2f" % avg,
          "narrated %r, document %r" % (narrated.get("avg quality"), avg))

# Human mode prints what it always has, on the stream it always has: the same
# block, line for line, that the --json run narrated to stderr.
out, err = drive_marathon(as_json=False)
check("human mode still prints that block on stdout, unchanged",
      scorecard_block(out) == narrated,
      "human %r vs --json stderr %r" % (scorecard_block(out), narrated))

# A night nothing scored reports no average rather than an average of nothing —
# `null`, which is the `n/a` the block prints, and not the 0.0 a zero-length mean
# would read as if it were rendered as a number.
out, err = drive_marathon(as_json=True, client=RefusingStub())
try:
    card = json.loads(out).get("scorecard")
except ValueError as exc:
    card = None
    check("a night that scored nothing carries a null average, not a zero",
          False, str(exc))
else:
    check("a night that scored nothing carries a null average, not a zero",
          isinstance(card, dict) and "avgQuality" in card
          and card["avgQuality"] is None and card.get("itemsRun") == 0,
          "scorecard: %r" % (card,))
check("and the block beside it still prints n/a",
      scorecard_block(err).get("avg quality") == "n/a",
      "block: %r" % (scorecard_block(err),))

# The other two --json paths have no scorecard to report, and their documents
# keep the shape every reader of them already has.
for label, argv in [("smoke", []),
                    ("--run", ["--run", "proj", "item", "--timeout-min", "1"])]:
    _, out, _ = run("--json", *argv)
    try:
        doc = json.loads(out)
    except ValueError as exc:
        check("%s: the --json document carries no scorecard key" % label, False, str(exc))
    else:
        check("%s: the --json document carries no scorecard key" % label,
              "scorecard" not in doc, "keys: %r" % sorted(doc))

# And end to end through the CLI, where `Report.finish` is the one writing it:
# against a port nothing listens on the queue is never read, so the night ran
# nothing — a scorecard of zeroes is still a scorecard, and its absence here
# would mean the key never left the stub.
_, out, _ = run("--json", "--marathon", "proj", "--hours", "0.01")
try:
    doc = json.loads(out)
except ValueError as exc:
    check("--marathon --json carries the scorecard end to end", False, str(exc))
else:
    card = doc.get("scorecard")
    check("--marathon --json carries the scorecard end to end",
          isinstance(card, dict) and card.get("itemsRun") == 0
          and card.get("completed") == 0 and card.get("avgQuality") is None,
          "scorecard: %r" % (card,))

# --- The exit a queue takes when every ready item has refused to start --------
#
# The other way out of the loop, and the last line in the file to be written with
# a bare `print`: a marathon that ends this way put prose ahead of the report and
# every reader of --json failed on the first byte.
REFUSED = "nothing left to start"

out, err = drive_marathon(as_json=True, client=RefusingStub())
try:
    json.loads(out)
except ValueError as exc:
    check("marathon with the queue all refused: stdout is one JSON document",
          False, str(exc))
else:
    check("marathon with the queue all refused: stdout is one JSON document", True)
check("marathon with the queue all refused: the line is on stderr, naming the item",
      REFUSED in err and "itm-refused" in err, "stderr: %r" % err[:300])

out, err = drive_marathon(as_json=False, client=RefusingStub())
check("marathon with the queue all refused, human mode: the line is still on stdout",
      REFUSED in out, "stdout: %r" % out[:300])
check("marathon with the queue all refused, human mode: nothing is diverted to stderr",
      err == "", "stderr: %r" % err[:200])

# --- A spent ceiling ends the night; an item's own refusal still does not ------
#
# `BacklogAutopilot.StartOutcome.Refusal.dailyBudget` refuses every autonomous
# start alike, so the item behind the one it refused would be refused by the same
# sentence. Stepping over it — which is right for the 422 a pickup gate returns
# about one item — used to post one doomed POST /v1/runs per remaining ready
# item, count each as an item that would not start, and end the night with
# `nothing left to start — all 3 remaining ready items refused: itm-a, itm-b,
# itm-c`: a line naming three perfectly good items and not the ceiling.
CEILING_LINE = "ceiling reached — ending the marathon"
CEILING_CHECK = "marathon: no spent ceiling stopped the night"
# What `DailyBudget.Refusal.logLine` reads for each of the two ceilings that
# govern an autonomous start, echoed by POST /v1/runs behind its "Run did not
# start: ". Both are matched, and each has to be named back: an operator who
# raises the portfolio's when it was the project's has not raised anything.
CEILINGS = {
    "portfolio": "Daily budget $50.00 spent ($51.20 today) — autonomous start refused. "
                 "A run you start yourself still runs; raise the daily budget or wait "
                 "for local midnight.",
    "project": "proj's daily budget $10.00 spent ($10.40 today) — autonomous start "
               "refused. A run you start yourself still runs; raise proj's daily "
               "budget or wait for local midnight.",
}


class CeilingStub:
    """Three ready items and a ceiling that refuses every start. The queue never
    drains — a refused item stays `ready` — so a marathon that walks it posts one
    run per item, which is what counting the starts here is for."""

    def __init__(self, detail):
        self.detail = detail
        self.starts = 0

    def request(self, method, path, body=None, **kw):
        if "backlog" in path:
            return 200, {"items": [{"id": "itm-a", "status": "ready"},
                                   {"id": "itm-b", "status": "ready"},
                                   {"id": "itm-c", "status": "ready"}]}
        if method == "POST" and path == "/v1/runs":
            self.starts += 1
            # 409, the same status a run already in flight answers with — which
            # is why the ceiling is told from the busy wait by its wording.
            return 409, {"error": "Run did not start: " + self.detail}
        return 200, {}


for scope, detail in CEILINGS.items():
    for as_json in (True, False):
        label = "%s ceiling (%s)" % (scope, "--json" if as_json else "human mode")
        stream = "stderr" if as_json else "stdout"
        stub = CeilingStub(detail)
        out, err = drive_marathon(as_json=as_json, client=stub)
        narrated = err if as_json else out

        check("%s: the night ends after one start attempt" % label,
              stub.starts == 1, "posted %d runs" % stub.starts)
        check("%s: the line names the ceiling that stopped it" % label,
              CEILING_LINE in narrated and detail in narrated,
              "%s: %r" % (stream, narrated[:600]))
        check("%s: no item is blamed for it" % label,
              REFUSED not in narrated and "itm-" not in narrated,
              "%s: %r" % (stream, narrated[:600]))
        check("%s: the scorecard counts it apart from failed starts" % label,
              "failed start: 0" in narrated and "ceiling stop: 1" in narrated,
              "%s: %r" % (stream, narrated[:600]))

        if as_json:
            try:
                doc = json.loads(out)
            except ValueError as exc:
                check("%s: stdout is one JSON document" % label, False, str(exc))
            else:
                check("%s: stdout is one JSON document" % label, True)
                rows = [c for c in doc["checks"] if c["name"] == CEILING_CHECK]
                check("%s: the report carries it as a failed check" % label,
                      len(rows) == 1 and not rows[0]["ok"]
                      and detail in rows[0]["detail"], "rows: %r" % (rows,))
        else:
            check("%s: the failed check prints beside the others" % label,
                  "\033[31m✗\033[0m " + CEILING_CHECK in out, "stdout: %r" % out[:600])
            check("%s: nothing is diverted to stderr" % label,
                  err == "", "stderr: %r" % err[:200])

# And a night nothing refused says so on the same line, rather than leaving the
# reader to notice a line that isn't there.
out, err = drive_marathon(as_json=False)
check("a night no ceiling refused records none, and adds no check",
      "ceiling stop: 0" in out and CEILING_CHECK not in out,
      "stdout: %r" % out[:600])


class ItemRefusalStub:
    """A queue of two whose first item the pickup gate refuses about itself — the
    422 an ungroomed, retired or unready item gets, which says nothing about the
    one behind it. Records which items were asked for, in order."""

    def __init__(self):
        self.asked = []
        self.ran = False

    def request(self, method, path, body=None, **kw):
        if "backlog" in path:
            # The refused item stays `ready`; the queue drains once the good one
            # behind it has run.
            if self.ran:
                return 200, {"items": []}
            return 200, {"items": [{"id": "itm-unready", "status": "ready"},
                                   {"id": "itm-good", "status": "ready"}]}
        if method == "POST" and path == "/v1/runs":
            item = (body or {}).get("item")
            self.asked.append(item)
            if item == "itm-unready":
                return 422, {"error": "Run did not start: no runnable items — "
                                      "itm-unready: not ready (no verify command)"}
            self.ran = True
            return 200, {"runId": "r-good"}
        if path.endswith("/result"):
            return 200, {"state": "finished", "outcome": "completed",
                         "itemStatus": "done", "qualityScore": 0.8}
        return 200, {}


stub = ItemRefusalStub()
out, err = drive_marathon(as_json=False, client=stub)
check("an item-level refusal still steps to the item behind it",
      stub.asked == ["itm-unready", "itm-good"], "asked: %r" % (stub.asked,))
check("an item-level refusal is still counted and named as a failed start",
      "failed start: 1  (never started: itm-unready)" in out and "ran itm-good" in out,
      "stdout: %r" % out[:600])
check("an item-level refusal does not end the night as a ceiling would",
      CEILING_LINE not in out and CEILING_CHECK not in out
      and "ceiling stop: 0" in out, "stdout: %r" % out[:600])

# --- A queue nobody could read is not a queue that drained --------------------
#
# A backlog read that fails at the connection level, or comes back 401 or 500,
# carries no `items` — so it used to take the `if not ready` arm, narrate
# `queue drained` and leave a scorecard reporting `items run: 0`, `rescues: 0`
# and SLO #1 met over a night on which nothing was ever asked.
UNREADABLE = "queue could not be read"
DRAINED = "queue drained — no ready items left."

for status, error in ((0, "<urlopen error [Errno 61] Connection refused>"),
                      (401, "unauthorized"),
                      (500, "internal error")):
    for as_json in (True, False):
        label = "%s, %s" % (status, "--json" if as_json else "human mode")
        stream = "stderr" if as_json else "stdout"
        stub = UnreadableQueueStub(status=status, error=error)
        out, err = drive_marathon(as_json=as_json, client=stub)
        narrated = err if as_json else out

        check("unreadable queue (%s): the line says the queue could not be read" % label,
              UNREADABLE in narrated, "%s: %r" % (stream, narrated[:400]))
        check("unreadable queue (%s): it names the status and the error" % label,
              ("status=%d" % status) in narrated and error in narrated,
              "%s: %r" % (stream, narrated[:400]))
        check("unreadable queue (%s): the drain is never narrated" % label,
              DRAINED not in narrated, "%s: %r" % (stream, narrated[:400]))
        check("unreadable queue (%s): the loop leaves on that first read" % label,
              stub.reads == 1, "read the backlog %d times" % stub.reads)

        if as_json:
            # The failure is a named check in the report, not only prose: a
            # caller reading the document sees the queue went unread.
            try:
                doc = json.loads(out)
            except ValueError as exc:
                check("unreadable queue (%s): stdout is one JSON document" % label,
                      False, str(exc))
            else:
                check("unreadable queue (%s): stdout is one JSON document" % label, True)
                rows = [c for c in doc["checks"] if "backlog readable" in c["name"]]
                check("unreadable queue (%s): the report carries it as a failed check"
                      % label,
                      len(rows) == 1 and not rows[0]["ok"]
                      and ("status=%d" % status) in rows[0]["detail"],
                      "rows: %r" % (rows,))
        else:
            check("unreadable queue (%s): the failed check prints beside the others"
                  % label,
                  "\033[31m✗\033[0m marathon: backlog readable" in out,
                  "stdout: %r" % out[:400])
            check("unreadable queue (%s): nothing is diverted to stderr" % label,
                  err == "", "stderr: %r" % err[:200])

# And the answer the drain message is for is untouched: 200, no ready items.
out, err = drive_marathon(as_json=False, client=DrainedQueueStub())
check("a 200 with an empty items list still narrates the drain, word for word",
      DRAINED in out, "stdout: %r" % out[:400])
check("and a drained queue adds no unread-queue check",
      UNREADABLE not in out and "backlog readable" not in out,
      "stdout: %r" % out[:400])

# --- A run the app died under: read once, scored on its own line --------------
#
# `/result` answers a run this process is not tracking from its durable record,
# and one the app restarted under reads `interrupted` with HTTP 200 — for ever.
# run_one used to poll it every 10s until --timeout-min expired and marathon then
# called it a rescue, so a restart mid-marathon burned 20 minutes per remaining
# item and reported a violated SLO #1 that never happened.
class InterruptedStub:
    """One ready item whose run comes back `interrupted` on every read, then a
    drained queue. Counts its `/result` reads: the record is final, so one is all
    there is to learn from it."""

    def __init__(self):
        self.starts = 0
        self.result_reads = 0

    def request(self, method, path, body=None, **kw):
        if "backlog" in path:
            if self.starts >= 1:
                return 200, {"items": []}
            return 200, {"items": [{"id": "itm-interrupted", "status": "ready"}]}
        if method == "POST" and path == "/v1/runs":
            self.starts += 1
            return 200, {"runId": "r-int"}
        if path.endswith("/result"):
            self.result_reads += 1
            # What historicalBody writes for an interrupted record: no outcome —
            # it was cut off before reaching one — and no endedAt.
            return 200, {"state": "interrupted", "itemStatus": "active",
                         "historical": True}
        return 200, {}


for as_json in (True, False):
    label = "--json" if as_json else "human mode"
    stream = "stderr" if as_json else "stdout"
    stub = InterruptedStub()
    began = time.monotonic()
    out, err = drive_marathon(as_json=as_json, client=stub)
    elapsed = time.monotonic() - began
    narrated = err if as_json else out

    # drive_marathon passes --timeout-min 1, and kv.time.sleep is stubbed out
    # above, so the old poll-to-the-deadline spun for a full real minute.
    check("interrupted run, %s: the poll ends on the first read" % label,
          stub.result_reads == 1, "read /result %d times" % stub.result_reads)
    check("interrupted run, %s: returns without sitting out the timeout" % label,
          elapsed < 5, "took %.1fs" % elapsed)

    check("interrupted run, %s: the scorecard counts it apart from rescues" % label,
          "interrupted:  1" in narrated and "rescues:      0" in narrated,
          "%s: %r" % (stream, narrated[-400:]))
    check("interrupted run, %s: it is neither completed nor blocked" % label,
          "completed:    0" in narrated and "blocked:      0" in narrated,
          "%s: %r" % (stream, narrated[-400:]))

    # The per-item line says what happened rather than reporting a run that ran.
    check("interrupted run, %s: the per-item line says interrupted" % label,
          "itm-interrupted: interrupted" in narrated
          and "ran itm-interrupted" not in narrated,
          "%s: %r" % (stream, narrated[:400]))

    # The SLO #1 check is a report row, so it lands wherever the report does:
    # inside the JSON document, or on stdout beside the other marks.
    if as_json:
        try:
            doc = json.loads(out)
        except ValueError as exc:
            check("interrupted run, --json: stdout is one JSON document", False, str(exc))
        else:
            check("interrupted run, --json: stdout is one JSON document", True)
            slo = [c for c in doc["checks"] if "zero rescues" in c["name"]]
            check("interrupted run, --json: SLO #1 passes — it was not a rescue",
                  len(slo) == 1 and slo[0]["ok"] and slo[0]["detail"] == "0 rescues",
                  "row: %r" % (slo,))
    else:
        check("interrupted run, human mode: SLO #1 passes — it was not a rescue",
              "\033[32m✓\033[0m marathon: zero rescues (SLO #1)" in out,
              "stdout: %r" % out[-400:])
        check("interrupted run, human mode: nothing is diverted to stderr",
              err == "", "stderr: %r" % err[:200])

# --- And what a rescue still is: no terminal state inside the timeout ---------
#
# The other half of the split. `active` is a run genuinely still going when the
# clock ran out — the SLO #1 number — and it must keep counting as a rescue now
# that `interrupted` no longer does.
class ActiveStub:
    """One ready item whose run never leaves `active`, then a drained queue."""

    def __init__(self):
        self.starts = 0

    def request(self, method, path, body=None, **kw):
        if "backlog" in path:
            if self.starts >= 1:
                return 200, {"items": []}
            return 200, {"items": [{"id": "itm-slow", "status": "ready"}]}
        if method == "POST" and path == "/v1/runs":
            self.starts += 1
            return 200, {"runId": "r-slow"}
        if path.endswith("/result"):
            return 200, {"state": "active", "itemStatus": "active"}
        return 200, {}


# A fraction of a minute rather than the default 1, so the deadline the run does
# not beat arrives in a third of a second instead of sixty.
out, err = drive_marathon(as_json=False, client=ActiveStub(), timeout_min=0.005)
check("a run still going when the clock ran out is still a rescue",
      "rescues:      1" in out and "interrupted:  0" in out,
      "stdout: %r" % out[-400:])
check("and SLO #1 still reports it",
      "\033[31m✗\033[0m marathon: zero rescues (SLO #1)" in out,
      "stdout: %r" % out[-400:])

# --- A server that stopped answering: its own classification, not a rescue -----
#
# When the app quits, crashes or its port closes mid-run, every poll comes back
# from Client.request's connection-level arm as (0, {"error": ...}). run_one used
# to throw that status away, so `state` stayed None, the poll sat out the whole
# --timeout-min, and marathon called the run a rescue — reporting a violated
# SLO #1 that never happened, for a run nobody could even ask about.
class UnreachableStub:
    """One ready item whose run can be started, but whose `/result` never reaches
    the server again — the app went away under it. Counts the polls: waiting past
    the tolerated miss learns nothing."""

    def __init__(self):
        self.starts = 0
        self.result_reads = 0

    def request(self, method, path, body=None, **kw):
        if "backlog" in path:
            if self.starts >= 1:
                return 200, {"items": []}
            return 200, {"items": [{"id": "itm-gone", "status": "ready"}]}
        if method == "POST" and path == "/v1/runs":
            self.starts += 1
            return 200, {"runId": "r-gone"}
        if path.endswith("/result"):
            self.result_reads += 1
            return 0, {"error": "<urlopen error [Errno 61] Connection refused>"}
        return 200, {}


for as_json in (True, False):
    label = "--json" if as_json else "human mode"
    stream = "stderr" if as_json else "stdout"
    stub = UnreachableStub()
    began = time.monotonic()
    out, err = drive_marathon(as_json=as_json, client=stub)
    elapsed = time.monotonic() - began
    narrated = err if as_json else out

    # One miss is tolerated on purpose (a restarting app comes back), so the poll
    # gives up on the second — not on the first, and not at --timeout-min.
    check("unreachable server, %s: the poll gives up after the tolerated miss" % label,
          stub.result_reads == 2, "read /result %d times" % stub.result_reads)
    check("unreachable server, %s: returns without sitting out the timeout" % label,
          elapsed < 5, "took %.1fs" % elapsed)

    check("unreachable server, %s: the scorecard counts it apart from rescues" % label,
          "unreachable:  1" in narrated and "rescues:      0" in narrated,
          "%s: %r" % (stream, narrated[-400:]))
    check("unreachable server, %s: it is neither completed nor blocked nor interrupted"
          % label,
          "completed:    0" in narrated and "blocked:      0" in narrated
          and "interrupted:  0" in narrated,
          "%s: %r" % (stream, narrated[-400:]))

    # The per-item line says the server went away, not that a run ran.
    check("unreachable server, %s: the per-item line says unreachable" % label,
          "itm-gone: unreachable" in narrated and "ran itm-gone" not in narrated,
          "%s: %r" % (stream, narrated[:400]))

    if as_json:
        try:
            doc = json.loads(out)
        except ValueError as exc:
            check("unreachable server, --json: stdout is one JSON document", False, str(exc))
        else:
            check("unreachable server, --json: stdout is one JSON document", True)
            slo = [c for c in doc["checks"] if "zero rescues" in c["name"]]
            check("unreachable server, --json: SLO #1 passes — it was not a rescue",
                  len(slo) == 1 and slo[0]["ok"] and slo[0]["detail"] == "0 rescues",
                  "row: %r" % (slo,))
    else:
        check("unreachable server, human mode: SLO #1 passes — it was not a rescue",
              "\033[32m✓\033[0m marathon: zero rescues (SLO #1)" in out,
              "stdout: %r" % out[-400:])
        check("unreachable server, human mode: nothing is diverted to stderr",
              err == "", "stderr: %r" % err[:200])


# One miss is a blip, not a departure: the app restarted and came back, and the
# record is readable again. That run finished, and is counted as having finished.
class FlakyStub:
    """One ready item whose first `/result` poll never reaches the server and
    whose second reads `finished`."""

    def __init__(self):
        self.starts = 0
        self.result_reads = 0

    def request(self, method, path, body=None, **kw):
        if "backlog" in path:
            if self.starts >= 1:
                return 200, {"items": []}
            return 200, {"items": [{"id": "itm-flaky", "status": "ready"}]}
        if method == "POST" and path == "/v1/runs":
            self.starts += 1
            return 200, {"runId": "r-flaky"}
        if path.endswith("/result"):
            self.result_reads += 1
            if self.result_reads == 1:
                return 0, {"error": "<urlopen error [Errno 61] Connection refused>"}
            return 200, {"state": "finished", "outcome": "done",
                         "itemStatus": "done", "qualityScore": 0.88}
        return 200, {}


stub = FlakyStub()
out, err = drive_marathon(as_json=False, client=stub)
check("a single failed poll is tolerated — the next one is still read",
      stub.result_reads == 2, "read /result %d times" % stub.result_reads)
check("and a run that then reads finished is completed, not unreachable",
      "completed:    1" in out and "unreachable:  0" in out
      and "rescues:      0" in out,
      "stdout: %r" % out[-400:])
check("the finished body is what is reported, not the failed poll's error",
      "ran itm-flaky: state=finished" in out and "score=0.88" in out,
      "stdout: %r" % out[:400])

# --- An auto-approved marathon looks at whether the approval landed -----------
#
# `--auto-approve` fired the POST and threw its (status, body) away. A gate that
# refused — 409 for a dirty checkout, a branch holding nothing, a failing verify
# — a run the server no longer has (404), or a server that had gone away (0) all
# left the item sitting at its gate overnight, and the report that came back in
# the morning was indistinguishable from one where every approval landed.
class ApprovingStub:
    """One ready item that runs to its approval gate, then a drained queue. The
    approve answers whatever this stub was built with, and counts its calls."""

    LANDED = {"runId": "r-appr", "item": "itm-gated", "resolved": "approved",
              "status": "done"}

    def __init__(self, status=200, body=None):
        self.status = status
        self.body = self.LANDED if body is None else body
        self.starts = 0
        self.approves = 0

    def request(self, method, path, body=None, **kw):
        if "backlog" in path:
            if self.starts >= 1:
                return 200, {"items": []}
            return 200, {"items": [{"id": "itm-gated", "status": "ready"}]}
        if method == "POST" and path == "/v1/runs":
            self.starts += 1
            return 200, {"runId": "r-appr"}
        if path.endswith("/result"):
            return 200, {"state": "finished", "outcome": "awaiting_approval",
                         "itemStatus": "awaiting-approval", "qualityScore": 0.9}
        if path.endswith("/approve"):
            self.approves += 1
            return self.status, self.body
        return 200, {}


APPROVE_ROW = "marathon: approve itm-gated → done"
REFUSAL = "the checkout holds uncommitted changes"

for as_json in (True, False):
    label = "--json" if as_json else "human mode"
    stream = "stderr" if as_json else "stdout"
    stub = ApprovingStub(status=409, body={"resolved": "not approved",
                                           "status": "awaiting-approval",
                                           "reason": REFUSAL})
    out, err = drive_marathon(as_json=as_json, client=stub)
    narrated = err if as_json else out

    check("refused approve, %s: the POST is still sent, once" % label,
          stub.approves == 1, "approved %d times" % stub.approves)
    check("refused approve, %s: the line names the item and the answer" % label,
          "itm-gated: approve did not land" in narrated
          and "status=409" in narrated and REFUSAL in narrated,
          "%s: %r" % (stream, narrated[-500:]))
    # A row nobody looks at is the failure this case exists for: the harness has
    # to come back non-zero, not merely print something.
    check("refused approve, %s: the harness exits non-zero" % label,
          drive_marathon.exit_code != 0, "exit=%r" % drive_marathon.exit_code)
    # And the item is still counted as completed — docs/success-metrics.md counts
    # one that reached `awaiting-approval` as completed, which the failed
    # approval does not change.
    check("refused approve, %s: the scorecard still counts it completed" % label,
          "completed:    1" in narrated, "%s: %r" % (stream, narrated[-400:]))

    if as_json:
        try:
            doc = json.loads(out)
        except ValueError as exc:
            check("refused approve, --json: stdout is one JSON document", False, str(exc))
        else:
            check("refused approve, --json: stdout is one JSON document", True)
            rows = [c for c in doc["checks"] if c["name"] == APPROVE_ROW]
            check("refused approve, --json: the report carries it as a failed check",
                  len(rows) == 1 and not rows[0]["ok"] and REFUSAL in rows[0]["detail"],
                  "rows: %r" % (rows,))
    else:
        check("refused approve, human mode: the failed row prints beside the others",
              "\033[31m✗\033[0m %s" % APPROVE_ROW in out, "stdout: %r" % out[-500:])
        check("refused approve, human mode: nothing is diverted to stderr",
              err == "", "stderr: %r" % err[:200])

# The answer the check is for: 200, and the item came back `done`.
stub = ApprovingStub()
out, err = drive_marathon(as_json=True, client=stub)
try:
    doc = json.loads(out)
except ValueError as exc:
    check("approve that landed: stdout is one JSON document", False, str(exc))
else:
    check("approve that landed: stdout is one JSON document", True)
    rows = [c for c in doc["checks"] if c["name"] == APPROVE_ROW]
    check("approve that landed: the report carries the row, passing",
          len(rows) == 1 and rows[0]["ok"], "rows: %r" % (rows,))
    check("approve that landed: the harness exits zero",
          drive_marathon.exit_code == 0,
          "exit=%r, checks=%r" % (drive_marathon.exit_code, doc["checks"]))
check("approve that landed: it adds no narration of its own",
      "approve" not in err, "stderr: %r" % err[-400:])

out, err = drive_marathon(as_json=False, client=ApprovingStub())
check("approve that landed, human mode: the row prints passing",
      "\033[32m✓\033[0m %s" % APPROVE_ROW in out, "stdout: %r" % out[-500:])
check("approve that landed, human mode: nothing is diverted to stderr",
      err == "", "stderr: %r" % err[:200])

# A server that went away answers no status at all — the connection-level arm of
# Client.request — and that is not an approval that landed either.
stub = ApprovingStub(status=0, body={"error": "<urlopen error [Errno 61] Connection refused>"})
out, err = drive_marathon(as_json=True, client=stub)
rows = [c for c in json.loads(out)["checks"] if c["name"] == APPROVE_ROW]
check("an approve nobody answered is a failed row too",
      len(rows) == 1 and not rows[0]["ok"], "rows: %r" % (rows,))
check("and its line names the status and the error",
      "status=0" in err and "Connection refused" in err, "stderr: %r" % err[-400:])

# --- What a run ended as, not merely that it ended ----------------------------
#
# `PersistedRunRecord.Outcome` names five endings a run can be read back with,
# and two of them delivered nothing: `cancelled` — somebody, or a POST
# /v1/runs/<id>/cancel, stopped it — and `did_not_run`, a start a pickup gate
# refused before any work began. Both answer `"state": "finished"`, so both used
# to fall into the else arm and carry the headline number: a night whose only
# terminal runs were these passed `marathon: completed at least one item` over a
# tree nothing had touched.
class OutcomeStub:
    """One ready item whose run reaches a terminal state with whatever outcome
    and item status this stub was built with, then a drained queue."""

    def __init__(self, item, outcome, item_status):
        self.item = item
        self.outcome = outcome
        self.item_status = item_status
        self.starts = 0

    def request(self, method, path, body=None, **kw):
        if "backlog" in path:
            if self.starts >= 1:
                return 200, {"items": []}
            return 200, {"items": [{"id": self.item, "status": "ready"}]}
        if method == "POST" and path == "/v1/runs":
            self.starts += 1
            return 200, {"runId": "r-out"}
        if path.endswith("/result"):
            return 200, {"state": "finished", "outcome": self.outcome,
                         "itemStatus": self.item_status, "qualityScore": 0.9}
        if path.endswith("/approve"):
            return 200, {"runId": "r-out", "item": self.item,
                         "resolved": "approved", "status": "done"}
        return 200, {}


COMPLETED_ROW = "marathon: completed at least one item"
# A cancelled run and a refused pickup both leave the item back at `ready` —
# `endingForRun` reads exactly that status to reach `.cancelled` — so neither
# reaches the blocked arm ahead of them, and the reading under test is the
# outcome itself.
DELIVERED_NOTHING = [
    ("cancelled", "itm-cancelled", "cancelled:    1", "did not run:  0"),
    ("did_not_run", "itm-never-picked-up", "did not run:  1", "cancelled:    0"),
]

for outcome, item, own_line, other_line in DELIVERED_NOTHING:
    for as_json in (True, False):
        label = "%s, %s" % (outcome, "--json" if as_json else "human mode")
        stream = "stderr" if as_json else "stdout"
        out, err = drive_marathon(as_json=as_json,
                                  client=OutcomeStub(item, outcome, "ready"))
        narrated = err if as_json else out

        check("%s: it is not counted as completed" % label,
              "completed:    0" in narrated, "%s: %r" % (stream, narrated[-500:]))
        check("%s: it is counted on its own line, naming the item" % label,
              ("%s  (%s)" % (own_line, item)) in narrated,
              "%s: %r" % (stream, narrated[-500:]))
        check("%s: the other line stays at zero, unnamed" % label,
              ("%s\n" % other_line) in narrated, "%s: %r" % (stream, narrated[-500:]))
        # It ended, so it is none of the three arms for a run that did not.
        check("%s: it is neither blocked nor a rescue nor unreachable" % label,
              "blocked:      0" in narrated and "rescues:      0" in narrated
              and "unreachable:  0" in narrated and "interrupted:  0" in narrated,
              "%s: %r" % (stream, narrated[-500:]))

        # The headline check is the whole point: a night like this one is not a
        # night the autopilot completed an item.
        if as_json:
            try:
                doc = json.loads(out)
            except ValueError as exc:
                check("%s: stdout is one JSON document" % label, False, str(exc))
            else:
                check("%s: stdout is one JSON document" % label, True)
                rows = [c for c in doc["checks"] if c["name"] == COMPLETED_ROW]
                check("%s: the completed-an-item check fails" % label,
                      len(rows) == 1 and not rows[0]["ok"]
                      and rows[0]["detail"] == "0 completed",
                      "rows: %r" % (rows,))
        else:
            check("%s: the completed-an-item check prints failing" % label,
                  "\033[31m✗\033[0m %s" % COMPLETED_ROW in out,
                  "stdout: %r" % out[-500:])
            check("%s: nothing is diverted to stderr" % label,
                  err == "", "stderr: %r" % err[:200])

# And the two endings that did deliver something still count, unchanged: `done`
# is an item the autopilot finished, and `awaiting_approval` one it finished and
# left at the human gate — which docs/success-metrics.md counts as completed.
for outcome, item, item_status in (("done", "itm-done", "done"),
                                   ("awaiting_approval", "itm-gate", "awaiting-approval")):
    out, err = drive_marathon(as_json=False,
                              client=OutcomeStub(item, outcome, item_status))
    check("a run that ended %s is still completed" % outcome,
          "completed:    1" in out and "cancelled:    0" in out
          and "did not run:  0" in out, "stdout: %r" % out[-500:])
    check("and the completed-an-item check passes for it",
          "\033[32m✓\033[0m %s" % COMPLETED_ROW in out, "stdout: %r" % out[-500:])

# --- run_loop names the unreachable server rather than reporting a null state --
class UnreachableRunStub:
    """A run that starts and is then unaskable — what run_loop sees when the app
    goes away under a --run."""

    def request(self, method, path, body=None, **kw):
        if method == "POST" and path == "/v1/runs":
            return 200, {"runId": "r-gone"}
        if path.endswith("/result"):
            return 0, {"error": "<urlopen error [Errno 61] Connection refused>"}
        return 200, {}


report = kv.Report(as_json=False)
_out, _err = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(_out), contextlib.redirect_stderr(_err):
    kv.run_loop(UnreachableRunStub(), report, "proj", "item",
                approve=False, timeout_min=1, repo_path=None)
terminal = [r for r in report.rows if r[0] == "run reached terminal/approval"]
check("run_loop still fails its terminal check when the server went away",
      len(terminal) == 1 and not terminal[0][1], "rows: %r" % (report.rows,))
check("and its detail names the unreachable server instead of a null state",
      terminal and "stopped answering" in terminal[0][2]
      and "state=None" not in terminal[0][2],
      "detail: %r" % (terminal[0][2] if terminal else None,))

# --- The guardrail flags reach the run they were passed with ------------------
#
# --worktree and the cost caps were parsed on the --run path and then dropped:
# only the marathon ever called configure_autopilot. A --run --repo-path then
# checked for the isolation nobody had asked the app for and reported it missing
# as if the app had lost it. These cases drive main() itself — the wiring is what
# broke — with the network replaced by a stub that records what was sent.
class RecordingStub:
    """Records every request, and answers a --run's start and poll so run_loop
    reaches its end. The cases read `calls` for what was sent, and in what order."""

    def __init__(self):
        self.calls = []

    @property
    def puts(self):
        return [body for method, path, body in self.calls
                if method == "PUT" and path == "/v1/autopilot"]

    def request(self, method, path, body=None, **kw):
        self.calls.append((method, path, body))
        if method == "PUT" and path == "/v1/autopilot":
            return 200, dict(body or {})          # the server echoes the config back
        if method == "POST" and path == "/v1/runs":
            return 200, {"runId": "r-cfg"}
        if path.endswith("/result"):
            return 200, {"state": "finished", "outcome": "completed",
                         "itemStatus": "done"}
        if "backlog" in path:
            return 200, {"items": []}             # a drained queue ends a marathon
        return 200, {}


def drive_main(*argv):
    """Run main() end to end with Client replaced by a RecordingStub. No socket is
    opened and no subprocess is started; --token keeps it off the token file too."""
    stub = RecordingStub()
    real_client, real_argv = kv.Client, sys.argv
    kv.Client = lambda base, token: stub
    sys.argv = ["kiteloop-verify.py", "--token", "x", *argv]
    out, err = io.StringIO(), io.StringIO()
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                kv.main()
                code = 0
            except SystemExit as exc:
                code = exc.code
    finally:
        kv.Client, sys.argv = real_client, real_argv
    return stub, code, out.getvalue(), err.getvalue()


def index_of(calls, method, path):
    for i, (m, p, _) in enumerate(calls):
        if m == method and p == path:
            return i
    return -1


stub, _, _, _ = drive_main("--run", "proj", "item", "--timeout-min", "1", "--worktree")
check("--run --worktree configures the run it was passed with",
      stub.puts == [{"project": "proj", "useWorktree": True}],
      "PUTs: %r" % (stub.puts,))
check("--run --worktree configures it before the run is started",
      -1 < index_of(stub.calls, "PUT", "/v1/autopilot") < index_of(stub.calls, "POST", "/v1/runs"),
      "calls: %r" % ([(m, p) for m, p, _ in stub.calls],))

stub, _, _, _ = drive_main("--run", "proj", "item", "--timeout-min", "1",
                           "--session-cap", "5", "--per-item-cap", "2", "--margin", "1.5")
check("--run carries the cost caps too, in the payload the marathon sends",
      stub.puts == [{"project": "proj", "sessionCostCapUSD": 5.0,
                     "perItemCostCapUSD": 2.0, "costCapMargin": 1.5}],
      "PUTs: %r" % (stub.puts,))

# Unchanged behaviour: a plain --run asks for nothing, so it sends nothing.
stub, _, _, _ = drive_main("--run", "proj", "item", "--timeout-min", "1")
check("--run with no guardrail flag issues no PUT at all",
      stub.puts == [] and index_of(stub.calls, "PUT", "/v1/autopilot") == -1,
      "calls: %r" % ([(m, p) for m, p, _ in stub.calls],))

# And the marathon path is untouched — --auto-merge still implies a worktree, and
# still warns when it is the item's own verify standing alone as the merge gate.
stub, _, out, _ = drive_main("--marathon", "proj", "--hours", "0.01", "--auto-merge")
check("--marathon --auto-merge still implies useWorktree",
      stub.puts == [{"project": "proj", "autoMergeOnApproval": True,
                     "useWorktree": True}],
      "PUTs: %r" % (stub.puts,))
check("--marathon --auto-merge without --merge-verify still warns",
      "WARNING: --auto-merge without --merge-verify" in out,
      "stdout: %r" % out[:400])

stub, _, _, _ = drive_main("--marathon", "proj", "--hours", "0.01",
                           "--auto-merge", "--merge-verify", "make test")
check("--marathon --merge-verify still rides along with --auto-merge",
      stub.puts == [{"project": "proj", "autoMergeOnApproval": True,
                     "useWorktree": True, "autoMergeVerifyCommand": "make test"}],
      "PUTs: %r" % (stub.puts,))

# --- A --repo-path git cannot read fails its checks rather than passing them ---
#
# `git()` handed back stdout and nothing else, so a mistyped path, a deleted
# checkout or a plain directory all answered `""`: run_loop compared that empty
# string against the empty string it took afterwards and recorded "worktree
# isolation: main tree unchanged — no new changes in main tree" having compared
# nothing, which is exactly the reading the harness exists to prevent. The branch
# check beside it read the same empty output as `(missing)` and blamed a branch
# that was never looked for.
class BranchRunStub:
    """A run that starts, finishes and reports a branch, so both isolation checks
    are reached. `on_poll` is the run's side effect on the main tree — what a run
    that failed to isolate itself would leave behind."""

    def __init__(self, on_poll=None):
        self.on_poll = on_poll

    def request(self, method, path, body=None, **kw):
        if method == "POST" and path == "/v1/runs":
            return 200, {"runId": "r-iso"}
        if path.endswith("/result"):
            if self.on_poll:
                self.on_poll()
            return 200, {"state": "finished", "outcome": "completed",
                         "itemStatus": "done", "branch": "kiteloop/itm"}
        return 200, {}


def drive_run_loop(repo_path, client=None):
    """run_loop for real against a stub client, with both streams captured and
    the report finished so its exit status can be read."""
    report = kv.Report(as_json=False)
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        kv.run_loop(client or BranchRunStub(), report, "proj", "item",
                    approve=False, timeout_min=1, repo_path=repo_path)
        code = report.finish()
    return report, code, out.getvalue(), err.getvalue()


def rows_named(report, prefix):
    return [r for r in report.rows if r[0].startswith(prefix)]


def make_repo(branch="kiteloop/itm"):
    """A real one-commit repository in a temporary directory — the readable case,
    which must keep behaving exactly as it did."""
    path = tempfile.mkdtemp(prefix="kv-repo-")

    def g(*args):
        subprocess.run(["git", "-C", path, *args], capture_output=True,
                       text=True, check=True)

    g("init", "-q")
    g("config", "user.email", "t@example.com")
    g("config", "user.name", "t")
    g("config", "commit.gpgsign", "false")
    with open(os.path.join(path, "README"), "w") as f:
        f.write("x\n")
    g("add", "-A")
    g("commit", "-qm", "init")
    if branch:
        g("branch", branch)
    return path


# A directory that is not a repository. mkdtemp puts it under the system temp
# root, which no checkout encloses, so `git -C` there fails on every machine.
not_a_repo = tempfile.mkdtemp(prefix="kv-not-a-repo-")
report, code, out, _ = drive_run_loop(not_a_repo)
iso = rows_named(report, "worktree isolation: main tree")
check("an unreadable --repo-path fails the main-tree check instead of passing it",
      len(iso) == 1 and not iso[0][1] and code != 0,
      "rows: %r exit=%s" % (report.rows, code))
check("and the failed check names the path and what git said about it",
      iso and not_a_repo in iso[0][2] and "not a git repository" in iso[0][2].lower(),
      "detail: %r" % (iso[0][2] if iso else None,))
branch_rows = rows_named(report, "worktree isolation: run branch")
check("the branch check says the repo could not be read, not that a branch is missing",
      len(branch_rows) == 1 and not branch_rows[0][1]
      and "(missing)" not in branch_rows[0][2]
      and "could not read repo" in branch_rows[0][2],
      "rows: %r" % (report.rows,))
check("and the unreadable path is narrated up front, before the run's checks",
      "repo path unreadable" in out and not_a_repo in out
      and out.index("repo path unreadable") < out.index("start run"),
      "stdout: %r" % out[:400])

# The narration is narration: --json still prints exactly one document, and the
# failure is inside it.
_stub, code, out, err = drive_main("--run", "proj", "item", "--timeout-min", "1",
                                   "--repo-path", not_a_repo, "--json")
try:
    doc = json.loads(out)
except ValueError as exc:
    check("an unreadable --repo-path leaves --json stdout one JSON document",
          False, "%s — stdout: %r" % (exc, out[:200]))
else:
    failing = [c for c in doc["checks"]
               if c["name"] == "worktree isolation: main tree unchanged" and not c["ok"]]
    check("an unreadable --repo-path leaves --json stdout one JSON document",
          isinstance(doc, dict) and len(failing) == 1 and code != 0,
          "exit=%s doc: %r" % (code, doc))
    check("and its narration stays on stderr",
          "repo path unreadable" in err and "repo path unreadable" not in out,
          "stderr: %r" % err[:300])
shutil.rmtree(not_a_repo, ignore_errors=True)

# --- A repo git can read behaves exactly as it always has ---------------------
repo = make_repo()
report, code, _, _ = drive_run_loop(repo)
iso = rows_named(report, "worktree isolation: main tree")
check("a readable repo whose main tree is unchanged still passes",
      len(iso) == 1 and iso[0][1] and iso[0][2] == "no new changes in main tree",
      "rows: %r" % (report.rows,))
branch_rows = rows_named(report, "worktree isolation: run branch")
check("and the branch the run reported is still found, so the run is all green",
      len(branch_rows) == 1 and branch_rows[0][1] and code == 0,
      "rows: %r exit=%s" % (report.rows, code))
shutil.rmtree(repo, ignore_errors=True)

repo = make_repo()


def leak_into_main_tree():
    with open(os.path.join(repo, "leaked.txt"), "w") as f:
        f.write("a run that did not isolate itself\n")


report, code, _, _ = drive_run_loop(repo, BranchRunStub(on_poll=leak_into_main_tree))
iso = rows_named(report, "worktree isolation: main tree")
check("a readable repo whose main tree changed under the run still fails",
      len(iso) == 1 and not iso[0][1] and iso[0][2] == "main tree changed!" and code != 0,
      "rows: %r exit=%s" % (report.rows, code))
shutil.rmtree(repo, ignore_errors=True)

# A branch genuinely absent from a repo git *could* read is still that: `git
# branch --list` exits 0 with nothing to say, which is not a failure to read.
repo = make_repo(branch=None)
report, _, _, _ = drive_run_loop(repo)
branch_rows = rows_named(report, "worktree isolation: run branch")
check("a branch absent from a readable repo still reads (missing)",
      len(branch_rows) == 1 and not branch_rows[0][1]
      and branch_rows[0][2] == "(missing)",
      "rows: %r" % (report.rows,))
shutil.rmtree(repo, ignore_errors=True)

# --- Whether the app took the guardrails is checked, not just narrated --------
#
# The PUT was narration only: a 409 (a run already in flight) or a 400 left every
# knob where it was, and the run that followed ran with none of --session-cap,
# --per-item-cap, --margin, --worktree or --auto-merge in force while the report
# still said every check passed. These drive the real configure_autopilot with a
# stub standing in for the handler, which echoes the whole config back.
class ConfigStub:
    """PUT /v1/autopilot answering as the handler does — the keys it was sent,
    alongside the knobs nobody set at their own values. `override` is what a
    server that did not take a value sends back instead; a non-200 `status` is
    the refusal, which carries no config at all."""

    def __init__(self, status=200, override=None):
        self.status = status
        self.override = override or {}
        self.calls = []

    def request(self, method, path, body=None, **kw):
        self.calls.append((method, path, body))
        if self.status != 200:
            return self.status, {"error": "autopilot run in flight"}
        echoed = {"sessionCostCapUSD": None, "perItemCostCapUSD": None,
                  "costCapMargin": 1.25, "useWorktree": False,
                  "autoMergeOnApproval": False, "autoMergeVerifyCommand": None}
        echoed.update({k: v for k, v in (body or {}).items() if k != "project"})
        echoed.update(self.override)
        return 200, echoed


def drive_configure(client, as_json=True, **flags):
    """Call configure_autopilot for real, with every flag defaulted to unset, and
    hand back the report it wrote along with both streams and its exit status."""
    kwargs = dict(session_cap=None, per_item_cap=None, margin=None,
                  auto_merge=False, merge_verify=None, worktree=False)
    kwargs.update(flags)
    report = kv.Report(as_json=as_json)
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        kv.configure_autopilot(client, report, "proj", **kwargs)
        code = report.finish()
    return report, code, out.getvalue(), err.getvalue()


GUARDRAILS = dict(session_cap=5.0, per_item_cap=2.0, margin=1.5, worktree=True)

report, code, out, err = drive_configure(ConfigStub(), **GUARDRAILS)
rows = [r for r in report.rows if "guardrail" in r[0]]
check("a 200 echoing what was asked for adds a passing check",
      len(rows) == 1 and rows[0][1], "rows: %r" % (report.rows,))
check("and the run is otherwise unchanged — that check is all it adds",
      len(report.rows) == 1 and code == 0, "rows: %r exit=%s" % (report.rows, code))
check("the configuration check is a report row, not a write to stdout",
      json.loads(out)["total"] == 1 and "Configured autopilot" in err,
      "stdout: %r stderr: %r" % (out[:200], err[:200]))

# A 200 the caller cannot trust: the server answered, but kept its own margin.
report, code, _, _ = drive_configure(
    ConfigStub(override={"costCapMargin": 1.25}), **GUARDRAILS)
rows = [r for r in report.rows if "guardrail" in r[0]]
check("a 200 that did not take a value the caller set fails the check",
      len(rows) == 1 and not rows[0][1] and code != 0,
      "rows: %r exit=%s" % (report.rows, code))
check("and the failed check names the knob the server did not take",
      rows and "costCapMargin" in rows[0][2] and "1.5" in rows[0][2],
      "detail: %r" % (rows[0][2] if rows else None,))

for status in (409, 400):
    report, code, _, _ = drive_configure(ConfigStub(status=status), **GUARDRAILS)
    rows = [r for r in report.rows if "guardrail" in r[0]]
    check("a %d from PUT /v1/autopilot fails the check, so finish() is non-zero"
          % status,
          len(rows) == 1 and not rows[0][1] and code != 0,
          "rows: %r exit=%s" % (report.rows, code))
    check("and the failed check carries the status it came back with",
          rows and str(status) in rows[0][2], "detail: %r" % (rows[0][2] if rows else None,))

# Nothing was asked for, so there is nothing to check — and nothing to send.
stub = ConfigStub()
report, code, out, err = drive_configure(stub)
check("passing no guardrail flag adds no check at all, and issues no PUT",
      report.rows == [] and stub.calls == [] and code == 0,
      "rows: %r calls: %r" % (report.rows, stub.calls))

# --auto-merge is checked on the two keys it implies, not on the one flag typed.
report, _, _, _ = drive_configure(
    ConfigStub(override={"useWorktree": False}), auto_merge=True)
rows = [r for r in report.rows if "guardrail" in r[0]]
check("--auto-merge fails the check when the implied worktree did not take",
      len(rows) == 1 and not rows[0][1] and "useWorktree" in rows[0][2],
      "rows: %r" % (report.rows,))

# --- A guardrail flag with neither mode is refused, not silently dropped -------
#
# Driven through the real command line: argparse's error path exits before a
# client is built, so this needs no stub and touches nothing.
for flag in ("--worktree", "--auto-merge"):
    code, out, err = run(flag)
    check("%s with neither --run nor --marathon exits non-zero" % flag,
          code != 0, "exit=%d" % code)
    check("%s with neither mode names the flag it is refusing" % flag,
          flag in err, "stderr: %r" % err[:300])
    check("%s with neither mode runs no smoke checks" % flag,
          "Smoke checks" not in out and "server up" not in out,
          "stdout: %r" % out[:300])

code, out, err = run("--session-cap", "5", "--margin", "1.5")
check("several guardrail flags with neither mode name all of them",
      code != 0 and "--session-cap" in err and "--margin" in err,
      "exit=%d stderr: %r" % (code, err[:300]))

# --- And so is a flag that shapes the run itself ------------------------------
#
# --repo-path verifies an isolation only a run can have, --approve and
# --auto-approve clear a gate only a run can raise, and the two clocks bound a
# wait there is nothing to wait for. Each was accepted in silence, so
# `--repo-path /tmp --approve --auto-approve --hours 3` ran the read-only smoke
# checks and reported on them having isolated nothing and approved nothing.
SHAPING = [
    ("--repo-path", ["--repo-path", "/tmp"]),
    ("--approve", ["--approve"]),
    ("--auto-approve", ["--auto-approve"]),
    ("--timeout-min", ["--timeout-min", "5"]),
    ("--hours", ["--hours", "3"]),
]

for flag, argv in SHAPING:
    code, out, err = run(*argv)
    check("%s with neither --run nor --marathon exits non-zero" % flag,
          code != 0, "exit=%d" % code)
    check("%s with neither mode names the flag it is refusing" % flag,
          flag in err, "stderr: %r" % err[:300])
    # Before any request is made: the smoke checks are what the caller would
    # otherwise get back, dressed up as a run that honoured the flag.
    check("%s with neither mode runs no smoke checks, and prints nothing" % flag,
          out == "", "stdout: %r" % out[:300])

code, out, err = run("--repo-path", "/tmp", "--approve", "--auto-approve", "--hours", "3")
check("several run-shaping flags with neither mode name all of them",
      code != 0 and all(f in err for f in ("--repo-path", "--approve",
                                           "--auto-approve", "--hours")),
      "exit=%d stderr: %r" % (code, err[:300]))
check("several run-shaping flags with neither mode still print nothing on stdout",
      out == "", "stdout: %r" % out[:300])

# --- With a run, they behave exactly as they did -------------------------------
#
# --timeout-min and --hours now parse as None so that "was it given?" has an
# answer, and their defaults are applied where they are read. A run driven
# without either reaches its poll rather than raising on `None * 60`.
stub, _, _, _ = drive_main("--run", "proj", "item")
check("--run without --timeout-min still applies the default and polls the run",
      index_of(stub.calls, "GET", "/v1/runs/r-cfg/result") > -1,
      "calls: %r" % ([(m, p) for m, p, _ in stub.calls],))

stub, _, out, _ = drive_main("--marathon", "proj")
check("--marathon without --hours still applies the default and works the queue",
      index_of(stub.calls, "GET", "/v1/backlog?project=proj") > -1
      and "MARATHON SCORECARD" in out,
      "calls: %r  stdout: %r" % ([(m, p) for m, p, _ in stub.calls], out[-200:]))

stub, _, _, _ = drive_main("--run", "proj", "item", "--timeout-min", "1", "--approve")
check("--run --approve is still accepted and still starts the run",
      index_of(stub.calls, "POST", "/v1/runs") > -1,
      "calls: %r" % ([(m, p) for m, p, _ in stub.calls],))

stub, _, _, _ = drive_main("--marathon", "proj", "--hours", "0.01", "--auto-approve")
check("--marathon --auto-approve is still accepted and still works the queue",
      index_of(stub.calls, "GET", "/v1/backlog?project=proj") > -1,
      "calls: %r" % ([(m, p) for m, p, _ in stub.calls],))

# --- And an approval flag given to the mode that cannot read it is refused -----
#
# The gate above asks only "was there a run at all?", which both flags pass with
# either mode — but `run_loop` is handed `args.approve` and never sees
# `args.auto_approve`, and `marathon` the reverse. So each crossed pairing
# configured the project, drove a full run to the end, and dropped the flag in
# silence: the caller waited out the run believing it had approved.
CROSSED = [
    ("--auto-approve", "--marathon", ["--run", "proj", "item", "--auto-approve"]),
    ("--approve", "--run", ["--marathon", "proj", "--approve"]),
]

for flag, mode, argv in CROSSED:
    code, out, err = run(*argv)
    check("%s with %s exits non-zero" % (flag, argv[0]),
          code != 0, "exit=%d" % code)
    check("%s with %s names the flag and the mode it belongs to" % (flag, argv[0]),
          flag in err and mode in err, "stderr: %r" % err[:300])
    # argparse errors before a client is built, so the refusal costs no run at
    # all — not a started one, not even the read-only smoke checks.
    check("%s with %s starts no run, and prints nothing" % (flag, argv[0]),
          out == "", "stdout: %r" % out[:300])

# --- A smoke run that exercised no item contract is not a clean bill of health -
#
# `smoke()` records one `backlog[<name>] contract` row per open project. With no
# project open the loop never runs, so the report counted only /health, the 401
# and the 404 and called them 3/3; with a project whose backlog is empty the row
# is there but vacuous, because `all(...)` over an empty `items` is True. Both
# read exactly like a run that had checked the contract and found it kept.
ITEM = {"id": "itm-1", "title": "t", "status": "ready", "epic": "e"}
EXERCISED = "backlog contract exercised"


class SmokeStub:
    """The four answers a smoke run asks for — /health, the unauthenticated
    projects read, the authenticated one, and a backlog per project — driven from
    `backlogs`, a {project name: [item, ...]} mapping."""

    def __init__(self, backlogs):
        self.backlogs = backlogs

    def request(self, method, path, body=None, auth=True, **kw):
        if path == "/health":
            return 200, {"status": "ok", "version": "9.9.9",
                         "projectsOpen": len(self.backlogs)}
        if path == "/v1/projects":
            if not auth:
                return 401, {"error": "unauthorized"}
            return 200, {"projects": [{"name": n} for n in self.backlogs]}
        if path.startswith("/v1/backlog"):
            name = urllib.parse.unquote(path.split("project=", 1)[1])
            return 200, {"items": self.backlogs.get(name, [])}
        return 404, {"error": "not found"}


def drive_smoke(backlogs, as_json=False):
    report = kv.Report(as_json=as_json)
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        kv.smoke(SmokeStub(backlogs), report)
        code = report.finish()
    return report, code, out.getvalue(), err.getvalue()


# No project open: the loop body never ran, so nothing was compared.
report, code, out, _ = drive_smoke({})
rows = rows_named(report, EXERCISED)
check("no project open: the report carries the check, failed, and exits non-zero",
      len(rows) == 1 and not rows[0][1] and code != 0,
      "rows: %r exit=%s" % (report.rows, code))
check("no project open: the detail says no contract was exercised, and how to open one",
      rows and "no backlog contract was exercised" in rows[0][2]
      and "POST /v1/projects/open" in rows[0][2],
      "detail: %r" % (rows[0][2] if rows else None,))

# A project whose backlog is empty: the per-project row is there and still says
# what it always said, and it is still vacuous — `all(...)` over no items.
report, code, out, _ = drive_smoke({"kiteloop": []})
rows = rows_named(report, EXERCISED)
check("an empty backlog fails the same check, and exits non-zero",
      len(rows) == 1 and not rows[0][1] and code != 0,
      "rows: %r exit=%s" % (report.rows, code))
per_project = rows_named(report, "backlog[kiteloop] contract")
check("and the per-project row still reports its counts as it does today",
      len(per_project) == 1 and per_project[0][1]
      and per_project[0][2] == "0 items, 0 ready",
      "rows: %r" % (report.rows,))

# At least one item checked: the contract *was* exercised, so the run reports
# exactly what it reported before — same rows, same wording, same exit status.
report, code, out, _ = drive_smoke({"kiteloop": [ITEM]})
check("a project carrying items adds no row — the rows are the ones from before",
      [r[0] for r in report.rows] == [
          "server up (/health)", "auth enforced (401 without token)",
          "list projects", "backlog[kiteloop] contract", "unknown route → 404"],
      "rows: %r" % ([r[0] for r in report.rows],))
check("and every one of them passes, so the exit status is still zero",
      all(r[1] for r in report.rows) and code == 0,
      "rows: %r exit=%s" % (report.rows, code))
check("the per-project row's wording is untouched",
      rows_named(report, "backlog[kiteloop] contract")[0][2] == "1 items, 1 ready",
      "rows: %r" % (report.rows,))

# And the new row is a report row like any other: in --json it lands inside the
# document, with the narration still on stderr.
report, code, out, err = drive_smoke({}, as_json=True)
try:
    doc = json.loads(out)
except ValueError as exc:
    check("no project open: --json stdout is still exactly one JSON document",
          False, "%s — stdout: %r" % (exc, out[:200]))
else:
    failing = [c for c in doc["checks"] if c["name"] == EXERCISED and not c["ok"]]
    check("no project open: --json stdout is still exactly one JSON document",
          isinstance(doc, dict) and len(failing) == 1 and doc["passed"] < doc["total"],
          "doc: %r" % (doc,))
    check("no project open: the narration is still on stderr",
          "Smoke checks (read-only):" in err, "stderr: %r" % err[:200])

# --- The smoke pass looks at whether the suite has ever run, and when ----------
#
# Every check above reads the running app, and the app can be in perfect health
# over a suite whose newest recorded run is red, or was taken ninety commits ago.
# Neither reading appeared anywhere an operator or a driver looks before starting
# a night: the harness reported a healthy loop and said nothing about it.
#
# The two failing readings are the unambiguous ones — no record at all, and a
# newest row whose `exit` cell is non-zero. Drift is reported and never enforced,
# so an ordinary commit does not break the harness.
SUITE_HEADER = (
    "# Suite status\n"
    "\n"
    "One line per run, appended by the script itself.\n"
    "\n"
    "| when (UTC) | commit | tree | tally | exit | result bundle | failing tests"
    " | skipped tests | duration |\n"
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n")

GREEN_TALLY = "✔ 3364 tests passed (1 skipped) — 3346 XCTest, 18 swift-testing"
RED_TALLY = ("✘ 3362 tests, 2 failures (1 skipped) — 3344 XCTest (2 failures), "
             "18 swift-testing (0 failures)")
RED_NAMES = ("KiteloopTests.Phase2BIntegrationTests.testFullLifecycleWithCheckpoints, "
             "KiteloopTests.ControlRouterTests.testEveryEndpointMatchesItsRoute")


def suite_row(commit, tally, exit_status, failing="—", when="2026-08-11T10:24:03Z",
              tree="clean", skipped="—"):
    return (when, commit, tree, tally, str(exit_status),
            "Test-Kiteloop-2026.08.11_00-24-05--1000.xcresult", failing, skipped,
            "412s")


def write_record(*rows, header=SUITE_HEADER):
    fd, path = tempfile.mkstemp(prefix="kv-suite-", suffix=".md")
    with os.fdopen(fd, "w") as handle:
        handle.write(header)
        for row in rows:
            handle.write("| %s |\n" % " | ".join(row))
    return path


def write_file(repo, relpath, text="x\n"):
    path = os.path.join(repo, *relpath.split("/"))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(text)
    return path


def make_repo_with_commits(count):
    """A repository with `count` commits, and their short shas oldest first. Real
    history, so the drift the check reports comes from a real `rev-list --count`
    rather than from a stub standing in for one."""
    path = tempfile.mkdtemp(prefix="kv-drift-")

    def g(*args):
        return subprocess.run(["git", "-C", path, *args], capture_output=True,
                              text=True, check=True).stdout.strip()

    g("init", "-q")
    g("config", "user.email", "t@example.com")
    g("config", "user.name", "t")
    g("config", "commit.gpgsign", "false")
    shas = []
    for i in range(count):
        with open(os.path.join(path, "f%d" % i), "w") as handle:
            handle.write("x\n")
        g("add", "-A")
        g("commit", "-qm", "c%d" % i)
        shas.append(g("rev-parse", "--short", "HEAD"))
    return path, shas


def drive_suite_record(record_path, repo_path=None, as_json=False):
    report = kv.Report(as_json=as_json)
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        kv.suite_record(report, record_path=record_path, repo_path=repo_path)
        code = report.finish()
    return report, code, out.getvalue(), err.getvalue()


def suite_row_of(report):
    rows = [r for r in report.rows if r[0] == kv.SUITE_RECORD_CHECK]
    return rows[0] if len(rows) == 1 else None


# The record it reads is the one shipping beside the script, resolved from
# __file__ — not one found relative to whatever directory the harness was
# invoked from, which is the working directory of whoever started the night.
check("the record the check reads is the one shipping beside the script",
      kv.SUITE_RECORD_PATH == os.path.join(os.path.dirname(HERE), "docs",
                                           "suite-status.md")
      and os.path.exists(kv.SUITE_RECORD_PATH),
      "path: %r" % kv.SUITE_RECORD_PATH)

# A red newest row: the failing reading this check exists for, and its detail has
# to name what was red — otherwise the operator's next step is to run the suite
# again to find out, which is the whole cost this row was added to save.
record = write_record(suite_row("bf9dd36", GREEN_TALLY, 0),
                      suite_row("349e40d", RED_TALLY, 65, failing=RED_NAMES))
report, code, _, _ = drive_suite_record(record)
row = suite_row_of(report)
check("a red newest row fails the check, so the harness exits non-zero",
      row is not None and not row[1] and code != 0,
      "rows: %r exit=%s" % (report.rows, code))
check("and its detail names the tests that row recorded as failing",
      row and all(name in row[2] for name in RED_NAMES.split(", ")),
      "detail: %r" % (row[2] if row else None,))
check("and it says the run was red, with the exit status the row carries",
      row and "red" in row[2] and "exit 65" in row[2],
      "detail: %r" % (row[2] if row else None,))
os.unlink(record)

# A red row from before the failing-tests column existed still fails, and says
# that the names are not there rather than printing an empty list.
record = write_record(suite_row("349e40d", RED_TALLY, 65, failing="—"))
report, code, _, _ = drive_suite_record(record)
row = suite_row_of(report)
check("a red row that recorded no failing names still fails, and says so",
      row is not None and not row[1] and code != 0
      and "not recorded in that row" in row[2],
      "rows: %r exit=%s" % (report.rows, code))
os.unlink(record)

# The newest row is the measurement, in both directions: a red run followed by a
# green one is a green tree, and a green run followed by a red one is not.
record = write_record(suite_row("349e40d", RED_TALLY, 65, failing=RED_NAMES),
                      suite_row("bf9dd36", GREEN_TALLY, 0))
report, code, _, _ = drive_suite_record(record)
row = suite_row_of(report)
check("a green row newer than a red one passes — the newest row is the reading",
      row is not None and row[1] and code == 0,
      "rows: %r exit=%s" % (report.rows, code))
check("and its detail carries the recorded commit and the tally",
      row and "bf9dd36" in row[2] and GREEN_TALLY in row[2],
      "detail: %r" % (row[2] if row else None,))
os.unlink(record)

# --- A row that measured nothing is not a green row ---------------------------
#
# xcodebuild returns 0 for a run that matched no tests, so such a row records
# exit 0 and a tally saying no framework reported a summary. Read off the `exit`
# cell alone it was reported to the operator as a green suite — the 'green
# because it never ran' answer the harness exists to refuse. The suite runner
# already refuses it on its own account: `exit_status_for` exits NO_TALLY_STATUS
# for exactly that run, while the recorded cell stays xcodebuild's.
with open(os.path.join(HERE, "run-unit-suite.sh")) as handle:
    check("the no-tally cell the check reads is the one the suite runner writes",
          kv.SUITE_RECORD_NO_TALLY in handle.read(),
          "cell: %r" % (kv.SUITE_RECORD_NO_TALLY,))

record = write_record(suite_row("bf9dd36", GREEN_TALLY, 0),
                      suite_row("349e40d", kv.SUITE_RECORD_NO_TALLY, 0))
report, code, _, _ = drive_suite_record(record)
row = suite_row_of(report)
check("a newest row that recorded no tally fails, so the harness exits non-zero",
      row is not None and not row[1] and code != 0,
      "rows: %r exit=%s" % (report.rows, code))
check("and its detail says nothing was measured, at that commit and timestamp",
      row and "measured nothing" in row[2] and "349e40d" in row[2]
      and "2026-08-11T10:24:03Z" in row[2],
      "detail: %r" % (row[2] if row else None,))
os.unlink(record)

# An empty tally cell says the same thing and reads the same way — a row that
# states no tally at all has no measurement in it either.
record = write_record(suite_row("349e40d", "", 0))
report, code, _, _ = drive_suite_record(record)
row = suite_row_of(report)
check("an empty tally cell fails for the same reason",
      row is not None and not row[1] and code != 0
      and "measured nothing" in row[2],
      "rows: %r exit=%s" % (report.rows, code))
os.unlink(record)

# One reading, not two: a row carrying that cell alongside a non-zero exit is
# already the red run the branch above reports, and must keep naming its status.
record = write_record(suite_row("349e40d", kv.SUITE_RECORD_NO_TALLY, 70,
                                failing=RED_NAMES))
report, code, _, _ = drive_suite_record(record)
row = suite_row_of(report)
check("a no-tally row with a non-zero exit still reads as the red run it is",
      row is not None and not row[1] and code != 0
      and "red" in row[2] and "exit 70" in row[2]
      and "measured nothing" not in row[2],
      "detail: %r" % (row[2] if row else None,))
os.unlink(record)

# --- A row ended at its time limit is not a green row either ------------------
#
# scripts/run-unit-suite.sh TERMs a build that outlives SUITE_TIMEOUT_SECONDS
# rather than leave it wedged, and gives it two seconds to notice — a build that
# exits on its own inside that window is waited on for its real status, so the
# recorded `exit` cell can be 0 for this row exactly as it can for the no-tally
# one above. Read off `exit` alone it is a second "green because it never ran"
# case the row above's check does not catch: the tally names a time limit rather
# than the no-tally sentence.
with open(os.path.join(HERE, "run-unit-suite.sh")) as handle:
    RUNNER_SOURCE = handle.read()
check("the timeout prefix and suffix the check matches are the ones the runner writes",
      kv.TIMEOUT_TALLY_PREFIX in RUNNER_SOURCE
      and kv.TIMEOUT_TALLY_SUFFIX in RUNNER_SOURCE,
      "prefix: %r suffix: %r" % (kv.TIMEOUT_TALLY_PREFIX, kv.TIMEOUT_TALLY_SUFFIX))

TIMEOUT_TALLY = kv.TIMEOUT_TALLY_PREFIX + "1800" + kv.TIMEOUT_TALLY_SUFFIX

record = write_record(suite_row("bf9dd36", GREEN_TALLY, 0),
                      suite_row("349e40d", TIMEOUT_TALLY, 0))
report, code, _, _ = drive_suite_record(record)
row = suite_row_of(report)
check("a newest row ended at its time limit fails, so the harness exits non-zero",
      row is not None and not row[1] and code != 0,
      "rows: %r exit=%s" % (report.rows, code))
check("and its detail names the commit and timestamp and says it was ended at "
      "its time limit, not that it reported no tally",
      row and "time limit" in row[2] and "349e40d" in row[2]
      and "2026-08-11T10:24:03Z" in row[2]
      and "reported no test tally" not in row[2],
      "detail: %r" % (row[2] if row else None,))
os.unlink(record)

# One reading, not two, exactly as for the no-tally cell above: a timeout row
# with a non-zero exit is already the red run the branch above reports.
record = write_record(suite_row("349e40d", TIMEOUT_TALLY, 70, failing=RED_NAMES))
report, code, _, _ = drive_suite_record(record)
row = suite_row_of(report)
check("a timeout row with a non-zero exit still reads as the red run it is",
      row is not None and not row[1] and code != 0
      and "red" in row[2] and "exit 70" in row[2]
      and "ended at its time limit" not in row[2],
      "detail: %r" % (row[2] if row else None,))
os.unlink(record)

# --- Rows that disagreed at one commit ----------------------------------------
#
# The newest row is still the verdict, but it is not the whole record. A commit
# whose suite ran red and then green on a retry read exactly like one that was
# green first time, and those are not the same tree: the second is flaky, which
# for an unattended night means merge gates failing at random. docs/suite-status.md
# carries such a pair today. Reported, never enforced — the same terms as drift.
EARLIER, LATER = "2026-08-11T09:23:01Z", "2026-08-11T09:29:35Z"

record = write_record(suite_row("349e40d", RED_TALLY, 65, failing=RED_NAMES,
                                when=EARLIER),
                      suite_row("349e40d", GREEN_TALLY, 0, when=LATER))
report, code, _, _ = drive_suite_record(record)
row = suite_row_of(report)
check("a green retry over a red row at the same commit still passes",
      row is not None and row[1] and code == 0,
      "rows: %r exit=%s" % (report.rows, code))
check("and the detail says that commit was recorded red earlier",
      row and "1 of 2 measurements at 349e40d recorded red earlier" in row[2],
      "detail: %r" % (row[2] if row else None,))
check("and it names what the red row recorded as failing",
      row and all(name in row[2] for name in RED_NAMES.split(", ")),
      "detail: %r" % (row[2] if row else None,))
os.unlink(record)

# The other direction is the same reading of the same record, and the newest row
# is still what decides: a red row over a green one at one commit fails exactly as
# a lone red row does.
record = write_record(suite_row("349e40d", GREEN_TALLY, 0, when=EARLIER),
                      suite_row("349e40d", RED_TALLY, 65, failing=RED_NAMES,
                                when=LATER))
report, code, _, _ = drive_suite_record(record)
row = suite_row_of(report)
check("a red row over a green one at the same commit still fails on the newest row",
      row is not None and not row[1] and code != 0 and "exit 65" in row[2],
      "rows: %r exit=%s" % (report.rows, code))
check("and it says the commit was recorded green earlier, naming no test",
      row and "1 of 2 measurements at 349e40d recorded green earlier" in row[2]
      and "recorded green earlier —" not in row[2],
      "detail: %r" % (row[2] if row else None,))
os.unlink(record)

# Rows that agreed say nothing: the sentence is about a disagreement, and printing
# it whenever a commit was measured twice would make an ordinary re-run read flaky.
for label, rows in (
        ("two green rows at one commit",
         (suite_row("bf9dd36", GREEN_TALLY, 0, when=EARLIER),
          suite_row("bf9dd36", GREEN_TALLY, 0, when=LATER))),
        ("a single row",
         (suite_row("bf9dd36", GREEN_TALLY, 0),)),
        ("a red row at a different commit",
         (suite_row("349e40d", RED_TALLY, 65, failing=RED_NAMES, when=EARLIER),
          suite_row("bf9dd36", GREEN_TALLY, 0, when=LATER))),
        # A row stating no exit status states no verdict, and a row with no
        # verdict cannot disagree with anything — the same reading the newest-row
        # branch takes, rather than guessing at a third.
        ("an earlier row whose exit cell states no status",
         (suite_row("bf9dd36", GREEN_TALLY, "—", failing=RED_NAMES, when=EARLIER),
          suite_row("bf9dd36", GREEN_TALLY, 0, when=LATER)))):
    record = write_record(*rows)
    report, code, _, _ = drive_suite_record(record)
    row = suite_row_of(report)
    check("%s adds no disagreement sentence" % label,
          row is not None and row[1] and code == 0
          and "measurements at" not in row[2],
          "detail: %r" % (row[2] if row else None,))
    os.unlink(record)

# Every data row is read, not just the last two: the pair that disagrees can sit
# anywhere in a record a year of nights has appended to.
record = write_record(suite_row("aaa1111", GREEN_TALLY, 0, when=EARLIER),
                      suite_row("349e40d", RED_TALLY, 65, failing=RED_NAMES,
                                when=EARLIER),
                      suite_row("349e40d", RED_TALLY, 65, failing=RED_NAMES,
                                when=LATER),
                      suite_row("349e40d", GREEN_TALLY, 0, when=LATER))
report, code, _, _ = drive_suite_record(record)
row = suite_row_of(report)
check("rows further up the record are counted, and a repeated name said once",
      row is not None and row[1] and code == 0
      and "2 of 3 measurements at 349e40d recorded red earlier" in row[2]
      and row[2].count(RED_NAMES.split(", ")[0]) == 1,
      "detail: %r" % (row[2] if row else None,))
os.unlink(record)

# --- Drift is reported, never enforced ----------------------------------------
#
# Read from a real repository, so the count is a real `rev-list --count`. A tree
# that has not moved and one that has moved a long way both pass: staleness is a
# fact about the tree, and failing on it would break the harness on every commit.
#
# Every commit this repository carries sits at its root, under neither path the
# second count is scoped to — so these rows are also the case the second count
# exists for, read from the other end: a tree three commits ahead, none of which
# could have invalidated the measurement.
drift_repo, shas = make_repo_with_commits(4)

SCOPED = ", %s of them touching Kiteloop/ or quality/ or quality.json or scripts/"
for label, commit, expected in (
        ("0", shas[-1], "HEAD is 0 commits ahead" + SCOPED % 0),
        ("1", shas[-2], "HEAD is 1 commit ahead" + SCOPED % 0),
        ("many", shas[0], "HEAD is 3 commits ahead" + SCOPED % 0)):
    record = write_record(suite_row(commit, GREEN_TALLY, 0))
    report, code, _, _ = drive_suite_record(record, repo_path=drift_repo)
    row = suite_row_of(report)
    check("a drift of %s still passes — staleness is reported, not enforced" % label,
          row is not None and row[1] and code == 0,
          "rows: %r exit=%s" % (report.rows, code))
    check("and the detail carries the count: %r" % expected,
          row and expected in row[2], "detail: %r" % (row[2] if row else None,))
    os.unlink(record)

# The drift is reported beside a red row too — it qualifies that reading the same
# way — but it is the `exit` cell that decides the verdict, not the count.
record = write_record(suite_row(shas[0], RED_TALLY, 65, failing=RED_NAMES))
report, code, _, _ = drive_suite_record(record, repo_path=drift_repo)
row = suite_row_of(report)
check("a red row at a commit HEAD has moved past still fails, and still says how far",
      row is not None and not row[1] and "HEAD is 3 commits ahead" in row[2],
      "rows: %r" % (report.rows,))
os.unlink(record)

# A commit git cannot resolve is normal — the record outlives rebases — and says
# the same thing the count does: the measurement does not describe this tree. It
# is not a failure, because the row's own verdict is still readable.
record = write_record(suite_row("0000000", GREEN_TALLY, 0))
report, code, _, _ = drive_suite_record(record, repo_path=drift_repo)
row = suite_row_of(report)
check("a commit git cannot resolve reports unknown drift and still passes",
      row is not None and row[1] and code == 0 and "drift unknown" in row[2]
      and "0000000" in row[2],
      "rows: %r exit=%s" % (report.rows, code))
check("and it reports that and nothing else — no count to scope, so no scope",
      row and "of them touching" not in row[2] and "ahead" not in row[2],
      "detail: %r" % (row[2] if row else None,))
os.unlink(record)
shutil.rmtree(drift_repo, ignore_errors=True)

# --- The second count: how much of that drift could have invalidated the row ---
#
# The raw count overstates what it is asked. Measured from the row at 2e6d3d1 the
# tree was 63 commits ahead, of which 31 had touched CODE_PATHS — an operator
# reading 63 was reading backlog and docs commits as staleness in a suite
# measurement, which they cannot cause. `--last` has taken both counts all along;
# this check took one, so the two readouts of one row said different things about
# it.


def make_repo_with_mixed_commits():
    """A repository whose history alternates between the paths the second count
    is scoped to and paths outside them. Returns `(path, shas)`, oldest first:

        c0  docs/                 (outside)
        c1  Kiteloop/             (code)
        c2  backlog/              (outside)
        c3  scripts/              (code)

    So from c0 the tree is 3 commits ahead, 2 of them touching code — the two
    counts differ, which is the whole reading under test."""
    path = tempfile.mkdtemp(prefix="kv-scope-")

    def g(*args):
        return subprocess.run(["git", "-C", path, *args], capture_output=True,
                              text=True, check=True).stdout.strip()

    g("init", "-q")
    g("config", "user.email", "t@example.com")
    g("config", "user.name", "t")
    g("config", "commit.gpgsign", "false")
    shas = []
    for i, relpath in enumerate(("docs/notes.md", "Kiteloop/Orchestrator.swift",
                                 "backlog/backlog.md", "scripts/run-unit-suite.sh")):
        write_file(path, relpath, "c%d\n" % i)
        g("add", "-A")
        g("commit", "-qm", "c%d" % i)
        shas.append(g("rev-parse", "--short", "HEAD"))
    return path, shas


scope_repo, scope_shas = make_repo_with_mixed_commits()

for label, commit, expected in (
        ("both counts", scope_shas[0], "HEAD is 3 commits ahead" + SCOPED % 2),
        ("a code commit and one outside", scope_shas[1],
         "HEAD is 2 commits ahead" + SCOPED % 1),
        ("a drift that is all code", scope_shas[2],
         "HEAD is 1 commit ahead" + SCOPED % 1)):
    record = write_record(suite_row(commit, GREEN_TALLY, 0))
    report, code, _, _ = drive_suite_record(record, repo_path=scope_repo)
    row = suite_row_of(report)
    check("the drift names %s: %r" % (label, expected),
          row is not None and expected in row[2],
          "detail: %r" % (row[2] if row else None,))
    check("and it changes no verdict there either — %s is reported, not enforced"
          % label,
          row is not None and row[1] and code == 0,
          "rows: %r exit=%s" % (report.rows, code))
    os.unlink(record)

# The number is the one `--last` would print for the same row: taken over the
# same paths, by the same command, rather than by a second reading of the graph
# that could come to say something else.
record = write_record(suite_row(scope_shas[0], GREEN_TALLY, 0))
report, _, _, _ = drive_suite_record(record, repo_path=scope_repo)
row = suite_row_of(report)
independent = subprocess.run(
    ["git", "-C", scope_repo, "rev-list", "--count",
     "%s..HEAD" % scope_shas[0], "--", *kv.CODE_PATHS],
    capture_output=True, text=True).stdout.strip()
check("the second count is what rev-list over those paths reports for the row",
      row is not None and (SCOPED % independent) in row[2],
      "detail: %r independent: %r" % (row[2] if row else None, independent))
os.unlink(record)

# And it is scoped to the paths the shell scopes it to — both readouts of one row
# answer one question, so a scope that drifted apart would make them disagree
# while both looked right.
with open(os.path.join(HERE, "run-unit-suite.sh")) as handle:
    shell = handle.read()
check("the paths and the wording are the ones run-unit-suite.sh reads drift by",
      "CODE_PATHS=(%s)" % " ".join(kv.CODE_PATHS) in shell
      and "of them touching" in shell,
      "code paths: %r" % (kv.CODE_PATHS,))

# The drift sits beside a red row unchanged: the second count qualifies that
# reading the way the first does, and neither is the verdict.
record = write_record(suite_row(scope_shas[0], RED_TALLY, 65, failing=RED_NAMES))
report, code, _, _ = drive_suite_record(record, repo_path=scope_repo)
row = suite_row_of(report)
check("a red row still fails, and still says how much of the drift was code",
      row is not None and not row[1] and code != 0
      and ("HEAD is 3 commits ahead" + SCOPED % 2) in row[2],
      "rows: %r exit=%s" % (report.rows, code))
os.unlink(record)


# A second count git cannot answer leaves the sentence as it was before the
# clause existed. The total is still a true reading of the graph, and withholding
# it because the scope came back unreadable would report less than is known.
real_git = kv.git


def failing_scoped_git(path, *args):
    """The real reader, except that the path-scoped call comes back unanswered —
    which is the one call `git()` reports as None."""
    if "--" in args:
        return None, "fatal: bad revision"
    return real_git(path, *args)


record = write_record(suite_row(scope_shas[0], GREEN_TALLY, 0))
kv.git = failing_scoped_git
try:
    report, code, _, _ = drive_suite_record(record, repo_path=scope_repo)
finally:
    kv.git = real_git
row = suite_row_of(report)
check("an unreadable second count keeps the sentence the check had before it",
      row is not None and row[1] and code == 0
      and "HEAD is 3 commits ahead" in row[2]
      and "of them touching" not in row[2],
      "detail: %r" % (row[2] if row else None,))
os.unlink(record)
shutil.rmtree(scope_repo, ignore_errors=True)

# --- What the commit count cannot see: an uncommitted tree ---------------------
#
# The drift count above reads the graph, so an edit nobody has committed moves it
# not at all: a checkout with a modified source file in it reported `HEAD is 0
# commits ahead`, word for word what an untouched tree reports. These cases drive
# the same real-repository path, with files left uncommitted under the scope the
# count is taken over.


def make_repo_with_code_tree():
    """A repository whose one commit carries a file under each path the count is
    scoped to, plus the record file itself — so a case can leave any of them
    modified. Returns `(path, sha)`."""
    path = tempfile.mkdtemp(prefix="kv-dirty-")

    def g(*args):
        return subprocess.run(["git", "-C", path, *args], capture_output=True,
                              text=True, check=True).stdout.strip()

    g("init", "-q")
    g("config", "user.email", "t@example.com")
    g("config", "user.name", "t")
    g("config", "commit.gpgsign", "false")
    for relpath in ("Kiteloop/Orchestrator.swift", "scripts/run-unit-suite.sh",
                    "docs/suite-status.md", "backlog/backlog.md"):
        write_file(path, relpath)
    g("add", "-A")
    g("commit", "-qm", "c0")
    return path, g("rev-parse", "--short", "HEAD")


def detail_at(repo, commit):
    record = write_record(suite_row(commit, GREEN_TALLY, 0))
    try:
        report, code, _, _ = drive_suite_record(record, repo_path=repo)
        row = suite_row_of(report)
        return (row, code)
    finally:
        os.unlink(record)


# A clean tree first, so the sentences the cases below look for are known to be
# absent from the reading they qualify.
dirty_repo, dirty_sha = make_repo_with_code_tree()
row, code = detail_at(dirty_repo, dirty_sha)
CLEAN_DETAIL = "%s (%s): %s — HEAD is 0 commits ahead%s" % (
    dirty_sha, "2026-08-11T10:24:03Z", GREEN_TALLY, SCOPED % 0)
check("a clean tree's detail reads exactly as it did before this line existed",
      row is not None and row[1] and code == 0 and row[2] == CLEAN_DETAIL,
      "detail: %r" % (row[2] if row else None,))

# A modified source file, at the very commit the row recorded: the reading this
# case exists for. The count is reported, and the verdict is untouched — the two
# failing readings stay the ones the docstring names.
write_file(dirty_repo, "Kiteloop/Orchestrator.swift", "changed\n")
row, code = detail_at(dirty_repo, dirty_sha)
check("a modified file under Kiteloop/ is counted, and the check still passes",
      row is not None and row[1] and code == 0
      and "1 file uncommitted under Kiteloop/ or quality/ or quality.json or scripts/" in row[2],
      "detail: %r" % (row[2] if row else None,))
check("and it says so beside the drift sentence rather than in place of it",
      row and row[2].startswith(CLEAN_DETAIL)
      and "the last measurement does not describe this tree" in row[2],
      "detail: %r" % (row[2] if row else None,))
subprocess.run(["git", "-C", dirty_repo, "checkout", "--", "."], check=True,
               capture_output=True)

# An untracked file counts the same way — it is code the measurement did not see
# either — and `-uall` makes the number files rather than the directories they
# sit in, which is what a collapsed `scripts/new/` entry would have reported as 1.
write_file(dirty_repo, "scripts/new/a.py")
write_file(dirty_repo, "scripts/new/b.py")
row, _ = detail_at(dirty_repo, dirty_sha)
check("untracked files under scripts/ are counted, one per file",
      row is not None and row[1]
      and "2 files uncommitted under Kiteloop/ or quality/ or quality.json or scripts/" in row[2],
      "detail: %r" % (row[2] if row else None,))
shutil.rmtree(os.path.join(dirty_repo, "scripts", "new"), ignore_errors=True)

# The state every finished run leaves behind is not a dirty tree: docs/ is under
# neither code path, so the row run-unit-suite.sh appends cannot make the next
# reading call the checkout uncommitted.
write_file(dirty_repo, "docs/suite-status.md", "| a new row |\n")
write_file(dirty_repo, "backlog/backlog.md", "an edit\n")
row, code = detail_at(dirty_repo, dirty_sha)
check("an uncommitted docs or backlog edit is not counted — same scope as the shell",
      row is not None and row[1] and code == 0 and row[2] == CLEAN_DETAIL,
      "detail: %r" % (row[2] if row else None,))
shutil.rmtree(dirty_repo, ignore_errors=True)

# --- The tree the measurement was taken on -------------------------------------
#
# The count above is about *this* checkout; the row's own `tree` cell is about
# the run. A row recorded against an uncommitted tree measured code that is in no
# commit, so the sha it names does not identify what ran — and the reading used
# to throw that cell away, reporting such a row word for word like one measured
# against a committed tree. Reported, never enforced: the verdict below each case
# is the one the `exit` cell already dictated.
TREE_CLAUSE = "taken against uncommitted code"

record = write_record(suite_row("bf9dd36", GREEN_TALLY, 0, tree="dirty"))
report, code, _, _ = drive_suite_record(record)
row = suite_row_of(report)
check("a green row measured on a dirty tree still passes",
      row is not None and row[1] and code == 0,
      "rows: %r exit=%s" % (report.rows, code))
check("and its detail says the measurement was taken against uncommitted code",
      row and TREE_CLAUSE in row[2] and "bf9dd36 does not identify what ran" in row[2],
      "detail: %r" % (row[2] if row else None,))
os.unlink(record)

# A red row is not softened by the clause, and does not lose what it already
# said: the operator's next step is still the tests it named.
record = write_record(suite_row("349e40d", RED_TALLY, 65, failing=RED_NAMES,
                                tree="dirty"))
report, code, _, _ = drive_suite_record(record)
row = suite_row_of(report)
check("a red row measured on a dirty tree still fails, and still names its tests",
      row is not None and not row[1] and code != 0
      and all(name in row[2] for name in RED_NAMES.split(", ")),
      "rows: %r exit=%s" % (report.rows, code))
check("and it carries the clause as well",
      row and TREE_CLAUSE in row[2],
      "detail: %r" % (row[2] if row else None,))
os.unlink(record)

# `clean` says the run was reproducible from the sha, which is the ordinary case
# and needs no sentence — and a row written before this column existed carries an
# empty cell, which says nothing at all rather than saying `clean`.
for label, tree in (("a clean cell", "clean"), ("an empty cell", "")):
    record = write_record(suite_row("bf9dd36", GREEN_TALLY, 0, tree=tree))
    report, code, _, _ = drive_suite_record(record)
    row = suite_row_of(report)
    check("%s adds no clause" % label,
          row is not None and row[1] and code == 0 and TREE_CLAUSE not in row[2],
          "detail: %r" % (row[2] if row else None,))
    os.unlink(record)

# --- Which coverage opted out --------------------------------------------------
#
# The tally says how many tests skipped and the cell beside it says which, and
# the reading used to stop one column short: `(1 skipped)` cannot tell an
# expected opt-out on a busy machine from an endpoint whose coverage went
# missing, and docs/suite-status.md carries a row of each. Named on the same
# terms as the drift — a qualification, never a verdict.
SKIPPED_CLAUSE = "; skipped: "
SKIPPED_NAMES = ("KiteloopTests.HTTPServerTests.testBindsToLoopback, "
                 "KiteloopTests.ControlRunStoreTests.testPrunesByAge")

record = write_record(suite_row("bf9dd36", GREEN_TALLY, 0, skipped=SKIPPED_NAMES))
report, code, _, _ = drive_suite_record(record)
row = suite_row_of(report)
check("a green row that skipped tests still passes — a skip is not a fault",
      row is not None and row[1] and code == 0,
      "rows: %r exit=%s" % (report.rows, code))
check("and its detail names them, in the cell's own order",
      row and SKIPPED_CLAUSE + SKIPPED_NAMES in row[2],
      "detail: %r" % (row[2] if row else None,))
os.unlink(record)

# A dash is a run that skipped nothing, which the tally has already said by
# carrying no parenthesis; an empty cell is a row written before the column
# existed. Both say nothing here — no empty clause, and not the cell next door,
# which is the failing names on one side and the duration on the other.
for label, skipped in (("a dash", "—"), ("an empty cell", "")):
    record = write_record(suite_row("349e40d", RED_TALLY, 65, failing=RED_NAMES,
                                    skipped=skipped))
    report, code, _, _ = drive_suite_record(record)
    row = suite_row_of(report)
    check("%s adds no skipped clause" % label,
          row is not None and SKIPPED_CLAUSE not in row[2],
          "detail: %r" % (row[2] if row else None,))
    os.unlink(record)

# The failing readings are still what they were: the cell qualifies them and
# moves none of them. Two of the three can carry it — the third is a record with
# no row at all, which has no cell to read. A red row keeps its status and the
# tests it named.
record = write_record(suite_row("349e40d", RED_TALLY, 65, failing=RED_NAMES,
                                skipped=SKIPPED_NAMES))
report, code, _, _ = drive_suite_record(record)
row = suite_row_of(report)
check("a red row that skipped tests still fails, and still names its failures",
      row is not None and not row[1] and code != 0 and "exit 65" in row[2]
      and all(name in row[2] for name in RED_NAMES.split(", ")),
      "rows: %r exit=%s" % (report.rows, code))
check("and it names the skipped tests as well, apart from the failing ones",
      row and SKIPPED_CLAUSE + SKIPPED_NAMES in row[2],
      "detail: %r" % (row[2] if row else None,))
os.unlink(record)

# A run that matched no tests can still have recorded a skip, and is still a run
# that measured nothing.
record = write_record(suite_row("349e40d", kv.SUITE_RECORD_NO_TALLY, 0,
                                skipped=SKIPPED_NAMES))
report, code, _, _ = drive_suite_record(record)
row = suite_row_of(report)
check("a no-tally row that skipped tests still fails as measuring nothing",
      row is not None and not row[1] and code != 0
      and "measured nothing" in row[2] and SKIPPED_CLAUSE in row[2],
      "detail: %r" % (row[2] if row else None,))
os.unlink(record)

# And the cell is the newest row's, not any row's: an older row's skips describe
# a run that is no longer the reading.
record = write_record(suite_row("349e40d", GREEN_TALLY, 0, skipped=SKIPPED_NAMES),
                      suite_row("bf9dd36", GREEN_TALLY, 0))
report, code, _, _ = drive_suite_record(record)
row = suite_row_of(report)
check("an older row's skipped names do not reach the newest row's detail",
      row is not None and row[1] and SKIPPED_CLAUSE not in row[2],
      "detail: %r" % (row[2] if row else None,))
os.unlink(record)

# --- A record that answers nothing is not a record that answers "green" --------
missing = os.path.join(tempfile.mkdtemp(prefix="kv-no-record-"), "suite-status.md")
report, code, _, _ = drive_suite_record(missing)
row = suite_row_of(report)
check("a missing record file fails rather than passing silently",
      row is not None and not row[1] and code != 0,
      "rows: %r exit=%s" % (report.rows, code))
check("and it names the path it looked for, and who writes it",
      row and missing in row[2] and "run-unit-suite.sh" in row[2],
      "detail: %r" % (row[2] if row else None,))
shutil.rmtree(os.path.dirname(missing), ignore_errors=True)

# The header and the rule are not a measurement: the same reading as the smoke
# checks' own "no contract was exercised" — a table nobody has written a row to
# has measured nothing, and reporting it green is the failure this check exists
# to stop.
record = write_record()
report, code, _, _ = drive_suite_record(record)
row = suite_row_of(report)
check("a record with the header and no data row fails too",
      row is not None and not row[1] and code != 0,
      "rows: %r exit=%s" % (report.rows, code))
check("and it says the table carries no data row",
      row and "no data row" in row[2],
      "detail: %r" % (row[2] if row else None,))
os.unlink(record)

# The header and the rule are the two lines that must not be read as rows — the
# rule's cells are dashes, and the header's first cell is a word.
record = write_record(suite_row("bf9dd36", GREEN_TALLY, 0))
with open(record) as handle:
    check("the header and the rule are in the file the rows are read from",
          "| when (UTC) |" in handle.read(), "the fixture lost its header")
report, _, _, _ = drive_suite_record(record)
row = suite_row_of(report)
check("neither the header nor the rule is mistaken for a row",
      row is not None and row[1] and "bf9dd36" in row[2],
      "rows: %r" % (report.rows,))
os.unlink(record)


# --- The cells are resolved from the record's own header, not from positions ---
#
# The layout used to be written down twice — once in `append_record` in
# scripts/run-unit-suite.sh, and once as indices here, with nothing tying them
# together. Four columns were added to that layout in a week, and any one of them
# landing left of `failing tests` would have made every reading below report the
# cell next door: the skipped names read as the failing ones, a bundle name read
# as a verdict. Reading the header the record already carries is what makes the
# writer free to add a column.
def header_cells_of(text):
    """The record's header line as its cells, or [] when it carries none — read
    the way a person reads it, by the names in it, so this is not the reader
    under test checking its own answer."""
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if "commit" in cells and "tally" in cells:
            return cells
    return []


with open(kv.SUITE_RECORD_PATH) as handle:
    shipped_header = header_cells_of(handle.read())
absent = [name for name in kv.SUITE_RECORD_READ_COLUMNS if name not in shipped_header]
check("the shipped record's header carries every column the reader resolves by name",
      shipped_header and not absent,
      "header: %r missing: %r" % (shipped_header, absent))
# And the fallback is that same layout, so the record whose header this reader
# cannot resolve is still read the way the shipped one is written.
check("and the fallback positions are the layout the shipped record carries",
      list(kv.SUITE_RECORD_COLUMNS) == shipped_header,
      "header: %r fallback: %r" % (shipped_header, list(kv.SUITE_RECORD_COLUMNS)))

WIDE_HEADER = (SUITE_HEADER
               .replace("| failing tests", "| rerun of | failing tests")
               .replace("| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
                        "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"))
check("the widened fixture is a header one column wider, with the rule to match",
      len(header_cells_of(WIDE_HEADER)) == len(header_cells_of(SUITE_HEADER)) + 1
      and "rerun of" in header_cells_of(WIDE_HEADER),
      "header: %r" % (header_cells_of(WIDE_HEADER),))


def widened(row, index=6, value="—"):
    """One row of the widened record: the same cells with the new column's in
    place, so the two records differ in nothing but the extra column."""
    cells = list(row)
    cells.insert(index, value)
    return tuple(cells)


for label, rows in (
        ("a green newest row disagreeing with a red one",
         (suite_row("349e40d", RED_TALLY, 65, failing=RED_NAMES),
          suite_row("349e40d", GREEN_TALLY, 0, skipped=SKIPPED_NAMES))),
        ("a red newest row naming failures and skips",
         (suite_row("bf9dd36", GREEN_TALLY, 0),
          suite_row("349e40d", RED_TALLY, 65, failing=RED_NAMES,
                    skipped=SKIPPED_NAMES)))):
    plain = write_record(*rows)
    wide = write_record(*[widened(r) for r in rows], header=WIDE_HEADER)
    plain_report, plain_code, _, _ = drive_suite_record(plain)
    wide_report, wide_code, _, _ = drive_suite_record(wide)
    plain_row, wide_row = suite_row_of(plain_report), suite_row_of(wide_report)
    check("a column inserted before `failing tests` changes nothing — %s" % label,
          plain_row is not None and wide_row is not None
          and plain_row == wide_row and plain_code == wide_code,
          "plain: %r wide: %r" % (plain_row, wide_row))
    os.unlink(plain)
    os.unlink(wide)

# A record this reader cannot resolve a header from falls back to today's
# positions, which is exactly how it read before it read any header at all.
baseline = write_record(suite_row("bf9dd36", GREEN_TALLY, 0, skipped=SKIPPED_NAMES))
baseline_report, baseline_code, _, _ = drive_suite_record(baseline)
baseline_row = suite_row_of(baseline_report)
os.unlink(baseline)
for label, header in (
        ("no header line at all", "# Suite status\n\n"),
        ("a header naming columns this reader does not know",
         "# Suite status\n\n"
         "| date | sha | state | result | status | bundle | failed | skipped | took |\n"
         "| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n")):
    record = write_record(suite_row("bf9dd36", GREEN_TALLY, 0, skipped=SKIPPED_NAMES),
                          header=header)
    report, code, _, _ = drive_suite_record(record)
    row = suite_row_of(report)
    check("a record with %s reads exactly as it does today" % label,
          row is not None and row == baseline_row and code == baseline_code,
          "row: %r baseline: %r" % (row, baseline_row))
    os.unlink(record)

# And a row written before a column existed simply runs out of cells. It reads
# empty there rather than raising, which is what lets the record outlive its own
# layout — the rows from before `failing tests` are still in the shipped file.
record = write_record(("2026-08-11T10:24:03Z", "bf9dd36", "clean", GREEN_TALLY, "0"))
report, code, _, _ = drive_suite_record(record)
row = suite_row_of(report)
check("a row written before the later columns reads empty there rather than raising",
      row is not None and row[1] and code == 0 and "bf9dd36" in row[2]
      and GREEN_TALLY in row[2] and SKIPPED_CLAUSE not in row[2],
      "row: %r" % (row,))
os.unlink(record)

record = write_record(("2026-08-11T10:24:03Z", "349e40d", "clean", RED_TALLY, "65"))
report, code, _, _ = drive_suite_record(record)
row = suite_row_of(report)
check("and such a red row still fails, saying its failures were not recorded",
      row is not None and not row[1] and code != 0 and "exit 65" in row[2]
      and "not recorded in that row" in row[2],
      "row: %r" % (row,))
os.unlink(record)

# --- And it is wired into the smoke pass, as a report row like any other -------
stub, code, out, err = drive_main("--json")
try:
    doc = json.loads(out)
except ValueError as exc:
    check("the suite-record row leaves --json stdout one JSON document",
          False, "%s — stdout: %r" % (exc, out[:200]))
else:
    names = [c["name"] for c in doc["checks"]]
    check("the suite-record row leaves --json stdout one JSON document",
          isinstance(doc, dict) and doc["total"] == len(doc["checks"]),
          "doc: %r" % (doc,))
    check("main() adds it once, after the smoke checks it follows",
          names.count(kv.SUITE_RECORD_CHECK) == 1
          and names[0] == "server up (/health)"
          and names[-1] == kv.SUITE_RECORD_CHECK,
          "names: %r" % (names,))
    check("and it costs no request of its own — it reads a file, not the app",
          not any(path.startswith("/v1/suite") for _m, path, _b in stub.calls),
          "calls: %r" % ([(m, p) for m, p, _ in stub.calls],))
check("and it narrates nothing — the row is the whole report of it",
      "suite record" not in err, "stderr: %r" % err[-300:])

stub, code, out, err = drive_main()
check("in human mode the row prints beside the others, on stdout",
      kv.SUITE_RECORD_CHECK in out, "stdout: %r" % out[:400])
check("and human mode still diverts nothing to stderr",
      err == "", "stderr: %r" % err[:200])

print()
if failed == 0:
    print("test-kiteloop-verify: all cases passed.")
    sys.exit(0)
print("test-kiteloop-verify: %d case(s) failed." % failed, file=sys.stderr)
sys.exit(1)
