# OpenWrt Tailscale LAN 一键部署

在 OpenWrt 安装 Tailscale，让**本机通过 `tailscale0` 使用 IPv4 / IPv6**，并按独立开关允许 LAN 设备访问 Tailnet。包含 LuCI **服务 → Tailscale**、`tslan` 命令行管理菜单和可选管理密码。

当前版本 **1.3.1**。默认 LAN IPv4 开启、LAN IPv6 关闭；两个 LAN 开关全部关闭时，本机双栈仍然可用。IPv6 隧道可经现有 IPv4 WAN 承载。脚本保留原 LAN/WAN IPv6 设置，不配置 RA/DHCPv6；主动开启 LAN IPv6 时，仅在 `tailscale0` 出口启用 IPv6 NAT。

已在 OpenWrt 23.05.5 测试实例验证安装、Web/命令行管理、密码保护，以及授权后的本机双栈 HTTP、LAN IPv4/IPv6 转发和四种开关组合。真实浏览器已验证自定义 Machine name 与本机/对端双栈地址复制。LAN 测试使用路由器上的隔离网络命名空间；本版整机重启及 flow offload 连接阻断仍待验证。详细范围见 [测试记录](docs/TESTING.md)。

v1.3.1 修复 v1.3.0 在实际固件上 Web 操作返回 `Unsupported action` 的问题：改用 `jsonfilter` 从标准输入读取请求，兼容该固件的 JSON 工具，同时避免密码出现在进程参数中。

## 一键安装

在 **OpenWrt 路由器的 SSH 终端**以 root 执行：

```sh
wget -O /tmp/tslan-install.sh https://raw.githubusercontent.com/Jk-z-Box/openwrt-tailscale-lan/v1.3.1/install.sh && sh /tmp/tslan-install.sh
```

也可以使用 curl：

```sh
curl -fL https://raw.githubusercontent.com/Jk-z-Box/openwrt-tailscale-lan/v1.3.1/install.sh -o /tmp/tslan-install.sh && sh /tmp/tslan-install.sh
```

脚本包含全部管理页和后端文件，不需要从第三方软件源安装 LuCI 插件。安装期间的 Tailscale、LuCI 及依赖来自路由器已配置的软件源；脚本不替换软件源，不跨固件安装内核模块，不关闭软件包签名校验，也不执行全系统软件包升级。

交互安装会询问是否显示 Web 菜单、是否设置管理密码。新安装默认 Web 显示、密码关闭；升级保留已有选择，已设密码时先验证当前密码。下载后执行的形式保留终端输入，请勿改成 `curl | sh`。

首次安装后：

1. 执行 `tslan` 打开命令行菜单，或打开 OpenWrt 后台，进入 **服务 → Tailscale**。若菜单尚未出现，刷新或重新登录 LuCI。
2. 点击 **登录 / 授权**，稍等状态刷新后打开登录链接，使用目标 Tailnet 的账户授权。若 Tailnet 启用了设备审批，还需管理员批准此路由器。
3. 从 LAN 电脑访问目标设备的 Tailscale IPv4 地址和实际服务端口，例如 `http://100.x.y.z:8080` 或 `ssh user@100.x.y.z`。
4. 在 OpenWrt 本机可以使用对端 IPv4 或 IPv6；例如 `ping -6 <对端Tailscale-IPv6>`，或 `curl -g 'http://[对端Tailscale-IPv6]:8080/'`（需相应命令已安装）。IPv6 URL 中的地址需要方括号。

**安装成功不等于账户已授权，也不等于目标设备端口可访问。** 目标设备必须在线、运行对应服务，并且 Tailnet ACL / Grants 与目标系统防火墙允许本路由器连接。

## 适用条件

