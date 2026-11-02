#!/usr/bin/env python3
"""test-check-companion-api-list — assert the readers in check-companion-api-list.py.

The check compares three files that agree only by convention: the `/v1/…`
strings in `KiteloopMobile/Sources`, the table in `KiteloopMobile/README.md`,
and `ControlRouter.table`. Its failure mode is silence — a screen starts
calling a route the README never mentions, and the list the README promises
to be is quietly incomplete. So each reader is driven over synthetic text, and
the check is run end to end over a scratch tree with one disagreement of each
kind, so "parses" and "reports" are asserted as the different claims they are.
Starts no build, reads no process list, writes only under a temporary
directory — safe while Kiteloop is running.

  ./scripts/test-check-companion-api-list.py
"""
import importlib.util
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("check", HERE / "check-companion-api-list.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

failed = 0


def expect(name, got, want):
    global failed
    if got == want:
        print(f"  ok    {name}")
    else:
        print(f"  FAIL  {name}\n          expected: {want!r}\n          actual:   {got!r}")
        failed += 1


with tempfile.TemporaryDirectory(prefix="companion-api-list") as tmp:
    root = Path(tmp)
    sources = root / "Sources"
    sources.mkdir()
    (sources / "A.swift").write_text('let a = client.get(client.query("/v1/projects", [("x", "1")]))\n'
                                     'let b = client.post("/v1/backlog/approve", body)\n')
    (sources / "B.swift").write_text('let c = client.get("/v1/agents/transcript?project=p&agent=a&limit=5")\n')
    expect("called paths are read without their query strings",
           check.called_paths(sources), {"/v1/projects", "/v1/backlog/approve", "/v1/agents/transcript"})

    readme = root / "README.md"
    readme.write_text("| Method | Path | Screen | For |\n|---|---|---|---|\n"
                      "| GET | `/v1/projects` | Projects | list |\n"
                      "| GET | `/v1/agents/transcript?project=&agent=` | Chat | words |\n"
                      "| POST | `/v1/backlog/approve` | Gate | verdict |\n")
    expect("listed paths are read off the table's second column, query stripped",
           check.listed_paths(readme), {"/v1/projects", "/v1/agents/transcript", "/v1/backlog/approve"})

    router = root / "ControlRouter.swift"
    router.write_text('Row("GET",  "/v1/projects")  { _ in .listProjects },\n'
                      'Row("POST", "/v1/runs/:id/approve") { id in .approveRun(runID: id) },\n')
    served = check.served_paths(router)
    expect("a literal route serves its own path", check.route_serves("/v1/projects", served), True)
    expect("a templated route serves a concrete spelling", check.route_serves("/v1/runs/abc/approve", served), True)
    expect("an unknown path is not served", check.route_serves("/v1/nothing", served), False)
    expect("a path with the wrong segment count is still not served",
           check.route_serves("/v1/runs/abc/extra/approve", served), False)

# end to end: a scratch repo with one disagreement of each kind
with tempfile.TemporaryDirectory(prefix="companion-api-list-e2e") as tmp:
    root = Path(tmp)
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    (root / "KiteloopMobile" / "Sources").mkdir(parents=True)
    (root / "Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/Control").mkdir(parents=True)
    (root / "KiteloopMobile/Sources/A.swift").write_text('client.get("/v1/projects")\nclient.get("/v1/uncounted")\n')
    (root / "KiteloopMobile/README.md").write_text("| Method | Path | Screen | For |\n|---|---|---|---|\n"
                                                   "| GET | `/v1/projects` | P | list |\n"
                                                   "| GET | `/v1/stale` | P | gone |\n")
    (root / "Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/Control/ControlRouter.swift").write_text(
        'Row("GET", "/v1/projects") { _ in .listProjects },\nRow("GET", "/v1/stale") { _ in .stale },\n')
    run = subprocess.run([sys.executable, str(HERE / "check-companion-api-list.py")], cwd=root,
                         capture_output=True, text=True)
    expect("a disagreeing tree fails", run.returncode, 1)
    expect("an uncounted call is named", "/v1/uncounted is called from KiteloopMobile/Sources" in run.stderr, True)
    expect("a stale row is named", "/v1/stale has a row in KiteloopMobile/README.md" in run.stderr, True)
    expect("a path no route serves is named", "/v1/uncounted is not a route" in run.stderr, True)

    (root / "KiteloopMobile/Sources/A.swift").write_text('client.get("/v1/projects")\n')
    (root / "KiteloopMobile/README.md").write_text("| Method | Path | Screen | For |\n|---|---|---|---|\n"
                                                   "| GET | `/v1/projects` | P | list |\n")
    run = subprocess.run([sys.executable, str(HERE / "check-companion-api-list.py"), "--quiet"], cwd=root,
                         capture_output=True, text=True)
    expect("an agreeing tree passes quietly", (run.returncode, run.stdout), (0, ""))

print("test-check-companion-api-list: all cases passed." if not failed else f"test-check-companion-api-list: {failed} FAILED")
sys.exit(1 if failed else 0)
