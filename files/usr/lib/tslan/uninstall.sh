#!/bin/sh
uninstall_integration() {
	[ -z "$(uci -q changes network)" ] && [ -z "$(uci -q changes firewall)" ] ||
		die "Save/revert pending network/firewall changes first"
	snapshot
	tailscale down 2>/dev/null || true
	if [ -f "$TSLAN_ROOT/etc/init.d/tslan-bypass" ]; then
		sh "$TSLAN_ROOT/etc/rc.common" "$TSLAN_ROOT/etc/init.d/tslan-bypass" stop
		sh "$TSLAN_ROOT/etc/rc.common" "$TSLAN_ROOT/etc/init.d/tslan-bypass" disable
		"$TSLAN_ROOT/usr/libexec/tslan-passwall2" remove
	fi
	sh "$TSLAN_ROOT/etc/rc.common" "$TSLAN_ROOT/etc/init.d/tslan" disable || true
	"$TSLAN_ROOT/etc/init.d/tailscale" disable || true
	"$TSLAN_ROOT/etc/init.d/tailscale" stop || true
	for key in $(managed_sections); do
		if [ "$(get "$key.tslan_managed")" = 1 ]; then uci delete "$key"; fi
	done
	uci commit network
	uci commit firewall
	rm -f "$TSLAN_ROOT/etc/sysctl.d/99-tslan.conf"
	"$TSLAN_ROOT/etc/init.d/network" reload
	"$TSLAN_ROOT/etc/init.d/firewall" reload
	remove_owned_tun
	while IFS= read -r path; do rm -f "$TSLAN_ROOT/$path"; done < "$TSLAN_DATA/manifest"
	rm -f "$TSLAN_ROOT/etc/config/tslan" "$TSLAN_DATA/password" "$TSLAN_DATA/forward.nft"
	rm -f "$TSLAN_ROOT/usr/share/luci/menu.d/luci-app-tslan.json"
	"$TSLAN_ROOT/etc/init.d/rpcd" restart
	rm -f "$TSLAN_ROOT/tmp/luci-indexcache"
	rm -rf "$TSLAN_ROOT/tmp/luci-modulecache"
	say "Removed LuCI integration, managed interface, zone, forwarding and startup service."
	say "Retained installed packages, /etc/tailscale identity and root-only backups in /etc/tslan."
	say "Tailscale is stopped. Before using it standalone run: /etc/init.d/tailscale start; tailscale set --netfilter-mode=on; tailscale up"
}
