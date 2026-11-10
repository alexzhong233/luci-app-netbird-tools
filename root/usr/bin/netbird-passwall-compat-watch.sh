#!/bin/sh
# SPDX-License-Identifier: MIT
#
# netbird-passwall-compat-watch.sh
#
# 事件驱动的兼容规则守护。用 `nft monitor` 订阅 nftables 规则变更事件，
# NetBird 一旦重建 prerouting 链就立即补回 PassWall mark 豁免，不再依赖
# 固定周期的轮询。
#
# 发现规则和插入规则的逻辑不在本脚本里实现，统一复用
# netbird-passwall-compat.sh --once，保证只有一份代码需要维护。
#
# 环境变量：
#   COMPAT   兼容脚本路径，默认 /usr/bin/netbird-passwall-compat.sh
#   WATCHDOG 兜底全量检查间隔（秒），默认 60，设为 0 关闭
#   MATCH    事件行过滤关键字，默认 netbird
#   LOCK_DIR 单实例锁目录
#
# 用法：
#   netbird-passwall-compat-watch.sh            常驻，事件驱动
#   netbird-passwall-compat-watch.sh --once     只做一次检查和补规则
#   netbird-passwall-compat-watch.sh --test     打印带时间戳的事件流，用于测延迟
#
# 注意：不要和 netbird-passwall-compat.sh 的轮询服务同时启用。轮询服务在
# 整个生命周期内持有同一把补丁锁，会让这里的补回变成空操作。

set -u

TAG="netbird-passwall-compat-watch"
COMPAT=${COMPAT:-/usr/bin/netbird-passwall-compat.sh}
WATCHDOG=${WATCHDOG:-60}
MATCH=${MATCH:-netbird}
LOCK_DIR=${LOCK_DIR:-/var/run/netbird-passwall-compat-watch.lock}
MAX_BACKOFF=16
MAIN_PID=$$
WATCHDOG_PID=""
PIPE_PID=""

log() {
	logger -t "$TAG" "$*" 2>/dev/null || printf '%s: %s\n' "$TAG" "$*" >&2
}

usage() {
	cat <<'EOF'
Usage: netbird-passwall-compat-watch.sh [--once|--test|--help]

  无参数   常驻运行，用 nft monitor 监听规则变更并即时补回兼容规则
  --once   只执行一次检查和补规则
  --test   打印带时间戳的 nftables 事件流，用于验证事件延迟

环境变量：
  COMPAT   兼容脚本路径（默认 /usr/bin/netbird-passwall-compat.sh）
  WATCHDOG 兜底检查间隔秒数（默认 60，0 关闭）
  MATCH    事件过滤关键字（默认 netbird）
EOF
}

acquire_lock() {
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		echo "$$" >"$LOCK_DIR/pid"
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
	echo "$$" >"$LOCK_DIR/pid"
	return 0
}

cleanup() {
	if [ -f "$LOCK_DIR/pid" ] && [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
		rm -rf "$LOCK_DIR"
	fi
	if [ -n "$PIPE_PID" ]; then
		kill "$PIPE_PID" 2>/dev/null
		PIPE_PID=""
	fi
	if [ -n "$WATCHDOG_PID" ]; then
		kill "$WATCHDOG_PID" 2>/dev/null
		WATCHDOG_PID=""
	fi
}

# 收到 TERM/INT 必须真正退出，否则 procd stop 会等超时再 SIGKILL，
# 期间锁目录不会被清理。EXIT 再用 cleanup 收尾一次（幂等）。
on_term() {
	cleanup
	exit 0
}

# 上一轮如果是被 SIGKILL 结束的（procd stop 超时就干这个），trap 不执行，
# 看门狗子 shell 和读 nft monitor 的子 shell 都会变成孤儿，继续反复补规则。
# 调用这个函数时我们已经持有锁，场上其它同名进程必然是遗留物，可以清掉。
kill_strays() {
	local entry pid cmdline

	for entry in /proc/[0-9]*/cmdline; do
		[ -r "$entry" ] || continue
		pid="${entry#/proc/}"
		pid="${pid%/cmdline}"
		[ "$pid" = "$$" ] && continue
		cmdline=$(tr '\0' ' ' <"$entry" 2>/dev/null)
		case "$cmdline" in
		*netbird-passwall-compat-watch.sh*)
			log "清理遗留进程 pid=$pid"
			kill -9 "$pid" 2>/dev/null
			;;
		esac
	done
}

# 复用兼容脚本的单次检查模式：发现 mark、发现链、幂等补规则都在里面。
ensure_now() {
	"$COMPAT" --once >/dev/null 2>&1
}

# nft monitor 的 stdout 在管道里可能是全缓冲，事件会被攒住。
# 有 stdbuf 就强制行缓冲，没有则退回裸 nft。
monitor_pipe() {
	if [ -n "${STDBUF:-}" ]; then
		stdbuf -oL nft monitor 2>/dev/null
	else
		nft monitor 2>/dev/null
	fi
}

