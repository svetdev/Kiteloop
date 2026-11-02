#!/usr/bin/env python3
"""kiteloop-verify — verify the Kiteloop control API and the autopilot loop.

Kiteloop is a GUI app that can't be driven headlessly from CI, but its local
control API *is* a verification surface. This tool exercises it and reports
pass/fail — the seed of the 8h "marathon" harness in docs/success-metrics.md.

Modes
  (default)   Read-only smoke checks: server up, auth enforced, endpoint contracts,
              and what the suite record last measured. Safe to run anytime; no
              side effects.
  --run P I   Drive a full autopilot loop for one ready item (P=project, I=item):
              start -> poll result -> optionally approve. Side-effecting (runs an
              agent, may change files) — opt-in only.
  --repo-path Verify worktree ISOLATION around a --run: the project's main working
              tree gains no changes and the run's branch exists.

The guardrail flags (--worktree, --session-cap, --per-item-cap, --margin,
--auto-merge, --merge-verify) configure the run they precede — they apply to
--run and --marathon alike, and are refused with neither. So do the flags that
shape the run itself (--repo-path, --approve, --auto-approve, --timeout-min,
--hours), for the same reason. The two approval flags answer to one mode each:
--approve to --run, --auto-approve to --marathon, and each is refused with the
other rather than accepted and dropped.

No third-party dependencies (Python 3 stdlib only). Exits non-zero on any failure.

Examples
  ./scripts/kiteloop-verify.py
  ./scripts/kiteloop-verify.py --run inventory inventory-add-cmd --approve \\
      --repo-path ~/code/inventory
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

TOKEN_PATH = os.path.expanduser("~/.kiteloop/control-token")
REQUIRED_ITEM_FIELDS = {"id", "title", "status", "epic"}

# The suite record, and the repository it belongs to, both resolved from this
# script rather than from the caller's working directory: the record read is the
# one shipping alongside the harness, whichever directory it was invoked from.
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUITE_RECORD_RELPATH = "docs/suite-status.md"
SUITE_RECORD_PATH = os.path.join(REPO_ROOT, *SUITE_RECORD_RELPATH.split("/"))
SUITE_RECORD_CHECK = "suite record: the newest run was green"

# The paths whose contents can change what a test reports — the same scope
# CODE_PATHS carries in scripts/run-unit-suite.sh, and read here for the same
# question. A backlog or docs edit cannot invalidate a measurement, and
# SUITE_RECORD_RELPATH is under none of these, so the row every finished run
# appends never makes this readout call the tree dirty.
CODE_PATHS = ["Kiteloop", "quality", "quality.json", "scripts"]

# The columns scripts/run-unit-suite.sh writes, in order — but only as the
# fallback. The record carries its own header, and the cells below are resolved
# from that header by name, so a column added to the writer's layout cannot
# silently shift every cell this check reports to the one next door: four were
# added in a week, each of which would have needed a matching edit here. The
# order below is what a record whose header cannot be read is assumed to have,
# which is the layout as it stands today.
SUITE_RECORD_COLUMNS = ("when (UTC)", "commit", "tree", "tally", "exit",
                        "result bundle", "failing tests", "skipped tests",
                        "duration", "package tally")
SUITE_RECORD_FALLBACK_COLUMNS = {name: index
                                 for index, name in enumerate(SUITE_RECORD_COLUMNS)}

# The columns this file actually reads out of a row. A header line has to carry
# all of them to be worth resolving against — a header missing one would leave
# that cell read positionally beside others read by name, which is the mixture
# reading by name exists to avoid. `result bundle` and `duration` are recorded
# for a person to read and are not among them.
SUITE_RECORD_READ_COLUMNS = ("when (UTC)", "commit", "tree", "tally", "exit",
                             "failing tests", "skipped tests")

# The tally cell scripts/run-unit-suite.sh writes when no framework reported a
# summary: the run matched no tests, so nothing was measured. Its `exit` cell
# still carries what xcodebuild itself returned, which for a run that matched
# nothing is 0 — so the cell below is the only thing that tells such a row from a
# green one. Spelled here, beside the columns it is read out of, so the reader
# and the writer cannot drift apart silently.
SUITE_RECORD_NO_TALLY = "no tally — xcodebuild exited before running tests"

# The prefix and suffix scripts/run-unit-suite.sh's timeout_tally_cell wraps
# around SUITE_TIMEOUT_SECONDS to build the tally cell a row gets when that
# script itself ended a run that outlived its time limit, rather than one
# xcodebuild ever reported a summary for or crashed out of on its own. Its
# `exit` cell can still be 0: the build is TERMed and given two seconds to
# notice, and one that finishes on its own inside that window is waited on for
# its real status. Same two constants as TIMEOUT_TALLY_PREFIX / _SUFFIX in
# scripts/run-unit-suite.sh — spelled here so the reader and the writer of this
# cell cannot drift apart silently.
TIMEOUT_TALLY_PREFIX = "no tally — xcodebuild ran past its "
TIMEOUT_TALLY_SUFFIX = "s time limit and was ended"


def tally_states_no_measurement(tally):
    """Whether a tally cell states that nothing was measured: empty (a row from
    before the tally column existed), SUITE_RECORD_NO_TALLY, or a cell recording
    a run scripts/run-unit-suite.sh ended at its time limit. Mirrors
    tally_states_no_measurement in scripts/run-unit-suite.sh."""
    if tally in ("", SUITE_RECORD_NO_TALLY):
        return True
    return tally.startswith(TIMEOUT_TALLY_PREFIX) and tally.endswith(TIMEOUT_TALLY_SUFFIX)


# --timeout-min and --hours parse as None so that "was it given?" has an answer —
# an argparse default is indistinguishable from a value the caller typed. The
# defaults live here and are applied where the flags are read, so a run behaves
# exactly as it did when neither is passed.
DEFAULT_TIMEOUT_MIN = 20
DEFAULT_HOURS = 1.0

# How many polls in a row must fail at the connection level before the poll loop
# gives up on the server. One is tolerated on purpose: an app that restarts comes
# back, and the run it was carrying is still readable from the durable record.
UNREACHABLE_POLLS = 2

# The wording a spent daily ceiling refuses a start with — `DailyBudget.Refusal`,
# whose `logLine` `POST /v1/runs` echoes in its 409 detail. Both ceilings that
# govern an autonomous start carry it: the portfolio's opens "Daily budget $…
# spent", a project's "<project>'s daily budget $… spent", so one substring
# matches either and the detail says which one it was.
#
# Matched rather than read off a status code because 409 is also what a run in
# flight answers with, and the two mean opposite things to a marathon: one is
# waited out, this one ends the night.
CEILING_REFUSAL = "daily budget"


class Client:
    def __init__(self, base, token):
        self.base = base
        self.token = token

    def request(self, method, path, body=None, auth=True, timeout=15):
        url = self.base + path
        data = json.dumps(body).encode() if body is not None else None
        headers = {}
        if data:
            headers["Content-Type"] = "application/json"
        if auth:
            headers["Authorization"] = f"Bearer {self.token}"
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.status, _parse(resp.read())
        except urllib.error.HTTPError as err:
            return err.code, _parse(err.read())
        except Exception as err:  # connection refused, timeout, etc.
            return 0, {"error": str(err)}


def _parse(raw):
    try:
        return json.loads(raw.decode())
    except Exception:
        return {"_raw": raw.decode(errors="replace")}


class Report:
    def __init__(self, as_json=False):
        self.rows = []
        self.as_json = as_json
        # The marathon scorecard, once `marathon` has one to hand over. Every
        # number on it used to exist only as narration, so reading an unattended
        # night's SLO #1 figures meant regexing prose; `finish` carries it as a
        # `scorecard` key instead. None on every other path — a smoke or --run
        # document has no scorecard to report and keeps the shape it has.
        self.scorecard = None

    def narrate(self, message=""):
        """Progress narration — headers, per-item lines, the scorecard. In JSON
        mode `finish` is the only writer of stdout, so this goes to stderr and
        stays visible; in human mode it prints where it always has."""
        print(message, file=sys.stderr if self.as_json else sys.stdout)

    def check(self, name, ok, detail=""):
        self.rows.append((name, bool(ok), str(detail)))
        if not self.as_json:
            mark = "\033[32m✓\033[0m" if ok else "\033[31m✗\033[0m"
            line = f"  {mark} {name}"
            if detail:
                line += f"  — {detail}"
            print(line)
        return ok

    def finish(self):
        passed = sum(1 for _, ok, _ in self.rows if ok)
        total = len(self.rows)
        if self.as_json:
            doc = {
                "passed": passed,
                "total": total,
                "checks": [{"name": n, "ok": ok, "detail": d} for n, ok, d in self.rows],
            }
            if self.scorecard is not None:
                doc["scorecard"] = self.scorecard
            print(json.dumps(doc, indent=2))
        else:
            color = "\033[32m" if passed == total else "\033[31m"
            print(f"\n{color}{passed}/{total} checks passed\033[0m")
        return 0 if passed == total else 1


def git(path, *args):
    """Run a git command in `path`, returning `(stdout, error)`.

    `stdout` is None when git could not answer at all — a mistyped path, a
    deleted checkout, a directory that is not a repository — and `error` then
    carries what git said. Returning only stdout is what made those cases
    indistinguishable from a command that succeeded with nothing to print: the
    worktree-isolation checks compared two empty strings and reported the main
    tree unchanged having looked at nothing."""
    try:
        p = subprocess.run(["git", "-C", path, *args], capture_output=True, text=True)
    except OSError as exc:                       # no git on PATH, unreadable cwd
        return None, str(exc)
    if p.returncode != 0:
        return None, (p.stderr.strip() or p.stdout.strip()
                      or f"git exited {p.returncode}")
    return p.stdout.strip(), ""


def code_paths_phrase():
    """CODE_PATHS as a sentence — `Kiteloop/ or quality/ or quality.json or
    scripts/`. Spelled from the list rather than beside it, so the sentence
    cannot come to name paths the count was not taken over. An entry is a
    directory unless its name carries a dot — quality.json is the one entry
    that does, and it reads as a file rather than as `quality.json/`. Same
    reasoning as its namesake in run-unit-suite.sh."""
    return " or ".join(path if "." in path else path + "/" for path in CODE_PATHS)


def uncommitted_code_files(repo_path):
    """How many files are uncommitted under CODE_PATHS — modified, staged or
    untracked — and 0 when the tree is clean or git could not answer.

    The drift count beside this one reads the commit graph alone, so an edit
    nobody has committed moves it not at all: a checkout with a modified source
    file in it reported `HEAD is 0 commits ahead`, word for word what a tree
    nobody had touched reported, and the one sentence meant to say the last
    measurement does not describe this tree said the opposite.

    `-uall` names untracked files one by one rather than collapsing a directory
    into a single entry, so the number means files."""
    out, _err = git(repo_path, "status", "--porcelain", "-uall", "--", *CODE_PATHS)
    if out is None:
        return 0
    return sum(1 for line in out.splitlines() if line.strip())


def smoke(client, report):
    report.narrate("Smoke checks (read-only):")
    st, d = client.request("GET", "/health", auth=False)
    report.check("server up (/health)", st == 200 and d.get("status") == "ok",
                 f"v{d.get('version')} · {d.get('projectsOpen')} projects" if st == 200 else d.get("error", st))
    if st != 200:
        return []  # nothing else will work

    st, _ = client.request("GET", "/v1/projects", auth=False)
    report.check("auth enforced (401 without token)", st == 401, f"got {st}")

    st, d = client.request("GET", "/v1/projects")
    projects = d.get("projects", []) if isinstance(d, dict) else []
    report.check("list projects", st == 200 and isinstance(projects, list), f"{len(projects)} open")

    items_checked = 0
    for p in projects:
        name = p.get("name", "?")
        st, d = client.request("GET", "/v1/backlog?project=" + urllib.parse.quote(name))
        items = d.get("items", []) if isinstance(d, dict) else []
        ok = st == 200 and all(REQUIRED_ITEM_FIELDS.issubset(i) for i in items)
        if st == 200:
            items_checked += len(items)
        ready = sum(1 for i in items if i.get("status") == "ready")
        report.check(f"backlog[{name}] contract", ok, f"{len(items)} items, {ready} ready")

    # The item contract is what these smoke checks exist to hold, and there are two
    # ways to hold none of it while every row stays green: with no project open the
    # loop above never runs at all, and for a project whose backlog is empty
    # `all(...)` over an empty `items` is True. Both then reported a clean bill of
    # health for a run that compared nothing. One rule covers both — a contract
    # counts as exercised only once some item's fields were actually checked. Same
    # reading as `exit_status_for` in scripts/run-unit-suite.sh, which exits
    # non-zero when xcodebuild returns 0 having measured nothing. The row is added
    # only when it fails, so a run that did check items reports exactly as before.
    if items_checked == 0:
        report.check("backlog contract exercised", False,
                     f"no backlog contract was exercised — {len(projects)} "
                     f"project(s) open, 0 items checked; open one with "
                     f"POST /v1/projects/open")

    st, _ = client.request("GET", "/v1/nope")
    report.check("unknown route → 404", st == 404, f"got {st}")
    return projects


def header_columns(cells):
    """The column map a header line carries — name to index — or None when the
    line is not a header this reader can resolve against.

    A name it does not know is simply not in the map, which is how a column added
    to the record leaves every other cell where it was. A name it does know but
    the line does not carry means the map cannot answer for a cell this file
    reads, and the caller falls back to positions wholesale rather than mixing
    the two readings. Matched case-insensitively: the header is prose in a
    markdown table, and `Commit` names the same column as `commit`."""
    found = {}
    known = {name.lower(): name for name in SUITE_RECORD_COLUMNS}
    for index, cell_text in enumerate(cells):
        name = known.get(cell_text.strip().lower())
        if name is not None and name not in found:
            found[name] = index
    if any(name not in found for name in SUITE_RECORD_READ_COLUMNS):
        return None
    return found


def suite_table(text):
    """The suite record's column map and its data rows, oldest first.

    Same rule as `table_rows` in scripts/run-unit-suite.sh for what a row is: a
    table line whose first cell starts with a year, which is what tells it from
    the header and the rule beneath it. The lines that are *not* rows are what
    the column map is read from — the first of them that names every column this
    file reads. The rule (`| --- | --- |`) names none of them and is passed over
    on the same test, as is a header from a record this reader cannot resolve,
    which falls back to today's positions.

    Rows are padded to the width the map needs, so a row written before a column
    existed reads empty there rather than raising."""
    columns = None
    rows = []
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        first = cells[0] if cells else ""
        if len(first) > 4 and first[:4].isdigit() and first[4] == "-":
            rows.append(cells)
        elif columns is None:
            columns = header_columns(cells)
    columns = columns if columns is not None else dict(SUITE_RECORD_FALLBACK_COLUMNS)
    width = max(columns.values()) + 1
    return columns, [row + [""] * (width - len(row)) for row in rows]


def cell(row, columns, name):
    """A row's named cell, or "" when the record has no such column and when the
    row was written before it did. Reading a cell that is not there is not an
    error: the record outlives its own layout, and a row from before a column
    says nothing about it rather than saying something wrong."""
    index = columns.get(name)
    if index is None or index >= len(row):
        return ""
    return row[index]


def row_verdict(row, columns):
    """`0` or the non-zero status a row's `exit` cell carries, or None when it
    carries no status at all.

    The `exit` cell is the verdict the check itself reads for the newest row, so
    reading it here means one row cannot be green to the verdict and red to the
    comparison beside it. That holds only while both read the same cell, which is
    why the column map is passed in rather than resolved again here. A cell
    stating no status states no verdict, and a row with no verdict cannot
    disagree with anything — those are passed over rather than guessed at, which
    is the same reading `verdict_of` takes in scripts/run-unit-suite.sh."""
    try:
        return int(cell(row, columns, "exit"))
    except ValueError:
        return None


def disagreement_sentence(rows, columns, commit, exit_status):
    """One clause about the measurements at `commit` that reached a verdict other
    than `exit_status`, or "" when they all agreed.

    The newest row is the reading, but it is not the whole record: a commit whose
    suite ran red and then green on a retry is a flaky tree, and read off the last
    row alone it is indistinguishable from one that was green first time. For an
    unattended night that difference is merge gates failing at random, so it is
    said out loud.

    The disagreement is reported in either direction, as it is in
    `disagreement_line` in scripts/run-unit-suite.sh: a green row under a red
    newest one says the same thing about the suite as a red row under a green one.
    Names come from the failing-tests cells of the rows that disagreed, so a green
    newest row is told which tests were red earlier; a row from before that column
    existed carries none and contributes only to the count."""
    total = against = 0
    names = []
    for row in rows:
        if cell(row, columns, "commit") != commit:
            continue
        verdict = row_verdict(row, columns)
        if verdict is None:
            continue
        total += 1
        if (verdict != 0) == (exit_status != 0):
            continue
        against += 1
        failing = cell(row, columns, "failing tests")
        if failing and failing != "—":  # a row from before that column existed
            # Deduplicated, keeping first appearance: a test that failed in each
            # of three red rows at one commit is one name, said once, and saying
            # it three times would read as three different tests.
            for name in failing.split(", "):
                if name and name not in names:
                    names.append(name)
    if not against:
        return ""
    other = "green" if exit_status != 0 else "red"
    sentence = (f"; {against} of {total} measurements at {commit} recorded "
                f"{other} earlier")
    if names:
        sentence += " — %s" % ", ".join(names)
    return sentence


def suite_record(report, record_path=None, repo_path=None):
    """Report what docs/suite-status.md last recorded, and how far the tree has
    moved since — the one question the smoke checks never asked.

    Every other check here reads the running app, which can be perfectly healthy
    over a suite that last came back red, or was last measured ninety commits
    ago. Both readings are the operator's to act on before starting a night, and
    neither was surfaced anywhere a driver looks.

    Three readings fail, and only three: no record at all (nothing has ever
    measured this suite, so there is no answer to give), a newest row whose
    `exit` cell is non-zero (the last measurement was red), and a newest row
    whose tally states no tally at all (the run matched no tests, so it measured
    nothing — and its `exit` cell is xcodebuild's own 0, which read alone is the
    'green because it never ran' answer this harness exists to refuse). Drift is
    *reported* — a
    stale measurement is a fact about the tree, not a fault in it, and failing on
    it would make every ordinary commit break the harness. A disagreement between
    the rows at that commit is reported for the same reason, and on the same
    terms: it says the tree is flaky, which the operator acts on, but it is not
    itself a red measurement and does not change the verdict either way.

    Nothing is written: the record's only writer is scripts/run-unit-suite.sh,
    which cannot run while the app is up — and the app is up whenever this
    harness has anything to check."""
    record_path = record_path or SUITE_RECORD_PATH
    repo_path = repo_path or REPO_ROOT
    try:
        with open(record_path) as handle:
            text = handle.read()
    except OSError as exc:
        return report.check(SUITE_RECORD_CHECK, False,
                            f"no suite record at {record_path} — "
                            f"{exc.strerror or exc}; scripts/run-unit-suite.sh "
                            f"appends one every time it finishes")
    columns, rows = suite_table(text)
    row = rows[-1] if rows else None
    if row is None:
        return report.check(SUITE_RECORD_CHECK, False,
                            f"{record_path} records no run — the table carries a "
                            f"header and no data row; run "
                            f"./scripts/run-unit-suite.sh once")

    when = cell(row, columns, "when (UTC)")
    commit = cell(row, columns, "commit")
    tree = cell(row, columns, "tree")
    tally = cell(row, columns, "tally")
    exit_cell = cell(row, columns, "exit")
    failing = cell(row, columns, "failing tests")
    skipped = cell(row, columns, "skipped tests")

    # How far the tree has moved since that measurement, which is what makes a
    # green row worth anything. A commit git cannot resolve is normal rather than
    # an error — the record outlives rebases — and says the same thing either
    # way: the measurement does not describe this tree.
    #
    # Two counts, because the raw one overstates what it is asked. `--last` takes
    # the second for the same reason, and its comment records the case: measured
    # from the row at 2e6d3d1 the tree was 63 commits ahead, of which 31 had
    # touched CODE_PATHS — the rest were backlog and docs, which cannot change
    # what a test reports. The total says how far the tree has moved; the second
    # says how much of that move could have invalidated the measurement, which is
    # the number an operator deciding whether to trust the last green row is
    # actually reading. Worded as `--last` words it, so the two readouts of one
    # row cannot be read as disagreeing.
    #
    # A second count git cannot answer leaves the sentence exactly as it was
    # before this clause existed: the total is still a true reading, and a
    # missing scope is no reason to withhold it.
    ahead, _err = git(repo_path, "rev-list", "--count", f"{commit}..HEAD")
    if ahead is None or not ahead.isdigit():
        drift = f"drift unknown — git cannot resolve {commit} in this checkout"
    else:
        count = int(ahead)
        drift = f"HEAD is {count} commit{'' if count == 1 else 's'} ahead"
        code_ahead, _err = git(repo_path, "rev-list", "--count",
                               f"{commit}..HEAD", "--", *CODE_PATHS)
        if code_ahead is not None and code_ahead.isdigit():
            drift += (f", {int(code_ahead)} of them touching "
                      f"{code_paths_phrase()}")

    # And what the graph cannot see at all. The count above is a commit count, so
    # an uncommitted edit under the code paths moves it not at all — which is how
    # a tree with a modified source file in it came to report exactly what an
    # untouched tree reports. This qualifies the drift sentence rather than
    # replacing it, and stays silent on a clean tree, so the ordinary detail reads
    # as it always has. Staleness is still only reported: the verdict below is the
    # `exit` cell's, and an uncommitted tree is a fact about the checkout rather
    # than a fault in it.
    dirty = uncommitted_code_files(repo_path)
    if dirty:
        drift += (f"; {dirty} file{'' if dirty == 1 else 's'} uncommitted under "
                  f"{code_paths_phrase()} — the last measurement does not "
                  f"describe this tree")

    # And whether the measurement itself was taken over uncommitted code. The
    # count above qualifies *this* checkout; the `tree` cell qualifies the row: a
    # run recorded against a dirty tree measured code that sits in no commit, so
    # the sha the row names does not identify what ran and nobody can reproduce
    # that reading from the graph. `--last` has printed this for the same row all
    # along; read here it was destructured away, and such a row was reported word
    # for word like one measured against a committed tree. Reported on the same
    # terms as the drift — a qualification, not a verdict — and silent for a
    # `clean` cell as for the empty one a row written before the column carries.
    if tree == "dirty":
        drift += (f"; that measurement was itself taken against uncommitted "
                  f"code, so {commit} does not identify what ran")

    # And which coverage opted out. The tally already carries `(N skipped)`, but
    # eleven characters cannot tell an expected opt-out on a busy machine from a
    # control-server endpoint whose coverage went missing, and the record's own
    # rows are both of those. Named here for the same reason the failing tests
    # are: so the operator's next step before an unattended night is not a re-run
    # to find out. A qualification beside the drift, not a verdict — a skip is a
    # fact about the run, not a fault in it, so neither reading below moves.
    #
    # Silent for a `—` as well as for the empty cell a row written before the
    # column carries, which is how `show_last` prints it in
    # scripts/run-unit-suite.sh: a run that skipped nothing has already said so
    # by carrying no parenthesis in the tally above.
    if skipped and skipped != "—":
        drift += f"; skipped: {skipped}"

    try:
        exit_status = int(exit_cell)
    except ValueError:
        # A row that states no exit status states no verdict, and a row with no
        # verdict is not a red one. Say what the cell held and pass: the two
        # failing readings above are the unambiguous ones, and guessing at a
        # third would fail the harness over the record's own formatting.
        return report.check(SUITE_RECORD_CHECK, True,
                            f"{commit} ({when}): {tally} — exit cell "
                            f"{exit_cell!r} states no status; {drift}")

    # And whether the rows at that commit agreed. This needs the newest row's own
    # verdict, which is why it sits below the parse: a row stating no status has
    # nothing for the others to disagree with, and the branch above has already
    # said so. Like the drift, it qualifies whichever reading follows rather than
    # replacing it.
    drift += disagreement_sentence(rows, columns, commit, exit_status)

    if exit_status != 0:
        named = failing if failing and failing != "—" else "not recorded in that row"
        return report.check(SUITE_RECORD_CHECK, False,
                            f"the newest recorded run was red — exit {exit_status} "
                            f"at {commit} ({when}): {tally}; failing tests: "
                            f"{named}; {drift}")

    # A run that matched no tests exits 0, because that is what xcodebuild
    # returns for it, and read off the `exit` cell alone it is indistinguishable
    # from a suite that passed. It is not one: nothing was measured. Same for a
    # run this script itself ended at SUITE_TIMEOUT_SECONDS — the build is TERMed
    # and given two seconds to notice, and one that finishes on its own inside
    # that window is waited on for its real status, so its `exit` cell can be 0
    # too. This sits below the red reading on purpose — a row that recorded no
    # tally *and* a non-zero exit has already been reported as the red run it is,
    # and gains no second reading here.
    if tally_states_no_measurement(tally):
        if tally.startswith(TIMEOUT_TALLY_PREFIX):
            detail = (f"the newest recorded run was ended at its time limit — "
                      f"{commit} ({when}) reported {tally!r}, so nothing was "
                      f"measured and its exit 0 is not a passing suite; run "
                      f"./scripts/run-unit-suite.sh; {drift}")
        else:
            detail = (f"the newest recorded run measured nothing — "
                      f"{commit} ({when}) reported no test tally, so its "
                      f"exit 0 is xcodebuild's and not a passing suite; "
                      f"run ./scripts/run-unit-suite.sh; {drift}")
        return report.check(SUITE_RECORD_CHECK, False, detail)

    return report.check(SUITE_RECORD_CHECK, True,
                        f"{commit} ({when}): {tally} — {drift}")


def run_one(client, project, item, timeout_min):
    """Start a run and poll /result to terminal. Returns the last result dict
    augmented with runId / started / reached_terminal / interrupted / unreachable."""
    # Longer timeout than the app's wait-for-idle tail (≤30s) so a busy autopilot
    # returns a clean 409 instead of a client-side "timed out".
    st, d = client.request("POST", "/v1/runs", {"project": project, "item": item}, timeout=90)
    run_id = d.get("runId") if isinstance(d, dict) else None
    if not run_id:
        return {"runId": None, "started": False, "start_response": d}
    deadline = time.time() + timeout_min * 60
    last, state = {}, None
    misses = 0     # consecutive polls that never reached the server
    while time.time() < deadline:
        st, body = client.request("GET", f"/v1/runs/{run_id}/result")
        # Status 0 is `Client.request`'s connection-level arm: the app quit,
        # crashed, or its port closed, so this poll learned nothing about the run.
        # Throwing the status away here is what let that read as an ordinary
        # answer with no `state`, poll on to the full --timeout-min, and come back
        # looking exactly like a run that never finished.
        if st == 0:
            misses += 1
            last = body
            # One miss is tolerated — a restarting app comes back and the record
            # is still readable. Past that, the argument the `interrupted` branch
            # below makes applies: waiting is no longer learning anything.
            if misses >= UNREACHABLE_POLLS:
                break
            time.sleep(10)
            continue
        misses = 0
        last = body
        state = last.get("state")
        if state in ("finished", "awaiting_approval"):
            break
        # `interrupted` is the app's word for "I died under this run", read back
        # from the durable record. Nothing in this process or any other will
        # change it, so a second read tells us exactly what the first one did:
        # polling on would spend the whole --timeout-min learning nothing. Not
        # the same as `unknown`, which is an *open* record whose run may be live.
        if state == "interrupted":
            break
        time.sleep(10)
    last["runId"] = run_id
    last["started"] = True
    last["reached_terminal"] = state in ("finished", "awaiting_approval")
    last["interrupted"] = state == "interrupted"
    # The run ended with the server not answering: whatever it was doing, this
    # process never got to see it, so it is neither finished nor unfinished.
    last["unreachable"] = misses > 0 and not last["reached_terminal"] and not last["interrupted"]
    return last


def run_loop(client, report, project, item, approve, timeout_min, repo_path):
    report.narrate(f"\nRun loop: {project} / {item}")
    # Preflight the repo before the run rather than after it: a path git cannot
    # read has no state to snapshot, and finding that out at the end means an
    # operator waited out a whole run for a check that was never going to
    # measure anything. `repo_error`, once set, is what the isolation checks
    # report below in place of a comparison nobody could make.
    before, repo_error = None, None
    if repo_path:
        _root, repo_error = git(repo_path, "rev-parse", "--show-toplevel")
        if not repo_error:
            before, repo_error = git(repo_path, "status", "--porcelain")
        if repo_error:
            report.narrate(f"  repo path unreadable: {repo_path} — {repo_error}")

    res = run_one(client, project, item, timeout_min)
    report.check("start run", res.get("started") and res.get("runId"),
                 res.get("runId") or res.get("start_response"))
    if not res.get("started"):
        return
    # An unreachable server has no state to report, and `state=None outcome=None`
    # reads as a run that answered and said nothing rather than as one nobody
    # could ask about — say which it was.
    if res.get("unreachable"):
        detail = ("the control server stopped answering — "
                  + str(res.get("error") or "connection failed"))
    else:
        detail = (f"state={res.get('state')} outcome={res.get('outcome')} "
                  f"item={res.get('itemStatus')}")
    report.check("run reached terminal/approval", res.get("reached_terminal"), detail)

    if res.get("branch"):
        report.check("run branch reported", True, res["branch"])

    if "qualityScore" in res:
        score = res["qualityScore"]
        dims = res.get("judgeDimensions", {})
        report.check("quality judge scored the run", isinstance(score, (int, float)),
                     f"{score:.2f}  dims={ {k: round(v, 2) for k, v in dims.items()} }")

    if repo_path:
        after, err = (None, repo_error) if repo_error else git(repo_path, "status", "--porcelain")
        if after is None:
            # Same reading as `run_one`'s unreachable arm: this process learned
            # nothing, which is its own outcome and not a pass. Reporting the
            # branch as `(missing)` here named the wrong failure — the branch was
            # never looked for, because the repo could not be read.
            detail = f"could not read repo at {repo_path} — {err}"
            report.check("worktree isolation: main tree unchanged", False, detail)
            if res.get("branch"):
                report.check("worktree isolation: run branch exists", False, detail)
        else:
            report.check("worktree isolation: main tree unchanged", after == before,
                         "no new changes in main tree" if after == before else "main tree changed!")
            if res.get("branch"):
                br, br_err = git(repo_path, "branch", "--list", res["branch"])
                report.check("worktree isolation: run branch exists", bool(br),
                             br or br_err or "(missing)")

    if approve and (res.get("itemStatus") == "awaiting-approval" or res.get("state") == "awaiting_approval"):
        st, ad = client.request("POST", f"/v1/runs/{res['runId']}/approve", {"approve": True})
        report.check("approve item → done", st == 200 and ad.get("status") == "done", ad)


def configure_autopilot(client, report, project, *, session_cap, per_item_cap, margin,
                        auto_merge, merge_verify, worktree):
    """Push the run's guardrail config through the sanctioned control API (never by
    hand-editing config files, which the running app would overwrite). Auto-merge
    implies worktree isolation — there must be a branch to merge."""
    payload = {"project": project}
    if session_cap is not None:  payload["sessionCostCapUSD"] = session_cap
    if per_item_cap is not None: payload["perItemCostCapUSD"] = per_item_cap
    if margin is not None:       payload["costCapMargin"] = margin
    if auto_merge:
        payload["autoMergeOnApproval"] = True
        payload["useWorktree"] = True   # required: merge needs a branch
        if merge_verify: payload["autoMergeVerifyCommand"] = merge_verify
    elif worktree:
        payload["useWorktree"] = True
    if len(payload) == 1:
        return  # nothing to set
    st, d = client.request("PUT", "/v1/autopilot", payload)
    report.narrate(f"Configured autopilot ({st}): "
                   f"session_cap={d.get('sessionCostCapUSD')} per_item={d.get('perItemCostCapUSD')} "
                   f"margin={d.get('costCapMargin')} worktree={d.get('useWorktree')} "
                   f"auto_merge={d.get('autoMergeOnApproval')} "
                   f"merge_verify={'item-verify + project' if d.get('autoMergeVerifyCommand') else 'item-verify only'}")
    # Whether the app took the guardrails is a check, not narration: a 409 (a run
    # already in flight) or a 400 leaves every knob at whatever it already was, and
    # the run that follows is then measured without the caps, the margin or the
    # isolation the caller asked for — while every check still passes. Only the
    # keys actually sent are compared: the handler echoes the whole config back,
    # and a knob nobody set keeps its own value.
    wanted = {k: v for k, v in payload.items() if k != "project"}
    echoed = d if isinstance(d, dict) else {}
    missed = [f"{k}={echoed.get(k)!r}, asked {v!r}" for k, v in wanted.items()
              if echoed.get(k) != v]
    if st != 200:
        detail = f"HTTP {st}: {echoed.get('error') or echoed.get('_raw') or ''}".strip()
    elif missed:
        detail = "not applied — " + "; ".join(missed)
    else:
        detail = ", ".join(sorted(wanted))
    report.check("autopilot guardrails applied", st == 200 and not missed, detail)
    if auto_merge and not merge_verify:
        report.narrate("  WARNING: --auto-merge without --merge-verify: each item's own verify "
                       "is the only merge gate. Pass --merge-verify to add a build+test gate "
                       "on top of it (both run; neither replaces the other).")


def next_startable(ready, refused):
    """The first id in the ready list that has not already refused to start, or
    None when every one of them has. An item the server won't start (no verify
    command, unmet `needs:`, oversized) stays `ready` in the backlog for as long
    as the marathon runs, so asking for it again only burns passes — step over it
    and work the queue behind it instead."""
    for item in ready:
        if item.get("id") not in refused:
            return item.get("id")
    return None


def start_refusal_detail(res):
    """What the server said about a start it refused, as one line: the `error` it
    sent, or the body as it arrived when there was none. Read here rather than at
    each arm so the line a refusal is narrated with and the one it is recorded
    with cannot come to quote different things about one answer."""
    body = res.get("start_response")
    if isinstance(body, dict):
        return str(body.get("error") or body.get("_raw") or body)
    return str(body) if body else ""


class MarathonTally:
    """What one night amounted to: every figure the metric-#1 scorecard reports,
    and the items behind the three rows that name items. The narrated block and
    the `--json` field are both read off this one object, so the document and the
    prose cannot come to report different nights."""

    def __init__(self):
        self.ran = self.completed = self.blocked = self.stalled = 0
        self.rescues = self.start_fails = self.interrupted = self.unreachable = 0
        # The items behind the two outcomes that end a run having delivered
        # nothing, named on the scorecard as `failed start` names the items it
        # refused: a count alone says a night went nowhere without saying which
        # items did.
        self.cancelled_items = []
        self.did_not_run_items = []
        self.scores = []
        # The ids that refused to start: both what `failed start` names and what
        # the next pass steps over rather than asking for again.
        self.refused = set()
        # What a spent ceiling said, once one has refused a start — and, being the
        # only record of it, what the scorecard counts. None until then.
        self.ceiling_stop = None

    @property
    def avg_quality(self):
        """The mean of what was scored, or None when nothing was — which is the
        `n/a` the narrated row prints, and not the 0.0 an empty mean would read
        as if it were rendered as a number."""
        return sum(self.scores) / len(self.scores) if self.scores else None

    def record_start_failure(self, item):
        """A start that failed for a reason of this item's own. It will refuse
        for as long as it sits in the queue, so it is remembered as refused and
        the ones behind it are worked instead of being starved by retries."""
        self.start_fails += 1
        self.refused.add(item)

    def record_unmeasured(self, kind):
        """A pass that measured nothing about the autopilot — `interrupted` or
        `unreachable`. Each gets its own line rather than being counted against
        the SLO, because neither is the autopilot failing to finish."""
        if kind == "interrupted":
            self.interrupted += 1
        else:
            self.unreachable += 1

    def record(self, bucket, item):
        """Count one run on the scorecard line `terminal_bucket` put it on."""
        if bucket == "rescue":
            self.rescues += 1
        elif bucket == "blocked":
            self.blocked += 1
        elif bucket == "stalled":
            self.blocked += 1        # a stall is a blocked run with a reason
            self.stalled += 1
        elif bucket == "cancelled":
            self.cancelled_items.append(item)
        elif bucket == "did_not_run":
            self.did_not_run_items.append(item)
        else:
            self.completed += 1

    def narrate(self, report, dur):
        """The metric-#1 scorecard as prose, off the same fields `document`
        writes, so the block and the JSON beside it report one night."""
        avg = self.avg_quality
        report.narrate("\n=== MARATHON SCORECARD (success-metrics.md #1) ===")
        report.narrate(f"  wall clock:   {wall_clock(dur)}")
        report.narrate(f"  items run:    {self.ran}")
        report.narrate(f"  completed:    {self.completed}")
        report.narrate(f"  blocked:      {self.blocked}  (stalled: {self.stalled})")
        # The item-naming rows are counted off the lists themselves, for the
        # reason `ceiling stop` is: the figure and the items it is about cannot
        # then say different things.
        report.narrate(counted_row("cancelled:    ", self.cancelled_items))
        report.narrate(counted_row("did not run:  ", self.did_not_run_items))
        report.narrate(f"  rescues:      {self.rescues}")
        report.narrate(f"  interrupted:  {self.interrupted}")
        report.narrate(f"  unreachable:  {self.unreachable}")
        report.narrate(counted_row("failed start: ", sorted(self.refused),
                                   count=self.start_fails, prefix="never started: "))
        # Beside `failed start` because it is the number those failures used to be
        # counted as, and counted off the detail rather than kept alongside it, so
        # the figure and the reason cannot say different things about one night. At
        # most one: the loop ends on the first ceiling it meets.
        report.narrate(counted_row("ceiling stop: ",
                                   [self.ceiling_stop] if self.ceiling_stop else []))
        report.narrate(f"  avg quality:  {('%.2f' % avg) if avg is not None else 'n/a'}")

    def document(self, dur):
        """The same figures again, for the reader that is a machine: `--json` used
        to carry only the two check rows `marathon` records, so every number the
        block above narrates — the metric #1 scorecard itself — could be had only
        by regexing the narration. `avgQuality` is the mean itself rather than the
        2-decimal rendering beside it, and is null when nothing was scored, which
        is the `n/a` that line prints. `ceilingStop` is what stopped the night, or
        null: the narrated count is read off it, and so is this."""
        return {
            "wallClock": wall_clock(dur),
            "durationSeconds": int(dur),
            "itemsRun": self.ran,
            "completed": self.completed,
            "blocked": self.blocked,
            "stalled": self.stalled,
            "cancelled": len(self.cancelled_items),
            "cancelledItems": self.cancelled_items,
            "didNotRun": len(self.did_not_run_items),
            "didNotRunItems": self.did_not_run_items,
            "rescues": self.rescues,
            "interrupted": self.interrupted,
            "unreachable": self.unreachable,
            "failedStart": self.start_fails,
            "neverStarted": sorted(self.refused),
            "ceilingStop": self.ceiling_stop,
            "avgQuality": self.avg_quality,
        }


def wall_clock(seconds):
    """A duration as the scorecard writes it: `0h07m`."""
    hrs, mins = int(seconds // 3600), int((seconds % 3600) // 60)
    return f"{hrs}h{mins:02d}m"


def counted_row(label, items, count=None, prefix=""):
    """A scorecard row that prints a figure and then names what is behind it —
    `cancelled:    2  (itm-a, itm-b)` — and prints the figure alone when nothing
    is. The figure is the length of that same list unless `count` says otherwise
    (`failed start` counts refusals, which is one per item it names), so a reader
    totalling the numbers and one acting on the ids read one night."""
    figure = len(items) if count is None else count
    return f"  {label}{figure}" + (f"  ({prefix}{', '.join(items)})" if items else "")


def queue_read_detail(status, body):
    """What a backlog read that never came back 200 said, as one line."""
    reported = (isinstance(body, dict) and body.get("error")) or "no error reported"
    return f"status={status}: {reported}"


def next_marathon_item(client, report, project, refused):
    """The id to start next, or None when the night is over — having narrated
    which of its three ends this was. A read that never came back 200 tells us
    nothing about the queue, and its body carries no `items`: without that arm an
    unreachable server, a 401 and a 500 would all narrate a drained queue and
    leave a scorecard reporting SLO #1 met over a night on which nothing was ever
    asked, so it is a failed check as well as a line."""
    st, d = client.request("GET", "/v1/backlog?project=" + urllib.parse.quote(project))
    if st != 200:
        detail = queue_read_detail(st, d)
        report.narrate(f"  queue could not be read — {detail}")
        report.check("marathon: backlog readable", False, detail)
        return None
    items = d.get("items", []) if isinstance(d, dict) else []
    ready = [i for i in items if i.get("status") == "ready"]
    if not ready:
        report.narrate("  queue drained — no ready items left.")
        return None
    item = next_startable(ready, refused)
    if item is None:
        report.narrate(f"  nothing left to start — all {len(ready)} remaining ready "
                       f"items refused: {', '.join(str(i.get('id')) for i in ready)}")
    return item


def start_refusal_kind(res):
    """Which of the three refusals a start met, as the thing to do about it.

    `busy` is NOT a start failure — a stalling in-flight item keeps the autopilot
    busy until its stall-timeout (~20 min) ends it, and that is waited out rather
    than aborted on: one slow item shouldn't kill a night. `ceiling` is a refusal
    about the moment rather than about this item — the daily-budget gate refuses
    every autonomous start alike, so the item behind this one would be refused for
    the same reason and by the same sentence. `item` is this item's own refusal,
    the 422 a pickup gate returns, which says nothing about the queue behind it."""
    resp = str(res.get("start_response") or "").lower()
    if "busy" in resp:
        return "busy"
    if CEILING_REFUSAL in resp:
        return "ceiling"
    return "item"


def wait_out_busy(report, waits):
    """Sit out the in-flight item that is keeping the autopilot busy, returning
    False once it has been busy long enough — ~30 min at 30s a wait — to call it
    wedged and end the night."""
    if waits > 60:
        report.narrate("  aborting: autopilot busy > ~30 min (wedged).")
        return False
    if waits % 5 == 1:
        report.narrate(f"  autopilot busy — waiting for the in-flight item to clear ({waits})")
    time.sleep(30)
    return True


def measurement_excuse(res):
    """The reason this pass measured nothing about the autopilot, as the line it
    is counted on and the sentence it is narrated with — or None when the run is
    the autopilot's to answer for. The app dying under a run is not the autopilot
    failing to finish, and a server that stopped answering told this process
    nothing about the run either way; counting either as a rescue reports a
    violated SLO #1 that never happened."""
    if res.get("interrupted"):
        return "interrupted", ("interrupted — the app restarted under this run "
                               f"(item={res.get('itemStatus')}); not counted as a rescue")
    if res.get("unreachable"):
        return "unreachable", ("unreachable — the control server stopped answering "
                               f"under this run ({res.get('error') or 'connection failed'}); "
                               "not counted as a rescue")
    return None


