# luci-app-netbird-tools

NetBird 与 PassWall 共存的小工具集：一个事件驱动的规则守护 + 一个 LuCI 状态页。

适用于同时装了 **NetBird** 和 **PassWall** 的 OpenWrt。两个一起用时，PassWall 的
mark 豁免规则会被 NetBird 重建 prerouting 链时冲掉，导致 NetBird 的 `wt0` 流量
被 PassWall 抢进代理；这个包负责在规则被重建的瞬间把它补回去。

## 装了什么

| 路径 | 作用 |
|---|---|
| `/usr/bin/netbird-passwall-compat.sh` | 真正改规则：检查并插入 PassWall 的 mark 豁免（`--once` 跑一次） |
| `/usr/bin/netbird-passwall-compat-watch.sh` | 事件驱动守护：`nft monitor` 订阅规则变更，触发上一个脚本 |
| `/usr/bin/netbird-compat-ctl` | 命令行入口：状态、切换模式、改兜底间隔、手动补一次、重启 netbird、看日志 |
| `/etc/init.d/netbird-passwall-compat-watch` | procd 服务，默认不启动 |
| `/etc/config/netbird-passwall-compat` | 配置（首次运行 ctl 时创建） |
| LuCI 页面 | **VPN → NetBird 工具** |

页面和服务共用一份配置，不依赖 LuCI 才能工作。

## 装

编进固件：

```sh
CONFIG_PACKAGE_luci-app-netbird-tools=y
```

单独成包：

```sh
# 把本仓库放到 package/ 下，或
git clone https://github.com/alexzhong233/luci-app-netbird-tools package/luci-app-netbird-tools
make package/luci-app-netbird-tools/compile
```

包只依赖 `luci-base`。`nft` 由脚本运行时检测，缺失会明确报错而不是静默失败。

## 配置

```uci
config compat 'settings'
	option mode 'off'      # off（默认）| watch
	option watchdog '60'   # 兜底全量检查间隔，0 关闭
```

uci 路径：`netbird-passwall-compat.settings.mode`。

```sh
netbird-compat-ctl mode watch            # 启用事件守护
netbird-compat-ctl mode off              # 关掉
netbird-compat-ctl watchdog 60           # 兜底间隔
netbird-compat-ctl status                # 模式、进程数、wt0 规则数、兼容规则数
netbird-compat-ctl once                  # 手动补一次，不用开守护
netbird-compat-ctl netbird-restart       # 重建 wt0 转发规则
netbird-compat-ctl log                   # 最近日志
```

默认 `off`，什么都不会跑。

## 为什么需要它

PassWall 给 NetBird 的 `wt0` 做 mark 豁免，规则挂在
`netbird-mangle-prerouting` 链上。NetBird 每次重建链路都会重刷这条链，
PassWall 的豁免随之消失，于是 `wt0` 的流量被当成普通流量送进代理。

轮询方案（每 N 秒检查一次）能修，但中间那段窗口里连接已经走错路。本包改成
**事件驱动**：`nft monitor` 一看到相关链被改动就立刻补规则，另留一个周期兜底，
防止 netlink 缓冲溢出时丢事件。

## 两个已知边界

1. **`wt0` 的转发规则不归本包管**。那两条是 NetBird 运行时插进 `inet fw4` 的，
   `/etc/init.d/firewall restart` 会冲掉，恢复靠 `/etc/init.d/netbird restart`
   （页面上的「重建 wt0 转发」按钮）。
2. **不要把轮询服务一起开**。旧的轮询实现会在整个生命周期里持有同一把补丁锁，
   让事件守护的补回变成空操作。本包只提供事件守护这一种常驻方式。

## 许可证

MIT，见 [LICENSE](LICENSE)。
