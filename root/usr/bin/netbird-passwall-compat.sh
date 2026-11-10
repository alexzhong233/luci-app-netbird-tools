#!/bin/sh

# Keep PassWall's current mark from being overwritten by NetBird's native
# nftables prerouting chain. The chain and mark are discovered at runtime.

TAG="netbird-passwall-compat"
RULE_TAG="PW-NB-COMPAT"
# 规则重建不是高频事件；30 秒足够，并可用 INTERVAL 临时覆盖。
INTERVAL="${INTERVAL:-30}"
LOCK_DIR="${LOCK_DIR:-/var/run/netbird-passwall-compat.lock}"
LAST_STATE=""
# ensure_rule 的副作用标记：missing / misplaced / 空（无需改动）
RULE_ACTION=""

log() {
	logger -t "$TAG" "$*"
}

acquire_lock() {
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		echo "$$" > "$LOCK_DIR/pid"
		trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
		return 0
	fi

	if [ -r "$LOCK_DIR/pid" ]; then
		PID=$(cat "$LOCK_DIR/pid" 2>/dev/null)
		if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
			return 1
		fi
	fi

	rm -rf "$LOCK_DIR"
	mkdir "$LOCK_DIR" 2>/dev/null || return 1
	echo "$$" > "$LOCK_DIR/pid"
	trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
}

