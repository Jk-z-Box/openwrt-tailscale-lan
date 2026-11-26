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
TSLAN_PAYLOAD_BASE64
	actual=$(sha256sum "$STAGE/payload.tar.gz" | awk '{print $1}')
	[ "$actual" = '8335c94d23f4cfd840e1b02487fc606d330fd761ae3ad367dee5429302eecc74' ] || die "Embedded payload checksum mismatch"
	tar -xzf "$STAGE/payload.tar.gz" -C "$STAGE"
}


main "$@"
