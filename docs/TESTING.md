# 验证记录

当前版本：1.3.3。本次设备测试日期：2026-11-27（UTC+8）。

## v1.3.3 终端密码输入修复

- 修复未检测 `stty` 导致终端无法隐藏密码的问题。安装器在缺少命令时检查并安装 `coreutils-stty`；新安装设置密码的输入延后到依赖安装之后。
- 已设置管理密码的升级仍先验证密码再刷新软件源；若终端缺少 `stty`，明确要求先安装依赖，不读取或回显密码。
- 使用伪终端测试：缺少 `stty`、无法读取终端状态、无法关闭回显时均在读取前报错；正常输入不回显，结束后原终端回显状态恢复。
- 在隔离测试环境分别模拟 opkg 和 apk 缺少 `stty`，确认从配置的软件源安装 `coreutils-stty`。
- 在 OpenWrt 23.05.5 x86/64 实例上，从 v1.3.2 升级到 v1.3.3：原先无 `stty`，安装器实际补装 `coreutils-stty`；UCI network/firewall/tslan、PassWall2 配置及原软件包启动脚本与升级前一致。
- 路由器直接下载软件源时速度过低并有一次签名文件下载失败，安装器未继续修改配置。复测将原有官方软件源的下载临时通过 SSH 转发到测试电脑，由电脑验证 HTTPS 证书、路由器继续校验软件源签名；没有更换软件源或关闭签名检查，测试结束关闭转发。
- 真实 SSH 伪终端设置随机临时管理密码，检查输入不回显，再验证密码并关闭保护；最终恢复密码关闭的原状态。Tailscale 保持 Running、PassWall2 绕过 ACTIVE，实际对端 IPv4/IPv6 HTTP 均为 200。未重启整机。

## v1.3.2 独立 DNS 与升级实机测试

在 OpenWrt 23.05.5 x86/64、Tailscale 1.58.2 上，从 v1.3.1 试用配置升级到 v1.3.2 候选版。脚本更新时保留原有 Tailscale 身份、LAN 开关、PassWall2 配置和绕过选项；原软件包的 Tailscale 启动脚本已恢复，项目以独立 procd 服务启动守护进程。安装及启动期间守护进程可能先报告 NoState；等待到 Running 后验证实际连接。

- 开启 FakeDNS 与 PassWall2 本机代理，移除此前临时的域名直连规则；系统 DNS 查询官网域名仍返回 Fake IP，PassWall2 配置文件与新增临时规则前一致。
- 绕过开关关闭、开启后分别回到 Running；关闭时使用原软件包服务，开启时项目服务拥有独立 resolv.conf 挂载且绕过规则显示 ACTIVE。
- 通过 `tslan restart` 重启后独立挂载仍存在，本机访问同一对端的 IPv4、IPv6 HTTP 均为 200。路由器普通 HTTPS 请求官网返回 308，DNS 返回 Fake IP，内核连接跟踪显示被 PassWall2 重定向到本机代理端口；未验证另一台客户端浏览器的最终出口。
- 实机卸载时，独立服务与 DNS wrapper 被移除，Tailscale 身份文件、原启动脚本及 PassWall2 配置保留。测试脚本手动恢复卸载前备份的项目设置后重新安装，设备无需重新授权恢复 Running，绕过 ACTIVE、两个 LAN 开关保持原设置，本机双栈 HTTP 再次返回 200。卸载会删除项目配置，普通重新安装不会自动恢复该配置。
- DNS wrapper 的本地回归测试检查去重、排除回环及 Fake IP 上游、保持原系统 DNS、拒绝不支持的解析器布局和缺少合适上游；管理测试检查与 accept-dns 冲突时拒绝并保留原设置。
- 本次未重启整台路由器，也未测试其他固件、CPU 架构、上游 DNS 动态变化或不同的 DNS 重定向规则；新增代码要求 `unshare` 和对应内核能力。

本次在新的 OpenWrt 23.05.5 x86/64 测试实例先完成未授权状态下的管理功能验收，随后由用户授权加入 Tailnet，再完成下述连通性与页面检查。未操作此前的测试路由器。历史版本记录仅代表对应旧版本的测试结果。

## v1.3.1 授权后连通性与页面测试

