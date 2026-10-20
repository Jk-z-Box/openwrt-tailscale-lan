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
	[ "$actual" = '90217bca103714c99e920174cd211e11a7ad13606d4028799e16e6f9b05a3c4b' ] || die "Embedded payload checksum mismatch"
	tar -xzf "$STAGE/payload.tar.gz" -C "$STAGE"
}


main "$@"
