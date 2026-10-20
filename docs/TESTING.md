# 验证记录

版本：1.2.0。设备测试日期：2026-10-21（UTC+8）。

## 基础功能设备测试

以下基础验收在 v1.1.1 完成；v1.2.0 另外复测本机双栈、LAN 访问及服务恢复。整机重启结果对应 v1.1.1，新增绕过守护进程尚未另做整机重启测试。

环境：OpenWrt 23.05.5 r24106-10cc5fcd00，x86/64，Linux 5.15.167，fw4/nftables，固件软件源中的 Tailscale 1.58.2。WAN 使用 IPv4；物理接口仅保留原有 IPv6 链路本地地址。

- 软件源更新及签名检查通过；实际安装 `tailscale` 和 `coreutils-timeout`，其余依赖已存在。
- 首次安装成功，浏览器授权后进入 `Running`。设备上保留安装前配置备份和审计日志。
- 本机 `tailscale0` 实际具有 IPv4/IPv6 地址，两种地址族的有效对端路由均经过该接口。
- 普通 `curl --interface tailscale0` 分别访问两台在线 Linux 对端的 IPv4/IPv6 HTTP 服务，四次请求均返回 200。目标为 Tailscale PeerAPI 的 HTTP 根路径，未执行文件上传。
- 其中一台对端的普通 IPv4/IPv6 ping 各 3 次，均为 0% 丢包。另一台的 IPv4 ping 首轮未响应，因此不把 ICMP 成功作为所有服务的必要条件。
- 通过临时网络命名空间与 veth 接入实际 `br-lan`，客户端经路由器访问远端 IPv4 HTTP 返回 200；内核连接跟踪确认源地址转换为路由器的 Tailscale IPv4。此测试验证实际 LAN 桥入口、内核转发、NAT 和回包路径；未使用另一台物理 LAN 终端。
- 测试用命名空间、veth、单条 `/32` 返回路由及临时安装的 `kmod-veth` 已清理。
- 用户授权重启后，启动标识已变化，无需重新登录或手动启动，两种地址族的 HTTP 请求再次返回 200。
- 原有 network/firewall 配置（排除本项目新增对象）、DHCP、DNS、主路由表、全局/default/物理接口 IPv6 参数逐项对比一致。设备原有 IPv6 forwarding 值保持原样；本项目通过防火墙拒绝 `tailscale0` IPv6 转发。
- `fw4 check` 通过；实际规则包含 IPv4 LAN 转发/NAT、双栈本机流量、必要 ICMPv6 错误及 IPv6 转发拒绝，不启用 NAT66。
- LuCI JavaScript 静态资源返回 200，专用 rpcd 方法注册正常，实际状态 RPC 返回双栈检查结果。
- 通过管理页使用的同一 RPC 执行停止/启动：停止后启用选项为 0、守护进程退出；启动后选项恢复为 1，开机服务仍启用，IPv4/IPv6 HTTP 均返回 200。停止守护进程需要等待 procd 异步退出完成。

实机测试发现并修复：缺少 `timeout`、首次 UCI 配置文件创建，以及旧版 `tailscale set` 缺少 `--netfilter-mode`。后者通过 Unix socket 的局部偏好更新处理；已核实 netfilter 模式关闭，默认 DNS 和子网路由接管均关闭。

## v1.2.0 PassWall2 共存测试

同一台设备，PassWall2 25.1.1、Xray 24.12.18，启用「路由器本机代理」，使用已有的 Tailscale IPv4 地址 VMess 节点：

- 未启用绕过时，经 PassWall2 本地 SOCKS 入口发起的 HTTPS 请求出现 SSL 连接超时。
- 启用绕过后，同一节点、同一 HTTPS 目标返回 204；本机经 `tailscale0` 的 IPv4/IPv6 HTTP 均返回 200。
- 路由器本机普通 HTTPS 请求（不指定 SOCKS/HTTP 代理）也通过透明代理访问成功，外网出口与该 Tailscale 节点的 SOCKS 请求一致。
- PassWall2 重启后，10 条托管规则自动恢复；nftables 计数器确认实际命中 Tailscale 外层标记豁免及 `tailscale0` 豁免。
- 在 Tailscale 对端仍作为活动代理节点的情况下重启 Tailscale，等待其从 `NoState` 恢复到 `Running` 且实际对端 HTTP 可用后，代理 HTTPS 再次返回 204。重启后的首轮请求曾因隧道尚未就绪而超时，不保证即时恢复。
- 重载 OpenWrt 防火墙后，保护规则存在且代理 HTTPS 返回 204。
- 临时网络命名空间经 veth 接入实际 `br-lan`，没有安装 Tailscale，也没有设置应用层代理：透明代理 HTTPS 返回 200，外网出口与经该 Tailscale 节点的 SOCKS 请求一致；直接访问 Tailnet HTTP 同样返回 200。
- 关闭开关并应用后，全部 10 条托管规则及守护进程自启动均移除；重新开启后恢复，状态 RPC 返回 `ACTIVE`。
- network、firewall、dhcp、passwall2 配置，IPv4/IPv6 策略路由及 IPv4 主路由表与本次优化前一致；临时 veth、命名空间、测试路由及 `kmod-veth` 已清理。
- 测试后恢复原来的 PassWall2 节点选择，保留本机代理开启和新的绕过开关开启。

测试使用临时隔离客户端，尚未以另一台物理 LAN 终端验证。规则恢复由约 3 秒的检查完成，重载瞬间可能存在短暂窗口；基础 DNS 仍需支持 Tailscale 自身建立连接。

## 自动化检查

在隔离的临时目录中运行**实际安装脚本与服务控制脚本**，以状态化命令替身模拟 OpenWrt 的 UCI、软件包管理、Tailscale 和服务管理。原集成测试包含 25 个测试方法（部分覆盖多个故障场景），另有 7 个 PassWall2 规则测试，共 32 项：