- OpenWrt **23.05 及更新版本**，使用默认 **firewall4/nftables** 后端，支持 `opkg` 或 `apk`，使用 BusyBox ash。
- 至少 32 MiB 可写空闲空间（安装检查下限；实际需求取决于架构与已有组件），建议 128 MiB 以上内存。
- 已配置的固件软件源可访问，并提供 `tailscale`、LuCI 和所需依赖。兼容 OpenWrt 23.05.5 软件源中的 Tailscale 1.58.2；缺少 `timeout` 时自动安装 `coreutils-timeout`。
- 内核支持 IPv6 与 IPv6 策略路由；`net.ipv6.conf.all.disable_ipv6=0`，全局防火墙未禁用 IPv6。允许 `default.disable_ipv6=1` 和物理接口单独禁用 IPv6：脚本仅开启 `tailscale0`。
- LAN 设备到目标 `100.x` 地址的流量必须经过这台 OpenWrt。最常见情况是 OpenWrt 本身就是 LAN 默认网关。
- LAN IPv6 为显式开关，须满足下节的 IPv6 前置条件。远端主动访问本地 LAN、出口节点和 LAN MagicDNS 不在自动配置范围内。

如果系统以 `ipv6.disable=1` 或 `net.ipv6.conf.all.disable_ipv6=1` 全局禁用了 IPv6，脚本会在安装软件和修改配置前停止。直接写全局开关会改变所有接口，因此本项目不会自动执行该操作；需先按当前固件恢复内核 IPv6 能力，并按接口保留 LAN/WAN 的限制。这个检查也会在开机启动时再次执行。

本版已在 **OpenWrt 23.05.5 x86/64、Tailscale 1.58.2** 上验证本机双栈 HTTP、接入实际 LAN 桥的隔离客户端 IPv4 转发、临时隔离 LAN 的 IPv6 转发，以及 LAN 开关和管理密码。测试没有给原 LAN/WAN 添加 IPv6 地址，也没有启用 RA/DHCPv6；这些结果不能代替其他固件与网络拓扑的验收。

如果 OpenWrt 是旁路由，需要在实际主路由上添加静态路由：

```text
目标网络：100.64.0.0/10
下一跳：OpenWrt 的 LAN 地址
```

若该范围与已有运营商/VPN 路由冲突，可只为需要访问的设备添加 `/32` 路由。此脚本无法自动修改另一台主路由。安装成功后，默认使用目标设备的 `100.x` 地址；LAN 设备的 MagicDNS 名称解析需要另外配置。

## LAN 连通开关

| LAN IPv4 | LAN IPv6 | 行为 |
| --- | --- | --- |
| 开 | 关 | 默认：LAN 访问 Tailnet IPv4，本机双栈可用 |
| 关 | 关 | 仅保留 OpenWrt 本机双栈访问 |
| 关 | 开 | LAN 仅转发 IPv6，本机双栈可用 |
| 开 | 开 | LAN 两种协议都允许，本机双栈可用 |

开启某协议会允许**选定 LAN 所属防火墙区域**转发到 `tailscale0`。关闭后，fw4 的 forward 前置规则会丢弃该协议经 `tailscale0` 的转发，包括已有连接的后续数据包；防火墙重载会重建 fw4 flowtable。不会禁用系统全局转发，避免影响其他路由功能。

LAN IPv6 必须已经满足：

- 路由器对应 LAN 接口有 ULA 或全局 IPv6 地址，客户端也有可路由的 IPv6 地址（仅 `fe80::` 链路本地地址不够）。
- 客户端到 `fd7a:115c:a1e0::/48` 的路由经过此 OpenWrt，可使用已有 IPv6 默认路由或专门的静态路由。
- 系统已有 `net.ipv6.conf.all.forwarding=1`。脚本检查系统转发能力和 LAN 地址，缺失时拒绝开启并回滚；客户端路由需从客户端验证。

开启后，对 `tailscale0` 出口启用 NAT66，以本机 Tailscale IPv6 身份访问远端，无需额外向 Tailnet 发布 LAN IPv6 子网。关闭时移除该转发和 NAT66。本来仅使用 IPv4 的 LAN 不会因为打开开关就自动获得 IPv6；继续只需要本机 IPv6 时，保持 LAN IPv6 关闭即可。

这些开关控制内核转发。LAN 设备通过路由器上的应用代理访问远端时，代理重新发起的连接属于**本机流量**，不受 LAN 转发开关限制。

## 命令行管理与密码

