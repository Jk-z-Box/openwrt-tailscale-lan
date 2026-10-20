#!/usr/bin/env python3
"""Run the real installer/control scripts against isolated OpenWrt test doubles."""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
MOCK = REPO / "tests/mock_command.py"


class Router:
    def __init__(self, pm="opkg"):
        self.temp = tempfile.TemporaryDirectory(prefix="tslan-test-")
        self.root = pathlib.Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.put("etc/openwrt_release", "DISTRIB_RELEASE='24.10.3'\n" if pm == "opkg" else "DISTRIB_RELEASE='25.12.0'\n")
        self.put("etc/config/network", json.dumps({"lan": {"_type": "interface", "proto": "static", "ipaddr": "192.168.1.1"}}))
        self.put("etc/config/firewall", json.dumps({"lan_zone": {"_type": "zone", "name": "home", "network": ["lan"]}, "wan_zone": {"_type": "zone", "name": "wan", "network": ["wan"]}}))
        self.put("etc/config/tailscale", "stock init config preserved\n")
        self.put("etc/opkg/distfeeds.conf", "src/gz packages https://example.invalid/release\n")
        self.put("etc/apk/repositories", "https://example.invalid/release\n")
        self.put("usr/share/libubox/jshn.sh", "# mocked runtime presence\n")
        (self.root / "proc/sys/net/ipv6").mkdir(parents=True)
        self.put("sysctl.json", json.dumps({
            "net.ipv4.ip_forward": "0",
            "net.ipv6.conf.all.disable_ipv6": "0",
            "net.ipv6.conf.all.disable_policy": "0",
            "net.ipv6.conf.all.forwarding": "0",
            "net.ipv6.conf.default.disable_ipv6": "1",
            "net.ipv6.conf.eth0.disable_ipv6": "1",
            "net.ipv6.conf.br-lan.disable_ipv6": "1",
        }))
        for command in ["uci", pm, "tailscale", "tailscaled", "jsonfilter", "sysctl", "fw4", "timeout", "ip", "sha256sum", "ubus", "ifup", "sleep", "curl"]:
            self.command(self.bin / command, command)
        for service in ["network", "firewall", "rpcd", "uhttpd", "tailscale"]:
            self.command(self.root / "etc/init.d" / service, "daemon-init" if service == "tailscale" else service)
        # The real integration init sources rc.common; emulate rc.common enable
        # semantics while the control executable itself runs unmodified.
        self.put("etc/rc.common", """#!/bin/sh
initscript=$1
shift
case "$1" in enable|disable) exit 0;; *) exit 0;; esac
""")
        self.env = dict(os.environ, TSLAN_ROOT=str(self.root), TSLAN_TEST_MODE="1", PATH=str(self.bin) + ":" + os.environ["PATH"])

    def command(self, path, name):
        path.parent.mkdir(parents=True, exist_ok=True)
        # sys.argv[0] is deliberately the command name for the test double.
        code = f"#!{sys.executable}\nimport sys\nsys.argv[0]={name!r}\nexec(compile(open({str(MOCK)!r}).read(), {str(MOCK)!r}, 'exec'))\n"
        path.write_text(code)
        path.chmod(0o755)

    def put(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def config(self, name):
        return json.loads((self.root / "etc/config" / name).read_text())

    def set_config(self, name, data):
        self.put("etc/config/" + name, json.dumps(data))

    def run(self, *args, extra=None):
        env = dict(self.env, **(extra or {}))
        # In test payloads replace only the init interpreter with our rc.common.
        result = subprocess.run(["/bin/sh", str(REPO / "install.sh"), *args], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return result

    def control(self, action, extra=None):
        return subprocess.run(["/bin/sh", str(self.root / "usr/libexec/tslan-control"), action],
                              env=dict(self.env, **(extra or {})), text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def running(self, peers=True):
        self.put("tailscale.json", json.dumps({
            "BackendState": "Running",
            "Peer": {"one": {"TailscaleIPs": ["100.90.1.2", "fd7a:115c:a1e0::5678"]}} if peers else {}
        }))

    def close(self):
        self.temp.cleanup()


class Integration(unittest.TestCase):
    def make(self, pm="opkg"):
        router = Router(pm)
        self.addCleanup(router.close)
        return router

    def success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_opkg_deployment_and_idempotency(self):
        r = self.make()
        self.success(r.run())
        fw = r.config("firewall")
        self.assertEqual(fw["tslan"]["masq"], "1")
        self.assertEqual(fw["tslan"]["input"], "REJECT")
        self.assertEqual(fw["tslan_lan"]["src"], "home")
        self.assertEqual(fw["tslan_lan"]["dest"], "tslan")
        self.assertEqual(len(fw), 7)
        self.assertEqual(fw["tslan"]["family"], "any")
        self.assertEqual(fw["tslan"]["masq6"], "0")
        self.assertEqual(fw["tslan_lan"]["family"], "ipv4")
        self.assertEqual(r.config("network")["lan"]["ipaddr"], "192.168.1.1")
        self.assertEqual(r.config("network")["tslan"]["device"], "tailscale0")
        self.assertEqual(json.loads((r.root / "prefs.json").read_text())["netfilter-mode"], "off")
        first = r.config("firewall")
        self.success(r.run())
        self.assertEqual(r.config("firewall"), first)
        self.assertTrue((r.root / "etc/tslan/report.txt").exists())
        self.assertEqual(r.config('tslan')['settings']['bypass_passwall2'], '0')
        self.assertTrue((r.root / 'etc/init.d/tslan-bypass').exists())

    def test_apk_deployment(self):
        r = self.make("apk")
        self.success(r.run())
        self.assertIn('"apk", "add"', (r.root / "commands.log").read_text())
        self.assertNotIn('"opkg"', (r.root / "commands.log").read_text())

    def test_missing_busybox_timeout_is_installed(self):
        r = self.make()
        (r.bin / "timeout").unlink()
        self.success(r.run())
        self.assertIn("coreutils-timeout", json.loads((r.root / "packages.json").read_text()))
        self.assertTrue((r.bin / "timeout").exists())

    def test_legacy_tailscale_preserves_unmanaged_preferences(self):
        r = self.make()
        r.put("prefs.json", json.dumps({"exit-node": "100.70.1.1", "ssh": "true"}))
        result = r.run(extra={"LEGACY_TAILSCALE": "1"})
        self.success(result)
        prefs = json.loads((r.root / "prefs.json").read_text())
        self.assertEqual(prefs["exit-node"], "100.70.1.1")
        self.assertEqual(prefs["ssh"], "true")
        self.assertEqual(prefs["netfilter-mode"], "off")
        self.assertNotIn("private-test-marker", result.stdout)
        self.assertNotIn("private-test-marker", (r.root / "etc/tslan/startup.log").read_text())

    def test_legacy_local_api_failure_is_reported(self):
        r = self.make()
        result = r.run(extra={"LEGACY_TAILSCALE": "1", "LOCALAPI_FAIL": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not set netfilter-mode=off", result.stdout)

    def test_preflight_does_not_install_or_change_config(self):
        r = self.make()
        before = r.config("network")
        self.success(r.run("--check"))
        self.assertEqual(r.config("network"), before)
        self.assertFalse((r.root / "packages.json").exists())
        self.assertFalse((r.root / "etc/tslan").exists())

    def test_feed_failure_and_partial_failure(self):
        for error in ["FEED_FAIL", "PARTIAL_FEED"]:
            with self.subTest(error=error):
                r = self.make()
                before = r.config("firewall")
                result = r.run(extra={error: "1"})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(r.config("firewall"), before)
                self.assertFalse((r.root / "packages.json").exists())

    def test_missing_package_fails_before_changes(self):
        r = self.make()
        result = r.run(extra={"MISSING_PACKAGE": "tailscale"})
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("tslan", r.config("network"))

    def test_existing_interface_conflict(self):
        r = self.make()
        config = r.config("network")
        config["vpn"] = {"_type": "interface", "device": "tailscale0"}
        r.set_config("network", config)
        result = r.run()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already uses tailscale0", result.stdout)
        self.assertEqual(r.config("network"), config)

    def test_pending_config_is_preserved(self):
        r = self.make()
        pending = r.config("firewall")
        pending["lan_zone"]["input"] = "DROP"
        r.put("etc/config/firewall.pending", json.dumps(pending))
        self.assertNotEqual(r.run().returncode, 0)
        self.assertEqual(json.loads((r.root / "etc/config/firewall.pending").read_text()), pending)

    def test_firewall_failure_rolls_back(self):
        r = self.make()
        network, firewall = r.config("network"), r.config("firewall")
        result = r.run(extra={"FW_FAIL": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(r.config("network"), network)
        self.assertEqual(r.config("firewall"), firewall)
        self.assertFalse((r.root / "usr/libexec/tslan-control").exists())
        self.assertFalse((r.root / "etc/config/tslan").exists())
        self.assertTrue((r.root / "packages.json").exists())

    def test_foreign_installer_lock_is_not_removed(self):
        r = self.make()
        lock = r.root / "tmp/tslan-install.lock"
        lock.mkdir(parents=True)
        result = r.run()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(lock.exists())

    def test_shell_injection_rejected_before_running(self):
        r = self.make()
        self.success(r.run())
        cfg = r.config("tslan")
        marker = r.root / "INJECTED"
        cfg["settings"]["hostname"] = "$(touch " + str(marker) + ")"
        r.set_config("tslan", cfg)
        result = r.control("apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())
        self.assertFalse((r.root / "var/run/tslan/lock").exists())

    def test_stop_start_and_login(self):
        r = self.make()
        self.success(r.run())
        self.success(r.control("login"))
        self.assertIn("AuthURL", json.loads((r.root / "tailscale.json").read_text()))
        self.success(r.control("stop"))
        self.assertEqual(r.config("tslan")["settings"]["enabled"], "0")
        self.success(r.control("start"))
        self.assertEqual(r.config("tslan")["settings"]["enabled"], "1")

    def test_start_failure_is_reported(self):
        r = self.make()
        result = r.run(extra={"PREF_FAIL": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("startup failed", result.stdout)
        self.assertTrue((r.root / "etc/tslan/report.txt").exists())

    def test_uninstall_preserves_unrelated_config_and_identity(self):
        r = self.make()
        original = r.config("firewall")
        self.success(r.run())
        r.put("etc/tailscale/tailscaled.state", "private-test-state")
        self.success(r.run("--uninstall"))
        self.assertEqual(r.config("firewall"), original)
        self.assertEqual((r.root / "etc/tailscale/tailscaled.state").read_text(), "private-test-state")
        self.assertFalse((r.root / "usr/libexec/tslan-control").exists())
        self.assertFalse((r.root / "sys/class/net/tailscale0").exists())

    def test_host_dualstack_preserves_physical_ipv6(self):
        r = self.make()
        r.running()
        before = json.loads((r.root / "sysctl.json").read_text())
        network = r.config("network")
        self.success(r.run())
        report = (r.root / "etc/tslan/report.txt").read_text()
        self.assertIn("OK: IPv4", report)
        self.assertIn("OK: IPv6", report)
        self.assertEqual(r.config("network")["lan"], network["lan"])
        after = json.loads((r.root / "sysctl.json").read_text())
        for key, value in before.items():
            if key.startswith("net.ipv6."):
                self.assertEqual(after[key], value, key)
        self.assertEqual(after["net.ipv6.conf.tailscale0.disable_ipv6"], "0")
        self.assertEqual(after["net.ipv6.conf.tailscale0.accept_ra"], "0")
        commands = [json.loads(line) for line in (r.root / "commands.log").read_text().splitlines()]
        writes = [c[-1] for c in commands if c[:2] == ["sysctl", "-w"] and "ipv6" in c[-1]]
        self.assertTrue(writes)
        self.assertTrue(all(w.startswith("net.ipv6.conf.tailscale0.") for w in writes))
        fw = r.config("firewall")
        for direction in ["in", "out"]:
            self.assertEqual(fw["tslan_no_forward6_" + direction]["family"], "ipv6")
            self.assertEqual(fw["tslan_no_forward6_" + direction]["target"], "REJECT")
        self.assertIn("packet-too-big", fw["tslan_icmp6"]["icmp_type"])

    def test_global_ipv6_disabled_fails_before_packages_or_config(self):
        r = self.make()
        before = r.config("network")
        knobs = json.loads((r.root / "sysctl.json").read_text())
        knobs["net.ipv6.conf.all.disable_ipv6"] = "1"
        r.put("sysctl.json", json.dumps(knobs))
        result = r.run()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("global enable would affect physical interfaces", result.stdout)
        self.assertEqual(r.config("network"), before)
        self.assertEqual(json.loads((r.root / "sysctl.json").read_text()), knobs)
        self.assertFalse((r.root / "packages.json").exists())

    def test_missing_kernel_ipv6_fails_before_install(self):
        r = self.make()
        shutil.rmtree(r.root / "proc/sys/net/ipv6")
        result = r.run("--check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("IPv6 kernel support is unavailable", result.stdout)
        self.assertFalse((r.root / "packages.json").exists())

    def test_global_firewall_ipv6_disabled_is_rejected(self):
        r = self.make()
        fw = r.config("firewall")
        fw["defaults"] = {"_type": "defaults", "disable_ipv6": "1"}
        r.set_config("firewall", fw)
        result = r.run()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dual-stack firewall rules cannot be enforced", result.stdout)
        self.assertEqual(r.config("firewall"), fw)

    def test_missing_kernel_address_or_wrong_route_is_not_success(self):
        for extra in [{"MISSING_V6_ADDRESS": "1"}, {"WRONG_ROUTE": "6"}, {"WRONG_ROUTE": "4"}]:
            with self.subTest(extra=extra):
                r = self.make()
                r.running()
                result = r.run(extra=extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Local IPv4/IPv6 validation failed", result.stdout)
                self.assertTrue((r.root / "etc/tslan/startup.log").exists())

    def test_no_peers_or_login_is_pending_not_verified(self):
        for running in [True, False]:
            with self.subTest(running=running):
                r = self.make()
                if running:
                    r.running(peers=False)
                self.success(r.run())
                report = (r.root / "etc/tslan/report.txt").read_text()
                self.assertIn("PENDING:", report)
                self.assertNotIn("OK: IPv", report)

    def test_boot_recreates_tun_and_restores_only_tun_ipv6(self):
        r = self.make()
        r.running()
        self.success(r.run())
        shutil.rmtree(r.root / "sys/class/net/tailscale0")
        self.success(r.control("boot"))
        self.assertIn("OK: IPv6", (r.root / "var/run/tslan/host-status").read_text())
        knobs = json.loads((r.root / "sysctl.json").read_text())
        self.assertEqual(knobs["net.ipv6.conf.default.disable_ipv6"], "1")
        self.assertEqual(knobs["net.ipv6.conf.eth0.disable_ipv6"], "1")
        self.success(r.control("apply"))
        self.assertIn("OK: IPv6", (r.root / "var/run/tslan/host-status").read_text())

    def test_upgrade_ipv4_zone_to_dualstack(self):
        r = self.make()
        r.running()
        self.success(r.run())
        fw = r.config("firewall")
        fw["tslan"]["family"] = "ipv4"
        fw["tslan_lan"].pop("family")
        for key in ["tslan_icmp6", "tslan_no_forward6_in", "tslan_no_forward6_out"]:
            fw.pop(key)
        r.set_config("firewall", fw)
        net = r.config("network")
        net.pop("tslan_device")
        r.set_config("network", net)
        self.success(r.run())
        self.assertEqual(r.config("firewall")["tslan_lan"]["family"], "ipv4")
        self.assertEqual(r.config("firewall")["tslan"]["family"], "any")
        self.assertIn("OK: IPv6", (r.root / "etc/tslan/report.txt").read_text())

    def test_foreign_tun_device_configuration_is_preserved(self):
        r = self.make()
        network = r.config("network")
        network["other"] = {"_type": "device", "name": "tailscale0", "ipv6": "0"}
        r.set_config("network", network)
        result = r.run()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already configures tailscale0", result.stdout)
        self.assertEqual(r.config("network"), network)


if __name__ == "__main__":
    unittest.main(verbosity=2)