def terminal_bucket(res):
    """Which scorecard line one measured run belongs on. Reaching a terminal state
    is not the same as having done the item, and `PersistedRunRecord.Outcome` has
    two endings that deliver nothing: a run somebody (or a cancel) stopped, and a
    start a pickup gate refused before any work began. Both answer
    `"state": "finished"`, so both used to carry the headline number — a night
    whose only terminal runs were these reported SLO #1 met over an empty tree."""
    outcome = res.get("outcome")
    if not res.get("reached_terminal"):
        return "rescue"
    if res.get("itemStatus") == "blocked" or outcome == "blocked":
        return "stalled" if "stall" in (res.get("reason") or "").lower() else "blocked"
    if outcome in ("cancelled", "did_not_run"):
        return outcome
    return "completed"


def approve_refusal_detail(body):
    """Why an approve did not land, as the server put it."""
    if isinstance(body, dict):
        return body.get("error") or body.get("reason") or body.get("status")
    return body


def approve_gated_item(client, report, item, run_id):
    """Approve one run that ended at its gate. The answer is the whole point of
    the POST: a gate that refused (409 — a dirty checkout, a branch holding
    nothing, a failing verify), a run the server no longer has (404) or a server
    that stopped answering (0) all leave the item sitting at its gate, and a night
    of them used to end with a scorecard nobody could tell apart from one where
    every approval landed."""
    ast, ad = client.request("POST", f"/v1/runs/{run_id}/approve", {"approve": True})
    landed = ast == 200 and isinstance(ad, dict) and ad.get("status") == "done"
    if not landed:
        report.narrate(f"  {item}: approve did not land — status={ast}: "
                       f"{approve_refusal_detail(ad) or 'no reason reported'}")
    report.check(f"marathon: approve {item} → done", landed, ad)


