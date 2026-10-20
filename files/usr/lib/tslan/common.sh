#!/bin/sh
# Shared POSIX/BusyBox ash functions. TSLAN_ROOT is only used by the test harness.
TSLAN_ROOT=${TSLAN_ROOT:-}
TSLAN_DATA="$TSLAN_ROOT/etc/tslan"
# Used by callers after sourcing this library.
# shellcheck disable=SC2034
TSLAN_RUN="$TSLAN_ROOT/var/run/tslan"
TSLAN_LIBDIR=${TSLAN_LIBDIR:-"$TSLAN_ROOT/usr/lib/tslan"}
# shellcheck source=files/usr/lib/tslan/host.sh
. "$TSLAN_LIBDIR/host.sh"

managed_sections() {
	printf '%s\n' network.tslan network.tslan_device firewall.tslan firewall.tslan_lan \
		firewall.tslan_icmp6 firewall.tslan_no_forward6_in firewall.tslan_no_forward6_out
}

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
	for key in $(managed_sections); do
		if [ -n "$(get "$key")" ] && [ "$(get "$key.tslan_managed")" != 1 ]; then
			die "Existing $key is not owned by this project; refusing to overwrite it"
		fi
	done
	for section in $(sections network device); do
		[ "$section" = tslan_device ] && continue
		[ "$(get "network.$section.name")" != tailscale0 ] ||
			die "Existing device section '$section' already configures tailscale0"
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
	check_ipv6_support
	# Recreate only sections that are owned by this project.
	for key in $(managed_sections); do
		uci -q delete "$key" 2>/dev/null || true
	done
	uci set network.tslan=interface
	uci set network.tslan.proto=none
	uci set network.tslan.device=tailscale0
	uci set network.tslan.force_link=1
	uci set network.tslan.tslan_managed=1
	uci set network.tslan_device=device
	uci set network.tslan_device.name=tailscale0
	uci set network.tslan_device.ipv6=1
	uci set network.tslan_device.tslan_managed=1
	uci set firewall.tslan=zone
	uci set firewall.tslan.name=tslan
	uci add_list firewall.tslan.network=tslan
	uci add_list firewall.tslan.device=tailscale0
	uci set firewall.tslan.family=any
	uci set firewall.tslan.input=REJECT
	uci set firewall.tslan.output=ACCEPT
	uci set firewall.tslan.forward=REJECT
	uci set firewall.tslan.masq=1
	uci set firewall.tslan.masq6=0
	uci set firewall.tslan.mtu_fix=1
	uci set firewall.tslan.tslan_managed=1
	uci set firewall.tslan_lan=forwarding
	uci set "firewall.tslan_lan.src=$LAN_ZONE"
	uci set firewall.tslan_lan.dest=tslan
	uci set firewall.tslan_lan.family=ipv4
	uci set firewall.tslan_lan.tslan_managed=1
	uci set firewall.tslan_icmp6=rule
	uci set firewall.tslan_icmp6.name=TSLAN-ICMPv6-errors
	uci set firewall.tslan_icmp6.src=tslan
	uci set firewall.tslan_icmp6.family=ipv6
	uci set firewall.tslan_icmp6.proto=icmp
	for icmp_type in destination-unreachable packet-too-big time-exceeded parameter-problem; do
		uci add_list "firewall.tslan_icmp6.icmp_type=$icmp_type"
	done
	uci set firewall.tslan_icmp6.target=ACCEPT
	uci set firewall.tslan_icmp6.tslan_managed=1
	for direction in in out; do
		key="firewall.tslan_no_forward6_$direction"
		uci set "$key=rule"
		uci set "$key.name=TSLAN-no-IPv6-forward-$direction"
		uci set "$key.family=ipv6"
		uci set "$key.proto=all"
		uci set "$key.target=REJECT"
		uci set "$key.tslan_managed=1"
		if [ "$direction" = in ]; then
			uci set "$key.src=*"
			uci set "$key.dest=tslan"
		else
			uci set "$key.src=tslan"
			uci set "$key.dest=*"
		fi
	done
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
	[ -z "$HOSTNAME" ] || set -- "$@" "--hostname=$HOSTNAME"
	if tailscale set --help 2>&1 | grep -q -- '--netfilter-mode'; then
		tailscale set "$@" --netfilter-mode=off
	else
		tailscale set "$@"
		# OpenWrt 23.05 supplies 1.58.2: "up" supports this preference but
		# "set" does not. Use its local masked-prefs API to change just this
		# field, preserving all unrelated options and avoiding "up --reset".
		# Do not print/store the full prefs response, which may contain keys.
		mode=$(curl --silent --show-error --fail --max-time 10 --noproxy '*' \
			--unix-socket "$TSLAN_ROOT/var/run/tailscale/tailscaled.sock" \
			-X PATCH -H 'Content-Type: application/json' \
			-d '{"NetfilterMode":0,"NetfilterModeSet":true}' \
			http://local-tailscaled.sock/localapi/v0/prefs |
			jsonfilter -e '@.NetfilterMode' 2>/dev/null || true)
		[ "$mode" = 0 ] || die "Could not set netfilter-mode=off using the local Tailscale socket"
	fi
}

start_client() {
	# Restart even after an existing installation: the daemon caches IPv6
	# capability, and netifd reload may have removed its previous addresses.
	"$TSLAN_ROOT/etc/init.d/tailscale" stop
	prepare_tun
	"$TSLAN_ROOT/etc/init.d/tailscale" start
	wait_daemon
	apply_preferences
	state=$(tailscale status --json 2>/dev/null | jsonfilter -e '@.BackendState')
	case "$state" in
		Stopped) timeout 20 tailscale up;;
		Running|NeedsLogin|NeedsMachineAuth|NoState|Starting) :;;
		*) say "Tailscale backend state: $state";;
	esac
	verify_host_stack
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
Managed interface: network.tslan, proto none, force_link=1, device tailscale0; no DHCP server.
Managed device: network.tslan_device enables IPv6 only on tailscale0.
Managed firewall: firewall.tslan (IPv4 + IPv6); input REJECT, output ACCEPT, forward REJECT.
IPv4 masquerading and MSS clamping are enabled; IPv6 NAT is disabled.
Managed forwarding: firewall.tslan_lan, IPv4 only, selected LAN zone -> tslan.
Managed rules: tslan_icmp6 accepts essential ICMPv6 errors; tslan_no_forward6_in/out reject IPv6 forwarding through tailscale0.
Return traffic uses the existing conntrack established/related rules.
IPv4 forwarding: /etc/sysctl.d/99-tslan.conf sets net.ipv4.ip_forward=1.
Runtime tailscale0 IPv6 settings: disable_ipv6=0, disable_policy=0, accept_ra=0, autoconf=0.
The TUN is prepared before daemon startup and retained across stop/start; an owned TUN is deleted on uninstall.
No global/default/physical-interface IPv6 sysctl is changed; IPv6 forwarding is not enabled.
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
		printf 'Scope: router host IPv4/IPv6 via tailscale0; LAN forwarding remains IPv4. LAN devices share this router identity.\n'
		printf '\nHost validation at report generation:\n'
		host_stack_status || true
	} > "$TSLAN_DATA/report.txt"
	chmod 600 "$TSLAN_DATA/report.txt"
}
