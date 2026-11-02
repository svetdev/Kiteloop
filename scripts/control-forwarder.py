#!/usr/bin/env python3
"""Forward the Kiteloop control API to addresses a phone can reach.

The control server deliberately binds 127.0.0.1 only. This forwarder listens on
the Mac's tailnet address (CGNAT 100.64/10, WireGuard-encrypted transport) and
its LAN address (same Wi-Fi, plain TCP — the bearer token still gates every
request, but the bytes are not encrypted on the wire), and pipes each
connection to the loopback server. Addresses are re-resolved every 30s, so the
LaunchAgent that keeps this alive survives DHCP handing the Mac a new lease:
it exits when a bound address disappears or a new one appears, and launchd
starts it again against whatever is current.

--tailnet-only leaves the LAN address alone: the setting for a work laptop on
shared office Wi-Fi, where plain TCP would put the token on the network.

Run directly for a one-off:  python3 scripts/control-forwarder.py
Kept alive across reboots:   ~/Library/LaunchAgents/ai.kasatkin.kiteloop-forwarder.plist
"""

import argparse
import asyncio
import json
import os
import socket
import sys

DEFAULT_PORT = 4517
VALID_PORT_RANGE = range(1024, 65536)


def config_port(home=None):
    """The port `GlobalConfigStore` last wrote to ~/.kiteloop/global-config.json,
    or None if the file is missing, will not parse, holds no port, or holds one
    `KiteloopControlServer.isValidPort` would reject — any of which falls back
    to DEFAULT_PORT, same as the app's own `KiteloopControlServer.resolvedPort`."""
    home = home or os.path.expanduser("~")
    path = os.path.join(home, ".kiteloop", "global-config.json")
    try:
        with open(path, "r", encoding="utf-8") as f:
            config = json.load(f)
    except (OSError, ValueError):
        return None
    port = config.get("controlServerPort")
    if not isinstance(port, int) or isinstance(port, bool) or port not in VALID_PORT_RANGE:
        return None
    return port


def resolve_port(cli_port=None, home=None):
    """`--port` wins outright; otherwise the configured port, falling back to
    DEFAULT_PORT."""
    if cli_port is not None:
        return cli_port
    return config_port(home) or DEFAULT_PORT


PORT = None
TARGET = None
TAILNET_ONLY = False


def _octets(ip):
    """ip parsed into four 0-255 ints, or None if it isn't a dotted quad."""
    parts = ip.split(".")
    if len(parts) != 4:
        return None
    try:
        values = [int(part) for part in parts]
    except ValueError:
        return None
    return values if all(0 <= value <= 255 for value in values) else None


def _is_tailnet(octets):
    a, b, _c, _d = octets
    return a == 100 and 64 <= b <= 127


def _is_lan(octets):
    a, b, _c, _d = octets
    if a == 10:
        return True
    if a == 172:
        return 16 <= b <= 31
    return a == 192 and b == 168


def classify_address(ip):
    """"tailnet" for Tailscale's CGNAT range (100.64.0.0/10), "lan" for a
    private range a phone can reach over Wi-Fi (10/8, 172.16/12, 192.168/16),
    None otherwise. Octet classification, mirroring the private helpers of
    the Mac side's `PairingAddresses`, so a 172.16-172.31 lease (ordinary on
    guest and corporate Wi-Fi) isn't dropped, and a public 100.200.x.x
    address isn't mistaken for Tailscale's range."""
    octets = _octets(ip)
    if octets is None:
        return None
    if _is_tailnet(octets):
        return "tailnet"
    if _is_lan(octets):
        return "lan"
    return None


def hostname_addresses():
    """Tailnet/LAN addresses socket.getaddrinfo(hostname) turns up, de-duplicated.
    A lookup failure (Wi-Fi flapping, a VPN coming up, mDNS not answering) is
    named on stderr and read as no addresses found, rather than raised — the
    routing-table probe needs no name resolution and may still find the bind."""
    found = []
    try:
        rows = socket.getaddrinfo(socket.gethostname(), None)
    except OSError as error:
        print(f"hostname lookup failed: {error}", file=sys.stderr)
        return found
    for family, _, _, _, sockaddr in rows:
        if family != socket.AF_INET:
            continue
        ip = sockaddr[0]
        if classify_address(ip) and ip not in found:
            found.append(ip)
    return found


