#!/bin/sh
# 把 luci-app-netbird-tools 的文件从 GitHub 拉到路由器上，不重刷固件就能用。
#
# 用法（两条任选，哪条通走哪条）：
#   curl -fsSL https://raw.githubusercontent.com/alexzhong233/luci-app-netbird-tools/main/deploy.sh | sh
#   curl -fsSL https://cdn.jsdelivr.net/gh/alexzhong233/luci-app-netbird-tools@main/deploy.sh | sh
#
# 也可以先下载再看：
#   curl -fsSL -o /tmp/d.sh https://cdn.jsdelivr.net/gh/alexzhong233/luci-app-netbird-tools@main/deploy.sh && sh /tmp/d.sh
#
# 幂等：重复执行就是覆盖同一批文件。刷机后 overlay 被清空，重跑一次即可。
# 装完不会自动启动守护，模式仍是 off，要启用执行：
#   netbird-compat-ctl mode watch

REPO="alexzhong233/luci-app-netbird-tools"
BRANCH="main"

RAW="https://raw.githubusercontent.com/$REPO/$BRANCH"
CDN="https://cdn.jsdelivr.net/gh/$REPO@$BRANCH"

TMP="/tmp/netbird-tools-deploy.$$"
mkdir -p "$TMP" || exit 1
trap 'rm -rf "$TMP"' EXIT

log() { echo "== $*"; }
die() { echo "!! $*" >&2; exit 1; }

fetch() {
	# $1 = 仓库内路径，$2 = 本地临时文件名
	local rel="$1" out="$2"

	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 10 --max-time 60 -o "$out" "$RAW/$rel" && return 0
		log "raw.githubusercontent.com 拉取失败，换 jsDelivr"
		curl -fsSL --connect-timeout 10 --max-time 60 -o "$out" "$CDN/$rel" && return 0
	elif command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -O "$out" "$RAW/$rel" && return 0
		log "raw.githubusercontent.com 拉取失败，换 jsDelivr"
		uclient-fetch -q -O "$out" "$CDN/$rel" && return 0
	else
		die "没有 curl 或 uclient-fetch，装一个：apk add curl"
	fi

	return 1
}

install_file() {
	# $1 = 仓库内路径，$2 = 目标路径，$3 = 权限
	local rel="$1" dst="$2" mode="$3" base

	base=$(basename "$rel")
	log "下载 $base"
	fetch "$rel" "$TMP/$base" || die "$rel 下载失败（两条线路都不通）"

	# 拉回来的东西一定得是个真文件：404 页面、占位文件都可能只有几十字节，
	# 直接铺上去会留下一个坏脚本。
	[ -s "$TMP/$base" ] || die "$rel 内容为空"
	[ "$(wc -c <"$TMP/$base")" -gt 100 ] || die "$rel 只有 $(wc -c <"$TMP/$base") 字节，不像正常内容"

	mkdir -p "$(dirname "$dst")" || die "无法创建 $(dirname "$dst")"
	cp -f "$TMP/$base" "$dst" || die "写入 $dst 失败"
	chmod "$mode" "$dst"
	echo "   -> $dst ($(wc -c <"$dst") 字节)"
}

install_file "root/usr/bin/netbird-passwall-compat.sh" \
	"/usr/bin/netbird-passwall-compat.sh" 0755
install_file "root/usr/bin/netbird-passwall-compat-watch.sh" \
	"/usr/bin/netbird-passwall-compat-watch.sh" 0755
install_file "root/usr/bin/netbird-compat-ctl" \
	"/usr/bin/netbird-compat-ctl" 0755
install_file "root/etc/init.d/netbird-passwall-compat-watch" \
	"/etc/init.d/netbird-passwall-compat-watch" 0755
install_file "root/usr/share/luci/menu.d/luci-app-netbird-tools.json" \
	"/usr/share/luci/menu.d/luci-app-netbird-tools.json" 0644
install_file "root/usr/share/rpcd/acl.d/luci-app-netbird-tools.json" \
	"/usr/share/rpcd/acl.d/luci-app-netbird-tools.json" 0644
install_file "htdocs/luci-static/resources/view/netbird-tools/status.js" \
	"/www/luci-static/resources/view/netbird-tools/status.js" 0644

log "重启 rpcd 并清 LuCI 缓存"
/etc/init.d/rpcd restart >/dev/null 2>&1
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null

log "自检"
/usr/bin/netbird-compat-ctl status 2>/dev/null | head -n 12 || true

cat <<'EOF'

装好了。浏览器 Ctrl+Shift+R（Mac 是 Cmd+Shift+R）强刷，左侧菜单：
  VPN → NetBird 工具

守护默认不启动（mode=off），要启用：
  netbird-compat-ctl mode watch

前提：这台机器上装了 netbird 和 passwall。只看状态不用开守护。
EOF