```sh
tslan                     # 中文交互菜单
tslan status              # 状态、双栈检查、LAN 开关、密码状态
tslan start               # 启动；也支持 stop / restart / login / logout
tslan lan4 off            # 关闭 LAN IPv4，不影响本机
tslan lan6 on             # 检查 IPv6 条件后启用 LAN IPv6
tslan bypass on           # 绕过 PassWall2
tslan web off             # 隐藏菜单；tslan web on 恢复，不重启 Tailscale
tslan config              # 查看当前选项
tslan config hostname router-name
tslan config accept_routes 1
tslan passwd              # 设置或更改管理密码，隐藏输入并确认两次
tslan passwd off          # 验证当前密码后关闭密码保护
tslan report              # 查看具体配置修改
tslan uninstall           # 一键卸载；交互终端需确认
```

启用管理密码后，通过本项目进行的启停、登录/注销、配置修改、Web 菜单开关、密码变更、升级及卸载均需当前密码；每次提交独立验证。状态、诊断、报告、地址复制无需密码。Web 修改由后端校验，专用 ACL 不授予通用 UCI 写权限；页面不会先写配置再验证密码。

密码保存为随机盐的 PBKDF2-HMAC-SHA256 派生值（200,000 次，256 位，使用 `openssl-util`），保存在 root 专用、权限 `0600` 的 `/etc/tslan/password`，不保存明文。校验失败后短暂限制重复尝试。RPC 与后台作业之间使用 root 专用、一次性、30 秒有效的授权票据；密码不进入命令参数、UCI、报告或作业日志。使用 Web 密码时应通过可信 LAN 或 HTTPS 访问 LuCI。

开机和自动规则恢复只应用已保存设置，不要求交互密码。这是本项目管理入口的确认机制，**不是对 root 的权限隔离**：SSH root、具有系统管理权限的 LuCI 账户仍能直接编辑配置、调用系统服务或修改程序。隐藏菜单同样不构成权限隔离。忘记密码时，root 可删除 `/etc/tslan/password` 后运行 `tslan passwd` 重新设置。

自动化执行可通过标准输入提供密码：已启用时第一行是当前密码；设置/更改时接着提供新密码。不要把密码放在命令参数、URL、shell 历史或公开脚本中。交互执行优先使用隐藏输入。

## 安装检查与重复运行

```sh
# 刷新软件包索引并检查依赖，不安装软件、不修改服务配置
sh /tmp/tslan-install.sh --check

# LAN 逻辑接口不是 lan 时指定现有接口名称
sh /tmp/tslan-install.sh --lan-network home

# 安装时隐藏 Web 菜单并设置密码（按提示输入）
sh /tmp/tslan-install.sh --web off --password on

# 无交互：保留已有选择，新安装 Web 开启、密码关闭
sh /tmp/tslan-install.sh --non-interactive

# 重复运行会更新项目文件和托管规则，保留本项目已有选项
sh /tmp/tslan-install.sh
```

脚本会识别实际包管理器，检查源刷新错误、依赖可用性、存储空间、LAN 防火墙区域、未保存 UCI 配置和接口冲突。新版 `tailscale` 包已经包含守护进程；仅在缺少 `tailscaled` 时检查旧版拆分包。

项目独占 `network.tslan`、`network.tslan_device`、`firewall.tslan`、`firewall.tslan_lan`、`firewall.tslan_icmp6`、`firewall.tslan_no_forward6_in/out`、`firewall.tslan_lan6`、`firewall.tslan_gate`，重复执行不会增加重复规则。若其他插件或手动配置已把 `tailscale0` 绑定到另一接口/设备配置/区域，脚本会停止并给出冲突对象；请先迁移旧配置。它不会删除其他插件来强行安装。

从旧版升级：运行最新安装命令。保留登录身份、服务选项及 PassWall2 绕过设置；新增 LAN IPv4 默认开启、LAN IPv6 默认关闭。升级和网络配置应用会重启 Tailscale，隧道短暂中断；单独隐藏/显示 Web 菜单不重启服务。
v1.1.1 修复了实机发现的三项安装兼容问题：BusyBox 缺少 `timeout`、首次安装时 UCI 配置文件尚不存在，以及 Tailscale 1.58.2 的 `set` 子命令不支持 `--netfilter-mode`。对于最后一种情况，通过本机 Unix socket 的偏好接口仅修改 `NetfilterMode`，保留其他非托管选项；不会将完整偏好响应写入日志。

## LuCI 管理功能

