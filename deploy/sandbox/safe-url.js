'use strict';

// SSRF guard for every navigation the sandbox browser performs (spec docs/agent-platform-v1.md §3.6).
// Kept out of browser.js so it can be tested without Playwright installed.
const dns = require('dns').promises;
const net = require('net');

const CDP_PORT = 9222;

// [network, prefix bits]. 0.0.0.0/8 belongs here as much as 127/8: on Linux 0.0.0.0 reaches loopback.
const BLOCKED_V4_RANGES = [
  ['0.0.0.0', 8],
  ['10.0.0.0', 8],
  ['100.64.0.0', 10],
  ['127.0.0.0', 8],
  ['169.254.0.0', 16],
  ['172.16.0.0', 12],
  ['192.0.0.0', 24],
  ['192.168.0.0', 16],
  ['224.0.0.0', 3],
];

// Only global unicast 2000::/3 is allowed, so ::1, fc00::/7, fe80::/10 and v4-mapped are not.
function isBlockedV6(ip) {
  const head = ip.split('%')[0].split(':')[0];
  if (head === '') return true;
  const value = parseInt(head, 16);
  return !(value >= 0x2000 && value <= 0x3fff);
}

function ipToInt(ip) {
  const parts = ip.split('.').map(Number);
  if (parts.length !== 4 || parts.some((p) => Number.isNaN(p) || p < 0 || p > 255)) return null;
  return ((parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]) >>> 0;
}

function isBlockedV4(ip) {
  const value = ipToInt(ip);
  if (value === null) return false;
  return BLOCKED_V4_RANGES.some(([base, bits]) => {
    const mask = bits === 0 ? 0 : (~0 << (32 - bits)) >>> 0;
    return (value & mask) === (ipToInt(base) & mask);
  });
}

// Literal addresses are decided here; a DNS failure stays non-fatal because an internal-only
// network cannot resolve public names and the egress proxy still filters every named host.
async function assertSafeUrl(rawUrl) {
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    throw new Error('invalid url');
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new Error(`blocked scheme: ${url.protocol}`);
  }
  if (Number(url.port) === CDP_PORT) {
    throw new Error('blocked port: the browser debugging port is not navigable');
  }
  const host = url.hostname.replace(/^\[|\]$/g, '');
  const family = net.isIP(host);
  if (family === 4) {
    if (isBlockedV4(host)) throw new Error(`blocked host: ${host}`);
    return url;
  }
  if (family === 6) {
    if (isBlockedV6(host)) throw new Error(`blocked host: ${host}`);
    return url;
  }
  let addresses = [];
  try {
    addresses = await dns.lookup(host, { all: true });
  } catch {
    return url;
  }
  for (const { address, family: resolved } of addresses) {
    const blocked = resolved === 6 ? isBlockedV6(address) : isBlockedV4(address);
    if (blocked) throw new Error(`blocked host: ${host} resolves to ${address}`);
  }
  return url;
}

module.exports = { CDP_PORT, assertSafeUrl, isBlockedV4, isBlockedV6 };
