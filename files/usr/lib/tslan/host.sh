#!/bin/sh
# Sourced by common.sh. All writes are limited to the project's TUN device.

check_ipv6_support() {
	[ -d "$TSLAN_ROOT/proc/sys/net/ipv6" ] ||
		die "IPv6 kernel support is unavailable (possibly ipv6.disable=1). Use an IPv6-capable firmware/kernel; LAN/WAN settings were not changed."
	[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" = 0 ] ||
		die "net.ipv6.conf.all.disable_ipv6=1 blocks Tailscale IPv6. A global enable would affect physical interfaces, so this script leaves it unchanged. Enable kernel IPv6 with per-interface LAN/WAN restrictions before retrying."
	[ "$(sysctl -n net.ipv6.conf.all.disable_policy 2>/dev/null || echo 0)" = 0 ] ||
		die "IPv6 policy routing is globally disabled; leaving the existing configuration unchanged."
	for defaults in $(sections firewall defaults); do
		[ "$(get "firewall.$defaults.disable_ipv6")" != 1 ] ||
			die "The global firewall disable_ipv6 option is enabled; dual-stack firewall rules cannot be enforced."
	done
}

prepare_tun() {
	check_ipv6_support
	# ip-full is installed by this point; the firmware's original BusyBox ip
	# may lack the rule/tuntap subcommands even with a capable kernel.
	ip -6 rule show >/dev/null 2>&1 || die "IPv6 policy routing is unavailable"
	if ! ip link show dev tailscale0 >/dev/null 2>&1; then
		# Prepare before tailscaled opens the TUN: default.disable_ipv6=1 may
		# otherwise make its first IPv6 address assignment fail.
		ip tuntap add dev tailscale0 mode tun || die "Cannot create tailscale0; check ip-full and kmod-tun"
		ip link set dev tailscale0 alias tslan-managed
	fi
	[ -r "$TSLAN_ROOT/sys/class/net/tailscale0/tun_flags" ] ||
		die "tailscale0 exists but is not a TUN device"
	# Bring netifd up before tailscaled assigns addresses; netifd may flush
	# addresses when it first claims a device.
	ifup tslan
	tun_wait=0
	while [ "$(ubus call network.interface.tslan status 2>/dev/null | jsonfilter -e '@.up')" != true ]; do
		tun_wait=$((tun_wait + 1))
		[ "$tun_wait" -lt 10 ] || die "netifd did not bring up the tslan interface"
		sleep 1
	done
	# Never write conf.all or conf.default, and never touch physical interfaces.
	for setting in accept_ra=0 autoconf=0 disable_ipv6=0 disable_policy=0; do
		sysctl -w "net.ipv6.conf.tailscale0.$setting" >/dev/null
	done
	ip link set dev tailscale0 up
}

remove_owned_tun() {
	if [ "$(cat "$TSLAN_ROOT/sys/class/net/tailscale0/ifalias" 2>/dev/null)" = tslan-managed ]; then
		ip link delete dev tailscale0 || true
	fi
}

# Read-only check shared by startup, diagnostics and LuCI. An address in the
# control-plane JSON alone is insufficient: inspect the kernel device and route.
# Return 0: local checks passed, 1: local error, 2: login/approval/peers pending.
host_stack_status() (
	host_state=$(tailscale status --json 2>/dev/null | jsonfilter -e '@.BackendState' 2>/dev/null)
	case "$host_state" in
		Running) :;;
		*) say "PENDING: Tailscale state ${host_state:-unavailable}; local dual-stack verification awaits connection."; exit 2;;
	esac
	host_result=0
	host_peers=$(tailscale status --json 2>/dev/null | jsonfilter -e '@.Peer.*.TailscaleIPs[*]' 2>/dev/null)
	for family in 4 6; do
		host_ip=$(tailscale ip "-$family" 2>/dev/null | head -n 1)
		case "$family:$host_ip" in
			4:100.*|6:fd7a:115c:a1e0:*) :;;
			*) say "ERROR: IPv$family Tailscale address is missing."; host_result=1; continue;;
		esac
		if ! ip "-$family" -o addr show dev tailscale0 scope global 2>/dev/null |
			awk -v address="$host_ip" 'split($4, a, "/") && a[1] == address { found=1 } END { exit !found }'; then
			say "ERROR: IPv$family $host_ip is not installed on tailscale0."
			host_result=1
			continue
		fi
		if [ "$family" = 4 ]; then
			host_peer=$(printf '%s\n' "$host_peers" | sed -n '/^100\./{p;q;}')
		else
			host_peer=$(printf '%s\n' "$host_peers" | sed -n '/^fd7a:115c:a1e0:/{p;q;}')
		fi
		if [ -z "$host_peer" ]; then
			say "PENDING: IPv$family $host_ip on tailscale0; no peer address available to check routing."
			[ "$host_result" = 1 ] || host_result=2
		elif ip "-$family" route get "$host_peer" 2>/dev/null | grep -Eq '(^|[[:space:]])dev tailscale0([[:space:]]|$)'; then
			say "OK: IPv$family $host_ip on tailscale0; route to $host_peer uses tailscale0."
		else
			say "ERROR: IPv$family route to $host_peer does not use tailscale0; inspect policy rules and overlapping routes."
			host_result=1
		fi
	done
	say "Local checks do not test peer services or Tailnet access policy."
	exit "$host_result"
)

verify_host_stack() {
	host_attempt=0
	while :; do
		host_check=0
		host_stack_status > "$TSLAN_RUN/host-status" || host_check=$?
		case "$host_check" in
			0|2) cat "$TSLAN_RUN/host-status"; return 0;;
		esac
		host_attempt=$((host_attempt + 1))
		if [ "$host_attempt" -ge 5 ]; then
			cat "$TSLAN_RUN/host-status"
			die "Local IPv4/IPv6 validation failed; see diagnostics"
		fi
		sleep 1
	done
}
