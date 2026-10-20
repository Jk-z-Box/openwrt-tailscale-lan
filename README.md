# OpenWrt Tailscale LAN 一键部署

在 OpenWrt 上安装 Tailscale，自动配置 IPv4 转发、接口、防火墙和 NAT，使 LAN 设备无需安装 Tailscale，就能访问 Tailnet 内其他设备的 `100.x.y.z` 地址。附带 LuCI **服务 → Tailscale** 管理页。

## 一键安装

在 **OpenWrt 路由器的 SSH 终端**以 root 执行：

```sh
wget -O /tmp/tslan-install.sh https://raw.githubusercontent.com/Jk-z-Box/openwrt-tailscale-lan/v1.0.0/install.sh && sh /tmp/tslan-install.sh
```

也可以使用 curl：

```sh
curl -fL https://raw.githubusercontent.com/Jk-z-Box/openwrt-tailscale-lan/v1.0.0/install.sh -o /tmp/tslan-install.sh && sh /tmp/tslan-install.sh
```

脚本包含全部管理页和后端文件，不需要从第三方软件源安装 LuCI 插件。安装期间的 Tailscale、LuCI 及依赖来自路由器已配置的软件源；脚本不替换软件源，不跨固件安装内核模块，不关闭软件包签名校验，也不执行全系统软件包升级。

首次安装后：

1. 打开 OpenWrt 后台，进入 **服务 → Tailscale**。若菜单尚未出现，刷新或重新登录 LuCI。
2. 点击 **登录 / 授权**，稍等状态刷新后打开登录链接，使用目标 Tailnet 的账户授权。若 Tailnet 启用了设备审批，还需管理员批准此路由器。
3. 从 LAN 电脑访问目标设备的 Tailscale IPv4 地址和实际服务端口，例如 `http://100.x.y.z:8080` 或 `ssh user@100.x.y.z`。

**安装成功不等于账户已授权，也不等于目标设备端口可访问。** 目标设备必须在线、运行对应服务，并且 Tailnet ACL / Grants 与目标系统防火墙允许本路由器连接。

## 适用条件

- OpenWrt **23.05 及更新版本**，支持 `opkg` 或 `apk`，使用 BusyBox ash。
- 至少 32 MiB 可写空闲空间（安装检查下限；实际需求取决于架构与已有组件），建议 128 MiB 以上内存。
- 已配置的固件软件源可访问，并提供 `tailscale`、LuCI 和所需依赖。Tailscale 必须支持 `tailscale set --netfilter-mode`。
- LAN 设备到目标 `100.x` 地址的流量必须经过这台 OpenWrt。最常见情况是 OpenWrt 本身就是 LAN 默认网关。
- 这个版本配置 **IPv4**。通过 IPv6 地址访问、远端主动访问本地 LAN、出口节点和 LAN MagicDNS 不在自动配置范围内。

本项目目前完成了状态化 OpenWrt 命令模拟测试、ShellCheck 和 LuCI 前端检查，**尚未在真实 OpenWrt 路由器上完成端到端验证**。详见 [测试记录](docs/TESTING.md)。

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

项目独占 `network.tslan`、`firewall.tslan` 和 `firewall.tslan_lan`，重复执行不会增加重复规则。若其他插件或手动配置已把 `tailscale0` 绑定到另一接口/区域，脚本会停止并给出冲突对象；请先迁移旧配置。它不会删除其他插件来强行安装。

## LuCI 管理功能

- 查看连接状态、Tailscale IP、设备列表、操作日志和配置修改报告。
- 启动、停止、重启、登录、注销、诊断。
- 配置服务启用状态、设备名称、LAN 逻辑接口、远端子网路由、Tailscale DNS 和 Shields Up。
- 选项使用 **保存并应用**；启停按钮会立即改变启用状态，操作完成后刷新页面再编辑表单。
- `accept-dns` 默认关闭，避免接管路由器 DNS。开启只影响 Tailscale 客户端的 DNS 行为，不会自动为整个 LAN 添加 MagicDNS 转发。
- `accept-routes` 默认关闭；只访问 Tailscale 设备自身的 `100.x` 地址不需要开启。

管理页复用 LuCI 登录和 rpcd 权限，不额外启动一个公开的 Web 管理端口。专用 RPC 仅允许固定操作，没有通用 `file.exec` 权限；用户配置使用独立参数传给 CLI。

## 具体修改了哪些配置