- 授权后状态为 Running；本机 IPv4/IPv6 地址与有效对端路由均通过 `tailscale0`。
- 本机以普通 `curl --interface tailscale0` 访问两台 Linux 对端的 IPv4/IPv6 PeerAPI HTTP 根路径，四次请求均返回 200；未执行文件上传。
- 临时网络命名空间中的客户端通过 veth 接入实际 `br-lan`，以该路由器为网关访问对端 IPv4 HTTP 返回 200。内核连接跟踪确认源地址转换为路由器的 Tailscale IPv4。关闭 LAN IPv4 后客户端请求失败，本机双栈 HTTP 仍均为 200；重新开启后客户端恢复。
- 在独立临时接口/区域配置 ULA IPv6 与客户端静态路由，测试下表四种组合。每种组合均在本机双栈 HTTP 恢复正常后验证客户端，避免把服务重启中的短暂中断误判为开关生效。

| LAN IPv4 | LAN IPv6 | 客户端 IPv4 HTTP | 客户端 IPv6 HTTP | 本机 IPv4 / IPv6 HTTP |
| --- | --- | --- | --- | --- |
| 开 | 开 | 200 | 200 | 200 / 200 |
| 关 | 开 | 阻断 | 200 | 200 / 200 |
| 开 | 关 | 200 | 阻断 | 200 / 200 |
| 关 | 关 | 阻断 | 阻断 | 200 / 200 |

- 临时 IPv6 测试区域最初使用 input=REJECT，阻断邻居发现，导致测试客户端无法访问。改用 input=ACCEPT 的隔离测试区域后通过；没有更改原 LAN 区域或项目代码。
- 四种组合的 `fw4 check` 均通过；服务配置重启后无需重新授权即可恢复本机双栈访问。
- 在双栈开启时抓取内核连接跟踪记录，确认客户端 IPv4 与 ULA IPv6 分别转换为路由器的 Tailscale IPv4/IPv6；IPv6 成功请求经过实际 NAT66。
- 真实 Chromium 登录 HTTP LuCI，本机与对端显示控制面自定义 Machine name，与操作系统 HostName 不同时仍显示正确；检查设备列表名称与实际状态数据一致。
- 本机及一台对端的 IPv4/IPv6 共四个独立复制按钮，均触发成功提示。HTTP 页实际走复制回退路径，通过浏览器内拦截生成的独立安全页面读取剪贴板，逐项核对实际内容；无页面脚本错误。未测试 HTTPS LuCI 的原生 Clipboard API 路径。
- 测试期间 PassWall2 原有“路由器本机代理”保持开启，项目绕过选项保持原值关闭；未替换代理节点，因此不能据此判定“代理节点就是 Tailnet 设备”时的回环场景。
- 完成后恢复 LAN IPv4 开启、LAN IPv6 关闭及其他原选项。network/firewall/tslan 导出、DHCP、DNS、PassWall2 配置、IPv4/IPv6 主路由、全局/default/原接口 IPv6 sysctl 和已安装软件包列表均与本轮测试前一致；临时命名空间、veth、UCI 接口/区域、返回路由和 `kmod-veth` 已清理。最终防火墙检查与本机双栈 HTTP 再次通过。

本次没有重启整台路由器，也没有验证已建立连接或 flow offload 连接的实际阻断。LAN 客户端使用隔离网络命名空间，未使用另一台物理终端。

### FakeDNS 与 PassWall2 绕过复测

在同一测试实例中启用 Xray FakeDNS 和 PassWall2 本机代理时，开启绕过后控制域名解析为 Fake IP，Tailscale 停在 NoState；关闭绕过后恢复。新增优先级靠前的 PassWall2 分流规则，匹配 `domain:tailscale.com`、`domain:tailscale.io` 并在当前 Xray 分流节点指定直连，重启 PassWall2 后控制和日志域名解析到真实地址，普通代理域名仍返回 Fake IP。开启 Tailscale 绕过后状态变为 ACTIVE / Running，本机通过 tailscale0 访问一个远端 IPv4 和 IPv6 HTTP 服务均返回 200。保留原 LAN 两项关闭设置和 FakeDNS，原 PassWall2 配置备份保存在设备本地。该规则是手动针对本台设备的 PassWall2 配置，安装脚本目前不会自动创建；未覆盖其他代理内核、分流节点或全部 DERP 域名。

