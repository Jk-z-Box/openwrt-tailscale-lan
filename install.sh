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
	for cmd in uci ip sysctl tar gzip base64 sha256sum mktemp timeout; do
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
	for package in tailscale luci rpcd uhttpd uhttpd-mod-ubus jshn jsonfilter; do
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
	# shellcheck source=files/usr/lib/tslan/common.sh
	. "$TSLAN_ROOT/usr/lib/tslan/common.sh"
	[ -z "$(uci -q changes network)" ] && [ -z "$(uci -q changes firewall)" ] ||
		die "Save/revert pending network/firewall changes first"
	snapshot
	tailscale down 2>/dev/null || true
	sh "$TSLAN_ROOT/etc/rc.common" "$TSLAN_ROOT/etc/init.d/tslan" disable || true
	"$TSLAN_ROOT/etc/init.d/tailscale" disable || true
	"$TSLAN_ROOT/etc/init.d/tailscale" stop || true
	for key in network.tslan firewall.tslan firewall.tslan_lan; do
		if [ "$(get "$key.tslan_managed")" = 1 ]; then uci delete "$key"; fi
	done
	uci commit network
	uci commit firewall
	rm -f "$TSLAN_ROOT/etc/sysctl.d/99-tslan.conf"
	"$TSLAN_ROOT/etc/init.d/network" reload
	"$TSLAN_ROOT/etc/init.d/firewall" reload
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
	if [ "$MODE" = uninstall ]; then uninstall; exit 0; fi
	extract_payload
	# shellcheck source=files/usr/lib/tslan/common.sh
	. "$STAGE/payload/usr/lib/tslan/common.sh"
	LAN=${LAN_ARG:-$(get tslan.settings.lan_network)}
	LAN=${LAN:-lan}
	[ "$(get "network.$LAN")" = interface ] || die "LAN interface '$LAN' does not exist; use --lan-network NAME"
	check_conflicts
	[ -z "$(uci -q changes tslan)" ] || die "Save/revert pending tslan changes first"
	if [ -n "$(get tslan.settings)" ] && [ "$(get tslan.settings.managed)" != 1 ]; then
		die "An unrelated /etc/config/tslan exists"
	fi
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
	say "Backend state: ${state:-stopped}. Deployment does not prove LAN-to-peer connectivity."
	say "Test from a LAN device using an allowed peer's 100.x address and service port."
}

extract_payload() {
	base64 -d > "$STAGE/payload.tar.gz" <<'TSLAN_PAYLOAD_BASE64'
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
TSLAN_PAYLOAD_BASE64
	actual=$(sha256sum "$STAGE/payload.tar.gz" | awk '{print $1}')
	[ "$actual" = 'c69722c51043ce317ddd9376ba2a57c9ef53b2332d2ce4f76309ac926969aee7' ] || die "Embedded payload checksum mismatch"
	tar -xzf "$STAGE/payload.tar.gz" -C "$STAGE"
}


main "$@"
