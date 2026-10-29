import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import fs from 'node:fs';

const site = fs.readFileSync(new URL('../../../portal/priv/static/assets/site.js', import.meta.url), 'utf8');
const analytics = fs.readFileSync(new URL('../../../portal/priv/static/assets/mixpanel.js', import.meta.url), 'utf8');

function page({ clipboard = 'success', dnt, kind = 'install', hostname = 'onlytty.com' } = {}) {
  const handlers = new Map();
  const events = [];
  const attrs = new Map([['data-copy', 'private test text must never reach analytics'], ['data-copy-kind', kind], ['aria-label', 'Copy command']]);
  let click;
  const button = {
    textContent: 'Copy',
    getAttribute: name => attrs.get(name),
    setAttribute: (name, value) => attrs.set(name, value),
    addEventListener: (name, callback) => { if (name === 'click') click = callback; },
  };
  const document = {
    querySelector: () => null,
    querySelectorAll: selector => selector === '[data-copy]' ? [button] : [],
    addEventListener: (name, callback) => handlers.set(name, callback),
    dispatchEvent: event => handlers.get(event.type)?.(event),
  };
  const mixpanel = { __SV: 1.2, init() {}, track: (name, data) => events.push({ name, data }) };
  const navigator = { doNotTrack: dnt };
  if (clipboard !== 'missing') navigator.clipboard = {
    writeText: async () => { if (clipboard === 'rejected') throw new Error('Denied'); },
  };
  const context = vm.createContext({
    document, navigator, mixpanel, location: { hostname, pathname: '/control/nvim', hash: '#private', search: '?private=value' },
    window: { mixpanel, matchMedia: () => ({ matches: true }) },
    matchMedia: () => ({ matches: true }),
    CustomEvent: class { constructor(type, init) { this.type = type; this.detail = init.detail; } },
    setTimeout: () => 1, clearTimeout() {},
  });
  vm.runInContext(site, context);
  vm.runInContext(analytics, context);
  return { click: () => click(), events, button };
}

test('only a successful public copy records bounded intent, never the command or URL secrets', async () => {
  const p = page();
  assert.equal(p.events.length, 0);
  await p.click();
  assert.equal(p.button.textContent, 'Copied');
  assert.deepEqual(JSON.parse(JSON.stringify(p.events)), [{
    name: 'content_copy_succeeded', data: { kind: 'install', page: '/control/nvim', measurement_version: 1 },
  }]);
});

for (const clipboard of ['rejected', 'missing']) {
  test(`${clipboard} clipboard reports failure without a success event`, async () => {
    const p = page({ clipboard });
    await p.click();
    assert.equal(p.button.textContent, 'Copy blocked');
    assert.match(p.button.getAttribute('aria-label'), /copy it manually/);
    assert.equal(p.events.length, 0);
  });
}

for (const dnt of ['1', 'yes']) {
  test(`Do Not Track ${dnt} suppresses copy analytics`, async () => {
    const p = page({ dnt });
    await p.click();
    assert.equal(p.button.textContent, 'Copied');
    assert.equal(p.events.length, 0);
  });
}

test('unknown copy kinds are not sent to analytics', async () => {
  const p = page({ kind: 'private-session' });
  await p.click();
  assert.equal(p.events.length, 0);
});

test('local previews copy successfully without sending production analytics', async () => {
  const p = page({ hostname: '127.0.0.1' });
  await p.click();
  assert.equal(p.button.textContent, 'Copied');
  assert.equal(p.events.length, 0);
});
