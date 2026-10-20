#!/usr/bin/env python3
"""Stateful OpenWrt command doubles. Never operate outside TSLAN_ROOT."""
import json
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(os.environ["TSLAN_ROOT"])
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
cfg = root / "etc/config"


def read(path, default):
    return json.loads(path.read_text()) if path.exists() else default


def write(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, sort_keys=True))


def emit(value):
    if isinstance(value, list):
        return " ".join(value)
    return str(value)


def config(package):
    return read(cfg / (package + ".pending"), read(cfg / package, {}))


with (root / "commands.log").open("a") as log:
    log.write(json.dumps([name, *args]) + "\n")

if name == "uci":
    args = [a for a in args if a != "-q"]
    cmd, rest = args[0], args[1:]
    key = rest[0] if rest else ""
    if cmd in ("set", "add_list"):
        key, value = key.split("=", 1)
    parts = key.split(".")
    package = parts[0]
    data = config(package)
    if cmd == "changes":
        if (cfg / (package + ".pending")).exists():
            print(package + ".pending=1")
    elif cmd == "get":
        try:
            obj = data[parts[1]]
            print(emit(obj["_type"] if len(parts) == 2 else obj[parts[2]]))
        except KeyError:
            sys.exit(1)
    elif cmd == "show":
        for sid, values in data.items():
            if len(parts) > 1 and parts[1] != sid:
                continue
            print(f"{package}.{sid}={values['_type']}")
            for option, value in values.items():
                if option != "_type":
                    print(f"{package}.{sid}.{option}='{emit(value)}'")
    elif cmd in ("set", "add_list"):
        if len(parts) == 2:
            data.setdefault(parts[1], {})["_type"] = value
        else:
            obj = data.setdefault(parts[1], {})
            if cmd == "add_list":
                obj.setdefault(parts[2], []).append(value)
            else:
                obj[parts[2]] = value
        write(cfg / (package + ".pending"), data)
    elif cmd == "delete":
        try:
            if len(parts) == 2:
                del data[parts[1]]
            else:
                del data[parts[1]][parts[2]]
        except KeyError:
            sys.exit(1)
        write(cfg / (package + ".pending"), data)
    elif cmd == "commit":
        write(cfg / package, data)
        (cfg / (package + ".pending")).unlink(missing_ok=True)
    elif cmd == "revert":
        (cfg / (package + ".pending")).unlink(missing_ok=True)
    else:
        raise ValueError(cmd)
elif name in ("opkg", "apk"):
    installed = read(root / "packages.json", [])
    available = ["tailscale", "tailscaled", "ip-full", "luci", "rpcd", "uhttpd", "uhttpd-mod-ubus", "jshn", "jsonfilter"]
    unavailable = os.environ.get("MISSING_PACKAGE")
    if unavailable in available:
        available.remove(unavailable)
    cmd = args[0]
    if cmd == "update":
        if os.environ.get("FEED_FAIL"):
            print("Failed to download: simulated feed failure")
            sys.exit(1)
        if os.environ.get("PARTIAL_FEED"):
            print("Failed to download: simulated partial feed failure")
        else:
            print("Indexes and signatures verified")
    elif name == "opkg" and cmd == "status":
        if args[1] not in installed:
            sys.exit(1)
        print("Status: install ok installed")
    elif name == "apk" and cmd == "info" and "-e" in args:
        sys.exit(0 if args[-1] in installed else 1)
    elif cmd in ("list-installed", "info"):
        for p in installed:
            print(p + (" - 1.0" if name == "opkg" else ""))
    elif cmd in ("list", "search"):
        if args[-1] in available:
            print(args[-1] + (" - 1.0 - mock" if name == "opkg" else "-1.0-r1"))
    elif cmd in ("install", "add"):
        if os.environ.get("INSTALL_FAIL"):
            print("Simulated package installation failure")
            sys.exit(1)
        installed = sorted(set(installed + args[1:]))
        write(root / "packages.json", installed)
    else:
        raise ValueError(args)
