# OpenWrt Tailscale LAN 一键部署

在 OpenWrt 上安装 Tailscale，使 **OpenWrt 本机通过 `tailscale0` 使用 IPv4 / IPv6**；同时自动配置 IPv4 转发和 NAT，使 LAN 设备无需安装 Tailscale，就能访问 Tailnet 内其他设备的 `100.x.y.z` 地址。附带 LuCI **服务 → Tailscale** 管理页。

IPv6 用于本机访问对端的 `fd7a:115c:a1e0::/48` 地址，可通过现有 IPv4 WAN 承载。脚本保留原有 LAN/WAN IPv6 设置，不配置 LAN RA/DHCPv6、不开启 IPv6 转发和 NAT66。

## 一键安装

在 **OpenWrt 路由器的 SSH 终端**以 root 执行：

```sh
wget -O /tmp/tslan-install.sh https://raw.githubusercontent.com/Jk-z-Box/openwrt-tailscale-lan/v1.1.1/install.sh && sh /tmp/tslan-install.sh
```

也可以使用 curl：

```sh
curl -fL https://raw.githubusercontent.com/Jk-z-Box/openwrt-tailscale-lan/v1.1.1/install.sh -o /tmp/tslan-install.sh && sh /tmp/tslan-install.sh
```

脚本包含全部管理页和后端文件，不需要从第三方软件源安装 LuCI 插件。安装期间的 Tailscale、LuCI 及依赖来自路由器已配置的软件源；脚本不替换软件源，不跨固件安装内核模块，不关闭软件包签名校验，也不执行全系统软件包升级。

首次安装后：

1. 打开 OpenWrt 后台，进入 **服务 → Tailscale**。若菜单尚未出现，刷新或重新登录 LuCI。
2. 点击 **登录 / 授权**，稍等状态刷新后打开登录链接，使用目标 Tailnet 的账户授权。若 Tailnet 启用了设备审批，还需管理员批准此路由器。
3. 从 LAN 电脑访问目标设备的 Tailscale IPv4 地址和实际服务端口，例如 `http://100.x.y.z:8080` 或 `ssh user@100.x.y.z`。
4. 在 OpenWrt 本机可以使用对端 IPv4 或 IPv6；例如 `ping -6 <对端Tailscale-IPv6>`，或 `curl -g 'http://[对端Tailscale-IPv6]:8080/'`（需相应命令已安装）。IPv6 URL 中的地址需要方括号。

**安装成功不等于账户已授权，也不等于目标设备端口可访问。** 目标设备必须在线、运行对应服务，并且 Tailnet ACL / Grants 与目标系统防火墙允许本路由器连接。

## 适用条件

- OpenWrt **23.05 及更新版本**，支持 `opkg` 或 `apk`，使用 BusyBox ash。
- 至少 32 MiB 可写空闲空间（安装检查下限；实际需求取决于架构与已有组件），建议 128 MiB 以上内存。
- 已配置的固件软件源可访问，并提供 `tailscale`、LuCI 和所需依赖。兼容 OpenWrt 23.05.5 软件源中的 Tailscale 1.58.2；缺少 `timeout` 时自动安装 `coreutils-timeout`。
- 内核支持 IPv6 与 IPv6 策略路由；`net.ipv6.conf.all.disable_ipv6=0`，全局防火墙未禁用 IPv6。允许 `default.disable_ipv6=1` 和物理接口单独禁用 IPv6：脚本仅开启 `tailscale0`。
- LAN 设备到目标 `100.x` 地址的流量必须经过这台 OpenWrt。最常见情况是 OpenWrt 本身就是 LAN 默认网关。
- 本机支持 Tailscale IPv4/IPv6，LAN 自动转发仅限 IPv4。LAN IPv6、远端主动访问本地 LAN、出口节点和 LAN MagicDNS 不在自动配置范围内。

如果系统以 `ipv6.disable=1` 或 `net.ipv6.conf.all.disable_ipv6=1` 全局禁用了 IPv6，脚本会在安装软件和修改配置前停止。直接写全局开关会改变所有接口，因此本项目不会自动执行该操作；需先按当前固件恢复内核 IPv6 能力，并按接口保留 LAN/WAN 的限制。这个检查也会在开机启动时再次执行。

已在 **OpenWrt 23.05.5 x86/64、Tailscale 1.58.2** 设备上验证本机双栈 HTTP、接入 LAN 桥的隔离客户端 IPv4 转发/NAT、重启自动恢复，以及原有网络配置保持一致。另有 25 项集成测试、ShellCheck 和 LuCI 前端检查。其他固件和架构仍需各自验收，详见 [测试记录](docs/TESTING.md)。

