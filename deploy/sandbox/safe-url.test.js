'use strict';

// node --test deploy/sandbox — no Playwright needed, the guard is a standalone module.
const test = require('node:test');
const assert = require('node:assert');

const { assertSafeUrl, isBlockedV4, isBlockedV6 } = require('./safe-url');

const BLOCKED_V4 = [
  '0.0.0.0',
  '0.1.2.3',
  '10.5.5.5',
  '100.64.0.1',
  '127.0.0.1',
  '169.254.169.254',
  '172.16.0.1',
  '172.30.0.5',
  '192.0.0.1',
  '192.168.1.1',
  '224.0.0.1',
  '255.255.255.255',
];

const ALLOWED_V4 = ['1.1.1.1', '8.8.8.8', '93.184.216.34', '172.15.0.1', '172.32.0.1', '99.64.0.1'];

const BLOCKED_V6 = ['::1', '::', 'fe80::1', 'fc00::1', 'fd00::1', '::ffff:127.0.0.1', '64:ff9b::1'];

const ALLOWED_V6 = ['2606:4700:4700::1111', '2001:4860:4860::8888', '3fff::1'];

test('blocked v4 ranges', () => {
  for (const ip of BLOCKED_V4) assert.equal(isBlockedV4(ip), true, ip);
});

test('public v4 stays reachable', () => {
  for (const ip of ALLOWED_V4) assert.equal(isBlockedV4(ip), false, ip);
});

test('only global unicast v6 is allowed', () => {
  for (const ip of BLOCKED_V6) assert.equal(isBlockedV6(ip), true, ip);
  for (const ip of ALLOWED_V6) assert.equal(isBlockedV6(ip), false, ip);
});

test('loopback literals are refused, bracketed v6 included', async () => {
  await assert.rejects(() => assertSafeUrl('http://127.0.0.1/'), /blocked host/);
  await assert.rejects(() => assertSafeUrl('http://0.0.0.0/'), /blocked host/);
  await assert.rejects(() => assertSafeUrl('http://[::1]/'), /blocked host/);
  await assert.rejects(() => assertSafeUrl('http://169.254.169.254/latest/meta-data/'), /blocked host/);
});

test('the CDP debugging port is not navigable on any host', async () => {
  await assert.rejects(() => assertSafeUrl('http://127.0.0.1:9222/json/version'), /blocked/);
  await assert.rejects(() => assertSafeUrl('http://example.com:9222/'), /blocked port/);
});

test('non-http schemes are refused', async () => {
  for (const url of ['file:///etc/passwd', 'ftp://example.com/', 'data:text/html,hi']) {
    await assert.rejects(() => assertSafeUrl(url), /blocked scheme/);
  }
});

test('a malformed url is refused rather than passed through', async () => {
  await assert.rejects(() => assertSafeUrl('http://'), /invalid url/);
  await assert.rejects(() => assertSafeUrl('not a url'), /invalid url/);
});

test('a public literal is accepted and returned parsed', async () => {
  const url = await assertSafeUrl('https://93.184.216.34/x?y=1');
  assert.equal(url.hostname, '93.184.216.34');
  assert.equal(url.pathname, '/x');
});

test('a name that resolves into a blocked range is refused', async () => {
  await assert.rejects(() => assertSafeUrl('http://localhost/'), /blocked host/);
});
