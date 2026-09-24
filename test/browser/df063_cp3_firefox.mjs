// Firefox / Gecko smoke check of where the Reader stands after wide Search
// closes (route W1 only).
//
// Uses Firefox's WebDriver BiDi endpoint with the same launch and input
// mechanics as df041_cp3_firefox.mjs, and introduces no npm dependency. The
// same script runs unchanged against a baseline and a candidate bundle.
//
//   node test/browser/df063_cp3_firefox.mjs <firefoxPath> <bundleDir> <out.json> <fixture.md>

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';

import { delay, removeDirectory, serveBundle, waitForValue } from './df031_cdp.mjs';

const [browserPath, bundleDir, outputPath, fixturePath] = process.argv.slice(2);
const fixture = await readFile(fixturePath, 'utf8');
const result = {
  harness: 'df063_cp3_firefox', route: 'W1', bundleDir, fixturePath,
  fixtureSha256: createHash('sha256').update(await readFile(fixturePath)).digest('hex').toUpperCase(),
  bundleMainSha256: createHash('sha256').update(await readFile(join(bundleDir, 'main.dart.js'))).digest('hex'),
  startedAt: new Date().toISOString(), steps: [],
};

class BidiSession {
  constructor(url) {
    this.socket = new WebSocket(url);
    this.nextId = 1;
    this.pending = new Map();
  }

