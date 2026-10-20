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
    tag, attrs: attrs || {}, children: Array.isArray(children) ? children : [children],
    replaceChildren(...nodes) { this.children = nodes; }
  };
}
const fixtures = {
  status: { tailscale: JSON.stringify({
    BackendState: 'Running', TailscaleIPs: ['100.80.1.2'],
    Self: { HostName: '<img src=x onerror=alert(1)>' },
    Peer: { one: { HostName: 'server', TailscaleIPs: ['100.90.1.2'], Online: true } }
  }), version: '1.80.3', busy: false, last_exit: '0' },
  report: { report: 'Managed interface: tslan' },
  action: { accepted: true }
};
const calls = [];
const nodes = Object.fromEntries(['tslan-status', 'tslan-log', 'tslan-report', 'tslan-peers'].map(id => [id, E('div')]));
const options = {};
const form = {
  NamedSection: {}, Flag: {}, Value: {},
  Map: class {
    section() {
      return { option(type, key) { return (options[key] = {}); } };
    }
    render() { return Promise.resolve(E('form')); }
    save() { calls.push('map.save'); return Promise.resolve(); }
  }
};
const ui = { createHandlerFn: (ctx, fn) => fn.bind(ctx), addNotification: () => {} };
const uci = Object.fromEntries(['load', 'save', 'apply'].map(method => [method, () => { calls.push('uci.' + method); return Promise.resolve(); }]));
const view = new Function('view', 'form', 'rpc', 'uci', 'ui', 'poll', 'E', 'document', 'window', source)(
  { extend: o => o }, form,
  { declare: spec => (...args) => { calls.push([spec.method, ...args]); return Promise.resolve(fixtures[spec.method]); } },
  uci, ui, { add: () => {} }, E, { getElementById: id => nodes[id] },
  { confirm: () => true, location: { reload() {} } }
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

  await view.refresh();
  assert.equal(nodes['tslan-peers'].children.length, 1);
  assert.equal(nodes['tslan-report'].textContent, fixtures.report.report);
  await view.handleSaveApply();
  const saved = calls.indexOf('map.save');
  const applied = calls.findIndex(c => Array.isArray(c) && c[0] === 'action' && c[1] === 'apply');
  assert.ok(saved >= 0 && applied > saved);
  console.log('LuCI UI checks passed: render, validators, auth URL restrictions, text-only peer display, polling and save/apply.');
})().catch(e => { console.error(e); process.exitCode = 1; });