# PassWall normally creates a table or chain containing passwall/PSW in its
# name. Keep the fallback for the commonly used inet passwall PSW_RULE path.
get_passwall_mark() {
	local MARK

	if [ -n "${PASSWALL_MARK:-}" ]; then
		printf '%s\n' "$PASSWALL_MARK"
		return 0
	fi

	# Prefer the mark used by the TCP classification rule in the conventional
	# PSW_RULE chain. A PassWall table can contain several unrelated marks.
	MARK=$(nft -a list ruleset 2>/dev/null | awk '
		/^table[[:space:]]/ {
			family = $2
			table = $3
			gsub(/[{}]/, "", table)
			chain = ""
			next
		}
		/^[[:space:]]*chain[[:space:]]/ {
			chain = $2
			gsub(/[{}]/, "", chain)
			next
		}
		/meta mark set/ && /tcp flags/ {
			scope = tolower(family " " table " " chain)
			if (scope ~ /passwall/ || scope ~ /psw/) {
				value = $0
				sub(/^.*meta mark set[[:space:]]+/, "", value)
				sub(/[[:space:]].*$/, "", value)
				if (value ~ /^0x[[:xdigit:]]+$/ || value ~ /^[0-9]+$/) {
					print value
					exit
				}
			}
	}' | head -n 1)

	# Fall back to any mark assignment inside a PassWall-named table or chain.
	# This covers UDP-only and newer rule layouts.
	if [ -z "$MARK" ]; then
		MARK=$(nft -a list ruleset 2>/dev/null | awk '
			/^table[[:space:]]/ {
				family = $2
				table = $3
				gsub(/[{}]/, "", table)
				chain = ""
				next
			}
			/^[[:space:]]*chain[[:space:]]/ {
				chain = $2
				gsub(/[{}]/, "", chain)
				next
			}
			/meta mark set/ {
				scope = tolower(family " " table " " chain)
				if (scope ~ /passwall/ || scope ~ /psw/) {
					value = $0
					sub(/^.*meta mark set[[:space:]]+/, "", value)
					sub(/[[:space:]].*$/, "", value)
					if (value ~ /^0x[[:xdigit:]]+$/ || value ~ /^[0-9]+$/) {
						print value
						exit
					}
				}
			}' | head -n 1)
	fi

	if [ -n "$MARK" ]; then
		printf '%s\n' "$MARK"
		return 0
	fi

	nft -a list chain inet passwall PSW_RULE 2>/dev/null |
		awk '/meta mark set/ {
			value = $0
			sub(/^.*meta mark set[[:space:]]+/, "", value)
			sub(/[[:space:]].*$/, "", value)
			if (value ~ /^0x[[:xdigit:]]+$/ || value ~ /^[0-9]+$/) print value
		}' | head -n 1
}

# Return family, table and chain as three whitespace-separated fields.
get_netbird_chain() {
	local INFO

	# First use the stable table/chain naming normally emitted by NetBird.
	INFO=$(nft -a list ruleset 2>/dev/null | awk '
		/^table[[:space:]]/ {
			family = $2
			table = $3
			gsub(/[{}]/, "", table)
			next
		}
		/^[[:space:]]*chain[[:space:]]/ {
			chain = $2
			gsub(/[{}]/, "", chain)
			scope = tolower(family " " table " " chain)
			if ((tolower(table) ~ /netbird/ || tolower(chain) ~ /netbird/) &&
			    tolower(chain) ~ /(prerouting|pre)/) {
				print family, table, chain
				exit
			}
		}' | head -n 1)

	[ -n "$INFO" ] && {
		printf '%s\n' "$INFO"
		return 0
	}

	# Fallback: identify a native mangle prerouting chain by NetBird's rule
	# shape, without hard-coding the LAN subnet or NetBird mark value.
	nft -a list ruleset 2>/dev/null | awk '
		/^table[[:space:]]/ {
			family = $2
			table = $3
			gsub(/[{}]/, "", table)
			candidate = ""
			in_candidate = 0
			has_wt0 = 0
			has_new = 0
			next
		}
		/^[[:space:]]*chain[[:space:]]/ {
			candidate = $2
			gsub(/[{}]/, "", candidate)
			in_candidate = 0
			has_wt0 = 0
			has_new = 0
			next
		}
		/type filter hook prerouting priority mangle;/ {
			in_candidate = 1
			next
		}
		in_candidate && /iifname[[:space:]]*!=[[:space:]]*"wt0"/ { has_wt0 = 1 }
		in_candidate && /ct state new/ { has_new = 1 }
		in_candidate && has_wt0 && has_new && /meta mark set/ {
			print family, table, candidate
			exit
		}
		/^[[:space:]]*}/ {
			in_candidate = 0
			has_wt0 = 0
			has_new = 0
		}' | head -n 1
}

delete_owned_rules() {
	local FAMILY="$1"
	local TABLE="$2"
	local CHAIN="$3"
	local RULES
	local HANDLE

	RULES=$(nft -a list chain "$FAMILY" "$TABLE" "$CHAIN" 2>/dev/null) || return 0
	printf '%s\n' "$RULES" |
		sed -n '/comment "'"$RULE_TAG"'"/ s/.*# handle \([0-9][0-9]*\).*/\1/p' |
		while IFS= read -r HANDLE; do
			[ -n "$HANDLE" ] || continue
			nft delete rule "$FAMILY" "$TABLE" "$CHAIN" handle "$HANDLE" 2>/dev/null || true
		done
}

# 判断豁免规则的位置是否有效。只检查"存在"是不够的：这条 return 必须排在
# 任何会改写 mark 的规则之前，否则等于没生效——而那种状态下列表看起来完全正常。
# 输出：ok / missing / misplaced <handle>
check_rule_position() {
	printf '%s\n' "$1" | awk -v mark="$2" '
		/^[[:space:]]*chain[[:space:]]/ { next }
		/type filter hook/ { next }
		/# handle [0-9]+/ {
			idx++
			handle = ""
			if (match($0, /# handle [0-9]+/))
				handle = substr($0, RSTART + 9, RLENGTH - 9)

			if (!ours && index($0, "meta mark " mark) && $0 ~ /return/) {
				ours = idx
				ours_handle = handle
			} else if (!first_set && index($0, "meta mark set")) {
				first_set = idx
			}
		}
		END {
			if (!ours)
				print "missing"
			else if (!first_set || ours < first_set)
				print "ok"
			else
				print "misplaced " ours_handle
		}
	'
}

ensure_rule() {
	local FAMILY="$1"
	local TABLE="$2"
	local CHAIN="$3"
	local PW_MARK="$4"
	local RULES
	local STATE
	local HANDLE

	RULES=$(nft -a list chain "$FAMILY" "$TABLE" "$CHAIN" 2>/dev/null) || return 1

	STATE=$(check_rule_position "$RULES" "$PW_MARK")

	case "$STATE" in
	ok)
		# 规则在且位置对：保留现有 handle，不动计数器和注释。
		RULE_ACTION=""
		return 0
		;;
	misplaced*)
		# 规则在但排到了覆盖规则后面。内容和我们要插的完全一致，
		# 删掉它再插到第一位，否则这条豁免永远不会命中。
		HANDLE=$(printf '%s\n' "$STATE" | awk '{print $2}')
		[ -n "$HANDLE" ] &&
			nft delete rule "$FAMILY" "$TABLE" "$CHAIN" handle "$HANDLE" 2>/dev/null
		RULE_ACTION="misplaced"
		;;
	*)
		RULE_ACTION="missing"
		;;
	esac

	# Only remove rules created by this script, including an old discovered mark.
	delete_owned_rules "$FAMILY" "$TABLE" "$CHAIN"

	nft insert rule "$FAMILY" "$TABLE" "$CHAIN" \
		meta mark "$PW_MARK" return comment "$RULE_TAG" 2>/dev/null
}

