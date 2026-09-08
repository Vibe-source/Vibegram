#!/usr/bin/env node
'use strict';

// CLI driver for sandbox-gateway's browser routes (spec docs/agent-platform-v1.md §3.6).
// Usage: node browser.js '<json request>' — prints exactly one JSON line to stdout.
const { spawn } = require('child_process');
const fs = require('fs');
const { chromium } = require('playwright-core');
const { assertSafeUrl } = require('./safe-url');

const CDP_PORT = 9222;
const CDP_URL = `http://127.0.0.1:${CDP_PORT}`;
const USER_DATA_DIR = '/home/agent/.vibe-browser';
const CHROMIUM_PATH = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH || '/usr/bin/chromium';
const DEFAULT_MAX_WIDTH = 1024;
const DEFAULT_QUALITY = 70;
const NAV_TIMEOUT_MS = 20000;
const ACTION_TIMEOUT_MS = 10000;
const LAUNCH_WAIT_MS = 15000;
const DISPLAY = process.env.DISPLAY || ':99';
const XVFB_SCREEN = process.env.XVFB_SCREEN || '1280x800x24';

function cdpReachable() {
  return fetch(`${CDP_URL}/json/version`).then((r) => r.ok).catch(() => false);
}

async function waitForCdp(deadline) {
  while (Date.now() < deadline) {
    if (await cdpReachable()) return true;
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  return false;
}

function xvfbSocket() {
  return `/tmp/.X11-unix/X${DISPLAY.replace(':', '').split('.')[0]}`;
}

// Headed Chromium needs an X display: headless is refused by Google sign-in, which is the
// point of this browser. One detached Xvfb per container, reused by later invocations.
async function ensureXvfb() {
  if (fs.existsSync(xvfbSocket())) return;
  const child = spawn('Xvfb', [DISPLAY, '-screen', '0', XVFB_SCREEN, '-nolisten', 'tcp'], {
    detached: true,
    stdio: 'ignore',
  });
  child.unref();
  const deadline = Date.now() + LAUNCH_WAIT_MS;
  while (Date.now() < deadline) {
    if (fs.existsSync(xvfbSocket())) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('Xvfb did not create its display socket');
}

// Launches ONE persistent, detached Chromium; later CLI invocations reconnect over CDP instead
// of relaunching, so browser state (cookies, tabs) survives across separate `node browser.js` runs.
async function launchChromium() {
  await ensureXvfb();
  const [screenWidth, screenHeight] = XVFB_SCREEN.split('x');
  const args = [
    `--remote-debugging-port=${CDP_PORT}`,
    `--user-data-dir=${USER_DATA_DIR}`,
    '--no-sandbox',
    '--disable-gpu',
    `--window-size=${screenWidth},${screenHeight}`,
    '--window-position=0,0',
    // Headed reintroduces the first-run tab, and a container's /dev/shm is too small to render into.
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-dev-shm-usage',
  ];
  if (process.env.HTTPS_PROXY) {
    args.push(`--proxy-server=${process.env.HTTPS_PROXY}`);
  }
  const child = spawn(CHROMIUM_PATH, args, {
    detached: true,
    stdio: 'ignore',
    env: { ...process.env, DISPLAY },
  });
  child.unref();
  const ready = await waitForCdp(Date.now() + LAUNCH_WAIT_MS);
  if (!ready) throw new Error('chromium did not become ready on the CDP port');
}

async function ensureBrowser() {
  if (!(await cdpReachable())) {
    await launchChromium();
  }
  return chromium.connectOverCDP(CDP_URL);
}

// Chromium follows redirects itself, so goto() only ever validates the first URL: every
// navigation request, redirect hops included, is re-checked here before it leaves.
async function guardNavigation(context) {
  await context.route('**/*', async (route, request) => {
    if (!request.isNavigationRequest()) return route.continue();
    try {
      await assertSafeUrl(request.url());
      await route.continue();
    } catch {
      await route.abort('blockedbyclient');
    }
  });
}

async function getPage(browser) {
  const context = browser.contexts()[0] || (await browser.newContext());
  await guardNavigation(context);
  return context.pages()[0] || context.newPage();
}

async function runAction(page, action) {
  switch (action.kind) {
    case 'click':
      await page.click(action.selector, { timeout: ACTION_TIMEOUT_MS });
      return;
    case 'type':
      await page.fill(action.selector, String(action.text ?? ''), { timeout: ACTION_TIMEOUT_MS });
      return;
    case 'key':
      await page.keyboard.press(String(action.text ?? ''));
      return;
    case 'select':
      await page.selectOption(action.selector, String(action.text ?? ''), { timeout: ACTION_TIMEOUT_MS });
      return;
    case 'scroll':
      await page.mouse.wheel(Number(action.x) || 0, Number(action.y) || 0);
      return;
    default:
      throw new Error(`unknown action kind: ${action.kind}`);
  }
}

// Renders at exactly maxWidth instead of capturing full-size then downscaling: no image
// library needed, and it keeps every screenshot at a predictable, bounded size.
async function takeScreenshot(page, maxWidth, quality) {
  const width = Number(maxWidth) > 0 ? Math.floor(Number(maxWidth)) : DEFAULT_MAX_WIDTH;
  const jpegQuality = Number(quality) > 0 ? Math.floor(Number(quality)) : DEFAULT_QUALITY;
  const current = page.viewportSize();
  if (!current || current.width !== width) {
    const ratio = current ? current.height / current.width : 9 / 16;
    await page.setViewportSize({ width, height: Math.round(width * ratio) });
  }
  const buffer = await page.screenshot({ type: 'jpeg', quality: jpegQuality });
  const size = page.viewportSize();
  return { imageBase64: buffer.toString('base64'), mime: 'image/jpeg', width: size.width, height: size.height };
}

const MAX_PAGE_TEXT = 6000;
const MAX_ELEMENTS = 60;

// Page text plus the elements worth acting on, each tagged with a stable ref the model can
// hand straight back as a selector. Cheaper and surer than reading a selector off a picture.
async function readPage(page) {
  return page.evaluate((limits) => {
    const isVisible = (el) => {
      const r = el.getBoundingClientRect();
      if (r.width < 1 || r.height < 1) return false;
      const s = window.getComputedStyle(el);
      return s.visibility !== "hidden" && s.display !== "none" && Number(s.opacity) > 0.05;
    };
    const oneLine = (v) => String(v || "").replace(/\s+/g, " ").trim();
    const asText = (v) =>
      String(v || "")
        .replace(/[ \t]+/g, " ")
        .replace(/\n{3,}/g, "\n\n")
        .trim();

    const nodes = Array.from(
      document.querySelectorAll(
        "a[href], button, input, textarea, select, [role=button], [role=link], [role=tab], [contenteditable=true]"
      )
    ).filter(isVisible);

    const elements = nodes.slice(0, limits.maxElements).map((el, i) => {
      const ref = "e" + (i + 1);
      el.setAttribute("data-vibe-ref", ref);
      const tag = el.tagName.toLowerCase();
      const name = oneLine(
        el.getAttribute("aria-label") || el.innerText || el.value || el.getAttribute("placeholder") || el.getAttribute("title")
      ).slice(0, 80);
      const entry = { ref, selector: `[data-vibe-ref="${ref}"]`, tag, type: el.getAttribute("type") || el.getAttribute("role") || tag, name };
      if (tag === "a") entry.href = oneLine(el.getAttribute("href")).slice(0, 200);
      return entry;
    });

    const text = asText(document.body ? document.body.innerText : "");
    return {
      text: text.slice(0, limits.maxText),
      textTruncated: text.length > limits.maxText,
      elements,
      elementsTruncated: nodes.length > limits.maxElements,
    };
  }, { maxText: MAX_PAGE_TEXT, maxElements: MAX_ELEMENTS });
}

async function readState(browser, page) {
  const tabCount = browser.contexts().reduce((total, ctx) => total + ctx.pages().length, 0);
  let loading = false;
  try {
    loading = (await page.evaluate(() => document.readyState)) !== 'complete';
  } catch {
    loading = true;
  }
  return { url: page.url(), title: await page.title(), loading, tabCount };
}

// Raw viewport coordinates: the frame the viewer clicked on was captured at this same viewport.
async function runInput(page, input) {
  switch (input.kind) {
    case 'click':
      await page.mouse.click(Number(input.x) || 0, Number(input.y) || 0);
      return;
    case 'type':
      await page.keyboard.type(String(input.text ?? ''), { delay: 12 });
      return;
    case 'key':
      await page.keyboard.press(String(input.key ?? input.text ?? 'Enter'));
      return;
    case 'scroll':
      await page.mouse.wheel(0, Number(input.deltaY) || 0);
      return;
    case 'back':
      await page.goBack({ timeout: NAV_TIMEOUT_MS, waitUntil: 'domcontentloaded' }).catch(() => null);
      return;
    case 'navigate': {
      const url = await assertSafeUrl(input.url);
      await page.goto(url.toString(), { timeout: NAV_TIMEOUT_MS, waitUntil: 'domcontentloaded' });
      return;
    }
    default:
      throw new Error(`unknown input kind: ${input.kind}`);
  }
}

// Never calls browser.close(): that sends CDP Browser.close and would kill the persistent
// process. Exiting this short-lived Node process just drops our one connection to it.
async function handle(request) {
  const browser = await ensureBrowser();
  const page = await getPage(browser);
  switch (request.kind) {
    case 'status':
      return { ok: true };
    case 'navigate': {
      const url = await assertSafeUrl(request.url);
      await page.goto(url.toString(), { timeout: NAV_TIMEOUT_MS, waitUntil: 'domcontentloaded' });
      return { url: page.url(), title: await page.title() };
    }
    case 'action':
      await runAction(page, request.action || {});
      return { ok: true, url: page.url(), title: await page.title() };
    case 'state':
      return readState(browser, page);
    case 'read': {
      const read = await readPage(page);
      return { url: page.url(), title: await page.title(), ...read };
    }
    case 'input':
      await runInput(page, request.input || {});
      return { ok: true, url: page.url(), title: await page.title() };
    case 'screenshot':
      return takeScreenshot(page, request.maxWidth, request.quality);
    default:
      throw new Error(`unknown kind: ${request.kind}`);
  }
}

// Writes the one required JSON line, waits for the flush to land, then exits — exiting right
// after an unflushed pipe write can truncate stdout.
function emit(payload, code) {
  process.stdout.write(`${JSON.stringify(payload)}\n`, () => process.exit(code));
}

process.on('unhandledRejection', (err) => {
  emit({ error: String((err && err.message) || err) }, 1);
});

async function main() {
  let request;
  try {
    request = JSON.parse(process.argv[2]);
  } catch {
    emit({ error: 'invalid json argument' }, 1);
    return;
  }
  try {
    emit(await handle(request), 0);
  } catch (err) {
    emit({ error: String((err && err.message) || err) }, 1);
  }
}

main();