后续按用户要求在该设备验证独立 DNS：安装匹配固件软件源的 `unshare`，给 tailscaled 创建独立挂载命名空间并绑定仅包含原上游 DNS 的 resolv.conf；没有修改系统 resolv.conf。移除上述两个 PassWall2 域名规则后，PassWall2 配置文件与规则添加前逐字节一致，官网域名在系统 DNS 中仍返回 Fake IP；启用绕过后为 ACTIVE / Running，经 Tailscale 菜单重启后仍有独立挂载，访问对端 IPv4/IPv6 HTTP 均为 200。测试未在浏览器验证官网的最终代理出口，未验证整机重启或 DNS 上游改变时的自动更新。

当时的 1.3.1 试用曾修改软件包启动脚本；随后升级 1.3.2 时该脚本已恢复，当前改用项目独立服务。试用和升级备份保存在设备 root 专用目录。

## v1.3.1 管理功能设备测试

环境：OpenWrt 23.05.5、Linux 5.15.167、Tailscale 1.58.2、firewall4/nftables，现有 LAN/WAN 仅 IPv4 与 IPv6 链路本地地址；系统原有 IPv6 forwarding=1。

- 从公开 v1.3.0 脚本首次安装，软件源与依赖检查通过；补装 Tailscale、OpenSSL 工具和 timeout。
- 实机发现 v1.3.0 的 Web action 请求总是返回 `Unsupported action`。原因是 `jshn -R` 按 `fstat().st_size` 读取文件，而管道的大小为零，无法解析 `/proc/self/fd/0`；本地 JSON 替身此前错误地允许了这种行为。
- v1.3.1 改为通过 `jsonfilter` 的标准输入解析请求，不将密码放入解析器参数，也不创建含明文密码的临时文件。修正测试替身后，6 项管理回归测试通过。
- 真实 Chromium 浏览器登录 LuCI，管理页渲染正常，无页面脚本错误；验证密码输入遮罩、取消不提交、错误密码拒绝、正确密码停止/启动服务，以及保存表单关闭/恢复 LAN IPv4。
- 未授权时显示 NeedsLogin/PENDING，IPv4/IPv6 显示未分配，不把状态误报为已连通。
- `tslan` 中文交互菜单及快捷指令可用。临时管理密码文件为 root 专用 0600；错误密码不能停止服务、升级或卸载。
- 隐藏/显示 Web 菜单不重启 tailscaled；带密码升级到 v1.3.1 保留密码和隐藏设置。
- 实际执行带密码卸载：项目文件、接口和托管规则移除，原 network/firewall 导出内容恢复一致，Tailscale 状态文件校验值保持不变。随后以“隐藏 Web + 启用密码”重新安装成功，再恢复菜单并关闭临时密码。
- 实际 LAN 缺少 ULA/全局 IPv6 地址时，开启 LAN IPv6 被拒绝，选项仍为关闭。
- 在临时隔离 veth 接口配置测试地址，验证 IPv4/IPv6 同时开启、仅 IPv6、全部关闭的规则组合；`fw4 check` 通过，实际 nftables 包含相应转发、NAT66 和早于 established/related 的关闭规则。该测试验证规则生成，**没有验证 Tailnet 的真实数据包收发**。
- PassWall2 绕过开关生成 10 条托管规则，防火墙重载后保护恢复 ACTIVE；关闭后恢复 OFF，未修改原 PassWall2 配置。未验证以 Tailnet 节点为代理出口的实际连接。
- 最终比较：排除本项目新增对象后，原 network/firewall 导出、DHCP、DNS、PassWall2 配置、原 IPv4/IPv6 主路由及全局/default/原接口 IPv6 sysctl 一致。新增的 tailscale0 链路本地路由属于项目接口。临时 veth、UCI 测试接口/区域、内核模块和测试密码已清理。

以上管理验收先在未授权状态完成；授权后的本机/LAN 连通性、真实设备名与地址复制结果见上一节。已有及 offload 连接的实际阻断、本版整机重启仍未验证。

