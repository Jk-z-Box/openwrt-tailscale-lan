#!/bin/sh
# Generated install.sh embeds the files/ payload. Rebuild with scripts/build.py.
set -eu
umask 077
export LC_ALL=C
TSLAN_ROOT=${TSLAN_ROOT:-}
MODE=install
LAN_ARG=
STAGE=
BACKUP=
TRANSACTION=0

say() { printf '%s\n' "$*"; }
die() { say "ERROR: $*" >&2; exit 1; }
usage() {
	cat <<'HELP'
OpenWrt Tailscale LAN installer
  sh install.sh                        Install/update; default LAN is lan
  sh install.sh --lan-network NAME     Select an existing LAN logical interface
  sh install.sh --check                Check system, feeds and available packages
  sh install.sh --uninstall            Remove integration; retain Tailscale identity and packages
  sh install.sh --help
Requires root and OpenWrt 23.05+ with working release-matched package feeds.
HELP
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--lan-network) [ "$#" -ge 2 ] || die "--lan-network needs a value"; LAN_ARG=$2; shift 2;;
			--check) MODE=check; shift;;
			--uninstall) MODE=uninstall; shift;;
			--help|-h) usage; exit 0;;
			*) die "Unknown option: $1";;
		esac
	done
	case "$LAN_ARG" in *[!a-zA-Z0-9_]*) die "Invalid LAN interface name";; esac
}

cleanup() {
	result=$?
	trap - EXIT
	if [ "$result" -ne 0 ] && [ "$TRANSACTION" = 1 ]; then
		say "Installation failed; restoring the pre-install network/firewall and integration files." >&2
		restore_network
		uci -q revert tslan 2>/dev/null || true
		if [ -f "$BACKUP/tslan" ]; then
			cp -p "$BACKUP/tslan" "$TSLAN_ROOT/etc/config/tslan"
		else
			rm -f "$TSLAN_ROOT/etc/config/tslan"
		fi
		# Restore exactly the integration paths, including upgrades of this project.
		while IFS= read -r path; do
			if [ -e "$BACKUP/payload/$path" ]; then
				cp -p "$BACKUP/payload/$path" "$TSLAN_ROOT/$path"
			else
				rm -f "$TSLAN_ROOT/$path"
			fi
		done < "$STAGE/manifest"
		if [ -f "$BACKUP/sysctl.conf" ]; then
			cp -p "$BACKUP/sysctl.conf" "$TSLAN_ROOT/etc/sysctl.d/99-tslan.conf"
		else
			rm -f "$TSLAN_ROOT/etc/sysctl.d/99-tslan.conf"
		fi
		sysctl -w "net.ipv4.ip_forward=$(cat "$BACKUP/ip_forward")" >/dev/null 2>&1 || true
		say "Packages already installed remain available. Backup: $BACKUP" >&2
	fi
	[ -z "$STAGE" ] || rm -rf "$STAGE"
	[ -z "${INSTALL_LOCK:-}" ] || rmdir "$INSTALL_LOCK" 2>/dev/null || true
	exit "$result"
}

preflight() {
	[ "$(id -u)" = 0 ] || [ "${TSLAN_TEST_MODE:-}" = 1 ] || die "Run as root on OpenWrt"
	[ -f "$TSLAN_ROOT/etc/openwrt_release" ] || die "This script must run on OpenWrt"
	release=$(sed -n "s/^DISTRIB_RELEASE=['\"]\\([^'\"]*\\)['\"].*/\\1/p" "$TSLAN_ROOT/etc/openwrt_release")
	case "$release" in
		SNAPSHOT) :;;
		[0-9][0-9].*) major=${release%%.*}; [ "$major" -ge 23 ] || die "OpenWrt 23.05 or later is required";;
		*) die "Unrecognized OpenWrt release: $release";;
	esac
	for cmd in uci ip sysctl tar gzip base64 sha256sum mktemp timeout ubus ifup; do
		command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
	done
	[ -f "$TSLAN_ROOT/etc/config/network" ] && [ -f "$TSLAN_ROOT/etc/config/firewall" ] ||
		die "OpenWrt network/firewall configuration is missing"
	say "Detected OpenWrt $release ($(uname -m))"
	mkdir -p "$TSLAN_ROOT/tmp"
	STAGE=$(mktemp -d "$TSLAN_ROOT/tmp/tslan-install.XXXXXXXX")
	lock_path="$TSLAN_ROOT/tmp/tslan-install.lock"
	mkdir "$lock_path" 2>/dev/null || die "Another installer is running"
	INSTALL_LOCK=$lock_path
}

