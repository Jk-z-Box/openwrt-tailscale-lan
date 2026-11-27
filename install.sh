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
	for cmd in tailscale tailscaled jsonfilter timeout curl openssl unshare; do command -v "$cmd" >/dev/null 2>&1 || die "Installation did not provide $cmd"; done
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
AQA=
TSLAN_PAYLOAD_BASE64
	actual=$(sha256sum "$STAGE/payload.tar.gz" | awk '{print $1}')
	[ "$actual" = '30ccf7ba08482a3d0387eb0aa849e288357cc9a311defa0f130ab352f527bbdb' ] || die "Embedded payload checksum mismatch"
	tar -xzf "$STAGE/payload.tar.gz" -C "$STAGE"
}


main "$@"