  async connect() {
    await new Promise((done, reject) => {
      this.socket.addEventListener('open', done, { once: true });
      this.socket.addEventListener('error', reject, { once: true });
    });
    this.socket.addEventListener('message', (event) => {
      const message = JSON.parse(event.data);
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.type === 'error') pending.reject(new Error(`${pending.method}: ${message.error} ${message.message}`));
      else pending.resolve(message.result);
    });
  }

  send(method, params = {}) {
    const id = this.nextId++;
    return new Promise((done, reject) => {
      this.pending.set(id, { resolve: done, reject, method });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  close() {
    try { this.socket.close(); } catch { /* already closed */ }
  }
}

async function launchFirefox(profile) {
  await mkdir(profile, { recursive: true });
  await writeFile(join(profile, 'user.js'), [
    'user_pref("browser.shell.checkDefaultBrowser", false);',
    'user_pref("browser.startup.homepage_override.mstone", "ignore");',
    'user_pref("datareporting.policy.dataSubmissionEnabled", false);',
    'user_pref("app.update.auto", false);',
    'user_pref("remote.prefs.recommended", true);',
  ].join('\n'));
  const child = spawn(browserPath, [
    '--headless', '--no-remote', '--new-instance', '--profile', profile,
    '--remote-debugging-port', '0', '--width', '1280', '--height', '900', 'about:blank',
  ], { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
  let output = '';
  child.stderr.setEncoding('utf8');
  child.stdout.setEncoding('utf8');
  child.stderr.on('data', (chunk) => { output += chunk; });
  child.stdout.on('data', (chunk) => { output += chunk; });
  const endpoint = await waitForValue(
    async () => output.match(/WebDriver BiDi listening on (ws:\/\/\S+)/)?.[1] ?? null,
    'Firefox WebDriver BiDi endpoint', 60000,
  );
  const session = new BidiSession(`${endpoint}/session`);
  await session.connect();
  const created = await session.send('session.new', { capabilities: { alwaysMatch: {} } });
  const tree = await session.send('browsingContext.getTree', {});
  return {
    session,
    context: tree.contexts[0].context,
    capabilities: created.capabilities ?? null,
    async close() {
      await Promise.race([session.send('browser.close').catch(() => {}), delay(4000)]);
      session.close();
      await Promise.race([
        new Promise((done) => (child.exitCode === null ? child.once('exit', done) : done())),
        delay(10000),
      ]);
      if (child.exitCode === null) child.kill();
      await delay(1000);
    },
  };
}

const server = await serveBundle(bundleDir);
const profile = join(dirname(outputPath), `firefox-profile-df063-${Date.now()}`);
let browser;

async function evaluate(expression) {
  const value = await browser.session.send('script.evaluate', {
    expression: `(async () => { ${expression} })()`,
    target: { context: browser.context }, awaitPromise: true, resultOwnership: 'none',
  });
  if (value.type === 'exception') throw new Error(`Page exception: ${JSON.stringify(value.exceptionDetails?.text ?? value)}`);
  return value.result?.value;
}
const nodes = async () => JSON.parse(await evaluate(`
  return JSON.stringify([...document.querySelectorAll('flt-semantics')].map(n => {
    const r = n.getBoundingClientRect();
    return { role: n.getAttribute('role'), label: n.getAttribute('aria-label'), text: n.textContent || '',
      x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) };
  }));
`));
const line = (n) => (n.label || n.text || '').split('\n')[0].trim();
const smallest = (ns) => ns.sort((a, b) => a.w * a.h - b.w * b.h)[0] ?? null;
const find = async (predicate) => smallest((await nodes()).filter((n) => n.w > 0 && n.h > 0 && predicate(n)));
const exact = (text) => waitForValue(() => find((n) => line(n) === text), `exact ${text}`, 15000);

async function click(n) {
  await browser.session.send('input.performActions', {
    context: browser.context,
    actions: [{ type: 'pointer', id: 'mouse', parameters: { pointerType: 'mouse' }, actions: [
      { type: 'pointerMove', x: Math.round(n.x + n.w / 2), y: Math.round(n.y + n.h / 2), origin: 'viewport', duration: 100 },
      { type: 'pause', duration: 120 }, { type: 'pointerDown', button: 0 },
      { type: 'pause', duration: 120 }, { type: 'pointerUp', button: 0 },
    ] }],
  });
  await delay(650);
}
async function typeText(text) {
  const characters = [...text];
  for (let start = 0; start < characters.length; start += 250) {
    const actions = [];
    for (const character of characters.slice(start, start + 250)) {
      const value = character === '\n' ? '' : character;
      actions.push({ type: 'keyDown', value }, { type: 'keyUp', value });
    }
    await browser.session.send('input.performActions', { context: browser.context, actions: [{ type: 'key', id: 'keyboard', actions }] });
  }
}
async function snapshot(label) {
  const all = await nodes();
  const viewport = JSON.parse(await evaluate('return JSON.stringify({w: innerWidth, h: innerHeight});'));
  const markers = all
    .filter((n) => /SECTION-\d\d-(?:START|END)/.test(n.text) && n.y >= 0 && n.y < viewport.h &&
      n.x >= 0 && n.x < viewport.w && n.w < viewport.w * 0.95 && n.h < 150)
    .map((n) => ({ marker: n.text.match(/SECTION-\d\d-(?:START|END)/)[0], x: n.x, y: n.y }));
  result.steps.push({ label, at: new Date().toISOString(), viewport, markers });
  process.stdout.write(JSON.stringify({ label, markers: markers.map((m) => m.marker) }) + '\n');
}

try {
  browser = await launchFirefox(profile);
  result.capabilities = browser.capabilities;
  await browser.session.send('browsingContext.setViewport', {
    context: browser.context, viewport: { width: 1280, height: 900 }, devicePixelRatio: 1,
  });
  await browser.session.send('browsingContext.navigate', { context: browser.context, url: `${server.origin}/`, wait: 'complete' });
  await waitForValue(async () => {
    await evaluate("const p = document.querySelector('flt-semantics-placeholder'); if (p) p.click(); return 1;");
    return find((n) => line(n) === 'Paste Markdown');
  }, 'Home exposed through semantics', 120000);
  await delay(900);

  await click(await exact('Paste Markdown'));
  await exact('Open');
  await typeText(fixture);
  await delay(800);
  await click(await exact('Open'));
  await waitForValue(async () => !(await find((n) => line(n) === 'Paste Markdown')), 'Reader to open', 30000);
  await delay(1200);
  await snapshot('reader-loaded');

  const size = JSON.parse(await evaluate('return JSON.stringify({w: innerWidth, h: innerHeight});'));
  const menu = await waitForValue(() => find((n) => n.role === 'button' && !n.label &&
    n.x + n.w > size.w - 110 && n.y + n.h > size.h - 110), 'Reader menu', 15000);
  await click(menu);
  await click(await exact('Search document'));
  await delay(700);
  const field = await waitForValue(async () => JSON.parse(await evaluate(`
    const n = document.querySelector('input'); if (!n) return JSON.stringify(null); const r = n.getBoundingClientRect();
    return JSON.stringify(r.width && r.height ? {x: r.x, y: r.y, w: r.width, h: r.height} : null);
  `)), 'Search field', 15000);
  await click(field);
  await typeText('SECTION-18-START');
  await delay(900);
  await click(await waitForValue(() => find((n) => /^Result 1 of \d+\./.test(n.label || '')), 'result row', 15000));
  await delay(900);
  await snapshot('before-close');
  await click(await exact('Close search'));
  await delay(1600);
  await snapshot('after-close');
  result.completed = true;
} catch (error) {
  result.completed = false; result.error = String(error?.stack || error); process.stderr.write(result.error + '\n');
} finally {
  result.finishedAt = new Date().toISOString();
  if (browser) await browser.close();
  await server.close();
  await removeDirectory(profile).catch(() => {});
  await writeFile(outputPath, JSON.stringify(result, null, 2) + '\n');
}
if (!result.completed) process.exitCode = 1;
