#!/bin/sh
# Shared POSIX/BusyBox ash functions. TSLAN_ROOT is only used by the test harness.
TSLAN_ROOT=${TSLAN_ROOT:-}
TSLAN_DATA="$TSLAN_ROOT/etc/tslan"
# Used by callers after sourcing this library.
# shellcheck disable=SC2034
TSLAN_RUN="$TSLAN_ROOT/var/run/tslan"

say() { printf '%s\n' "$*"; }
die() { say "ERROR: $*" >&2; exit 1; }
get() { uci -q get "$1" 2>/dev/null || true; }
bool() { case "$1" in 0|1) return 0;; *) return 1;; esac; }
identifier() { case "$1" in ''|*[!a-zA-Z0-9_]) return 1;; *) return 0;; esac; }
sections() { uci -q show "$1" | sed -n "s/^$1\.\([^.=]*\)=$2$/\1/p"; }
has_word() { case " $1 " in *" $2 "*) return 0;; *) return 1;; esac; }

load_settings() {
	ENABLED=$(get tslan.settings.enabled)
	LAN=$(get tslan.settings.lan_network)
	HOSTNAME=$(get tslan.settings.hostname)
	ACCEPT_DNS=$(get tslan.settings.accept_dns)
	ACCEPT_ROUTES=$(get tslan.settings.accept_routes)
	SHIELDS_UP=$(get tslan.settings.shields_up)
	for value in "$ENABLED" "$ACCEPT_DNS" "$ACCEPT_ROUTES" "$SHIELDS_UP"; do
		bool "$value" || die "Invalid boolean in /etc/config/tslan"
	done
	identifier "$LAN" || die "Invalid LAN interface name"
	[ "$LAN" != tslan ] && [ "$LAN" != loopback ] || die "Invalid LAN interface"
	[ "$(get "network.$LAN")" = interface ] || die "LAN interface '$LAN' does not exist"
	case "$HOSTNAME" in *[!a-zA-Z0-9-]*|-*|*-) die "Hostname must contain letters, numbers or internal hyphens";; esac
	[ "${#HOSTNAME}" -le 63 ] || die "Hostname exceeds 63 characters"
	LAN_ZONE=
	for section in $(sections firewall zone); do
		if has_word "$(get "firewall.$section.network")" "$LAN"; then
			[ -z "$LAN_ZONE" ] || die "LAN belongs to multiple firewall zones"
			LAN_ZONE=$(get "firewall.$section.name")
		fi
	done
	[ -n "$LAN_ZONE" ] || die "No firewall zone covers '$LAN'"
	case "$LAN_ZONE" in *[!a-zA-Z0-9_-]*|tslan) die "Invalid LAN firewall zone";; esac
}

check_conflicts() {
	for package in network firewall; do
		[ -z "$(uci -q changes "$package")" ] || die "Unsaved UCI changes in $package; save/revert them first"
	done
	for key in network.tslan firewall.tslan firewall.tslan_lan; do
		if [ -n "$(get "$key")" ] && [ "$(get "$key.tslan_managed")" != 1 ]; then
			die "Existing $key is not owned by this project; refusing to overwrite it"
		fi
	done
	for section in $(sections network interface); do
		[ "$section" = tslan ] && continue
		if [ "$(get "network.$section.device")" = tailscale0 ] ||
			[ "$(get "network.$section.ifname")" = tailscale0 ]; then
			die "Existing interface '$section' already uses tailscale0. Remove/migrate the old Tailscale interface and zone first."
		fi
	done
	for section in $(sections firewall zone); do
		[ "$section" = tslan ] && continue
		if [ "$(get "firewall.$section.name")" = tslan ] ||
			has_word "$(get "firewall.$section.device")" tailscale0 ||
			has_word "$(get "firewall.$section.network")" tslan; then
			die "Existing firewall zone '$section' conflicts with tslan/tailscale0"
		fi
	done
}

snapshot() {
	mkdir -p "$TSLAN_DATA/backups"
	chmod 700 "$TSLAN_DATA" "$TSLAN_DATA/backups"
	BACKUP=$(mktemp -d "$TSLAN_DATA/backups/config-XXXXXXXX")
	for name in network firewall tailscale tslan; do
		if [ -f "$TSLAN_ROOT/etc/config/$name" ]; then
			cp -p "$TSLAN_ROOT/etc/config/$name" "$BACKUP/$name"
		else
			: > "$BACKUP/$name.absent"
		fi
	done
	printf '%s\n' "$BACKUP" > "$TSLAN_DATA/latest-backup"
}

