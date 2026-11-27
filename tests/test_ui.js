#!/usr/bin/env node
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../files/www/luci-static/resources/view/tslan/settings.js'), 'utf8');

function E(tag, attrs, children) {
  if (children == null && (typeof attrs === 'string' || Array.isArray(attrs))) {
    children = attrs; attrs = {};
  }
  return {
    focus() {}, select() { selectedField = this; }, setSelectionRange() {}, remove() {}, value: "", tag, attrs: attrs || {}, children: Array.isArray(children) ? children : [children],
    replaceChildren(...nodes) { this.children = nodes; }
  };
}
const fixtures = {
  status: { tailscale: JSON.stringify({
    BackendState: 'Running', TailscaleIPs: ['100.80.1.2', 'fd7a:115c:a1e0::1234'],
    Self: { HostName: '<img src=x onerror=alert(1)>', DNSName: 'custom-router.tail-demo.ts.net.' },
    Peer: { one: { HostName: 'server', DNSName: 'my-machine.tail-demo.ts.net.', TailscaleIPs: ['100.90.1.2'], Online: true } }
  }), version: '1.80.3', busy: false, last_exit: '0',
    host_stack: 'ERROR: IPv6 route does not use tailscale0',
    passwall2_bypass: 'ACTIVE: Tailscale bypass protection' },
  report: { report: 'Managed interface: tslan' },
  action: { accepted: true }
};
const calls = [];
const nodes = Object.fromEntries(['tslan-status', 'tslan-log', 'tslan-report', 'tslan-peers'].map(id => [id, E('div')]));
const options = {};
const form = {
  NamedSection: {}, Flag: {}, Value: {},
  JSONMap: class {
    constructor(data) { this.data = { get: (c, section, key) => data[section][key] }; }
    section() {
      return { option(type, key) { return (options[key] = {}); } };
    }
    render() { return Promise.resolve(E('form')); }
    save() { calls.push('map.save'); return Promise.resolve(); }
  }
};
let modal, copied, selectedField, menuFlushes = 0, redirected;
const ui = { menu: { flushCache: () => { menuFlushes++; } }, createHandlerFn: (ctx, fn) => fn.bind(ctx), addNotification: () => {}, showModal: (title, nodes) => { modal = E('div', {}, nodes); }, hideModal: () => { modal = null; } };
const fakeWindow = { confirm: () => true, location: { reload() {}, replace: url => { redirected = url; } }, isSecureContext: true, navigator: { clipboard: { writeText: text => { copied = text; return Promise.resolve(); } } } };
const uci = { save() { throw Error('Generic UCI writes are forbidden'); }, apply() { throw Error('Generic UCI writes are forbidden'); } };
const view = new Function('view', 'form', 'rpc', 'uci', 'ui', 'poll', 'E', 'document', 'window', 'L', source)(
  { extend: o => o }, form,
  { declare: spec => (...args) => { calls.push([spec.method, ...args]); return Promise.resolve(fixtures[spec.method]); } },
  uci, ui, { add: () => {} }, E, { getElementById: id => nodes[id], body: { appendChild() {} }, execCommand: command => { assert.equal(command, 'copy'); copied = selectedField.value; return true; } },
  fakeWindow, {url: path => '/cgi-bin/luci/' + path}
);

function walk(node, result = []) {
  if (!node || typeof node !== 'object') return result;
  result.push(node);
  for (const child of node.children || []) walk(child, result);
  return result;
}