- 查看连接状态、IPv4/IPv6、设备列表、操作日志和配置修改报告。本机和每台设备的 IPv4、IPv6 有独立复制按钮；无地址时不显示复制按钮，支持 HTTP 页面复制回退。
- 设备名优先取 Tailscale `DNSName` 的机器名部分，反映控制台自定义的 Machine name；无 DNSName 时回退到系统 HostName。显示更新时间取决于 Tailscale 状态同步，不额外存储管理 API token。
- 动态检查本机实际内核地址及到一个对端的每个地址族的有效路由。`OK` 表示本机地址和选中对端路由正确；`PENDING` 表示尚待登录/审批/对端信息；`ERROR` 表示缺少地址或路由未走 `tailscale0`。这些检查不代替实际端口和 ACL 测试。
- 启动、停止、重启、登录、注销、诊断。
- 配置服务启用状态、LAN IPv4/IPv6 独立开关、Web 菜单显示、设备名称、LAN 逻辑接口、远端子网路由、Tailscale DNS 和 Shields Up。
- 选项使用 **保存并应用**；启停按钮会立即改变启用状态，操作完成后刷新页面再编辑表单。
- `accept-dns` 默认关闭，避免接管路由器 DNS。开启只影响 Tailscale 客户端的 DNS 行为，不会自动为整个 LAN 添加 MagicDNS 转发。
- `accept-routes` 默认关闭；访问 Tailscale 设备自身的 `100.x` 和 `fd7a:115c:a1e0::` 地址不需要开启。

管理页复用 LuCI 登录和 rpcd 权限，不额外启动一个公开的 Web 管理端口。专用 RPC 仅允许固定操作，没有通用 `file.exec` 权限；用户配置使用独立参数传给 CLI。

## 与 PassWall2 本机代理共存

当 PassWall2 节点使用 Tailscale 地址，同时启用了「路由器本机代理」，Tailscale 自身的公网连接也可能被交给该节点，形成循环依赖。

在 **服务 → Tailscale** 勾选 **绕过 PassWall2 代理（防止回环）**，保存并应用即可。该功能支持 PassWall2 的 **nftables 后端**，默认关闭；需要系统已有 `nft` 命令。iptables 后端不在此功能支持范围内。

开启后的规则只作用于 `inet passwall2` 的 `mangle_output`、`nat_output`、`mangle_prerouting` 和 `dstnat` 链：

- 本机外连匹配 Tailscale 原有标记 `0x80000/0xff0000` 后提前返回，不改写标记；同时豁免经 `tailscale0` 输出的流量。
- 入站/转发处理豁免来自 `tailscale0` 的流量，以及目的地址为 `100.64.0.0/10`、`fd7a:115c:a1e0::/48` 的流量。这些地址将直接按内核路由处理，不再交给 PassWall2 分流。
- 原 OpenWrt 防火墙的访问限制仍然有效；此选项不会额外允许 Tailnet 主动访问 LAN，也不会打开 LAN IPv6 转发。
- 通过独立的 procd 服务每 **3 秒**检查一次规则顺序和数量，自动补回 PassWall2 重启、防火墙重载后缺失的规则。重载到下一次检查之间可能短暂中断，不保证无缝切换。
- 不修改 PassWall2 的程序文件、节点、分流配置或包标记；关闭选项、停止 Tailscale、卸载时只删除本项目带标识的规则并停止检查进程。

页面显示 `ACTIVE`（四个预期链均已处理）、`PENDING`（等待 PassWall2 nftables 链）、`ERROR`（更新失败或检查进程过期）或 `OFF`。公网出口和基础 DNS 必须能独立支持 Tailscale 建立连接；此选项不改系统 DNS，也不会强行绕过其他代理插件。

**使用 FakeDNS 时**，如果 Tailscale 控制域名被解析成 `198.18.x.x` 等虚拟地址，绕过代理后的连接可能无法访问这些地址。对于使用 Xray 分流节点的 PassWall2，可以在分流规则中新增高优先级规则 `domain:tailscale.com` 和 `domain:tailscale.io`，并在当前分流节点中将该规则指定为“直连”；保留全局 FakeDNS。这会影响该 PassWall2 DNS 服务中所有客户端对这些域名的解析和分流，且需要可用的直连 DNS 和公网出口。不同 DNS 后端、分流配置或 DERP 域名可能还需要额外处理。请先备份配置、检查 DNS 是否返回真实地址，并测试实际连接；项目的绕过开关不会自动创建此 PassWall2 规则。

