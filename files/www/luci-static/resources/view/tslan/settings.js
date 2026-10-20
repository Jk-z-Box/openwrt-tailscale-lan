'use strict';
'require view';
'require form';
'require rpc';
'require uci';
'require ui';
'require poll';

var getStatus = rpc.declare({ object: 'tslan', method: 'status', expect: {} });
var getReport = rpc.declare({ object: 'tslan', method: 'report', expect: {} });
var runAction = rpc.declare({ object: 'tslan', method: 'action', params: ['name'], expect: {} });

function parseStatus(result) {
	try { return JSON.parse(result.tailscale || '{}'); }
	catch (e) { return {}; }
}

function loginLink(url) {
	// Only render Tailscale's HTTPS authentication URLs as clickable links.
	if (!/^https:\/\/(login|controlplane)\.tailscale\.com\//.test(url || ''))
		return E('span', {}, '暂无登录链接，请点击“登录 / 授权”。');
	return E('a', { href: url, target: '_blank', rel: 'noopener noreferrer' }, '打开 Tailscale 登录授权页面');
}

return view.extend({
	load: function() {
		return Promise.all([uci.load('tslan'), getStatus(), getReport()]);
	},

	renderStatus: function(result) {
		var st = parseStatus(result), self = st.Self || {};
		var rows = [
			['客户端版本', result.version || '不可用'],
			['连接状态', st.BackendState || '服务未启动'],
			['Tailscale 分配的 IPv4', (st.TailscaleIPs || []).filter(function(ip) { return ip.indexOf(':') < 0; }).join(', ') || '未分配'],
			['Tailscale 分配的 IPv6', (st.TailscaleIPs || []).filter(function(ip) { return ip.indexOf(':') >= 0; }).join(', ') || '未分配'],
			['本机双栈检查', E('pre', { style: 'white-space:pre-wrap;margin:0' }, result.host_stack || '等待检查；分配地址不代表内核路由已就绪。')],
			['PassWall2 绕过状态', result.passwall2_bypass || '等待检查'],
			['设备名称', self.HostName || '—'],
			['操作状态', result.busy ? '执行中，请稍候…' :
				(result.last_exit && result.last_exit !== '0' ? '上次操作失败，请查看下方日志' : '就绪')]
		];
		return E('div', {}, [
			E('table', { 'class': 'table' }, rows.map(function(row) {
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', style: 'width:180px' }, row[0]),
					E('td', { 'class': 'td' }, row[1])
				]);
			})),
			E('p', {}, loginLink(st.AuthURL)),
			E('p', {}, (st.Health || []).join('；'))
		]);
	},

	run: function(name) {
		var self = this;
		if (name === 'logout' && !window.confirm('注销当前 Tailscale 账户并停用服务？')) return Promise.resolve();
		return runAction(name).then(function(result) {
			if (!result.accepted) throw new Error(result.error || '操作未接受');
			ui.addNotification(null, E('p', {}, '操作已提交，结果会显示在状态和日志中。'), 'info');
			// The next poll refreshes state. UCI edits stay in the form until reload.
			return self.refresh();
		}).catch(function(error) {
			ui.addNotification(null, E('p', {}, error.message), 'error');
		});
	},

	refresh: function() {
		var self = this;
		return Promise.all([getStatus(), getReport()]).then(function(results) {
			var status = document.getElementById('tslan-status');
			if (!status) return;
			status.replaceChildren(self.renderStatus(results[0]));
			document.getElementById('tslan-log').textContent = results[0].log || '暂无操作日志。';
			document.getElementById('tslan-report').textContent = results[1].report || '暂无报告。';
			var st = parseStatus(results[0]), peers = st.Peer || {};
			var body = document.getElementById('tslan-peers');
			body.replaceChildren.apply(body, Object.keys(peers).map(function(key) {
				var peer = peers[key];
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, peer.HostName || peer.DNSName || '—'),
					E('td', { 'class': 'td' }, (peer.TailscaleIPs || []).join(', ')),
					E('td', { 'class': 'td' }, peer.Online ? '在线' : '离线')
				]);
			}));
		});
	},

	render: function(data) {
		var self = this, option;
		this.map = new form.Map('tslan', 'Tailscale', '本机通过 tailscale0 使用 Tailscale IPv4 / IPv6；LAN 设备继续通过本路由器访问 Tailscale IPv4。保留现有 LAN/WAN IPv6 设置，不开启 IPv6 转发和地址分发。');
		var section = this.map.section(form.NamedSection, 'settings', 'settings', '服务选项');
		section.anonymous = true;
		option = section.option(form.Flag, 'enabled', '启用 Tailscale');
		option.default = '1'; option.rmempty = false;
		option.description = '控制当前服务和开机启动；保存并应用后生效。';
		option = section.option(form.Flag, 'bypass_passwall2', '绕过 PassWall2 代理（防止回环）');
		option.default = '0'; option.rmempty = false;
		option.description = '适用于 PassWall2 的 nftables 后端。让 Tailscale 外层连接、tailscale0 流量及 Tailnet IPv4/IPv6 目的地址绕过透明代理；其他流量按原策略处理。启用后每 3 秒检查规则，自动修复重载后丢失的规则，重载瞬间可能短暂中断。公网出口及基础 DNS 需能独立连通。';
		option = section.option(form.Value, 'hostname', '设备名称');
		option.placeholder = '留空保持现有名称';
		option.validate = function(sid, value) {
			return !value || (value.length <= 63 && /^[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?$/.test(value))
				? true : '仅可使用字母、数字和中间的连字符，最多 63 字符。';
		};
		option = section.option(form.Value, 'lan_network', 'LAN 逻辑接口');
		option.default = 'lan'; option.rmempty = false;
		option.validate = function(sid, value) { return /^[a-zA-Z0-9_]+$/.test(value) ? true : '请输入已有的逻辑接口名称，例如 lan'; };
		option.description = '授权其所属防火墙区域访问 Tailscale；同区域的其他网络也会获得访问权限。';
		option = section.option(form.Flag, 'accept_routes', '接受远端子网路由');
		option.default = '0'; option.rmempty = false;
		option.description = '访问设备自身的 100.x / fd7a:115c:a1e0:: 地址无需开启。开启后接受已批准的远端子网路由，请注意与现有路由冲突；LAN 转发仍仅限 IPv4。';
		option = section.option(form.Flag, 'accept_dns', '使用 Tailscale DNS');
		option.default = '0'; option.rmempty = false;
		option.description = '默认关闭。开启可能修改路由器 DNS；此选项不会自动为 LAN 配置 MagicDNS。';
		option = section.option(form.Flag, 'shields_up', '阻止 Tailnet 主动连接本机');
		option.default = '0'; option.rmempty = false;
		option.description = '保留本机主动连接及其响应；LAN 转发仍受 OpenWrt 和 Tailnet 策略控制。';
		return this.map.render().then(function(formNode) {
			var controls = [['start', '启动'], ['stop', '停止'], ['restart', '重启'],
				['login', '登录 / 授权'], ['logout', '注销'], ['diagnose', '运行诊断']];
			var node = E('div', {}, [
				E('h2', {}, 'Tailscale 状态'),
				E('div', { id: 'tslan-status' }, self.renderStatus(data[1])),
				E('div', { style: 'display:flex;gap:8px;flex-wrap:wrap;margin:16px 0' }, controls.map(function(item) {
					return E('button', { 'class': 'cbi-button cbi-button-action',
						click: ui.createHandlerFn(self, function() { return self.run(item[0]); }) }, item[1]);
				})),
				E('p', {}, '启停按钮立即修改服务状态和启用设置。使用按钮后请刷新页面，再编辑表单。'),
				formNode,
				E('h3', {}, 'Tailnet 设备'),
				E('table', { 'class': 'table' }, [
					E('thead', {}, E('tr', { 'class': 'tr' }, ['设备', 'Tailscale IP', '状态'].map(function(t) { return E('th', { 'class': 'th' }, t); }))),
					E('tbody', { id: 'tslan-peers' })
				]),
				E('details', {}, [E('summary', {}, '操作日志'), E('pre', { id: 'tslan-log', style: 'white-space:pre-wrap' }, data[1].log || '暂无操作日志。')]),
				E('details', {}, [E('summary', {}, '部署和配置修改报告'), E('pre', { id: 'tslan-report', style: 'white-space:pre-wrap' }, data[2].report || '暂无报告。')])
			]);
			poll.add(function() { return self.refresh(); }, 5);
			return node;
		});
	},

	handleSaveApply: function() {
		var self = this;
		return this.map.save().then(function() { return uci.save(); })
			.then(function() { return uci.apply(); })
			.then(function() { return self.run('apply'); })
			.catch(function(error) { ui.addNotification(null, E('p', {}, error.message), 'error'); });
	},
	handleSave: null,
	handleReset: function() { window.location.reload(); }
});
