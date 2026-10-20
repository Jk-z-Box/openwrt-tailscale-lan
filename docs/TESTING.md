# 验证记录

版本：1.0.0。

## 已验证

在隔离的临时目录中运行**实际安装脚本与服务控制脚本**，以状态化命令替身模拟 OpenWrt 的 UCI、软件包管理、Tailscale 和服务管理：

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

另外运行：

- ShellCheck 0.11.0 静态检查。
- 所有 shell 文件的语法检查、菜单与 ACL JSON 解析。
- LuCI JavaScript 渲染/表单验证/登录 URL 限制/刷新/保存应用测试。
- 可重复构建校验与内嵌载荷 SHA-256 校验。

## 尚未验证

目前没有在真实 OpenWrt 路由器或 OpenWrt 虚拟机上运行，因此模拟测试不能证明以下事项：

- 特定固件的软件源、依赖、存储与 init/rpcd 版本均兼容。
- 首次账户授权、真实 Tailnet ACL 和 Tailscale 控制面的行为。
- 内核转发、nftables/iptables NAT 与回包路径的实际结果。
- 重启后服务恢复和真实 LuCI 登录会话的完整交互。
- 吞吐量、CPU/内存消耗、MTU、直接连接或 DERP 中继性能。

## 真机验收步骤

1. 运行 `sh /tmp/tslan-install.sh --check`，确认软件源检查通过。
2. 安装后检查 `/etc/tslan/install-report.txt` 和 `tailscale status`。
3. 在 LuCI「服务 → Tailscale」授权登录，确认节点处于 Running。
4. 在路由器运行 `tailscale ping <目标100.x地址>`；这仅验证路由器的 Tailscale 路径。
5. 在一台**未安装 Tailscale**、以 OpenWrt 为网关的 LAN 设备上连接远端实际服务，例如 SSH 或 HTTP。此步才验证 LAN 转发和 NAT。
6. 检查目标端 ACL/防火墙；ping 被禁不代表 TCP 服务不可访问。
7. 通过管理页测试关闭、开启和修改设备名，再重启路由器复测。
8. 如需卸载，运行安装脚本的 `--uninstall`，检查其他网络配置保持正常。

请在 Issue 中附 OpenWrt 版本、CPU 架构、主路由/旁路由拓扑、失败步骤和脱敏错误日志。