# stdbuf 存在不等于可用：LD_PRELOAD 环境不对时它会静默吞掉子进程输出，
# 等于把事件流彻底断掉。所以先做一次真实功能自检，失败就退回裸 nft。
detect_stdbuf() {
	STDBUF=""
	command -v stdbuf >/dev/null 2>&1 || return 0
	printf 'ok\n' | stdbuf -oL cat 2>/dev/null | grep -q '^ok$' || return 0
	STDBUF=1
}

case "${1:-}" in
--help | -h)
	usage
	exit 0
	;;
--once | check)
	[ -x "$COMPAT" ] || {
		echo "找不到可执行的兼容脚本：$COMPAT" >&2
		exit 1
	}
	ensure_now
	exit $?
	;;
--test)
	command -v nft >/dev/null 2>&1 || {
		echo "找不到 nft" >&2
		exit 1
	}
	detect_stdbuf
	echo "监听 nftables 规则变更，Ctrl-C 结束。"
	echo "另开一个窗口重建 NetBird 规则，观察下面每行的时间戳与事件到达时间。"
	monitor_pipe | while IFS= read -r LINE; do
		printf '%s %s\n' "$(date '+%H:%M:%S')" "$LINE"
	done
	exit 0
	;;
"") ;;
*)
	usage >&2
	exit 1
	;;
esac

command -v nft >/dev/null 2>&1 || {
	log "找不到 nft 命令，无法使用事件驱动模式"
	exit 1
}

[ -x "$COMPAT" ] || {
	log "找不到可执行的兼容脚本：$COMPAT"
	exit 1
}

acquire_lock || {
	log "已有 watcher 实例在运行（$LOCK_DIR），本次退出"
	exit 0
}

kill_strays

trap on_term INT TERM
trap cleanup EXIT

STDBUF=""
detect_stdbuf

if [ -x /etc/init.d/netbird-passwall-compat ] &&
	/etc/init.d/netbird-passwall-compat status 2>/dev/null | grep -q running; then
	log "警告：netbird-passwall-compat 轮询服务仍在运行，它长期持有补丁锁，会导致事件补回无效；请先停止该服务"
fi

log "启动事件驱动守护：兜底 ${WATCHDOG}s，监听关键字 '${MATCH}'"

ensure_now
log "启动检查完成"

if [ "$WATCHDOG" -gt 0 ] 2>/dev/null; then
	(
		# 子 shell 不能继承 EXIT 清理，否则它退出时会误删主进程的锁。
		trap - EXIT INT TERM
		while :; do
			sleep "$WATCHDOG" || exit 0
			# 主进程被 SIGKILL 时 trap 不会执行（procd stop 超时就会走这条路），
			# 这个子 shell 会变成孤儿，继续每 WATCHDOG 秒重插一遍规则。
			# 累积几次就是好几个进程同时改 nft，所以每轮都要确认父进程还活着。
			kill -0 "$MAIN_PID" 2>/dev/null || exit 0
			ensure_now
		done
	) &
	WATCHDOG_PID=$!
fi

BACKOFF=1
FAILS=0

while :; do
	START=$(date +%s)

	# 事件循环：只有规则/链/表的变更加入，报文过境不产生事件，开销为零。
	# 自己插入的规则带 PW-NB-COMPAT 注释，必须过滤掉，否则会自己触发自己。
	#
	# 这段必须放到后台再用 wait 等：前台管道会让 shell 卡在等子进程上，
	# TERM 要等管道结束才处理，procd stop 会一直拖到超时再 SIGKILL。
	# wait 可以被信号打断，trap 立刻生效。
	monitor_pipe | (
		trap - EXIT INT TERM
		while IFS= read -r LINE; do
			case "$LINE" in
			*"$MATCH"*)
				case "$LINE" in
				*PW-NB-COMPAT*) ;;
				*) ensure_now ;;
				esac
				;;
			esac
		done
	) &
	PIPE_PID=$!
	wait "$PIPE_PID" 2>/dev/null
	PIPE_PID=""

	ELAPSED=$(($(date +%s) - START))

	# monitor 退出可能是 ENOBUFS 丢了事件，先全量校验一次再重连。
	ensure_now

	if [ "$ELAPSED" -ge 60 ]; then
		BACKOFF=1
		FAILS=0
		log "nft monitor 退出（运行 ${ELAPSED}s），已重新校验兼容规则，准备重连"
	else
		FAILS=$((FAILS + 1))
		if [ "$FAILS" -eq 3 ]; then
			log "nft monitor 连续快速退出 ${FAILS} 次，可能是内核或版本不支持；兜底检查仍在运行"
		fi
	fi

	# 退避同样用 wait 等后台 sleep，保证这段时间也能被信号打断。
	sleep "$BACKOFF" &
	wait $! 2>/dev/null
	BACKOFF=$((BACKOFF * 2))
	[ "$BACKOFF" -gt "$MAX_BACKOFF" ] && BACKOFF=$MAX_BACKOFF
done
