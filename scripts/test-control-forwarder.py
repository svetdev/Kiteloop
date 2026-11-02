#!/usr/bin/env python3
"""test-control-forwarder — assert the address readers in control-forwarder.py.

hostname_addresses() and routing_table_addresses() are driven over synthetic
socket.getaddrinfo results and a fake UDP socket standing in for the routing
probe — never a real socket.getaddrinfo call and never a real socket, so this
opens no socket and starts no server, safe to run while Kiteloop is up. Then
addresses(), which composes the two, is driven over the same fakes to assert
the order (the tailnet address first) and the de-duplication that survives
the split of what was one addresses() function into three. config_port(),
resolve_port() and parse_port_arg() are driven over a temporary HOME standing
in for ~/.kiteloop, covering a config file that is present, absent, unreadable
or holds an out-of-range port, and the --port override — none of it opens a
socket either.

  ./scripts/test-control-forwarder.py
"""

import asyncio
import importlib.util
import io
import json
import os
import socket
import sys
import tempfile
from contextlib import redirect_stderr, redirect_stdout

sys.dont_write_bytecode = True  # leave no __pycache__ beside the script

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "control-forwarder.py")

failed = 0


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
    """The script as a module — its filename has a dash, so it cannot be imported."""
    spec = importlib.util.spec_from_file_location("control_forwarder", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


module = load_script()


def addrinfo(family, ip):
    """One socket.getaddrinfo() row, shaped like the real thing enough for
    hostname_addresses() to read: (family, type, proto, canonname, sockaddr)."""
    sockaddr = (ip, 0) if family == socket.AF_INET else (ip, 0, 0, 0)
    return (family, socket.SOCK_STREAM, 6, "", sockaddr)


class FakeGetaddrinfo:
    """Stands in for socket.getaddrinfo(hostname, None) for the life of a `with`."""

    def __init__(self, rows):
        self.rows = rows
        self.original = None

    def __enter__(self):
        self.original = socket.getaddrinfo
        socket.getaddrinfo = lambda *a, **k: self.rows
        return self

    def __exit__(self, *exc):
        socket.getaddrinfo = self.original


class FakeGetaddrinfoError:
    """Stands in for socket.getaddrinfo(hostname, None) raising, for the life
    of a `with` — a transient name-resolution failure (Wi-Fi flapping, a VPN
    coming up, mDNS not answering)."""

    def __init__(self, error):
        self.error = error
        self.original = None

    def __enter__(self):
        self.original = socket.getaddrinfo

        def raiser(*a, **k):
            raise self.error

        socket.getaddrinfo = raiser
        return self

    def __exit__(self, *exc):
        socket.getaddrinfo = self.original


class FakeProbeSocket:
    """A UDP socket that never touches the network: connect() looks up the
    probe address in a table and getsockname() returns what that table says,
    or raises OSError for a probe with no route — same as the real socket
    would for an address nothing can reach."""

    def __init__(self, routes):
        self.routes = routes
        self.probe = None

    def connect(self, addr):
        host, _port = addr
        if host not in self.routes:
            raise OSError("no route to %s" % host)
        self.probe = host

    def getsockname(self):
        return (self.routes[self.probe], 0)

    def close(self):
        pass


class FakeSocketModule:
    """Stands in for socket.socket(...) for the life of a `with`, so
    routing_table_addresses() never opens a real socket."""

    def __init__(self, routes):
        self.routes = routes
        self.original = None

    def __enter__(self):
        self.original = socket.socket
        socket.socket = lambda *a, **k: FakeProbeSocket(self.routes)
        return self

    def __exit__(self, *exc):
        socket.socket = self.original


print("test-control-forwarder")

# --- classify_address --------------------------------------------------------

for ip in ("172.16.0.4", "172.31.9.9"):
    check_equal("%s is in the 172.16/12 LAN range" % ip, "lan", module.classify_address(ip))

for ip in ("172.15.0.4", "172.32.0.4"):
    check_equal("%s is outside the 172.16/12 LAN range" % ip, None, module.classify_address(ip))

check_equal("100.64.1.2 is tailnet", "tailnet", module.classify_address("100.64.1.2"))
check_equal("100.127.255.255 is tailnet", "tailnet", module.classify_address("100.127.255.255"))
check_equal("100.200.1.2 is outside the CGNAT range, not tailnet or LAN", None, module.classify_address("100.200.1.2"))
check_equal("100.63.0.1 is just below the CGNAT range", None, module.classify_address("100.63.0.1"))
check_equal("100.128.0.1 is just above the CGNAT range", None, module.classify_address("100.128.0.1"))
check_equal("10.0.0.9 is LAN", "lan", module.classify_address("10.0.0.9"))
check_equal("192.168.1.5 is LAN", "lan", module.classify_address("192.168.1.5"))
check_equal("192.169.1.5 is not the 192.168/16 LAN range", None, module.classify_address("192.169.1.5"))
check_equal("8.8.8.8 is a public address, neither tailnet nor LAN", None, module.classify_address("8.8.8.8"))
check_equal("a malformed address classifies as neither", None, module.classify_address("not.an.ip.address"))

# --- hostname_addresses ----------------------------------------------------

with FakeGetaddrinfo([
    addrinfo(socket.AF_INET, "100.64.1.2"),
    addrinfo(socket.AF_INET, "100.64.1.2"),  # duplicate, dropped
    addrinfo(socket.AF_INET, "192.168.1.5"),
    addrinfo(socket.AF_INET, "8.8.8.8"),  # not a tailnet or LAN range, dropped
    addrinfo(socket.AF_INET6, "fe80::1"),  # not AF_INET, dropped
]):
    check_equal(
        "the tailnet address leads, the LAN address follows, duplicates and "
        "non-private/non-AF_INET rows are dropped",
        ["100.64.1.2", "192.168.1.5"],
        module.hostname_addresses(),
    )

with FakeGetaddrinfo([addrinfo(socket.AF_INET, "10.0.0.9")]):
    check_equal("a 10.x row counts as a private address too", ["10.0.0.9"], module.hostname_addresses())

with FakeGetaddrinfo([addrinfo(socket.AF_INET, "172.16.0.4")]):
    check_equal("a 172.16/12 row counts as a private address too", ["172.16.0.4"], module.hostname_addresses())

with FakeGetaddrinfo([addrinfo(socket.AF_INET, "8.8.8.8")]):
    check_equal("no private row at all reads as no address", [], module.hostname_addresses())

with FakeGetaddrinfo([addrinfo(socket.AF_INET, "100.200.1.2")]):
    check_equal("a public 100.200.x.x row is not mistaken for the tailnet range", [], module.hostname_addresses())

with FakeGetaddrinfoError(OSError("Name or service not known")):
    out = io.StringIO()
    with redirect_stderr(out):
        result = module.hostname_addresses()
    check_equal("a raising getaddrinfo reads as no addresses found, not an exception", [], result)
    check("the lookup failure is named on stderr", "hostname lookup failed" in out.getvalue())

# --- routing_table_addresses -------------------------------------------------

with FakeSocketModule({"100.100.100.100": "100.64.1.2", "192.0.2.1": "192.168.1.5"}):
    check_equal(
        "both probes answer: tailnet source address first, then the LAN one",
        ["100.64.1.2", "192.168.1.5"],
        module.routing_table_addresses(),
    )

with FakeSocketModule({"192.0.2.1": "192.168.1.5"}):
    check_equal(
        "the tailnet probe has no route: only the LAN probe's address comes back",
        ["192.168.1.5"],
        module.routing_table_addresses(),
    )

with FakeSocketModule({"100.100.100.100": "203.0.113.9", "192.0.2.1": "203.0.113.9"}):
    check_equal(
        "a public source address is dropped rather than bound, not just loopback",
        [],
        module.routing_table_addresses(),
    )

with FakeSocketModule({"100.100.100.100": "127.0.0.1", "192.0.2.1": "127.0.0.1"}):
    check_equal("loopback is filtered out of both probes", [], module.routing_table_addresses())

with FakeSocketModule({"100.100.100.100": "100.200.1.2", "192.0.2.1": "192.168.1.5"}):
    check_equal(
        "the tailnet probe's public 100.200.x.x source address is dropped, not treated as tailnet",
        ["192.168.1.5"],
        module.routing_table_addresses(),
    )

with FakeSocketModule({"100.100.100.100": "172.16.0.4"}):
    check_equal(
        "a 172.16/12 source address from the tailnet probe is classified as LAN, not dropped",
        ["172.16.0.4"],
        module.routing_table_addresses(),
    )

# --- addresses, composing both readers --------------------------------------

with FakeGetaddrinfo([addrinfo(socket.AF_INET, "100.64.1.2")]), \
        FakeSocketModule({"100.100.100.100": "100.64.1.2", "192.0.2.1": "192.168.1.5"}):
    check_equal(
        "the probe's tailnet address, already found by hostname, is not repeated; "
        "its LAN address is appended",
        ["100.64.1.2", "192.168.1.5"],
        module.addresses(),
    )

with FakeGetaddrinfo([]), FakeSocketModule({"100.100.100.100": "100.64.1.2"}):
    check_equal(
        "a tailnet address getaddrinfo misses is still found through the routing probe",
        ["100.64.1.2"],
        module.addresses(),
    )

with FakeGetaddrinfo([]), FakeSocketModule({}):
    check_equal("neither reader finds anything: no address to bind", [], module.addresses())

with FakeGetaddrinfoError(OSError("Name or service not known")), \
        FakeSocketModule({"100.100.100.100": "100.64.1.2", "192.0.2.1": "192.168.1.5"}):
    out = io.StringIO()
    with redirect_stderr(out):
        result = module.addresses()
    check_equal(
        "a raising hostname lookup does not stop addresses() from returning what the routing probe found",
        ["100.64.1.2", "192.168.1.5"],
        result,
    )

# --- --tailnet-only ----------------------------------------------------------

check_equal("in_scope keeps every address when not tailnet-only",
            ["100.64.1.2", "192.168.1.5"], module.in_scope(["100.64.1.2", "192.168.1.5"], False))
check_equal("in_scope drops the LAN address when tailnet-only",
            ["100.64.1.2"], module.in_scope(["100.64.1.2", "192.168.1.5"], True))
check_equal("in_scope with only a LAN address and tailnet-only leaves nothing to bind",
            [], module.in_scope(["192.168.1.5"], True))

module.TAILNET_ONLY = True
try:
    with FakeGetaddrinfo([addrinfo(socket.AF_INET, "100.64.1.2")]), \
            FakeSocketModule({"100.100.100.100": "100.64.1.2", "192.0.2.1": "192.168.1.5"}):
        current = module.addresses()
    check_equal("a tailnet-only forwarder sees only the tailnet address beside a LAN one",
                ["100.64.1.2"], current)
    check_equal("a LAN address appearing is no reason for a tailnet-only forwarder to rebind",
                None, module.rebind_reason(["100.64.1.2"], current))
finally:
    module.TAILNET_ONLY = False

check_equal("--tailnet-only is off unless given", False, module.parse_args([]).tailnet_only)
check_equal("--tailnet-only parses", True, module.parse_args(["--tailnet-only"]).tailnet_only)

# --- rebind_reason -----------------------------------------------------------

check_equal("binds and current agree: no reason to rebind",
            None, module.rebind_reason(["100.64.1.2", "192.168.1.5"], ["100.64.1.2", "192.168.1.5"]))

check_equal("a bound address gone from current names it in the reason",
            "192.168.1.5 disappeared; exiting for launchd to rebind",
            module.rebind_reason(["100.64.1.2", "192.168.1.5"], ["100.64.1.2"]))

check_equal("an address current holds that binds does not names it in the reason",
            "192.168.1.5 appeared; exiting for launchd to rebind",
            module.rebind_reason(["100.64.1.2"], ["100.64.1.2", "192.168.1.5"]))

check_equal("an address bind_servers could not bind stays in binds, so it is not read as newly appeared",
            None, module.rebind_reason(["100.64.1.2", "192.168.1.5"], ["100.64.1.2"] + ["192.168.1.5"]))

check_equal("no addresses either side: no reason to rebind", None, module.rebind_reason([], []))

# --- watch_addresses -----------------------------------------------------

class FakeServer:
    def __init__(self):
        self.closed = False

    def close(self):
        self.closed = True


class FakeSleep:
    """Stands in for asyncio.sleep for the life of a `with`, so the test
    takes no wall clock time."""

    def __init__(self):
        self.calls = []
        self.original = None

    def __enter__(self):
        self.original = asyncio.sleep

        async def fake_sleep(seconds):
            self.calls.append(seconds)

        asyncio.sleep = fake_sleep
        return self

    def __exit__(self, *exc):
        asyncio.sleep = self.original


class FakeAddresses:
    """Stands in for module.addresses for the life of a `with`."""

    def __init__(self, result):
        self.result = result
        self.original = None

    def __enter__(self):
        self.original = module.addresses
        module.addresses = lambda: self.result
        return self

    def __exit__(self, *exc):
        module.addresses = self.original


binds = ["100.64.1.2"]
servers = [FakeServer(), FakeServer()]
with FakeSleep() as sleep, FakeAddresses(["100.64.1.2", "192.168.1.5"]):
    out = io.StringIO()
    with redirect_stdout(out):
        asyncio.run(module.watch_addresses(binds, servers))
    check("a new address closes every server and returns", all(s.closed for s in servers))
    check_equal("watch_addresses stubs the 30s sleep rather than waiting for it", [30], sleep.calls)
    check("watch_addresses prints the appearance reason",
          "192.168.1.5 appeared; exiting for launchd to rebind" in out.getvalue())

# --- config_port / resolve_port / parse_port_arg ----------------------------
# A temporary HOME stands in for ~/.kiteloop/global-config.json; none of this
# opens a socket.


def write_config(home, text):
    directory = os.path.join(home, ".kiteloop")
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, "global-config.json"), "w", encoding="utf-8") as f:
        f.write(text)