detect_pm() {
	if command -v apk >/dev/null 2>&1; then
		PM=apk
		feeds="$TSLAN_ROOT/etc/apk/repositories"
		[ -s "$feeds" ] || [ -d "$TSLAN_ROOT/etc/apk/repositories.d" ] || die "APK repositories are missing"
	elif command -v opkg >/dev/null 2>&1; then
		PM=opkg
		grep -qs '^[[:space:]]*src' "$TSLAN_ROOT/etc/opkg/"*.conf || die "OPKG feeds are missing"
	else
		die "Neither apk nor opkg was found"
	fi
	say "Checking configured $PM feeds (no feed replacement or signature bypass)."
	if ! "$PM" update >"$STAGE/feed.log" 2>&1; then
		cat "$STAGE/feed.log"
		die "Feed refresh failed. Check router time, DNS, connectivity and feeds matching this firmware."
	fi
	# Some opkg builds may report a partial refresh with a success exit status.
	if grep -Eqi 'Failed to download|Signature check failed|BAD signature|SSL certificate problem|temporary error|ERROR:' "$STAGE/feed.log"; then
		cat "$STAGE/feed.log"
		die "One or more feeds failed; fix them before installation"
	fi
}

installed() {
	if [ "$PM" = apk ]; then apk info -e "$1" >/dev/null 2>&1
	else opkg status "$1" 2>/dev/null | grep -q '^Status:.* installed$'; fi
}

available() {
	if [ "$PM" = apk ]; then
		apk search -x "$1" 2>/dev/null | grep -q "^$1-"
	else
		opkg list "$1" 2>/dev/null | awk -v p="$1" '$1 == p { found=1 } END { exit !found }'
	fi
}

check_packages() {
	NEEDED=
	# Modern tailscale packages include/provide tailscaled. Check the actual
	# executable after installation and add the older split package if needed.
	for package in tailscale ip-full luci rpcd uhttpd uhttpd-mod-ubus jshn jsonfilter; do
		if ! installed "$package"; then
			available "$package" || die "Package '$package' is unavailable for this firmware/architecture"
			NEEDED="$NEEDED $package"
		fi
	done
	say "Packages to install:${NEEDED:- (none)}"
	if [ "$MODE" != check ] && [ -n "$NEEDED" ]; then
		target="$TSLAN_ROOT/overlay"
		[ -d "$target" ] || target="$TSLAN_ROOT/"
		free_kb=$(df -Pk "$target" | awk 'END {print $4}')
		case "$free_kb" in ''|*[!0-9]*) die "Cannot determine free storage";; esac
		[ "$free_kb" -ge 32768 ] || die "At least 32 MiB free writable storage is required"
	fi
}