def record_run(client, report, tally, item, res, auto_approve):
    """Count, narrate and — when it ended at its gate and the night is approving —
    approve one run that started."""
    tally.ran += 1
    if isinstance(res.get("qualityScore"), (int, float)):
        tally.scores.append(res["qualityScore"])
    excuse = measurement_excuse(res)
    if excuse:
        kind, sentence = excuse
        tally.record_unmeasured(kind)
        report.narrate(f"  {item}: {sentence}")
        return
    tally.record(terminal_bucket(res), item)
    report.narrate(f"  ran {item}: state={res.get('state')} outcome={res.get('outcome')} "
                   f"item={res.get('itemStatus')} score={res.get('qualityScore')}")
    if auto_approve and res.get("itemStatus") == "awaiting-approval" and res.get("runId"):
        approve_gated_item(client, report, item, res["runId"])


def marathon(client, report, project, hours, timeout_min, auto_approve):
    """Run every `ready` item for up to `hours`, then emit the metric-#1 scorecard
    from docs/success-metrics.md (duration, completed, blocked, stalled, rescues,
    avg quality). A rescue = a run that never reached a terminal state in time —
    which neither an interrupted run nor one whose server stopped answering did
    either, but for a reason that is not the autopilot's, so each is counted on
    its own line rather than against the SLO. `completed` is what a run *ended
    as*, not merely that it ended: a cancelled run and one a pickup gate refused
    are terminal too, and each gets its own line rather than the headline. What
    each of those lines is counted from is `MarathonTally`; the loop here is the
    order the night is worked in."""
    report.narrate(f"\nMarathon: {project} — up to {hours}h (timeout {timeout_min}m/item)")
    start = time.time()
    deadline = start + hours * 3600
    tally = MarathonTally()
    busy_waits = 0
    while time.time() < deadline:
        item = next_marathon_item(client, report, project, tally.refused)
        if item is None:
            break
        res = run_one(client, project, item, timeout_min)
        if res.get("started"):
            busy_waits = 0
            record_run(client, report, tally, item, res, auto_approve)
            continue
        kind = start_refusal_kind(res)
        if kind == "busy":
            busy_waits += 1
            if not wait_out_busy(report, busy_waits):
                break
            continue
        if kind == "ceiling":
            # Stepping over a ceiling — which is right for an item's own refusal —
            # posts a doomed POST /v1/runs per remaining ready item, counts each as
            # an item that would not start, and ends the night with a line naming
            # every one of those perfectly good items and not the ceiling that
            # actually stopped it. End here instead, and say which ceiling it was.
            tally.ceiling_stop = start_refusal_detail(res)
            report.narrate(f"  ceiling reached — ending the marathon: {tally.ceiling_stop}")
            report.check("marathon: no spent ceiling stopped the night", False,
                         tally.ceiling_stop)
            break
        tally.record_start_failure(item)
        report.narrate(f"  {item}: did not start ({res.get('start_response')}) "
                       "— skipping to the next ready item")

    dur = time.time() - start
    tally.narrate(report, dur)
    report.scorecard = tally.document(dur)
    report.check("marathon: zero rescues (SLO #1)", tally.rescues == 0,
                 f"{tally.rescues} rescues")
    report.check("marathon: completed at least one item", tally.completed >= 1,
                 f"{tally.completed} completed")