elif name == "tailscale":
    state = read(root / "tailscale.json", {"BackendState": "NeedsLogin"})
    if args == ["set", "--help"]:
        print("--netfilter-mode string")
    elif args[0] == "status":
        print(json.dumps(state) if "--json" in args else state["BackendState"])
    elif args[0] == "set":
        if os.environ.get("PREF_FAIL"):
            sys.exit(1)
        prefs = read(root / "prefs.json", {})
        for arg in args[1:]:
            k, v = arg[2:].split("=", 1)
            prefs[k] = v
        write(root / "prefs.json", prefs)
    elif args[0] == "up":
        if state["BackendState"] in ("NeedsLogin", "NoState"):
            state["AuthURL"] = "https://login.tailscale.com/a/test-only"
        else:
            state["BackendState"] = "Running"
            knobs = read(root / "sysctl.json", {})
            write(root / "addresses.json", {
                "4": True,
                "6": knobs.get("net.ipv6.conf.tailscale0.disable_ipv6") == "0",
            })
        write(root / "tailscale.json", state)
        sys.exit(1 if "AuthURL" in state else 0)
    elif args[0] in ("down", "logout"):
        state = {"BackendState": "Stopped" if args[0] == "down" else "NeedsLogin"}
        write(root / "tailscale.json", state)
    elif args[0] == "version":
        print("1.80.3")
    elif args[0] == "ip":
        if state["BackendState"] == "Running":
            print("100.80.1.2" if args[1] == "-4" else "fd7a:115c:a1e0::1234")
        else:
            sys.exit(1)
    else:
        raise ValueError(args)
elif name == "jsonfilter":
    value = json.loads(sys.stdin.read())
    expression = args[args.index("-e") + 1]
    if expression == "@.Peer.*.TailscaleIPs[*]":
        for peer in value.get("Peer", {}).values():
            for address in peer.get("TailscaleIPs", []):
                print(address)
        sys.exit(0)
    for part in expression.removeprefix("@.").split("."):
        value = value.get(part, "") if isinstance(value, dict) else ""
    if value != "":
        print(str(value).lower() if isinstance(value, bool) else value)
elif name == "sysctl":
    path = root / "sysctl.json"
    value = read(path, {"net.ipv4.ip_forward": "0"})
    if "-w" in args:
        k, v = args[-1].split("=", 1)
        value[k] = v
        write(path, value)
    elif "-n" in args:
        if args[-1] not in value:
            sys.exit(1)
        print(value[args[-1]])
    else:
        if args[-1] not in value:
            sys.exit(1)
        print(f"{args[-1]} = {value[args[-1]]}")
elif name == "fw4":
    if os.environ.get("FW_FAIL"):
        print("Simulated invalid firewall", file=sys.stderr)
        sys.exit(1)
elif name == "timeout":
    sys.exit(subprocess.call(args[1:]))
elif name in ("network", "firewall", "rpcd", "uhttpd", "tslan", "tailscaled"):
    pass
elif name == "daemon-init":
    if args[0] == "start":
        state = read(root / "tailscale.json", {"BackendState": "NeedsLogin"})
        # Model address assignment failure when IPv6 is disabled at daemon start.
        tun_present = (root / "sys/class/net/tailscale0/tun_flags").exists()
        knobs = read(root / "sysctl.json", {})
        v6_on = knobs.get("net.ipv6.conf.tailscale0.disable_ipv6") == "0"
        write(root / "addresses.json", {
            "4": tun_present and state["BackendState"] == "Running",
            "6": tun_present and v6_on and state["BackendState"] == "Running"
                 and not os.environ.get("MISSING_V6_ADDRESS"),
        })
    elif args[0] == "stop":
        write(root / "addresses.json", {})
elif name == "ifup":
    pass
elif name == "ubus":
    print(json.dumps({"up": not os.environ.get("IFUP_FAIL")}))
elif name == "sleep":
    pass  # Bounded retry tests do not need wall-clock delays.
elif name == "ip":
    device = root / "sys/class/net/tailscale0"
    if args[:3] == ["link", "show", "dev"]:
        sys.exit(0 if (device / "tun_flags").exists() else 1)
    elif args[:2] == ["tuntap", "add"]:
        device.mkdir(parents=True, exist_ok=True)
        (device / "tun_flags").write_text("0x1001\n")
        knobs = read(root / "sysctl.json", {})
        knobs["net.ipv6.conf.tailscale0.disable_ipv6"] = knobs.get(
            "net.ipv6.conf.default.disable_ipv6", "0")
        write(root / "sysctl.json", knobs)
    elif args[:2] == ["link", "set"]:
        if "alias" in args:
            (device / "ifalias").write_text(args[-1])
    elif args[:2] == ["link", "delete"]:
        import shutil
        shutil.rmtree(device)
    elif "addr" in args:
        family = args[0][1:]
        if read(root / "addresses.json", {}).get(family):
            proto, address = ("inet", "100.80.1.2/32") if family == "4" else ("inet6", "fd7a:115c:a1e0::1234/128")
            print(f"6: tailscale0    {proto} {address} scope global tailscale0")
    elif "route" in args and "get" in args:
        family = args[0][1:]
        target = args[-1]
        dev = "eth0" if os.environ.get("WRONG_ROUTE") == family else "tailscale0"
        print(f"{target} dev {dev} table 52")
    else:
        print("mock policy route output")
elif name == "sha256sum":
    import hashlib
    print(hashlib.sha256(pathlib.Path(args[0]).read_bytes()).hexdigest(), args[0])
else:
    raise ValueError(name)
