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
	rm -f "$TSLAN_ROOT/tmp/luci-indexcache"
	rm -rf "$TSLAN_ROOT/tmp/luci-modulecache"
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
fHY+O5+dz85n57Pz2fnsfB765/8HZ0vudABAAQA=
TSLAN_PAYLOAD_BASE64
	actual=$(sha256sum "$STAGE/payload.tar.gz" | awk '{print $1}')
	[ "$actual" = '5d908a99f5071fa14bc1602f065e26ee2c0952fb88176a1f1e76567918320b3c' ] || die "Embedded payload checksum mismatch"
	tar -xzf "$STAGE/payload.tar.gz" -C "$STAGE"
}


main "$@"