install_packages() {
	if [ "$PM" = apk ]; then before=$(apk info); else before=$(opkg list-installed | awk '{print $1}'); fi
	printf '%s\n' "$before" | sort > "$STAGE/packages-before"
	if [ -n "$NEEDED" ]; then
		# Intentional splitting: package names above are a fixed allowlist.
		# shellcheck disable=SC2086
		set -- $NEEDED
		if [ "$PM" = apk ]; then apk add "$@"; else opkg install "$@"; fi
	fi
	if ! command -v tailscaled >/dev/null 2>&1; then
		available tailscaled || die "tailscaled is missing and no split daemon package is available"
		if [ "$PM" = apk ]; then apk add tailscaled; else opkg install tailscaled; fi
	fi
	for cmd in tailscale tailscaled jsonfilter; do command -v "$cmd" >/dev/null 2>&1 || die "Installation did not provide $cmd"; done
	[ -x "$TSLAN_ROOT/etc/init.d/tailscale" ] || die "Packaged tailscale init script is missing"
	[ -f "$TSLAN_ROOT/usr/share/libubox/jshn.sh" ] || die "jshn runtime is missing"
	tailscale set --help 2>&1 | grep -q -- '--netfilter-mode' ||
		die "This Tailscale version cannot set netfilter-mode; update firmware/package feeds"
	if [ "$PM" = apk ]; then apk info; else opkg list-installed | awk '{print $1}'; fi | sort > "$STAGE/packages-after"
	awk 'FILENAME == ARGV[1] { seen[$0]=1; next } !($0 in seen)' \
		"$STAGE/packages-before" "$STAGE/packages-after" > "$TSLAN_DATA/packages-added-current"
	cat "$TSLAN_DATA/packages-added-current" "$TSLAN_DATA/packages-added" 2>/dev/null | sort -u > "$STAGE/packages-added"
	cp "$STAGE/packages-added" "$TSLAN_DATA/packages-added"
	rm -f "$TSLAN_DATA/packages-added-current"
}