def routing_table_addresses():
    """The source address the routing table picks for the tailnet, then the
    open internet — getaddrinfo on the hostname can miss interfaces."""
    found = []
    # A documentation-range address (RFC 5737): the routing table is consulted
    # and no packet leaves.
    for probe in ("100.100.100.100", "192.0.2.1"):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect((probe, 53))
            ip = s.getsockname()[0]
            s.close()
        except OSError:
            continue
        if classify_address(ip):
            found.append(ip)
    return found


def in_scope(found, tailnet_only):
    """found, less every address that is not on the tailnet when tailnet_only."""
    if not tailnet_only:
        return found
    return [ip for ip in found if classify_address(ip) == "tailnet"]


def addresses():
    """The tailnet address if there is one, and the primary LAN address —
    only the tailnet one under --tailnet-only, so a LAN lease coming or going
    is no reason to rebind either."""
    found = hostname_addresses()
    for ip in routing_table_addresses():
        if ip not in found:
            found.append(ip)
    return in_scope(found, TAILNET_ONLY)


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, asyncio.CancelledError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def handle(client_reader, client_writer):
    try:
        upstream_reader, upstream_writer = await asyncio.open_connection(*TARGET)
    except OSError:
        client_writer.close()
        return
    await asyncio.gather(pipe(client_reader, upstream_writer),
                         pipe(upstream_reader, client_writer))


async def bind_servers(binds):
    """A server per address in binds that will accept a connection; the rest
    are logged and skipped rather than failing the whole forwarder."""
    servers = []
    for ip in binds:
        try:
            servers.append(await asyncio.start_server(handle, ip, PORT))
            print(f"forwarding {ip}:{PORT} -> {TARGET[0]}:{TARGET[1]}", flush=True)
        except OSError as error:
            print(f"cannot bind {ip}:{PORT}: {error}", file=sys.stderr)
    return servers


def rebind_reason(binds, current):
    """The sentence to print once a rebind is warranted, or None when binds
    and current still agree: a bound address missing from current, or an
    address in current that binds does not hold. binds is the full list the
    process was launched with (not bind_servers' subset of what actually
    bound), so an address that refused to bind is not read as newly
    appeared on every pass."""
    for ip in binds:
        if ip not in current:
            return f"{ip} disappeared; exiting for launchd to rebind"
    for ip in current:
        if ip not in binds:
            return f"{ip} appeared; exiting for launchd to rebind"
    return None


async def watch_addresses(binds, servers):
    """Exit (for launchd to restart us) once the bound addresses and the
    current ones disagree, in either direction."""
    while True:
        await asyncio.sleep(30)
        reason = rebind_reason(binds, addresses())
        if reason:
            print(reason, flush=True)
            for server in servers:
                server.close()
            return


def parse_args(argv):
    """--port N as a one-off override and --tailnet-only; exits non-zero naming
    the value when the port is not usable, rather than silently falling back to
    the default."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=None)
    parser.add_argument("--tailnet-only", action="store_true")
    args = parser.parse_args(argv)
    if args.port is not None and args.port not in VALID_PORT_RANGE:
        print(f"--port {args.port} is not a usable port (must be {VALID_PORT_RANGE.start}-{VALID_PORT_RANGE.stop - 1})",
              file=sys.stderr)
        sys.exit(1)
    return args


def parse_port_arg(argv):
    """The --port override alone, or None."""
    return parse_args(argv).port


async def main():
    global PORT, TARGET, TAILNET_ONLY
    args = parse_args(sys.argv[1:])
    PORT = resolve_port(args.port)
    TARGET = ("127.0.0.1", PORT)
    TAILNET_ONLY = args.tailnet_only
    binds = addresses()
    if not binds:
        print("no tailnet address to bind" if TAILNET_ONLY else "no tailnet or LAN address to bind",
              file=sys.stderr)
        sys.exit(1)
    servers = await bind_servers(binds)
    if not servers:
        sys.exit(1)
    await watch_addresses(binds, servers)


if __name__ == "__main__":
    asyncio.run(main())