run_once() {
	local PW_MARK
	local NB_INFO
	local FAMILY
	local TABLE
	local CHAIN

	PW_MARK=$(get_passwall_mark)
	NB_INFO=$(get_netbird_chain)

	printf 'PassWall mark: %s\n' "${PW_MARK:-未发现}"
	printf 'NetBird 链: %s\n' "${NB_INFO:-未发现}"

	[ -n "$PW_MARK" ] || return 2
	[ -n "$NB_INFO" ] || return 3

	set -- $NB_INFO
	FAMILY="$1"
	TABLE="$2"
	CHAIN="$3"

	RULE_ACTION=""
	if ensure_rule "$FAMILY" "$TABLE" "$CHAIN" "$PW_MARK"; then
		case "$RULE_ACTION" in
		missing) printf '兼容规则缺失，已补回。\n' ;;
		misplaced) printf '兼容规则排在覆盖规则之后（等于没生效），已删除并重插到第一位。\n' ;;
		*) printf '兼容规则已存在且位置正确。\n' ;;
		esac
		return 0
	fi

	printf '无法安装兼容规则。\n' >&2
	return 1
}

cycle() {
	local PW_MARK
	local NB_INFO
	local FAMILY
	local TABLE
	local CHAIN
	local STATE
	local MESSAGE

	PW_MARK=$(get_passwall_mark)
	NB_INFO=$(get_netbird_chain)

	if [ -z "$PW_MARK" ]; then
		STATE="waiting-passwall-mark"
		MESSAGE="等待 PassWall 当前 nftables mark"
	elif [ -z "$NB_INFO" ]; then
		STATE="waiting-netbird-chain"
		MESSAGE="等待 NetBird prerouting 链"
	else
		set -- $NB_INFO
		FAMILY="$1"
		TABLE="$2"
		CHAIN="$3"
		RULE_ACTION=""
		if ensure_rule "$FAMILY" "$TABLE" "$CHAIN" "$PW_MARK"; then
			STATE="ready:$FAMILY:$TABLE:$CHAIN:$PW_MARK"
			case "$RULE_ACTION" in
			missing)
				MESSAGE="已补回兼容规则：$FAMILY $TABLE $CHAIN / $PW_MARK"
				;;
			misplaced)
				MESSAGE="豁免规则排在覆盖规则之后，已删除并重插到第一位：$FAMILY $TABLE $CHAIN / $PW_MARK"
				;;
			*)
				MESSAGE="兼容规则正常：$FAMILY $TABLE $CHAIN / $PW_MARK"
				;;
			esac
		else
			STATE="error:$FAMILY:$TABLE:$CHAIN:$PW_MARK"
			MESSAGE="无法在 $FAMILY $TABLE $CHAIN 安装兼容规则"
		fi
	fi

	# 规则被补回或纠正时，STATE 字符串和上一轮相同，只看状态会把这件事故意吞掉。
	if [ "$STATE" != "$LAST_STATE" ] || [ -n "$RULE_ACTION" ]; then
		log "$MESSAGE"
		LAST_STATE="$STATE"
	fi
}

case "$1" in
	--once|check)
		acquire_lock || exit 0
		run_once
		exit $?
		;;
esac

acquire_lock || exit 0

while :; do
	cycle
	sleep "$INTERVAL"
done