install_payload() {
	while IFS= read -r path; do
		(umask 022; mkdir -p "$TSLAN_ROOT/$(dirname "$path")")
		cp "$STAGE/payload/$path" "$TSLAN_ROOT/$path"
		case "$path" in
			etc/init.d/*|usr/libexec/*) chmod 755 "$TSLAN_ROOT/$path";;
			*) chmod 644 "$TSLAN_ROOT/$path";;
		esac
	done < "$STAGE/manifest"
	cp "$STAGE/manifest" "$TSLAN_DATA/manifest"
}

uninstall() {
	[ -f "$TSLAN_ROOT/usr/lib/tslan/common.sh" ] || die "Integration is not installed"
	TSLAN_LIBDIR="$STAGE/payload/usr/lib/tslan"
	# shellcheck source=files/usr/lib/tslan/common.sh
	. "$TSLAN_LIBDIR/common.sh"
	[ -z "$(uci -q changes network)" ] && [ -z "$(uci -q changes firewall)" ] ||
		die "Save/revert pending network/firewall changes first"
	snapshot
	tailscale down 2>/dev/null || true
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
	rm -f "$TSLAN_ROOT/etc/config/tslan"
	"$TSLAN_ROOT/etc/init.d/rpcd" restart
	rm -f "$TSLAN_ROOT/tmp/luci-indexcache"
	rm -rf "$TSLAN_ROOT/tmp/luci-modulecache"
	say "Removed LuCI integration, managed interface, zone, forwarding and startup service."
	say "Retained installed packages, /etc/tailscale identity and root-only backups in /etc/tslan."
	say "Tailscale is stopped. Before using it standalone run: /etc/init.d/tailscale start; tailscale set --netfilter-mode=on; tailscale up"
}

main() {
	parse_args "$@"
	trap cleanup EXIT
	trap 'exit 130' INT TERM
	preflight
	extract_payload
	if [ "$MODE" = uninstall ]; then uninstall; exit 0; fi
	TSLAN_LIBDIR="$STAGE/payload/usr/lib/tslan"
	# shellcheck source=files/usr/lib/tslan/common.sh
	. "$TSLAN_LIBDIR/common.sh"
	LAN=${LAN_ARG:-$(get tslan.settings.lan_network)}
	LAN=${LAN:-lan}
	[ "$(get "network.$LAN")" = interface ] || die "LAN interface '$LAN' does not exist; use --lan-network NAME"
	check_conflicts
	[ -z "$(uci -q changes tslan)" ] || die "Save/revert pending tslan changes first"
	if [ -n "$(get tslan.settings)" ] && [ "$(get tslan.settings.managed)" != 1 ]; then
		die "An unrelated /etc/config/tslan exists"
	fi
	check_ipv6_support
	detect_pm
	check_packages
	if [ "$MODE" = check ]; then
		say "Preflight passed; package indexes refreshed, no services or configuration changed."
		exit 0
	fi
	snapshot
	# Back up managed files for failure recovery before installing dependencies.
	while IFS= read -r path; do
		if [ -e "$TSLAN_ROOT/$path" ]; then
			mkdir -p "$BACKUP/payload/$(dirname "$path")"
			cp -p "$TSLAN_ROOT/$path" "$BACKUP/payload/$path"
		fi
	done < "$STAGE/manifest"
	[ ! -f "$TSLAN_ROOT/etc/sysctl.d/99-tslan.conf" ] ||
		cp -p "$TSLAN_ROOT/etc/sysctl.d/99-tslan.conf" "$BACKUP/sysctl.conf"
	sysctl -n net.ipv4.ip_forward > "$BACKUP/ip_forward"
	install_packages
	TRANSACTION=1
	install_payload
	if [ "$(get tslan.settings.managed)" != 1 ]; then
		uci set tslan.settings=settings
		uci set tslan.settings.managed=1
		uci set tslan.settings.enabled=1
		uci set tslan.settings.accept_dns=0
		uci set tslan.settings.accept_routes=0
		uci set tslan.settings.shields_up=0
	fi
	uci set "tslan.settings.lan_network=$LAN"
	uci commit tslan
	chmod 600 "$TSLAN_ROOT/etc/config/tslan"
	load_settings
	configure_network
	# Network configuration has passed validation; remaining failures are reported,
	# leaving the management page installed for diagnosis and login.
	TRANSACTION=0
	write_report
	cp "$TSLAN_DATA/report.txt" "$TSLAN_DATA/install-report.txt"
	"$TSLAN_ROOT/etc/init.d/tailscale" disable
	sh "$TSLAN_ROOT/etc/rc.common" "$TSLAN_ROOT/etc/init.d/tslan" enable
	"$TSLAN_ROOT/etc/init.d/uhttpd" enable
	"$TSLAN_ROOT/etc/init.d/uhttpd" start
	"$TSLAN_ROOT/etc/init.d/rpcd" restart
	rm -f "$TSLAN_ROOT/tmp/luci-indexcache"
	rm -rf "$TSLAN_ROOT/tmp/luci-modulecache"
	start_result=0
	if [ "$ENABLED" = 1 ]; then
		# Execute in a separate process so a daemon failure cannot suppress reporting.
		"$TSLAN_ROOT/usr/libexec/tslan-control" boot > "$TSLAN_DATA/startup.log" 2>&1 || start_result=$?
	else
		"$TSLAN_ROOT/etc/init.d/tailscale" stop
	fi
	write_report
	say ''
	cat "$TSLAN_DATA/report.txt"
	say ''
	say "Management: LuCI -> Services -> Tailscale (refresh/re-login to LuCI if necessary)."
	say "First use: click Login / Authorize and finish Tailscale account authorization."
	say "Report: /etc/tslan/report.txt; install report: /etc/tslan/install-report.txt"
	if [ "$start_result" -ne 0 ]; then
		cat "$TSLAN_DATA/startup.log"
		die "Integration installed, but Tailscale startup failed. See /etc/tslan/startup.log"
	fi
	state=$(tailscale status --json 2>/dev/null | jsonfilter -e '@.BackendState' || true)
	say "Backend state: ${state:-stopped}. Local dual-stack checks do not prove peer service connectivity."
	say "Router host: use the peer's 100.x IPv4 or fd7a:115c:a1e0:: IPv6 address."
	say "Test from a LAN device using an allowed peer's 100.x address and service port."
}

extract_payload() {
	base64 -d > "$STAGE/payload.tar.gz" <<'TSLAN_PAYLOAD_BASE64'
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
TSLAN_PAYLOAD_BASE64
	actual=$(sha256sum "$STAGE/payload.tar.gz" | awk '{print $1}')
	[ "$actual" = 'f7f305fb6ff073f9963c4d7d19ec59c8bf3eab518b773d7c7d3442e6c4379eb6' ] || die "Embedded payload checksum mismatch"
	tar -xzf "$STAGE/payload.tar.gz" -C "$STAGE"
}


main "$@"
