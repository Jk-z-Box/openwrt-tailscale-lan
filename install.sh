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
	for package in tailscale ip-full luci rpcd uhttpd uhttpd-mod-ubus jshn jsonfilter curl openssl-util unshare; do
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
	if ! command -v stty >/dev/null 2>&1; then
		available coreutils-stty || die "Package 'coreutils-stty' is required for secure terminal password input but unavailable"
		NEEDED="$NEEDED coreutils-stty"
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
	for cmd in tailscale tailscaled jsonfilter timeout curl openssl unshare stty; do command -v "$cmd" >/dev/null 2>&1 || die "Installation did not provide $cmd"; done
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
	# New passwords are read only after a missing stty has been installed.
	# Existing passwords were authenticated before any feed/package changes.
	if [ "$PASSWORD_ARG" = on ]; then auth_read_new_password; fi
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
	check_dns_settings
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
	invalidate_luci_cache
	rm -rf "$CONTROL_LOCK"
	CONTROL_LOCK=
	start_result=0
	if [ "$ENABLED" = 1 ]; then
		# Execute in a separate process so a daemon failure cannot suppress reporting.
		"$TSLAN_ROOT/usr/libexec/tslan-control" boot > "$TSLAN_DATA/startup.log" 2>&1 || start_result=$?
	else
		daemon_stop
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
TSLAN_PAYLOAD_BASE64
	actual=$(sha256sum "$STAGE/payload.tar.gz" | awk '{print $1}')
	[ "$actual" = '89f9080bf7ce8b28b460e20ee39552f77451f74420627e2ac671d8465b8a09f9' ] || die "Embedded payload checksum mismatch"
	tar -xzf "$STAGE/payload.tar.gz" -C "$STAGE"
}


main "$@"
