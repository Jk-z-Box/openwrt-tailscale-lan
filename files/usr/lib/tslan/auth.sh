#!/bin/sh
# Passwords travel only through shell memory/stdin; never argv, UCI or job logs.
auth_enabled() { [ -f "$TSLAN_DATA/password" ]; }
read_secret() (
	# Subshell trap restores the terminal even on interruption.
	[ -t 0 ] || { IFS= read -r secret || return 1; printf '%s' "$secret"; return; }
	printf '%s: ' "$1" >&2
	old_tty=$(stty -g)
	trap 'stty "$old_tty"; printf "\n" >&2' EXIT
	trap 'exit 130' INT TERM
	stty -echo
	IFS= read -r secret || exit 1
	printf '%s' "$secret"
)
password_key() {
	# OpenSSL 1.1/3.0 enc uses 8-byte salts; pin this on newer OpenSSL too.
	set -- enc -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -S "$1" -P -pass stdin
	if openssl enc -help 2>&1 | grep -q -- '-saltlen'; then set -- "$@" -saltlen 8; fi
	openssl "$@" 2>/dev/null | sed -n 's/^key=//p'
}
auth_verify() (
	auth_enabled || exit 0
	[ "${#AUTH_PASSWORD}" -le 128 ] || exit 1
	mkdir -p "$TSLAN_RUN"
	mkdir "$TSLAN_RUN/auth-lock" 2>/dev/null || { say 'Password verification busy; retry shortly' >&2; exit 1; }
	trap 'rmdir "$TSLAN_RUN/auth-lock"' EXIT
	now=$(date +%s)
	next=$(cat "$TSLAN_RUN/auth-next" 2>/dev/null || printf 0)
	[ "$now" -ge "$next" ] || { say 'Password attempts too frequent; wait 3 seconds' >&2; exit 1; }
	printf '%s\n' "$((now + 3))" > "$TSLAN_RUN/auth-next"
	IFS=: read -r format salt expected < "$TSLAN_DATA/password"
	[ "$format" = pbkdf2-sha256-200000 ] && [ "${#salt}" = 16 ] && [ "${#expected}" = 64 ] || exit 1
	case "$salt$expected" in *[!0-9A-Fa-f]*) exit 1;; esac
	actual=$(printf '%s\n' "$AUTH_PASSWORD" | password_key "$salt")
	[ -n "$actual" ] && [ "$actual" = "$expected" ] || { say '管理密码错误；未修改配置。' >&2; exit 1; }
	rm -f "$TSLAN_RUN/auth-next"
)
auth_require() {
	auth_enabled || return 0
	AUTH_PASSWORD=$(read_secret '管理密码') || die '需要管理密码（交互输入或标准输入第一行）'
	auth_verify || { unset AUTH_PASSWORD; die 'Password verification failed'; }
	unset AUTH_PASSWORD
}
auth_save_password() {
	[ "${#NEW_PASSWORD}" -ge 8 ] && [ "${#NEW_PASSWORD}" -le 128 ] || die '密码长度必须为 8–128 字符'
	cr=$(printf '\r')
	case "$NEW_PASSWORD" in *'
'*|*"$cr"*) die 'Password must be a single line';; esac
	command -v openssl >/dev/null 2>&1 || die '需要软件包 openssl-util'
	salt=$(openssl rand -hex 8)
	key=$(printf '%s\n' "$NEW_PASSWORD" | password_key "$salt")
	[ "${#key}" = 64 ] || die 'OpenSSL PBKDF2 failed'
	mkdir -p "$TSLAN_DATA"
	chmod 700 "$TSLAN_DATA"
	tmp=$(mktemp "$TSLAN_DATA/.password.XXXXXXXX")
	printf 'pbkdf2-sha256-200000:%s:%s\n' "$salt" "$key" > "$tmp"
	chmod 600 "$tmp"
	mv "$tmp" "$TSLAN_DATA/password"
	unset NEW_PASSWORD key
}
auth_read_new_password() {
	NEW_PASSWORD=$(read_secret '新管理密码（至少 8 字符）') || die '未提供新密码'
	if [ -t 0 ]; then
		confirmation=$(read_secret '再次输入新密码') || die '未确认新密码'
		[ "$NEW_PASSWORD" = "$confirmation" ] || die '两次密码不一致'
		unset confirmation
	fi
	[ "${#NEW_PASSWORD}" -ge 8 ] && [ "${#NEW_PASSWORD}" -le 128 ] || die '密码长度必须为 8–128 字符'
}
auth_new_password() { auth_read_new_password; auth_save_password; }
auth_ticket() {
	mkdir -p "$TSLAN_RUN/tickets"
	chmod 700 "$TSLAN_RUN/tickets"
	ticket=$(mktemp "$TSLAN_RUN/tickets/XXXXXXXXXXXX")
	date +%s > "$ticket"
	printf '%s\n' "${ticket##*/}"
}
auth_consume_ticket() {
	case "$1" in ''|*[!a-zA-Z0-9]*) die 'Invalid authorization ticket';; esac
	ticket="$TSLAN_RUN/tickets/$1"
	created=$(cat "$ticket" 2>/dev/null) || die 'Invalid authorization ticket'
	rm -f "$ticket"
	now=$(date +%s)
	[ "$now" -ge "$created" ] && [ "$((now - created))" -le 30 ] || die 'Authorization expired'
}