如果 OpenWrt 是旁路由，需要在实际主路由上添加静态路由：

```text
目标网络：100.64.0.0/10
下一跳：OpenWrt 的 LAN 地址
```

若该范围与已有运营商/VPN 路由冲突，可只为需要访问的设备添加 `/32` 路由。此脚本无法自动修改另一台主路由。安装成功后，默认使用目标设备的 `100.x` 地址；LAN 设备的 MagicDNS 名称解析需要另外配置。

## 安装检查与重复运行

```sh
# 刷新软件包索引并检查依赖，不安装软件、不修改服务配置
sh /tmp/tslan-install.sh --check

# LAN 逻辑接口不是 lan 时指定现有接口名称
sh /tmp/tslan-install.sh --lan-network home

# 重复运行会更新项目文件和托管规则，保留本项目已有选项
sh /tmp/tslan-install.sh
```

脚本会识别实际包管理器，检查源刷新错误、依赖可用性、存储空间、LAN 防火墙区域、未保存 UCI 配置和接口冲突。新版 `tailscale` 包已经包含守护进程；仅在缺少 `tailscaled` 时检查旧版拆分包。

项目独占 `network.tslan`、`network.tslan_device`、`firewall.tslan`、`firewall.tslan_lan`、`firewall.tslan_icmp6`、`firewall.tslan_no_forward6_in/out`，重复执行不会增加重复规则。若其他插件或手动配置已把 `tailscale0` 绑定到另一接口/设备配置/区域，脚本会停止并给出冲突对象；请先迁移旧配置。它不会删除其他插件来强行安装。

从 v1.0.0 / v1.1.0 升级：执行上面的 v1.1.1 命令即可。原有服务选项和登录身份保留，托管防火墙区域升级为双栈，LAN 转发显式限定为 IPv4。升级和应用配置会重启 Tailscale，期间隧道连接会短暂中断。

v1.1.1 修复了实机发现的三项安装兼容问题：BusyBox 缺少 `timeout`、首次安装时 UCI 配置文件尚不存在，以及 Tailscale 1.58.2 的 `set` 子命令不支持 `--netfilter-mode`。对于最后一种情况，通过本机 Unix socket 的偏好接口仅修改 `NetfilterMode`，保留其他非托管选项；不会将完整偏好响应写入日志。

## LuCI 管理功能

- 查看连接状态、分别显示 Tailscale IPv4/IPv6、设备列表、操作日志和配置修改报告。
- 动态检查本机实际内核地址及到一个对端的每个地址族的有效路由。`OK` 表示本机地址和选中对端路由正确；`PENDING` 表示尚待登录/审批/对端信息；`ERROR` 表示缺少地址或路由未走 `tailscale0`。这些检查不代替实际端口和 ACL 测试。
- 启动、停止、重启、登录、注销、诊断。
- 配置服务启用状态、设备名称、LAN 逻辑接口、远端子网路由、Tailscale DNS 和 Shields Up。
- 选项使用 **保存并应用**；启停按钮会立即改变启用状态，操作完成后刷新页面再编辑表单。
- `accept-dns` 默认关闭，避免接管路由器 DNS。开启只影响 Tailscale 客户端的 DNS 行为，不会自动为整个 LAN 添加 MagicDNS 转发。
- `accept-routes` 默认关闭；访问 Tailscale 设备自身的 `100.x` 和 `fd7a:115c:a1e0::` 地址不需要开启。

管理页复用 LuCI 登录和 rpcd 权限，不额外启动一个公开的 Web 管理端口。专用 RPC 仅允许固定操作，没有通用 `file.exec` 权限；用户配置使用独立参数传给 CLI。

## 具体修改了哪些配置