| 路径 / 对象 | 改动 |
| --- | --- |
| 软件包 | 按需安装 `tailscale luci rpcd uhttpd uhttpd-mod-ubus jshn jsonfilter` 及其依赖；旧版可能追加 `tailscaled` |
| `/etc/config/network` | 新建/更新托管接口 `tslan`，协议 `none`，设备 `tailscale0` |
| `/etc/config/firewall` | 托管区域 `tslan`：IPv4、输入拒绝、输出允许、区域内转发拒绝，开启 NAT 与 MSS 修正 |
| `/etc/config/firewall` | 托管转发 `tslan_lan`：选定 LAN 所属区域 → `tslan`；返回流量通过已有连接跟踪规则 |
| `/etc/sysctl.d/99-tslan.conf` | 持久化 `net.ipv4.ip_forward=1` 并即时应用 |
| `/etc/config/tslan` | 保存本项目管理选项 |
| Tailscale 客户端偏好 | `netfilter-mode=off`，由 OpenWrt 管理防火墙；应用页面中的 DNS、路由、Shields Up 和非空设备名称 |
| `/etc/init.d/tslan` | 开机启动并恢复选项；保留软件包原有 `tailscale` init 文件，关闭其独立自启动，避免重复管理 |
| `/usr/lib/tslan/`、`/usr/libexec/tslan-control` | 配置和服务控制逻辑 |
| `/usr/libexec/rpcd/tslan`、`/usr/share/rpcd/acl.d/luci-app-tslan.json` | 专用 RPC 后端和访问权限 |
| `/usr/share/luci/menu.d/luci-app-tslan.json` | 「服务 → Tailscale」菜单 |
| `/www/luci-static/resources/view/tslan/settings.js` | LuCI 管理页 |
| `/usr/share/tslan/version` | 项目版本 |
| `/etc/tslan/` | 初始部署报告、当前报告、依赖清单、配置备份、启动日志和文件清单；仅 root 可读 |
| `/var/run/tslan/` | 临时操作日志、运行锁和退出状态 |

安装会重新加载 network/firewall，重启 rpcd，并启动/启用 LuCI 的 uhttpd。不改 LAN 地址、DHCP 范围或默认网关，也不添加 WAN 入站允许规则和端口转发。防火墙授权以**源区域**为单位：与选定 LAN 处于同一区域的其他网络也会获得访问能力。

NAT 后，LAN 设备使用本路由器的 Tailscale 身份访问远端。远端看不到每台 LAN 设备的原始地址，因此 Tailnet 侧不能据此单独区分这些 LAN 客户端。

**已有 Tailscale 安装：** 本项目会接管上述受管理偏好和自启动方式；其他 Tailscale 偏好通常保留。但 `netfilter-mode=off` 会影响原先依赖 Tailscale 自动防火墙规则的子网/出口节点功能，请先迁移相关规则。本项目不会把已有复杂路由配置重置成默认值；登录时如 CLI 要求补齐旧选项，日志会保留错误，需按原配置处理。

报告可在管理页查看，也可执行：

```sh
cat /etc/tslan/install-report.txt
cat /etc/tslan/report.txt
cat /etc/tslan/packages-added
cat /etc/tslan/latest-backup
/usr/libexec/tslan-control diagnose
```

备份包含原始网络配置，可能有设备自身的敏感信息；不要把备份、Tailscale 状态文件或登录 URL 放到公开 Issue。

## 失败恢复与卸载

软件源或预检查失败会在修改配置前退出。配置阶段若防火墙校验或网络加载失败，会尝试恢复本轮安装前的 network/firewall、项目文件及 IPv4 转发设置；已经安装的软件包保留，避免错误移除共用依赖。实际断电/进程被强制杀死无法保证自动回滚。

守护进程启动失败时会以非零状态退出，并保留管理页及 `/etc/tslan/startup.log` 供排查。不会把未连接状态报告为“已打通 LAN”。

卸载本项目：

```sh
sh /tmp/tslan-install.sh --uninstall
```

卸载会停止 Tailscale、删除本项目的接口/防火墙规则、管理页及自启动配置；保留安装的软件包、`/etc/tailscale/` 登录身份和 `/etc/tslan/` 备份。卸载不会恢复整个旧配置文件，因此不会覆盖部署后新增的无关配置。IPv4 转发作为路由器基础能力保持现状。

如之后独立使用 Tailscale，可执行：

```sh
/etc/init.d/tailscale start
tailscale set --netfilter-mode=on
tailscale up
/etc/init.d/tailscale enable
```

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