命令行等效操作：

```sh
tslan bypass on
/usr/libexec/tslan-passwall2 status
```

关闭时运行 `tslan bypass off`。

## 具体修改了哪些配置

| 路径 / 对象 | 改动 |
| --- | --- |
| 软件包 | 按需安装 `tailscale ip-full luci rpcd uhttpd uhttpd-mod-ubus jshn jsonfilter curl openssl-util` 及其依赖；缺少 `timeout` 时追加 `coreutils-timeout`，旧版可能追加 `tailscaled` |
| `/etc/config/network` | 托管接口 `tslan`：协议 `none`、设备 `tailscale0`、`force_link=1`；托管设备 `tslan_device` 仅对 `tailscale0` 开启 IPv6 |
| `/etc/config/firewall` | 托管区域 `tslan`：IPv4/IPv6、输入拒绝、输出允许、区域内转发拒绝，开启 IPv4 NAT 与 MSS 修正；NAT66 跟随 LAN IPv6 开关 |
| `/etc/config/firewall` | 托管转发 `tslan_lan` / `tslan_lan6`：按 IPv4/IPv6 开关，选定 LAN 所属区域 → `tslan`；未启用的转发不创建 |
| `/etc/config/firewall` | `tslan_icmp6` 允许必要 ICMPv6 错误（含 Packet Too Big）；`tslan_no_forward6_out` 拒绝新建反向 IPv6 转发；LAN IPv6 关闭时保留 `tslan_no_forward6_in` |
| `/etc/tslan/forward.nft`、`firewall.tslan_gate` | 在 fw4 forward 链开头阻断已关闭协议的 Tailscale 转发，不涉及本机 output/input |
| `/usr/sbin/tslan` | 命令行菜单及快捷指令 |
| `/etc/tslan/password` | 可选密码的盐和派生值，root 专用，卸载时删除 |
| `tailscale0` 运行时 | 守护进程启动前准备持久 TUN，等待 netifd 就绪，仅设置该接口 `disable_ipv6=0`、`disable_policy=0`、`accept_ra=0`、`autoconf=0`；每次开机/启动重新应用 |
| `/etc/sysctl.d/99-tslan.conf` | 持久化 `net.ipv4.ip_forward=1` 并即时应用 |
| `/etc/config/tslan` | 保存本项目管理选项 |
| Tailscale 客户端偏好 | `netfilter-mode=off`，由 OpenWrt 管理防火墙；应用页面中的 DNS、路由、Shields Up 和非空设备名称 |
| `/etc/init.d/tslan` | 开机启动并恢复选项；保留软件包原有 `tailscale` init 文件，关闭其独立自启动，避免重复管理 |
| `/etc/init.d/tslan-bypass`、`/usr/libexec/tslan-passwall2` | 可选 PassWall2 防回环规则及每 3 秒检查；仅开关启用且 Tailscale 启用时运行 |
| `inet passwall2` 的四个代理基础链 | 开关启用时插入 `tslan-pw2-v1:*` 标识的提前返回规则，关闭时按规则句柄仅删除这些规则 |
| `/usr/lib/tslan/`、`/usr/libexec/tslan-control`、`/usr/libexec/tslan-check` | 配置、服务控制和只读双栈检查 |
| `/usr/libexec/rpcd/tslan`、`/usr/share/rpcd/acl.d/luci-app-tslan.json` | 专用 RPC 后端和访问权限 |
| `/usr/share/luci/menu.d/luci-app-tslan.json` | 「服务 → Tailscale」菜单，隐藏时移除，模板保存在 `/usr/share/tslan/menu.json` |
| `/www/luci-static/resources/view/tslan/settings.js` | LuCI 管理页 |
| `/usr/share/tslan/version` | 项目版本 |
| `/etc/tslan/` | 初始部署报告、当前报告、依赖清单、配置备份、启动日志和文件清单；仅 root 可读 |
| `/var/run/tslan/` | 临时操作日志、运行锁和退出状态 |

安装会重新加载 network/firewall，重启 Tailscale/rpcd，并启动/启用 LuCI 的 uhttpd。不改 LAN 地址、DHCP 范围或默认网关，也不添加 WAN 入站允许规则和端口转发。脚本不写全局/default/物理接口的 IPv6 sysctl；地址与 Tailnet 路由由 Tailscale 管理。防火墙授权以**源区域**为单位：与选定 LAN 处于同一区域的其他网络也会获得已启用协议的访问能力。

