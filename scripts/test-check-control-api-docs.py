#!/usr/bin/env python3
"""test-check-control-api-docs — assert the readers in check-control-api-docs.py.

The check it asserts is regex over two files that agree by convention, not by
anything the compiler enforces: `ControlRouter.table` in
`Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/Control/ControlRouter.swift`
and the endpoint index and section headings in `docs/control-api.md`. Its
failure mode is silence — two retired endpoints, `POST
/v1/coordinator/action` and `PUT /v1/coordinator/policy`, stayed documented
for a day after the routes themselves were deleted, and nothing said so. So
the readers (`read_routes`, `read_index_rows`, `read_sections`,
`normalize_path`, `compare`) are driven directly over synthetic table and doc
text — one fixture per disagreement the check exists to name — and then the
check itself is run end to end over a mutated copy of the real files, handed
to it through `--router`/`--doc`, so a reader that parses correctly and a
check that actually reports are asserted as the different claims they are.

It starts no build, reads no process list and writes nothing outside a
temporary directory, so it is safe to run — on its own or as part of the
suite — while Kiteloop is running.

  ./scripts/test-check-control-api-docs.py
"""

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True  # leave no __pycache__ beside the script

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SCRIPT = os.path.join(HERE, "check-control-api-docs.py")

failed = 0
fixtures = []


def check(name, ok, detail=""):
    global failed
    if ok:
        print("  ok    %s" % name)
    else:
        print("  FAIL  %s%s" % (name, "\n          " + detail if detail else ""))
        failed += 1


def check_equal(name, expected, actual):
    check(name, expected == actual, "expected %r, got %r" % (expected, actual))