def main():
    ap = argparse.ArgumentParser(description="Verify the Kiteloop control API + autopilot loop.")
    ap.add_argument("--port", type=int, default=4517)
    ap.add_argument("--token", help="bearer token (default: read ~/.kiteloop/control-token)")
    ap.add_argument("--json", action="store_true", help="machine-readable report")
    ap.add_argument("--run", nargs=2, metavar=("PROJECT", "ITEM"),
                    help="drive a full autopilot loop for one ready item (side-effecting)")
    ap.add_argument("--approve", action="store_true", help="approve the item after a --run")
    ap.add_argument("--repo-path", help="project git root, to verify worktree isolation around a --run")
    ap.add_argument("--timeout-min", type=int,
                    help=f"max minutes to wait on a --run (default: {DEFAULT_TIMEOUT_MIN})")
    ap.add_argument("--marathon", metavar="PROJECT",
                    help="run all ready items for --hours and emit the metric-#1 scorecard")
    ap.add_argument("--hours", type=float,
                    help=f"marathon duration cap (default: {DEFAULT_HOURS})")
    ap.add_argument("--auto-approve", action="store_true",
                    help="auto-approve awaiting-approval items during a marathon")
    ap.add_argument("--session-cap", type=float, help="session cost cap USD (circuit breaker)")
    ap.add_argument("--per-item-cap", type=float, help="per-item cost cap USD (flat floor)")
    ap.add_argument("--margin", type=float, help="cost-cap margin (effective cap = max(flat, predicted×margin))")
    ap.add_argument("--worktree", action="store_true", help="run each item in an isolated worktree")
    ap.add_argument("--auto-merge", action="store_true",
                    help="merge reviewer-passed items into main when the merge-verify is green (implies --worktree)")
    ap.add_argument("--merge-verify", metavar="CMD",
                    help="command that must pass on the merged tree before a merge is kept (e.g. a build+test)")
    args = ap.parse_args()

    # The guardrail flags configure the run they precede, so outside --run and
    # --marathon there is no run to configure. Accepting them there and doing
    # nothing is the worst of the three readings: the caller believes it asked
    # for isolation it never got, and then measures the app against it.
    guardrails = [
        ("--session-cap", args.session_cap is not None),
        ("--per-item-cap", args.per_item_cap is not None),
        ("--margin", args.margin is not None),
        ("--worktree", args.worktree),
        ("--auto-merge", args.auto_merge),
        ("--merge-verify", args.merge_verify is not None),
    ]
    given = [flag for flag, was_given in guardrails if was_given]
    if given and not (args.run or args.marathon):
        ap.error(f"{', '.join(given)}: guardrail flags configure a run, and apply "
                 f"only to --run or --marathon; pass one of those, or drop the flag")

    # The same reading for the flags that shape the run itself: --repo-path asks
    # for isolation only a run can have, --approve and --auto-approve clear a gate
    # only a run can raise, and the two clocks bound a wait there is nothing to
    # wait for. Accepting any of them with no run reports on the read-only smoke
    # checks as though it had honoured them.
    shaping = [
        ("--repo-path", args.repo_path is not None),
        ("--approve", args.approve),
        ("--auto-approve", args.auto_approve),
        ("--timeout-min", args.timeout_min is not None),
        ("--hours", args.hours is not None),
    ]
    shaping_given = [flag for flag, was_given in shaping if was_given]
    if shaping_given and not (args.run or args.marathon):
        ap.error(f"{', '.join(shaping_given)}: these flags shape a run, and apply "
                 f"only to --run or --marathon; pass one of those, or drop the flag")

    # The gate above asks only "was there a run at all?", and the two approval
    # flags each answer to one mode: --approve clears the human gate a --run
    # raises, --auto-approve clears them as a --marathon works its queue. Passed
    # to the other mode they parse, configure a run, drive it to the end, and are
    # never read — the caller waits out a full run believing it approved.
    if args.auto_approve and not args.marathon:
        ap.error("--auto-approve approves items as a --marathon works its queue, "
                 "and applies only to --marathon; pass --marathon, or --approve "
                 "to approve a --run")
    if args.approve and not args.run:
        ap.error("--approve approves the item a --run drove, and applies only to "
                 "--run; pass --run, or --auto-approve to approve during a "
                 "--marathon")

    timeout_min = args.timeout_min if args.timeout_min is not None else DEFAULT_TIMEOUT_MIN
    hours = args.hours if args.hours is not None else DEFAULT_HOURS

    token = args.token
    if not token:
        try:
            token = open(TOKEN_PATH).read().strip()
        except OSError:
            print(f"No token at {TOKEN_PATH} — is the app installed/run at least once?", file=sys.stderr)
            sys.exit(2)

    client = Client(f"http://127.0.0.1:{args.port}", token)
    report = Report(args.json)
    guardrail_args = dict(
        session_cap=args.session_cap, per_item_cap=args.per_item_cap, margin=args.margin,
        auto_merge=args.auto_merge, merge_verify=args.merge_verify, worktree=args.worktree)

    smoke(client, report)
    # Read-only like everything above it, and reported the same way — it belongs
    # to the smoke pass rather than to either run mode, because the question it
    # answers is asked before a night starts, not about the run that follows.
    suite_record(report)
    if args.run:
        # Same configuration step the marathon takes, and for the same reason:
        # --repo-path checks a --run for worktree isolation, so the run has to be
        # told to isolate. configure_autopilot sends nothing when no flag was set.
        configure_autopilot(client, report, args.run[0], **guardrail_args)
        repo = os.path.expanduser(args.repo_path) if args.repo_path else None
        run_loop(client, report, args.run[0], args.run[1], args.approve, timeout_min, repo)
    if args.marathon:
        configure_autopilot(client, report, args.marathon, **guardrail_args)
        marathon(client, report, args.marathon, hours, timeout_min, args.auto_approve)

    sys.exit(report.finish())


if __name__ == "__main__":
    main()