| 路径 / 对象 | 改动 |
| --- | --- |
| 软件包 | 按需安装 `tailscale ip-full luci rpcd uhttpd uhttpd-mod-ubus jshn jsonfilter curl` 及其依赖；缺少 `timeout` 时追加 `coreutils-timeout`，旧版可能追加 `tailscaled` |
| `/etc/config/network` | 托管接口 `tslan`：协议 `none`、设备 `tailscale0`、`force_link=1`；托管设备 `tslan_device` 仅对 `tailscale0` 开启 IPv6 |
| `/etc/config/firewall` | 托管区域 `tslan`：IPv4/IPv6、输入拒绝、输出允许、区域内转发拒绝，开启 IPv4 NAT 与 MSS 修正，关闭 NAT66 |
| `/etc/config/firewall` | 托管转发 `tslan_lan`：仅 IPv4，选定 LAN 所属区域 → `tslan`；返回流量通过已有连接跟踪规则 |
| `/etc/config/firewall` | `tslan_icmp6` 允许必要 ICMPv6 错误（含 Packet Too Big）；`tslan_no_forward6_in/out` 拒绝经过 `tailscale0` 的 IPv6 转发 |
| `tailscale0` 运行时 | 守护进程启动前准备持久 TUN，等待 netifd 就绪，仅设置该接口 `disable_ipv6=0`、`disable_policy=0`、`accept_ra=0`、`autoconf=0`；每次开机/启动重新应用 |
| `/etc/sysctl.d/99-tslan.conf` | 持久化 `net.ipv4.ip_forward=1` 并即时应用 |
| `/etc/config/tslan` | 保存本项目管理选项 |
| Tailscale 客户端偏好 | `netfilter-mode=off`，由 OpenWrt 管理防火墙；应用页面中的 DNS、路由、Shields Up 和非空设备名称 |
| `/etc/init.d/tslan` | 开机启动并恢复选项；保留软件包原有 `tailscale` init 文件，关闭其独立自启动，避免重复管理 |
| `/usr/lib/tslan/`、`/usr/libexec/tslan-control`、`/usr/libexec/tslan-check` | 配置、服务控制和只读双栈检查 |
| `/usr/libexec/rpcd/tslan`、`/usr/share/rpcd/acl.d/luci-app-tslan.json` | 专用 RPC 后端和访问权限 |
| `/usr/share/luci/menu.d/luci-app-tslan.json` | 「服务 → Tailscale」菜单 |
| `/www/luci-static/resources/view/tslan/settings.js` | LuCI 管理页 |
| `/usr/share/tslan/version` | 项目版本 |
| `/etc/tslan/` | 初始部署报告、当前报告、依赖清单、配置备份、启动日志和文件清单；仅 root 可读 |
| `/var/run/tslan/` | 临时操作日志、运行锁和退出状态 |

安装会重新加载 network/firewall，重启 Tailscale/rpcd，并启动/启用 LuCI 的 uhttpd。不改 LAN 地址、DHCP 范围或默认网关，也不添加 WAN 入站允许规则和端口转发。脚本不写全局/default/物理接口的 IPv6 sysctl；地址与 Tailnet 路由由 Tailscale 管理。防火墙授权以**源区域**为单位：与选定 LAN 处于同一区域的其他网络也会获得 IPv4 访问能力。

NAT 后，LAN 设备使用本路由器的 Tailscale 身份访问远端。远端看不到每台 LAN 设备的原始地址，因此 Tailnet 侧不能据此单独区分这些 LAN 客户端。

**已有 Tailscale 安装：** 本项目会接管上述受管理偏好和自启动方式；其他 Tailscale 偏好通常保留。但 `netfilter-mode=off` 会影响原先依赖 Tailscale 自动防火墙规则的子网/出口节点功能，请先迁移相关规则。本项目不会把已有复杂路由配置重置成默认值；登录时如 CLI 要求补齐旧选项，日志会保留错误，需按原配置处理。

报告可在管理页查看，也可执行：

```sh
cat /etc/tslan/install-report.txt
cat /etc/tslan/report.txt
cat /etc/tslan/packages-added
cat /etc/tslan/latest-backup
/usr/libexec/tslan-control diagnose
/usr/libexec/tslan-check
```

备份包含原始网络配置，可能有设备自身的敏感信息；不要把备份、Tailscale 状态文件或登录 URL 放到公开 Issue。

## 失败恢复与卸载

软件源或预检查失败会在修改配置前退出。配置阶段若防火墙校验或网络加载失败，会尝试恢复本轮安装前的 network/firewall、项目文件及 IPv4 转发设置；已经安装的软件包保留，避免错误移除共用依赖。实际断电/进程被强制杀死无法保证自动回滚。

守护进程启动失败、已连接但本机缺少某一地址族的地址，或到抽查对端的路由未走 `tailscale0` 时，会以非零状态退出，并保留管理页及 `/etc/tslan/startup.log` 供排查。未登录/未批准/没有对端时明确显示 `PENDING`，不会报告为双栈已验证。首次授权在浏览器中完成后，管理页会自动重新检查。

卸载本项目：

```sh
sh /tmp/tslan-install.sh --uninstall
```

卸载会停止 Tailscale、删除本项目的接口/设备/防火墙规则、管理页及自启动配置，并删除带有 `tslan-managed` 标记的持久 TUN；保留安装的软件包、`/etc/tailscale/` 登录身份和 `/etc/tslan/` 备份。卸载不会恢复整个旧配置文件，因此不会覆盖部署后新增的无关配置。IPv4 转发作为路由器基础能力保持现状。

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
- [Linux IPv6 sysctl](https://docs.kernel.org/networking/ip-sysctl.html)