- opkg 安装、apk 安装。
- 重复安装不增加重复防火墙转发。
- 软件源整体/部分失败时不开始安装和配置。
- 软件包不可用时提前退出。
- 已有 tailscale0 接口、未保存的 UCI 配置、其他安装进程锁的保护。
- 防火墙校验失败后恢复原 network/firewall 和托管文件。
- 拒绝设备名称中的 shell 命令替换字符。
- 登录、停止、启动及服务选项持久化。
- 守护进程配置失败时返回非零并保留报告。
- 卸载保留其他防火墙配置和 Tailscale 身份。
- 原 IPv4 托管区域升级为双栈，LAN 转发显式保留为 IPv4；添加 IPv6 转发拒绝与必要 ICMPv6 规则。
- `default.disable_ipv6=1` 时，在守护进程启动前仅开启 TUN 的 IPv6；全局/default/物理接口 sysctl 保持原值。
- 全局 IPv6 被禁用、内核缺少 IPv6、全局防火墙禁用 IPv6 时，在安装包和修改配置前报错。
- 检测“控制面分配了地址、内核未安装 IPv6 地址”及 IPv4/IPv6 实际路由走错接口。
- 未登录或无对端时报告待验证，不误报本机双栈已经通过。
- 模拟重启后 TUN 重建、重新应用配置、TUN 所有权冲突和卸载清理。
- 缺少 BusyBox `timeout` 时从当前软件源安装替代包。
- 旧版 CLI 通过局部偏好 API 设置 netfilter 模式，保留其他选项，不记录完整偏好响应。
- 本机偏好 API 失败时返回错误，不误报配置成功。
- PassWall2 绕过规则优先于代理规则、重复执行不重复插入；保留其他插件规则及原包标记。
- PassWall2 重建链或其他规则插入到前方时恢复保护顺序。
- 关闭开关或暂停服务时仅删除自己的规则。
- nft 事务失败时显示错误、保持原规则，后续重试恢复。
- PassWall2 未启动时等待；启动后补齐规则；检查进程状态过期时不显示成功。
- 非法开关值拒绝执行，不修改防火墙。

另外运行：

- ShellCheck 0.11.0 静态检查。
- 所有 shell 文件的语法检查、菜单与 ACL JSON 解析。
- LuCI JavaScript 渲染/表单验证/登录 URL 限制/刷新/保存应用测试。
- 可重复构建校验与内嵌载荷 SHA-256 校验。

## 尚未验证

- 其他 OpenWrt 版本、CPU 架构、apk 固件及 fw3/iptables 的实机行为。
- 在另一台物理 LAN 终端上的完整访问，以及旁路由场景下主路由静态路由配置。
- 任意业务服务、不同 Tailnet ACL/Grants、MTU 边界和复杂已有 Tailscale 配置。
- 真实浏览器中 LuCI 登录、所有按钮和表单的完整交互；前端已运行模拟测试，设备上已检查资源和 RPC。
- 实机卸载，以及 `default.disable_ipv6=1` 场景的实机启动（已由自动化测试覆盖）。
- 吞吐量、CPU/内存消耗、MTU、直接连接或 DERP 中继性能。

## 真机验收步骤

1. 运行 `sh /tmp/tslan-install.sh --check`，确认软件源检查通过。
2. 安装后检查 `/etc/tslan/install-report.txt` 和 `tailscale status`。
3. 在 LuCI「服务 → Tailscale」授权登录，确认节点处于 Running。
4. 在路由器运行 `/usr/libexec/tslan-check`；确认两个地址族的地址存在于 `tailscale0`，到被检查对端的有效路由也经过 `tailscale0`。检查 `ip -4 addr show dev tailscale0`、`ip -6 addr show dev tailscale0` 与 `ip -4/-6 route get <对端地址>`。
5. 在一台**未安装 Tailscale**、以 OpenWrt 为网关的 LAN 设备上连接远端实际服务，例如 SSH 或 HTTP。此步才验证 LAN 转发和 NAT。
6. 检查目标端 ACL/防火墙；ping 被禁不代表 TCP 服务不可访问。
7. 通过管理页测试关闭、开启和修改设备名，再重启路由器复测。
8. 如需卸载，运行安装脚本的 `--uninstall`，检查其他网络配置保持正常。

本机双栈还需要以下真机验收：

1. 安装前保存 `uci export network`、`uci export dhcp`、`ip -4 route show table main`、`ip -6 route show table main`、DNS 配置，以及 `/proc/sys/net/ipv6/conf/` 中全局/default/各物理接口的值。备份仅保存在设备本地。
2. 确认 WAN 仅有 IPv4。分别用普通 `ping -4/-6` 或 HTTP/SSH 客户端访问对端的两类 Tailscale 地址；目标服务必须支持相应地址族。只执行 `tailscale ping` 不足以证明主机内核数据路径正常。
3. 查看 `nft list ruleset`（fw4）或 `ip6tables-save`（fw3），确认本机输出、回包、必要 ICMPv6 正常，未允许 LAN IPv6 转发及 NAT66。
4. 对比原 LAN/WAN、DHCP/DNS、默认路由和物理接口 IPv6 参数；允许新增本项目托管对象及 Tailscale 专属地址/路由。
5. 重启路由器并重复两个地址族的实际服务访问。再测试停止/启动，以及默认禁止新接口 IPv6 的场景。

上方记录了本次设备测试实际完成的部分；其余步骤仍适用于新设备验收，模拟测试不能替代对应实机结果。

请在 Issue 中附 OpenWrt 版本、CPU 架构、主路由/旁路由拓扑、失败步骤和脱敏错误日志。