(async () => {
  const data = await view.load();
  const rendered = await view.render(data);
  assert.ok(walk(rendered).some(n => n.tag === 'form'));
  assert.equal(options.bypass_passwall2.default, '0');
  assert.equal(options.bypass_passwall2.rmempty, false);
  assert.equal(options.hostname.validate(null, 'router-1'), true);
  assert.notEqual(options.hostname.validate(null, '$(id)'), true);
  assert.notEqual(options.hostname.validate(null, '-bad'), true);
  assert.equal(options.hostname.validate(null, ''), true);
  assert.notEqual(options.lan_network.validate(null, 'lan;reboot'), true);

  const unsafe = view.renderStatus({ tailscale: JSON.stringify({ AuthURL: 'javascript:alert(1)' }) });
  assert.equal(walk(unsafe).filter(n => n.tag === 'a').length, 0);
  const spoof = view.renderStatus({ tailscale: JSON.stringify({ AuthURL: 'https://login.tailscale.com.evil.invalid/x' }) });
  assert.equal(walk(spoof).filter(n => n.tag === 'a').length, 0);
  const safe = view.renderStatus({ tailscale: JSON.stringify({ AuthURL: 'https://login.tailscale.com/a/demo' }) });
  assert.equal(walk(safe).filter(n => n.tag === 'a').length, 1);
  assert.doesNotThrow(() => view.renderStatus({ tailscale: 'not json' }));
  assert.ok(!walk(view.renderStatus(fixtures.status)).some(n => n.tag === 'img'));
  const statusText = JSON.stringify(view.renderStatus(fixtures.status));
  assert.ok(statusText.includes('fd7a:115c:a1e0::1234'));
  assert.ok(statusText.includes(fixtures.status.host_stack));
  assert.ok(statusText.includes(fixtures.status.passwall2_bypass));

  await view.refresh();
  assert.equal(nodes['tslan-peers'].children.length, 1);
  assert.equal(nodes['tslan-report'].textContent, fixtures.report.report);
  fixtures.status.settings = { web_visible: '0' };
  fixtures.status.busy = true;
  await view.refresh();
  assert.equal(menuFlushes, 0);
  assert.equal(redirected, undefined);
  fixtures.status.busy = false;
  await view.refresh();
  assert.equal(menuFlushes, 1);
  assert.equal(redirected, '/cgi-bin/luci/admin/status/overview');
  fixtures.status.settings = { web_visible: '1' };
  await view.handleSaveApply();
  const saved = calls.indexOf('map.save');
  const applied = calls.findIndex(c => Array.isArray(c) && c[0] === 'action' && c[1] === 'set');
  assert.ok(saved >= 0 && applied > saved);
  assert.equal(options.lan_ipv4.default, '1');
  assert.equal(options.lan_ipv6.default, '0');
  assert.ok(statusText.includes('custom-router'));
  assert.ok(!statusText.includes('<img'));
  assert.ok(JSON.stringify(nodes['tslan-peers']).includes('my-machine'));
  const buttons = walk(view.renderStatus(fixtures.status)).filter(n => n.tag === 'button');
  assert.equal(buttons.length, 2);
  assert.ok(buttons.some(n => n.children.includes('复制 IPv4')));
  assert.ok(buttons.some(n => n.children.includes('复制 IPv6')));
  assert.equal(walk(view.renderStatus({})).filter(n => n.tag === 'button').length, 0);
  await buttons.find(n => n.children.includes('复制 IPv6')).attrs.click();
  assert.equal(copied, 'fd7a:115c:a1e0::1234');
  fakeWindow.isSecureContext = false;
  await buttons.find(n => n.children.includes('复制 IPv4')).attrs.click();
  assert.equal(copied, '100.80.1.2');
  fakeWindow.isSecureContext = true;
  fixtures.status.password_required = true;
  let pending = view.run('stop');
  await new Promise(resolve => setImmediate(resolve));
  assert.ok(modal);
  const actionCount = calls.filter(c => Array.isArray(c) && c[0] === 'action').length;
  walk(modal).find(n => n.tag === 'button' && n.children.includes('取消')).attrs.click();
  await pending;
  assert.equal(calls.filter(c => Array.isArray(c) && c[0] === 'action').length, actionCount);
  pending = view.run('restart');
  await new Promise(resolve => setImmediate(resolve));
  const passwordInput = walk(modal).find(n => n.tag === 'input');
  assert.equal(passwordInput.attrs.type, 'password');
  passwordInput.value = 'ui-test-secret';
  walk(modal).find(n => n.tag === 'button' && n.children.includes('确认')).attrs.click();
  await pending;
  assert.equal(passwordInput.value, '');
  assert.ok(calls.some(c => Array.isArray(c) && c[0] === 'action' && c[1] === 'restart' && c[2] === 'ui-test-secret'));
  console.log('LuCI UI checks passed: render, validators, auth URL restrictions, text-only peer display, polling and save/apply.');
})().catch(e => { console.error(e); process.exitCode = 1; });