参考：[OpenWrt jshn 文件读取实现](https://github.com/openwrt/libubox/blob/master/jshn.c)。

## v1.3.0 本地验证

38 项自动化测试、LuCI 交互测试、ShellCheck 0.11.0、shell/JSON 语法检查及 Python 3.9/3.12 可重复构建检查通过。

在隔离目录运行实际安装器、控制程序、CLI 和 RPC 插件；OpenWrt 命令用状态化替身模拟。新增用例覆盖：

- LAN IPv4 关闭后本机两个地址族仍可用；LAN IPv6 条件不足时拒绝开启并恢复配置；已有条件满足时创建独立 IPv6 转发与 NAT66。
- 错误密码不能修改服务、LAN、Web、配置、密码或卸载；已启用密码的升级/检查在更新软件源前先认证。
- 使用 Python `hashlib.pbkdf2_hmac` 独立核对 OpenSSL 派生结果，检查密码文件权限与日志不含明文。
- 新安装的 Web/密码选项、隐藏后的再次升级、改密/关闭密码、无需交互的开机恢复和卸载清理。
- 防火墙验证失败后恢复配置及 forward 前置规则；非法参数不被当作 shell 命令执行。
- 实际 RPC 插件拒绝错误密码、未授权动作、未知配置项及错误类型；正确请求通过一次性票据进入后台作业，票据随后销毁。
- LuCI 本地渲染验证 Machine name、双栈复制按钮、无地址状态、密码输入遮罩、取消不提交、逐次确认与纯 JSON 表单保存（不直接调用 UCI 写接口）。

本地替身不能证明实机 nftables 渲染、实际数据包转发/NAT66、flow offload 的清除、具体浏览器权限或不同固件行为。实机完成的部分见本页首节；其余仍需按文末步骤验收。

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

在隔离的临时目录中运行**实际安装脚本与服务控制脚本**，以状态化命令替身模拟 OpenWrt 的 UCI、软件包管理、Tailscale 和服务管理。原集成测试包含 25 个测试方法（部分覆盖多个故障场景），另有 7 个 PassWall2 规则测试，共 32 项；另增加 6 项管理集成测试：

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

- 其他 OpenWrt 版本、CPU 架构与 apk 固件的实机行为。v1.3.0 的 LAN 开关要求 fw4，不支持 fw3。
- 在另一台物理 LAN 终端上的完整访问，以及旁路由场景下主路由静态路由配置。
- 任意业务服务、不同 Tailnet ACL/Grants、MTU 边界和复杂已有 Tailscale 配置。
- 控制台现场改名后的同步延迟、HTTPS LuCI 原生 Clipboard API 路径，以及其他浏览器的复制行为；现有自定义名称与 HTTP Chromium 复制已验证。
- 本版整机重启、已有及 flow offload 连接的实际阻断。
- `default.disable_ipv6=1` 场景的实机启动（已由自动化测试覆盖）。
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
3. 查看 `nft list ruleset`（fw4），确认本机输出、回包、必要 ICMPv6 正常，未允许 LAN IPv6 转发及 NAT66。
4. 对比原 LAN/WAN、DHCP/DNS、默认路由和物理接口 IPv6 参数；允许新增本项目托管对象及 Tailscale 专属地址/路由。
5. 重启路由器并重复两个地址族的实际服务访问。再测试停止/启动，以及默认禁止新接口 IPv6 的场景。

上方记录了本次设备测试实际完成的部分；其余步骤仍适用于新设备验收，模拟测试不能替代对应实机结果。

请在 Issue 中附 OpenWrt 版本、CPU 架构、主路由/旁路由拓扑、失败步骤和脱敏错误日志。

## v1.3.x 实机验收清单

以下是完整清单，不代表全部已执行；已完成范围见本页前两节。

1. 保留原始网络配置和版本，分别安装选择 Web 显示/隐藏、密码启用/关闭；验证 `tslan` 菜单。
2. 通过 SSH 菜单、快捷命令及 LuCI 分别测试错误/正确密码、取消、改密、关闭密码；确认错误密码下配置、服务和网络不变。
3. 关闭两个 LAN 开关后，本机对端 IPv4/IPv6 服务仍通；LAN 客户端直接访问两种协议均失败，包括此前建立的连接及启用 flow offload 的情况。
4. 依次打开 LAN IPv4、LAN IPv6，验证独立性。LAN IPv6 使用已有 ULA/全局地址、客户端静态路由和现有系统转发能力；检查实际 NAT66 回包及 fw4 前置规则。
5. 对比 LAN/WAN 地址、RA、DHCPv6、DNS、全局/default/物理接口 IPv6 sysctl 均未改变。
6. 修改 Tailnet 控制台 Machine name，等待状态同步后验证本机及对端显示；在 HTTPS 和 HTTP LuCI 上分别复制 IPv4/IPv6。
7. 隐藏 Web 后确认服务不中断、CLI 可恢复菜单；带密码升级保留选项；授权重启后无需输入密码自动恢复。
8. 在测试设备验证带密码卸载、其他防火墙规则和 Tailscale 身份保留。
