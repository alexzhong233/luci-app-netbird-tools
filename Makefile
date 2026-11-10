include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-netbird-tools
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=Alex Zhong <alexzhong233@users.noreply.github.com>

LUCI_TITLE:=NetBird 与 PassWall 共存：兼容规则守护与状态页
LUCI_DESCRIPTION:=事件驱动地补回 PassWall 的 mark 豁免规则，并在 LuCI 里查看 \
NetBird 状态、wt0 转发规则与守护进程状态。
LUCI_PKGARCH:=all
LUCI_DEPENDS:=+luci-base

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