def load_script():
    """The script as a module — its filename has dashes, so it cannot be imported."""
    spec = importlib.util.spec_from_file_location("check_control_api_docs", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


module = load_script()

print("test-check-control-api-docs")

# --- normalize_path ------------------------------------------------------
#
# What makes a `:id` route in the table and its `{runId}` doc spelling read
# as the same request, rather than two disagreements.

check_equal(
    "a plain path is untouched",
    "/v1/backlog",
    module.normalize_path("/v1/backlog"),
)
check_equal(
    "a `:name` capture segment becomes a placeholder",
    "/v1/runs/*",
    module.normalize_path("/v1/runs/:id"),
)
check_equal(
    "a `{name}` capture segment becomes the same placeholder",
    "/v1/runs/*",
    module.normalize_path("/v1/runs/{runId}"),
)
check_equal(
    "the two capture spellings agree beyond the segment itself",
    module.normalize_path("/v1/runs/:id/approve"),
    module.normalize_path("/v1/runs/{runId}/approve"),
)
check_equal(
    "a `?query` suffix is stripped",
    "/v1/backlog",
    module.normalize_path("/v1/backlog?project="),
)
check_equal(
    "a trailing slash contributes no empty segment",
    "/v1/backlog",
    module.normalize_path("/v1/backlog/"),
)

# --- read_routes -----------------------------------------------------------

TABLE_TEXT = """
    private static let table: [Row] = [
        Row("GET",  "/health")                  { _ in .health },
        Row("GET",  "/v1/backlog")              { _ in .listBacklog },
        Row("GET",  "/v1/runs/:id")             { .runStatus(runID: $0[0]) },
        Row("POST", "/v1/runs/:id/approve")     { .approveRun(runID: $0[0]) }
    ]
"""

routes = module.read_routes(TABLE_TEXT)
check_equal(
    "every Row(...) entry is read as (method, normalized path, raw path)",
    [
        ("GET", "/health", "/health"),
        ("GET", "/v1/backlog", "/v1/backlog"),
        ("GET", "/v1/runs/*", "/v1/runs/:id"),
        ("POST", "/v1/runs/*/approve", "/v1/runs/:id/approve"),
    ],
    routes,
)

# --- read_index_rows ---------------------------------------------------------

DOC_TEXT = """# Control API

| Method | Path | Description |
|---|---|---|
| GET | `/health` | Liveness probe |
| GET | `/v1/backlog?project=` | List backlog items |
| GET | `/v1/runs/{runId}` | Poll run status |

## Detail

### GET /health

Body.

### GET /v1/backlog

Body.
"""

index_rows = module.read_index_rows(DOC_TEXT)
check_equal(
    "each `| METHOD | \\`path\\` | ... |` row is read with its line number",
    [
        ("GET", "/health", "/health", 5),
        ("GET", "/v1/backlog", "/v1/backlog?project=", 6),
        ("GET", "/v1/runs/*", "/v1/runs/{runId}", 7),
    ],
    index_rows,
)

sections = module.read_sections(DOC_TEXT)
check_equal(
    "each `### METHOD /path` heading is read with its line number",
    [
        ("GET", "/health", "/health", 11),
        ("GET", "/v1/backlog", "/v1/backlog", 15),
    ],
    sections,
)
check_equal(
    "a prose heading that is not `### METHOD /path` is not read as a section",
    True,
    all(raw != "Detail" for _, _, raw, _ in sections),
)

# --- compare: the four disagreements ------------------------------------------

BASE_ROUTES = [
    ("GET", "/health", "/health"),
    ("GET", "/v1/backlog", "/v1/backlog"),
]
BASE_INDEX = [
    ("GET", "/health", "/health", 5),
    ("GET", "/v1/backlog", "/v1/backlog", 6),
]
BASE_SECTIONS = [
    ("GET", "/health", "/health", 11),
    ("GET", "/v1/backlog", "/v1/backlog", 15),
]

undocumented, unanswered, duplicates, orphan_sections = module.compare(
    BASE_ROUTES, BASE_INDEX, BASE_SECTIONS
)
check_equal("agreeing input reports nothing wrong at all", ([], [], [], []), (undocumented, unanswered, duplicates, orphan_sections))

# 1. a route the table answers with no index row for it.
extra_route = BASE_ROUTES + [("POST", "/v1/runs", "/v1/runs")]
undocumented, unanswered, duplicates, orphan_sections = module.compare(
    extra_route, BASE_INDEX, BASE_SECTIONS
)
check_equal(
    "a route with no index row is reported as undocumented, named by method and path",
    [("POST", "/v1/runs")],
    undocumented,
)
check_equal("nothing else is reported alongside it", ([], [], []), (unanswered, duplicates, orphan_sections))

# 2. an index row naming a request the table has no route for.
extra_index = BASE_INDEX + [("DELETE", "/v1/ghost", "/v1/ghost", 9)]
undocumented, unanswered, duplicates, orphan_sections = module.compare(
    BASE_ROUTES, extra_index, BASE_SECTIONS
)
check_equal(
    "an index row naming no route is reported as unanswered, with its line",
    [("DELETE", "/v1/ghost", "/v1/ghost", 9)],
    unanswered,
)
check_equal("nothing else is reported alongside it", ([], [], []), (undocumented, duplicates, orphan_sections))

# 3. a duplicated index row.
dup_index = BASE_INDEX + [("GET", "/health", "/health", 20)]
undocumented, unanswered, duplicates, orphan_sections = module.compare(
    BASE_ROUTES, dup_index, BASE_SECTIONS
)
check_equal(
    "a repeated (method, path) row is reported as a duplicate, at its own line",
    [("GET", "/health", "/health", 20)],
    duplicates,
)
check_equal("nothing else is reported alongside it", ([], [], []), (undocumented, unanswered, orphan_sections))

# 4. a section heading with no matching index row.
extra_section = BASE_SECTIONS + [("POST", "/v1/backlog/approve", "/v1/backlog/approve", 30)]
undocumented, unanswered, duplicates, orphan_sections = module.compare(
    BASE_ROUTES, BASE_INDEX, extra_section
)
check_equal(
    "a section heading matching no index row is reported, at its own line",
    [("POST", "/v1/backlog/approve", "/v1/backlog/approve", 30)],
    orphan_sections,
)
check_equal("nothing else is reported alongside it", ([], [], []), (undocumented, unanswered, duplicates))

# A `:id` route and its `{runId}` doc spelling normalise to one request, so
# they are read as agreeing rather than as an undocumented/unanswered pair.
id_route = [("GET", module.normalize_path("/v1/runs/:id"), "/v1/runs/:id")]
runid_index = [("GET", module.normalize_path("/v1/runs/{runId}"), "/v1/runs/{runId}", 40)]
undocumented, unanswered, duplicates, orphan_sections = module.compare(id_route, runid_index, [])
check_equal(
    "`:id` and `{runId}` are read as the same request, not a disagreement",
    ([], [], [], []),
    (undocumented, unanswered, duplicates, orphan_sections),
)

# --- The check itself, end to end ---------------------------------------------
#
# A reader that parses correctly and a check that reports are different
# claims; only the second one is what stops a run. Each case below writes a
# router and a doc to a temporary directory and runs the real script against
# them through --router/--doc, asserting the exit status and that the report
# names the offending method and path.


def run(router_path, doc_path, *args):
    proc = subprocess.run(
        [sys.executable, SCRIPT, "--router", router_path, "--doc", doc_path, *args],
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout, proc.stderr


def write_fixture(router_text, doc_text):
    root = tempfile.mkdtemp(prefix="test-check-control-api-docs-")
    fixtures.append(root)
    router_path = os.path.join(root, "ControlRouter.swift")
    doc_path = os.path.join(root, "control-api.md")
    with open(router_path, "w") as handle:
        handle.write(router_text)
    with open(doc_path, "w") as handle:
        handle.write(doc_text)
    return router_path, doc_path


CLEAN_ROUTER = """
    private static let table: [Row] = [
        Row("GET",  "/health")                  { _ in .health },
        Row("GET",  "/v1/backlog")              { _ in .listBacklog },
        Row("GET",  "/v1/runs/:id")             { .runStatus(runID: $0[0]) }
    ]
"""

CLEAN_DOC = """# Control API

| Method | Path | Description |
|---|---|---|
| GET | `/health` | Liveness probe |
| GET | `/v1/backlog?project=` | List backlog items |
| GET | `/v1/runs/{runId}` | Poll run status |

### GET /health

Body.

### GET /v1/backlog

Body.

### GET /v1/runs/{runId}

Body.
"""

router_path, doc_path = write_fixture(CLEAN_ROUTER, CLEAN_DOC)
code, out, err = run(router_path, doc_path)
check_equal("agreeing files pass", 0, code)
check_equal("and print one OK summary line", 1, len([l for l in out.splitlines() if l.strip()]))
check_equal("--quiet prints nothing on success", "", run(router_path, doc_path, "--quiet")[1])

# Removing an index row: the route it named is now undocumented.
missing_row_doc = CLEAN_DOC.replace('| GET | `/v1/backlog?project=` | List backlog items |\n', "")
router_path, doc_path = write_fixture(CLEAN_ROUTER, missing_row_doc)
code, out, err = run(router_path, doc_path)
check_equal("removing an index row fails the check", 1, code)
check("and names the method and path left undocumented", "GET /v1/backlog" in err)

# Adding an index row that names no route.
extra_row_doc = CLEAN_DOC.replace(
    "| GET | `/health` | Liveness probe |\n",
    "| GET | `/health` | Liveness probe |\n| DELETE | `/v1/ghost` | Nothing answers this |\n",
)
router_path, doc_path = write_fixture(CLEAN_ROUTER, extra_row_doc)
code, out, err = run(router_path, doc_path)
check_equal("an index row naming no route fails the check", 1, code)
check("and names the method and path", "DELETE /v1/ghost" in err)

# Duplicating a row.
dup_row_doc = CLEAN_DOC.replace(
    "| GET | `/health` | Liveness probe |\n",
    "| GET | `/health` | Liveness probe |\n| GET | `/health` | Liveness probe, again |\n",
)
router_path, doc_path = write_fixture(CLEAN_ROUTER, dup_row_doc)
code, out, err = run(router_path, doc_path)
check_equal("a duplicated index row fails the check", 1, code)
check("and names the method and path of the duplicate", "GET /health" in err)

# Deleting a section heading with the index row left standing: the doc still
# documents the request, and this failure mode is about the section only.
no_section_doc = CLEAN_DOC.replace("### GET /v1/backlog\n\nBody.\n\n", "")
router_path, doc_path = write_fixture(CLEAN_ROUTER, no_section_doc)
code, out, err = run(router_path, doc_path)
check_equal(
    "an index row with no section heading is not, on its own, a failure",
    0,
    code,
)

# A section heading with no index row for it.
orphan_section_doc = CLEAN_DOC + "\n### POST /v1/backlog/approve\n\nBody.\n"
router_path, doc_path = write_fixture(CLEAN_ROUTER, orphan_section_doc)
code, out, err = run(router_path, doc_path)
check_equal("a section heading matching no index row fails the check", 1, code)
check("and names the method and path", "POST /v1/backlog/approve" in err)

code, out, err = run(router_path, doc_path, "--quiet")
check_equal("--quiet still fails", 1, code)
check("--quiet still names the offender", "POST /v1/backlog/approve" in err)

# A `:id` route and its `{runId}` doc spelling: read as agreeing, not as an
# undocumented/unanswered pair either way.
id_router = """
    private static let table: [Row] = [
        Row("GET",  "/v1/runs/:id")             { .runStatus(runID: $0[0]) }
    ]
"""
id_doc = """# Control API

| Method | Path | Description |
|---|---|---|
| GET | `/v1/runs/{runId}` | Poll run status |

### GET /v1/runs/{runId}

Body.
"""
router_path, doc_path = write_fixture(id_router, id_doc)
code, out, err = run(router_path, doc_path)
check_equal("a `:id` route and its `{runId}` doc spelling pass as one request", 0, code)

# --- Against this checkout ----------------------------------------------------

code, out, err = run(module.ROUTER, module.DOC)
check_equal("the check passes against this repository's own files", 0, code)
check("and its summary line names what agreed", "are documented" in out)

for path in fixtures:
    shutil.rmtree(path, ignore_errors=True)

print("\n%s" % ("FAILED" if failed else "All checks passed."))
sys.exit(1 if failed else 0)