configure_network() {
	check_conflicts
	# Recreate only sections that are owned by this project.
	for key in network.tslan firewall.tslan firewall.tslan_lan; do
		uci -q delete "$key" 2>/dev/null || true
	done
	uci set network.tslan=interface
	uci set network.tslan.proto=none
	uci set network.tslan.device=tailscale0
	uci set network.tslan.tslan_managed=1
	uci set firewall.tslan=zone
	uci set firewall.tslan.name=tslan
	uci add_list firewall.tslan.network=tslan
	uci set firewall.tslan.family=ipv4
	uci set firewall.tslan.input=REJECT
	uci set firewall.tslan.output=ACCEPT
	uci set firewall.tslan.forward=REJECT
	uci set firewall.tslan.masq=1
	uci set firewall.tslan.mtu_fix=1
	uci set firewall.tslan.tslan_managed=1
	uci set firewall.tslan_lan=forwarding
	uci set "firewall.tslan_lan.src=$LAN_ZONE"
	uci set firewall.tslan_lan.dest=tslan
	uci set firewall.tslan_lan.tslan_managed=1
	uci commit network
	uci commit firewall
	# Validate before reloading the running firewall.
	if command -v fw4 >/dev/null 2>&1; then
		fw4 check || die "fw4 validation failed"
	elif command -v fw3 >/dev/null 2>&1; then
		fw3 print >/dev/null || die "fw3 validation failed"
	else
		die "Neither fw4 nor fw3 was found"
	fi
	mkdir -p "$TSLAN_ROOT/etc/sysctl.d"
	printf 'net.ipv4.ip_forward=1\n' > "$TSLAN_ROOT/etc/sysctl.d/99-tslan.conf"
	sysctl -w net.ipv4.ip_forward=1 >/dev/null
	"$TSLAN_ROOT/etc/init.d/network" reload
	"$TSLAN_ROOT/etc/init.d/firewall" reload
}

restore_network() {
	[ -n "${BACKUP:-}" ] && [ -d "$BACKUP" ] || return 0
	for name in network firewall; do
		uci -q revert "$name" 2>/dev/null || true
		[ ! -f "$BACKUP/$name" ] || cp -p "$BACKUP/$name" "$TSLAN_ROOT/etc/config/$name"
	done
	"$TSLAN_ROOT/etc/init.d/network" reload >/dev/null 2>&1 || true
	"$TSLAN_ROOT/etc/init.d/firewall" reload >/dev/null 2>&1 || true
}

wait_daemon() {
	tries=0
	while [ "$tries" -lt 20 ]; do
		if tailscale status --json 2>/dev/null | jsonfilter -e '@.BackendState' | grep -q .; then return 0; fi
		tries=$((tries + 1))
		sleep 1
	done
	die "tailscaled did not become ready; inspect logread -e tailscale"
}

apply_preferences() {
	# Always use separate argv arguments; never evaluate UCI values as shell code.
	set -- "--accept-dns=$([ "$ACCEPT_DNS" = 1 ] && printf true || printf false)"
	set -- "$@" "--accept-routes=$([ "$ACCEPT_ROUTES" = 1 ] && printf true || printf false)"
	set -- "$@" "--shields-up=$([ "$SHIELDS_UP" = 1 ] && printf true || printf false)"
	set -- "$@" --netfilter-mode=off
	[ -z "$HOSTNAME" ] || set -- "$@" "--hostname=$HOSTNAME"
	tailscale set "$@"
}

start_client() {
	"$TSLAN_ROOT/etc/init.d/tailscale" start
	wait_daemon
	apply_preferences
	state=$(tailscale status --json 2>/dev/null | jsonfilter -e '@.BackendState')
	case "$state" in
		Stopped) timeout 20 tailscale up;;
		Running|NeedsLogin|NeedsMachineAuth|NoState|Starting) :;;
		*) say "Tailscale backend state: $state";;
	esac
}

write_report() {
	mkdir -p "$TSLAN_DATA"
	{
		printf 'OpenWrt Tailscale LAN deployment %s\n' "$(cat "$TSLAN_ROOT/usr/share/tslan/version")"
		date -u '+Updated: %Y-%m-%dT%H:%M:%SZ'
		printf 'LAN interface: %s; source firewall zone: %s\n' "$LAN" "$LAN_ZONE"
		printf 'Installed packages: '
		cat "$TSLAN_DATA/packages-added" 2>/dev/null || true
		printf '\n'
		cat <<'REPORT'
Managed interface: network.tslan, unmanaged, device tailscale0; no DHCP server.
Managed firewall: firewall.tslan (IPv4); input REJECT, output ACCEPT, forward REJECT.
Masquerading and MSS clamping are enabled on tslan.
Managed forwarding: firewall.tslan_lan, selected LAN zone -> tslan.
Return traffic uses the existing conntrack established/related rules.
IPv4 forwarding: /etc/sysctl.d/99-tslan.conf sets net.ipv4.ip_forward=1.
Tailscale preferences: netfilter-mode=off; OpenWrt manages this integration's firewall.
LuCI: Services -> Tailscale; JS view, menu JSON, dedicated rpcd plugin and ACL.
No WAN firewall allow rule, port forward, LAN DHCP/DNS rule, default route or subnet advertisement is added.
The source firewall zone covers all networks assigned to that zone.
Nondefault existing Tailscale options not managed by this page remain in Tailscale state.
REPORT
		printf 'Preferences: enabled=%s, accept-dns=%s, accept-routes=%s, shields-up=%s, hostname=%s\n' \
			"$ENABLED" "$ACCEPT_DNS" "$ACCEPT_ROUTES" "$SHIELDS_UP" "${HOSTNAME:-(unchanged)}"
		printf 'Service: /etc/init.d/tslan manages startup and applies preferences; stock tailscale init is preserved.\n'
		printf 'Backup directory: %s\n' "$(cat "$TSLAN_DATA/latest-backup" 2>/dev/null || true)"
		printf 'Default gateway requirement: LAN traffic for Tailscale must reach this OpenWrt router.\n'
		printf 'Access targets by their 100.x IPv4 addresses; LAN MagicDNS is not configured.\n'
		printf 'Scope: IPv4; local LAN devices share this router identity in Tailnet access policy.\n'
	} > "$TSLAN_DATA/report.txt"
	chmod 600 "$TSLAN_DATA/report.txt"
}