with tempfile.TemporaryDirectory() as home:
    write_config(home, json.dumps({"controlServerPort": 5150}))
    check_equal("a valid configured port is read back", 5150, module.config_port(home))

with tempfile.TemporaryDirectory() as home:
    check_equal("no config file at all reads as no configured port", None, module.config_port(home))

with tempfile.TemporaryDirectory() as home:
    write_config(home, "{not json")
    check_equal("a config file that will not parse reads as no configured port", None, module.config_port(home))

if hasattr(os, "geteuid") and os.geteuid() != 0:
    with tempfile.TemporaryDirectory() as home:
        write_config(home, json.dumps({"controlServerPort": 5150}))
        path = os.path.join(home, ".kiteloop", "global-config.json")
        os.chmod(path, 0o000)
        try:
            check_equal("a config file this process cannot read reads as no configured port",
                        None, module.config_port(home))
        finally:
            os.chmod(path, 0o600)

for bad_port, label in [
    (80, "below the valid range"),
    (70000, "above the valid range"),
    (None, "missing from the config"),
    ("5150", "not an int"),
    (True, "a bool, not a real port"),
]:
    with tempfile.TemporaryDirectory() as home:
        body = {} if bad_port is None else {"controlServerPort": bad_port}
        write_config(home, json.dumps(body))
        check_equal("a configured port %s falls through to no configured port" % label,
                    None, module.config_port(home))

with tempfile.TemporaryDirectory() as home:
    write_config(home, json.dumps({"controlServerPort": 5150}))
    check_equal("resolve_port prefers the configured port over the default",
                5150, module.resolve_port(cli_port=None, home=home))
    check_equal("resolve_port lets an explicit --port win over the config file",
                9001, module.resolve_port(cli_port=9001, home=home))

with tempfile.TemporaryDirectory() as home:
    check_equal("resolve_port falls back to DEFAULT_PORT with nothing configured and no --port",
                module.DEFAULT_PORT, module.resolve_port(cli_port=None, home=home))

check_equal("no --port on the command line parses as no override", None, module.parse_port_arg([]))
check_equal("a usable --port parses through", 9001, module.parse_port_arg(["--port", "9001"]))

for bad in ("80", "70000"):
    try:
        module.parse_port_arg(["--port", bad])
        check("--port %s exits non-zero" % bad, False, "did not raise SystemExit")
    except SystemExit as exc:
        check_equal("--port %s exits non-zero" % bad, True, exc.code != 0)

print("\n%s" % ("FAILED" if failed else "All checks passed."))
sys.exit(1 if failed else 0)