NAT 后，LAN 设备使用本路由器的 Tailscale 身份访问远端。远端看不到每台 LAN 设备的原始地址，因此 Tailnet 侧不能据此单独区分这些 LAN 客户端。

**已有 Tailscale 安装：** 本项目会接管上述受管理偏好和自启动方式；其他 Tailscale 偏好通常保留。但 `netfilter-mode=off` 会影响原先依赖 Tailscale 自动防火墙规则的子网/出口节点功能，请先迁移相关规则。本项目不会把已有复杂路由配置重置成默认值；登录时如 CLI 要求补齐旧选项，日志会保留错误，需按原配置处理。

报告可在管理页查看，也可执行：

```sh
cat /etc/tslan/install-report.txt
cat /etc/tslan/report.txt
cat /etc/tslan/packages-added
cat /etc/tslan/latest-backup
tslan diagnose
/usr/libexec/tslan-check
```

备份包含原始网络配置，可能有设备自身的敏感信息；不要把备份、Tailscale 状态文件或登录 URL 放到公开 Issue。

## 失败恢复与卸载

软件源或预检查失败会在修改配置前退出。配置阶段若防火墙校验或网络加载失败，会尝试恢复本轮安装前的 network/firewall、项目文件及 IPv4 转发设置；已经安装的软件包保留，避免错误移除共用依赖。实际断电/进程被强制杀死无法保证自动回滚。

守护进程启动失败、已连接但本机缺少某一地址族的地址，或到抽查对端的路由未走 `tailscale0` 时，会以非零状态退出，并保留管理页及 `/etc/tslan/startup.log` 供排查。未登录/未批准/没有对端时明确显示 `PENDING`，不会报告为双栈已验证。首次授权在浏览器中完成后，管理页会自动重新检查。

卸载本项目：

```sh
tslan uninstall
# 或 sh /tmp/tslan-install.sh --uninstall
```

卸载会停止 Tailscale、删除本项目的接口/设备/防火墙规则、管理页、管理密码及自启动配置，并删除带有 `tslan-managed` 标记的持久 TUN；保留安装的软件包、`/etc/tailscale/` 登录身份和 `/etc/tslan/` 备份。卸载不会恢复整个旧配置文件，因此不会覆盖部署后新增的无关配置。IPv4 转发作为路由器基础能力保持现状。

如之后独立使用 Tailscale，可启动原服务并按其 CLI 提示恢复原有选项：

```sh
/etc/init.d/tailscale start
tailscale up --netfilter-mode=on --accept-dns=false --accept-routes=false --shields-up=false
/etc/init.d/tailscale enable
```

上述选项对应本项目默认值；若曾启用其他选项，请补齐相应参数，避免改变原有意图。

系统固件升级后请重新运行安装脚本，确保软件包和自定义 LuCI 文件都已恢复。

## 开发与验证

```sh
python3 scripts/build.py
python3 -m unittest discover -s tests -v
node tests/test_ui.js
```

`files/` 是可审阅的源文件；`install.sh` 由模板和可重复构建的内嵌压缩包生成，内嵌 SHA-256 用于检测载荷损坏。仓库的 `SHA256SUMS` 记录最终安装脚本校验值。内部校验不是独立签名，下载来源仍需可信。

参考：

- [OpenWrt 软件包管理](https://openwrt.org/docs/guide-user/additional-software/managing_packages)
- [OpenWrt Tailscale 配置](https://openwrt.org/docs/guide-user/services/vpn/tailscale/start)
- [OpenWrt rpcd 插件接口](https://openwrt.org/docs/techref/rpcd)
- [Tailscale CLI](https://tailscale.com/kb/1080/cli)
- [Tailscale IPv6：可以通过 IPv4 网络承载](https://tailscale.com/docs/concepts/ipv6)
- [Tailscale Machine names](https://tailscale.com/docs/concepts/machine-names)
- [OpenWrt firewall4 规则模板](https://github.com/openwrt/firewall4/blob/master/root/usr/share/firewall4/templates/ruleset.uc)
- [Linux IPv6 sysctl](https://docs.kernel.org/networking/ip-sysctl.html)
