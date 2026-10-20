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
	for cmd in uci ip sysctl tar gzip base64 sha256sum mktemp ubus ifup; do
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
	for package in tailscale ip-full luci rpcd uhttpd uhttpd-mod-ubus jshn jsonfilter curl; do
		if ! installed "$package"; then
			available "$package" || die "Package '$package' is unavailable for this firmware/architecture"
			NEEDED="$NEEDED $package"
		fi
	done
	# Stock OpenWrt 23.05 BusyBox may omit timeout. Install the command from
	# the configured feed instead of rejecting an otherwise supported router.
	if ! command -v timeout >/dev/null 2>&1; then
		available coreutils-timeout || die "Package 'coreutils-timeout' is required but unavailable"
		NEEDED="$NEEDED coreutils-timeout"
	fi
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
	for cmd in tailscale tailscaled jsonfilter timeout curl; do command -v "$cmd" >/dev/null 2>&1 || die "Installation did not provide $cmd"; done
	[ -x "$TSLAN_ROOT/etc/init.d/tailscale" ] || die "Packaged tailscale init script is missing"
	[ -f "$TSLAN_ROOT/usr/share/libubox/jshn.sh" ] || die "jshn runtime is missing"
	tailscale up --help 2>&1 | grep -q -- '--netfilter-mode' ||
		die "This Tailscale version does not support netfilter-mode"
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
		# UCI cannot create a section in a package whose config file does
		# not yet exist. Keep this inside the installation rollback window.
		[ -f "$TSLAN_ROOT/etc/config/tslan" ] || : > "$TSLAN_ROOT/etc/config/tslan"
		uci set tslan.settings=settings
		uci set tslan.settings.managed=1
		uci set tslan.settings.enabled=1
		uci set tslan.settings.accept_dns=0
		uci set tslan.settings.accept_routes=0
		uci set tslan.settings.shields_up=0
	fi
	uci set "tslan.settings.lan_network=$LAN"
	[ -n "$(get tslan.settings.bypass_passwall2)" ] || uci set tslan.settings.bypass_passwall2=0
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
		configure_bypass
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
37f8+3/s34jnAMgAAA==
TSLAN_PAYLOAD_BASE64
	actual=$(sha256sum "$STAGE/payload.tar.gz" | awk '{print $1}')
	[ "$actual" = '9861235cad5dff45994c5e2e628d6eb889592092de906aae578d7a9de9059545' ] || die "Embedded payload checksum mismatch"
	tar -xzf "$STAGE/payload.tar.gz" -C "$STAGE"
}


main "$@"
