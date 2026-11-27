#!/bin/sh
# Generated install.sh embeds the files/ payload. Rebuild with scripts/build.py.
set -eu
umask 077
export LC_ALL=C
TSLAN_ROOT=${TSLAN_ROOT:-}
MODE=install
WEB_ARG=
PASSWORD_ARG=
NONINTERACTIVE=0
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
  sh install.sh --web on|off           Show/hide Services -> Tailscale
  sh install.sh --password on|off      Set/change or disable management password
  sh install.sh --non-interactive      Preserve existing choices; new defaults: Web on, password off
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
			--web) [ "$#" -ge 2 ] || die '--web needs on/off'; WEB_ARG=$2; shift 2;;
			--password) [ "$#" -ge 2 ] || die '--password needs on/off'; PASSWORD_ARG=$2; shift 2;;
			--non-interactive) NONINTERACTIVE=1; shift;;
			--check) MODE=check; shift;;
			--uninstall) MODE=uninstall; shift;;
			--help|-h) usage; exit 0;;
			*) die "Unknown option: $1";;
		esac
	done
	case "$WEB_ARG" in ''|on|off) :;; *) die '--web needs on/off';; esac
	case "$PASSWORD_ARG" in ''|on|off) :;; *) die '--password needs on/off';; esac
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
	[ -z "${CONTROL_LOCK:-}" ] || rm -rf "$CONTROL_LOCK"
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
	for package in tailscale ip-full luci rpcd uhttpd uhttpd-mod-ubus jshn jsonfilter curl openssl-util; do
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
	for cmd in tailscale tailscaled jsonfilter timeout curl openssl; do command -v "$cmd" >/dev/null 2>&1 || die "Installation did not provide $cmd"; done
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
			etc/init.d/*|usr/libexec/*|usr/sbin/*) chmod 755 "$TSLAN_ROOT/$path";;
			*) chmod 644 "$TSLAN_ROOT/$path";;
		esac
	done < "$STAGE/manifest"
	cp "$STAGE/manifest" "$TSLAN_DATA/manifest"
}

installer_control_lock() {
	mkdir -p "$TSLAN_RUN"
	mkdir "$TSLAN_RUN/lock" 2>/dev/null || die 'Another Tailscale operation is running'
	CONTROL_LOCK="$TSLAN_RUN/lock"
	printf '%s\n' "$$" > "$CONTROL_LOCK/pid"
}

uninstall() {
	TSLAN_LIBDIR="$STAGE/payload/usr/lib/tslan"
	# shellcheck source=files/usr/lib/tslan/common.sh
	. "$TSLAN_LIBDIR/common.sh"
	[ -f "$TSLAN_ROOT/usr/lib/tslan/common.sh" ] || die "Integration is not installed"
	auth_require
	installer_control_lock
	# shellcheck source=files/usr/lib/tslan/uninstall.sh
	. "$TSLAN_LIBDIR/uninstall.sh"
	uninstall_integration
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
	# Authenticate upgrades/checks before refreshing feeds or changing any package/config.
	auth_require
	installer_control_lock
	if [ "$MODE" = install ] && [ "$NONINTERACTIVE" = 0 ] && [ -t 0 ]; then
		if [ -z "$WEB_ARG" ]; then
			printf '显示 LuCI 服务菜单？[y/n，回车保留现有值，新安装默认 y] '
			IFS= read -r answer
			case "$answer" in y|Y) WEB_ARG=on;; n|N) WEB_ARG=off;; '') :;; *) die '请输入 y 或 n';; esac
		fi
		if [ -z "$PASSWORD_ARG" ] && ! auth_enabled; then
			printf '设置管理密码？[y/N] '
			IFS= read -r answer
			case "$answer" in y|Y) PASSWORD_ARG=on;; n|N|'') :;; *) die '请输入 y 或 n';; esac
		fi
	fi
	if [ "$MODE" = install ] && [ "$PASSWORD_ARG" = on ]; then auth_read_new_password; fi
	LAN=${LAN_ARG:-$(get tslan.settings.lan_network)}
	LAN=${LAN:-lan}
	[ "$(get "network.$LAN")" = interface ] || die "LAN interface '$LAN' does not exist; use --lan-network NAME"
	check_conflicts
	[ -z "$(uci -q changes tslan)" ] || die "Save/revert pending tslan changes first"
	if [ -n "$(get tslan.settings)" ] && [ "$(get tslan.settings.managed)" != 1 ]; then
		die "An unrelated /etc/config/tslan exists"
	fi
	check_ipv6_support
	command -v fw4 >/dev/null 2>&1 || die "LAN switches require firewall4"
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
	# Derive and validate the new hash before exposing/updating the integration.
	if [ "$PASSWORD_ARG" = on ]; then
		saved_data=$TSLAN_DATA
		TSLAN_DATA=$STAGE
		auth_save_password
		TSLAN_DATA=$saved_data
	fi
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
	[ -n "$(get tslan.settings.lan_ipv4)" ] || uci set tslan.settings.lan_ipv4=1
	[ -n "$(get tslan.settings.lan_ipv6)" ] || uci set tslan.settings.lan_ipv6=0
	[ -n "$(get tslan.settings.web_visible)" ] || uci set tslan.settings.web_visible=1
	case "$WEB_ARG" in on) uci set tslan.settings.web_visible=1;; off) uci set tslan.settings.web_visible=0;; esac
	uci commit tslan
	chmod 600 "$TSLAN_ROOT/etc/config/tslan"
	load_settings
	configure_network
	# Network configuration has passed validation; remaining failures are reported,
	# leaving the management page installed for diagnosis and login.
	configure_web
	case "$PASSWORD_ARG" in on) mv "$STAGE/password" "$TSLAN_DATA/password";; off) rm -f "$TSLAN_DATA/password";; esac
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
	rm -rf "$CONTROL_LOCK"
	CONTROL_LOCK=
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
	say "Management: tslan (CLI menu); LuCI -> Services -> Tailscale when Web visibility is enabled."
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
57Pz2fnsfHY+O5+dzz/V5/8BppcxkwBAAQA=
TSLAN_PAYLOAD_BASE64
	actual=$(sha256sum "$STAGE/payload.tar.gz" | awk '{print $1}')
	[ "$actual" = '003c9f5f236754dbea1671eb37de889317a295173a36fd9c529f6ea7a1feee24' ] || die "Embedded payload checksum mismatch"
	tar -xzf "$STAGE/payload.tar.gz" -C "$STAGE"
}


main "$@"
