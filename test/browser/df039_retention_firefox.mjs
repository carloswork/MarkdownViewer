// DF-039 runtime verification for browser-local retention, Firefox / Gecko,
// over WebDriver BiDi.
//
// Verification support, not product code. Nothing here is imported by `lib/`.
//
//   node test/browser/df039_retention_firefox.mjs \
//     --browser "<path to firefox.exe>" --bundle build/web \
//     --legacy <v1.1.0 bundle dir> --out <evidence dir>
//
// It runs the same scenarios and assertions as df039_retention_chromium.mjs:
// default OFF is current-session only and forgets on relaunch; ON stores the
// document and reading place, relaunches to Home and restores the place; ON to
// OFF removal is verified in IndexedDB; a real v1.1.0 profile is migrated at the
// same origin; and no request leaves the origin and no CSP violation occurs.
//
// Three differences are deliberate and disclosed:
//
//  1. Transport is WebDriver BiDi, because Firefox does not speak CDP.
//  2. Documents enter through Paste Markdown, typed key by key. BiDi cannot fill
//     the transient <input type="file"> this app's picker creates, so the other
//     document-entry path the product ships is used. Both paths end in the same
//     document-opening code; what Firefox does not independently cover is the
//     Load from file transition itself, which Chrome and Edge verify.
//  3. Between the v1.1.0 and DF-039 bundles, service workers and Cache Storage are
//     cleared by script from a same-origin page, because BiDi has no equivalent of
//     CDP's Storage.clearDataForOrigin. IndexedDB is never touched.
//
// Off-origin requests are counted only for the page's own browsing context.
// Firefox makes background requests of its own, which are not the app's and
// must not be mistaken for a leak - and if network monitoring cannot be
// subscribed at all, the check fails rather than passing vacuously.

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { extname, join, normalize, resolve, sep } from 'node:path';
import { delay, removeDirectory, waitForValue } from './df031_cdp.mjs';

function argument(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  if (index === -1) {
    if (fallback === undefined) throw new Error(`missing --${name}`);
    return fallback;
  }
  return process.argv[index + 1];
}

const BROWSER = argument('browser');
const NAME = argument('name', 'firefox');
const BUNDLE = resolve(argument('bundle'));
const LEGACY = resolve(argument('legacy'));
const OUT = resolve(argument('out'));
const FIXTURE = resolve(argument(
  'fixture',
  join('test', 'browser', 'df039_fixtures', 'paste_long.md'),
));
const FIXTURE_TITLE = 'DF-039 paste fixture';

const evidence = {
  harness: 'df039_retention_firefox',
  transport: 'WebDriver BiDi',
  documentEntry: 'Paste Markdown (typed)',
  browser: BROWSER,
  name: NAME,
  startedAt: new Date().toISOString(),
  steps: [],
  failures: 0,
};

function record(step, data) {
  evidence.steps.push({ step, ...data });
  console.log(`${data.pass === false ? 'FAIL' : data.pass === true ? 'PASS' : 'NOTE'}  ${step}`);
}

function expect(step, pass, data = {}) {
  record(step, { pass: Boolean(pass), ...data });
  if (!pass) evidence.failures += 1;
}

async function sha256(path) {
  return createHash('sha256').update(await readFile(path)).digest('hex');
}

// --- A static server whose root can change while its origin cannot ----------
// The same server as the Chromium harness: both bundles must share one origin,
// because IndexedDB is scoped by origin.

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.css': 'text/css; charset=utf-8',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.svg': 'image/svg+xml',
  '.otf': 'font/otf',
  '.ttf': 'font/ttf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.bin': 'application/octet-stream',
  '.frag': 'application/octet-stream',
};

async function serveSwitchable(initialRoot) {
  let root = resolve(initialRoot);
  const requestLog = [];
  const server = createServer(async (request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1');
    requestLog.push({ root: root === BUNDLE ? 'df039' : 'v1.1.0', path: url.pathname });
    let relative = decodeURIComponent(url.pathname);
    if (relative === '/' || relative === '') relative = '/index.html';
    const target = normalize(join(root, relative));
    if (!target.startsWith(root + sep) && target !== root) {
      response.writeHead(403).end('Forbidden');
      return;
    }
    try {
      const info = await stat(target);
      if (!info.isFile()) throw new Error('not a file');
      response.writeHead(200, {
        'Content-Type': MIME[extname(target).toLowerCase()] ?? 'application/octet-stream',
        'Content-Length': info.size,
        'Cache-Control': 'no-store',
      });
      createReadStream(target).pipe(response);
    } catch {
      response.writeHead(404, { 'Content-Type': 'text/plain', 'Cache-Control': 'no-store' }).end('Not found');
    }
  });
  await new Promise((done, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', done);
  });
  const { port } = server.address();
  return {
    origin: `http://127.0.0.1:${port}`,
    requestLog,
    setRoot(next) {
      root = resolve(next);
    },
    async close() {
      if (!server.listening) return;
      await new Promise((done) => server.close(done));
    },
  };
}

// --- BiDi transport ------------------------------------------------------------

class BidiSession {
  constructor(url) {
    this.socket = new WebSocket(url);
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = new Map();
  }

  async connect() {
    await new Promise((done, reject) => {
      this.socket.addEventListener('open', done, { once: true });
      this.socket.addEventListener('error', reject, { once: true });
    });
    this.socket.addEventListener('message', (event) => {
      const message = JSON.parse(event.data);
      if (message.type === 'event') {
        for (const listener of this.listeners.get(message.method) ?? []) listener(message.params);
        return;
      }
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.type === 'error') {
        pending.reject(new Error(`${pending.method}: ${message.error} ${message.message}`));
      } else {
        pending.resolve(message.result);
      }
    });
  }

  on(method, listener) {
    const listeners = this.listeners.get(method) ?? [];
    listeners.push(listener);
    this.listeners.set(method, listeners);
  }

  send(method, params = {}) {
    const id = this.nextId++;
    return new Promise((done, reject) => {
      this.pending.set(id, { resolve: done, reject, method });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  close() {
    try { this.socket.close(); } catch { /* already gone */ }
  }
}

async function launchFirefox(profile) {
  await mkdir(profile, { recursive: true });
  await writeFile(join(profile, 'user.js'), [
    'user_pref("layout.css.prefers-color-scheme.content-override", 1);',
    'user_pref("browser.shell.checkDefaultBrowser", false);',
    'user_pref("browser.startup.homepage_override.mstone", "ignore");',
    'user_pref("browser.sessionstore.resume_from_crash", false);',
    'user_pref("datareporting.policy.dataSubmissionEnabled", false);',
    'user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);',
    'user_pref("app.update.auto", false);',
    'user_pref("remote.prefs.recommended", true);',
  ].join('\n'));

  const child = spawn(BROWSER, [
    '--headless',
    '--no-remote',
    '--new-instance',
    '--profile', profile,
    '--remote-debugging-port', '0',
    '--width', '1024',
    '--height', '1400',
    'about:blank',
  ], { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });

  let output = '';
  child.stderr.setEncoding('utf8');
  child.stdout.setEncoding('utf8');
  child.stderr.on('data', (chunk) => { output += chunk; });
  child.stdout.on('data', (chunk) => { output += chunk; });

  const url = await waitForValue(
    async () => output.match(/WebDriver BiDi listening on (ws:\/\/\S+)/)?.[1] ?? null,
    'Firefox WebDriver BiDi endpoint',
    60000,
  );

  const session = new BidiSession(`${url}/session`);
  await session.connect();
  const created = await session.send('session.new', {
    capabilities: { alwaysMatch: { acceptInsecureCerts: true } },
  });
  const tree = await session.send('browsingContext.getTree', {});
  return {
    child,
    session,
    context: tree.contexts[0].context,
    version: created.capabilities?.browserVersion ?? null,
    async close() {
      // Graceful shutdown releases the profile lock before the next launch.
      await Promise.race([session.send('browser.close').catch(() => {}), delay(4000)]);
      session.close();
      await Promise.race([
        new Promise((done) => (child.exitCode === null ? child.once('exit', done) : done())),
        delay(10000),
      ]);
      if (child.exitCode === null) child.kill();
      await delay(1500);
    },
  };
}

// --- Page probes -------------------------------------------------------------------
// Template literals evaluated in the page: a regular-expression backslash must be
// written doubled to survive into it. BiDi serialises plain values awkwardly, so
// probes return JSON strings.

const SEMANTICS = `
  return JSON.stringify([...document.querySelectorAll('flt-semantics')].map(n => {
    const r = n.getBoundingClientRect();
    const describedby = (n.getAttribute('aria-describedby') || '')
      .split(/\\s+/).filter(Boolean)
      .map(id => document.getElementById(id)?.textContent ?? '')
      .join('\\n');
    return {
      role: n.getAttribute('role'),
      label: n.getAttribute('aria-label'),
      description: n.getAttribute('aria-description'),
      describedby: describedby || null,
      text: (n.childNodes.length && n.firstChild.nodeType === 3 ? n.textContent : null),
      all: n.textContent || '',
      checked: n.getAttribute('aria-checked'),
      x: Math.round(r.x), y: Math.round(r.y),
      w: Math.round(r.width), h: Math.round(r.height),
    };
  }));
`;

// Never creates the store's database: opening a missing IndexedDB database
// creates an empty one, and Hive would then fail to create its object store.
const STORAGE = `
  const dbs = indexedDB.databases ? await indexedDB.databases() : null;
  if (dbs && !dbs.some(d => d.name === 'markdown_viewer')) {
    return JSON.stringify({ database: false, keys: [] });
  }
  const db = await new Promise((res, rej) => {
    const r = indexedDB.open('markdown_viewer');
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  });
  if (!db.objectStoreNames.length) { db.close(); return JSON.stringify({ database: true, keys: [] }); }
  const storeName = db.objectStoreNames[0];
  const read = (key) => new Promise((res, rej) => {
    const r = db.transaction(storeName, 'readonly').objectStore(storeName).get(key);
    r.onsuccess = () => res(r.result ?? null);
    r.onerror = () => rej(r.error);
  });
  const keys = await new Promise((res, rej) => {
    const r = db.transaction(storeName, 'readonly').objectStore(storeName).getAllKeys();
    r.onsuccess = () => res(r.result.map(String));
    r.onerror = () => rej(r.error);
  });
  const parse = (raw) => { try { return raw == null ? null : JSON.parse(raw); } catch { return { unparseable: true }; } };
  const documentRaw = parse(await read('document'));
  const positionRaw = parse(await read('position'));
  const settingsRaw = parse(await read('settings'));
  db.close();
  return JSON.stringify({
    database: true,
    storeName,
    keys,
    document: documentRaw && {
      id: documentRaw.id, title: documentRaw.title,
      sourceName: documentRaw.sourceName ?? null,
      sourceLength: (documentRaw.source || '').length,
    },
    position: positionRaw && {
      documentId: positionRaw.documentId, blockIndex: positionRaw.blockIndex,
    },
    settings: settingsRaw,
  });
`;

const CSP_PRELOAD = `() => {
  window.__df039Csp = [];
  document.addEventListener('securitypolicyviolation', (e) => {
    window.__df039Csp.push({ directive: e.violatedDirective, blocked: e.blockedURI });
  });
}`;

/// Everything a semantics node announces, wherever Flutter published it.
function haystack(n) {
  return [n.label, n.description, n.describedby, n.all].filter(Boolean).join('\n');
}

// --- Driver ----------------------------------------------------------------------

class App {
  constructor(browser) {
    this.s = browser.session;
    this.context = browser.context;
  }

  async evaluate(expression) {
    const result = await this.s.send('script.evaluate', {
      expression: `(async () => { ${expression} })()`,
      target: { context: this.context },
      awaitPromise: true,
      resultOwnership: 'none',
    });
    if (result.type === 'exception') {
      throw new Error(`Page exception: ${JSON.stringify(result.exceptionDetails?.text ?? result)}`);
    }
    return result.result?.value;
  }

  async json(expression) {
    return JSON.parse(await this.evaluate(expression));
  }

  navigate(url) {
    return this.s.send('browsingContext.navigate', { context: this.context, url, wait: 'complete' });
  }

  nodes() {
    return this.json(SEMANTICS);
  }

  storage() {
    return this.json(STORAGE);
  }

  firstLine(node) {
    return (node.text ?? node.label ?? node.all ?? '').split('\n')[0].trim();
  }

  async has(needle) {
    return (await this.nodes()).some((n) => haystack(n).includes(needle));
  }

  mostSpecific(nodes) {
    return nodes.sort((a, b) => a.w * a.h - b.w * b.h)[0] ?? null;
  }

  /// The most specific node announcing [needle] - smallest by area, because an
  /// ancestor's text content includes every descendant's text.
  async announcing(needle) {
    return this.mostSpecific(
      (await this.nodes()).filter((n) => haystack(n).includes(needle) && n.w > 0),
    );
  }

  async waitFor(needle, timeoutMs = 10000) {
    return waitForValue(
      async () => this.mostSpecific(
        (await this.nodes()).filter((n) => haystack(n).includes(needle) && n.w > 0),
      ),
      `text "${needle}"`,
      timeoutMs,
    );
  }

  /// A tap Flutter's gesture arena accepts: the move needs a duration and the
  /// press must be held, or the click is delivered but never resolved as a tap.
  async click(x, y) {
    await this.s.send('input.performActions', {
      context: this.context,
      actions: [{
        type: 'pointer',
        id: 'mouse',
        parameters: { pointerType: 'mouse' },
        actions: [
          { type: 'pointerMove', x: Math.round(x), y: Math.round(y), origin: 'viewport', duration: 100 },
          { type: 'pause', duration: 150 },
          { type: 'pointerDown', button: 0 },
          { type: 'pause', duration: 150 },
          { type: 'pointerUp', button: 0 },
        ],
      }],
    });
    await delay(700);
  }

  async tap(text, { timeoutMs = 10000 } = {}) {
    const node = await waitForValue(
      async () => (await this.nodes())
        .filter((n) => this.firstLine(n) === text && n.w > 0 && n.h > 0)
        .sort((a, b) => a.w * a.h - b.w * b.h)[0],
      `semantics node "${text}"`,
      timeoutMs,
    );
    await this.click(node.x + node.w / 2, node.y + node.h / 2);
    await delay(400);
    return node;
  }

  /// Selected by role, never by text: the migration notice also contains the
  /// words "Keep for next time".
  async keepControl() {
    return waitForValue(
      async () => (await this.nodes()).find(
        (n) => n.role === 'switch' && (n.label ?? '').startsWith('Keep for next time') && n.w > 0,
      ),
      'Keep for next time switch',
    );
  }

  async toggleKeep() {
    await this.openSettings();
    const node = await this.keepControl();
    await this.click(node.x + node.w / 2, node.y + node.h / 2);
    await delay(1500);
  }

  /// Whether Settings is showing, recognised by the retention switch, which
  /// exists nowhere else.
  async onSettings() {
    return (await this.nodes()).some(
      (n) => n.role === 'switch' && (n.label ?? '').startsWith('Keep for next time') && n.w > 0,
    );
  }

  /// Opens Settings from Home, where the retention choice and the saved-document
  /// removal live.
  async openSettings() {
    if (await this.onSettings()) return;
    await this.tap('Settings');
    await this.keepControl();
  }

  /// Returns from Settings to Home through its Back button.
  async closeSettings() {
    if (!(await this.onSettings())) return;
    const back = await waitForValue(
      async () => this.mostSpecific(
        (await this.nodes()).filter(
          (n) => [n.label, n.text, n.all].some((v) => (v ?? '').trim() === 'Back') && n.w > 0,
        ),
      ),
      'Settings Back button',
    );
    await this.click(back.x + back.w / 2, back.y + back.h / 2);
    await this.waitFor('Paste Markdown');
    await delay(600);
  }

  async escape() {
    await this.s.send('input.performActions', {
      context: this.context,
      actions: [{ type: 'key', id: 'keyboard', actions: [{ type: 'keyDown', value: '' }, { type: 'keyUp', value: '' }] }],
    });
    await delay(700);
  }

  /// Types [text] into the focused field. BiDi has no insert-text primitive, so
  /// this is a key source; newlines are sent as the normalised Enter key.
  async typeText(text) {
    const characters = [...text];
    for (let start = 0; start < characters.length; start += 250) {
      const actions = [];
      for (const character of characters.slice(start, start + 250)) {
        const value = character === '\n' ? '' : character;
        actions.push({ type: 'keyDown', value }, { type: 'keyUp', value });
      }
      await this.s.send('input.performActions', {
        context: this.context,
        actions: [{ type: 'key', id: 'keyboard', actions }],
      });
    }
  }

  async scrollBy(pixels) {
    const size = await this.json('return JSON.stringify({ w: innerWidth, h: innerHeight });');
    const x = Math.round(size.w / 2);
    const y = Math.round(size.h / 2);
    await this.s.send('input.performActions', {
      context: this.context,
      actions: [{ type: 'wheel', id: 'wheel', actions: [{ type: 'scroll', x, y, deltaX: 0, deltaY: pixels, origin: 'viewport' }] }],
    }).catch(() => {});
    await delay(350);
    await this.evaluate(`
      const target = document.querySelector('flt-glass-pane') ?? document.querySelector('flutter-view') ?? document.body;
      target.dispatchEvent(new WheelEvent('wheel', {
        deltaY: ${pixels}, deltaMode: 0, clientX: ${x}, clientY: ${y},
        bubbles: true, cancelable: true, composed: true,
      }));
      return 1;
    `);
    await delay(900);
  }

  /// The reader's position, read from the geometry of the blocks on screen.
  async blockSignature() {
    const size = await this.json('return JSON.stringify({ w: innerWidth, h: innerHeight });');
    return (await this.nodes())
      .filter((n) => !n.label && !n.text && n.role === null &&
        n.w > 600 && n.w < size.w - 20 && n.h > 20 && n.h < size.h &&
        n.y >= 0 && n.y < size.h)
      .map((n) => [n.y, n.h])
      .sort((a, b) => a[0] - b[0])
      .slice(0, 8);
  }

  async openReaderMenu() {
    const size = await this.json('return JSON.stringify({ w: innerWidth, h: innerHeight });');
    for (let attempt = 0; attempt < 3; attempt++) {
      const node = await waitForValue(
        async () => (await this.nodes()).find(
          (n) => n.role === 'button' && !n.text && !n.label &&
            n.w > 20 && n.w <= 70 && n.h > 20 && n.h <= 70 &&
            n.x + n.w > size.w - 110 && n.y + n.h > size.h - 110,
        ),
        'reader menu button',
      );
      await this.click(node.x + node.w / 2, node.y + node.h / 2);
      await delay(900);
      if (await this.has('Return to main')) return;
      await this.scrollBy(-120);
    }
    throw new Error('the reader menu did not open');
  }

  async returnHome() {
    await this.openReaderMenu();
    await this.tap('Return to main');
    await this.waitFor('Paste Markdown');
  }

  /// Enters [source] through Paste Markdown, the path BiDi can drive.
  async pasteDocument(source) {
    await this.tap('Paste Markdown');
    await delay(1000);
    // Replacing a document is confirmed before the editor opens on this path.
    if (await this.has('Replace current document?')) {
      await this.tap('Replace');
      await delay(1200);
    }
    await waitForValue(
      async () => (await this.nodes()).some((n) => this.firstLine(n) === 'Open'),
      'the paste editor',
    );
    await this.typeText(source);
    await delay(1200);
    await this.tap('Open');
    await waitForValue(async () => !(await this.has('Paste Markdown')), 'the reader to open', 20000);
    await delay(1500);
  }

  async cspViolations() {
    const raw = await this.evaluate('return JSON.stringify(window.__df039Csp ?? null);');
    return JSON.parse(raw);
  }
}

// --- Session lifecycle -------------------------------------------------------------

async function open(profile, server, { clearCaches = false } = {}) {
  const browser = await launchFirefox(profile);
  evidence.browserVersion ??= browser.version;
  const app = new App(browser);
  const s = browser.session;
  await s.send('browsingContext.setViewport', {
    context: browser.context, viewport: { width: 1024, height: 1400 },
  }).catch(() => { /* keep the window size from the command line */ });

  const offOrigin = [];
  let networkMonitored = true;
  s.on('network.beforeRequestSent', (params) => {
    if (params.context !== browser.context) return;
    const url = params.request?.url ?? '';
    if (!url.startsWith(server.origin) && !/^(data|blob|about|moz-extension|resource|chrome):/.test(url)) {
      offOrigin.push(url);
    }
  });
  try {
    await s.send('session.subscribe', { events: ['network.beforeRequestSent'] });
  } catch (error) {
    networkMonitored = false;
    record('network monitoring unavailable', { note: String(error) });
  }
  await s.send('script.addPreloadScript', { functionDeclaration: CSP_PRELOAD });

  if (clearCaches) {
    // A same-origin page that is not the app, so nothing the app would run is
    // loaded before its caches are gone. IndexedDB is deliberately untouched.
    await app.navigate(`${server.origin}/__df039_clear_caches`);
    const cleared = await app.json(`
      const registrations = navigator.serviceWorker ? await navigator.serviceWorker.getRegistrations() : [];
      for (const r of registrations) await r.unregister();
      const names = globalThis.caches ? await caches.keys() : [];
      for (const n of names) await caches.delete(n);
      return JSON.stringify({ serviceWorkers: registrations.length, caches: names.length });
    `);
    record('cleared service workers and Cache Storage before serving this build', { cleared });
  }

  await app.navigate(`${server.origin}/`);
  await waitForValue(
    async () => app.evaluate(`return !!document.querySelector('flt-semantics-placeholder');`),
    'Flutter bootstrap',
    45000,
  );
  await delay(2500);
  await app.evaluate(`document.querySelector('flt-semantics-placeholder').click(); return 1;`);
  await delay(1500);
  return { browser, app, offOrigin, networkMonitored };
}

async function close(session, label) {
  const csp = await session.app.cspViolations().catch(() => null);
  evidence.pageLifetimes ??= [];
  evidence.pageLifetimes.push({
    label, cspViolations: csp, networkMonitored: session.networkMonitored, offOriginRequests: session.offOrigin,
  });
  expect(`${label}: no Content-Security-Policy violation`, Array.isArray(csp) && csp.length === 0, { csp });
  expect(`${label}: no off-origin request`,
    session.networkMonitored && session.offOrigin.length === 0,
    { networkMonitored: session.networkMonitored, offOrigin: session.offOrigin });
  await session.browser.close();
}

// --- The run -------------------------------------------------------------------------

await mkdir(OUT, { recursive: true });
const SOURCE = await readFile(FIXTURE, 'utf8');
evidence.bundles = {
  df039: { root: BUNDLE, mainDartJsSha256: await sha256(join(BUNDLE, 'main.dart.js')) },
  legacy: { root: LEGACY, mainDartJsSha256: await sha256(join(LEGACY, 'main.dart.js')) },
  fixture: { path: FIXTURE, sha256: await sha256(FIXTURE), characters: [...SOURCE].length },
};
expect('the two bundles are different builds',
  evidence.bundles.df039.mainDartJsSha256 !== evidence.bundles.legacy.mainDartJsSha256,
  { bundles: evidence.bundles });

const server = await serveSwitchable(BUNDLE);
evidence.origin = server.origin;
const freshProfile = join(OUT, `${NAME}-profile-fresh`);
const legacyProfile = join(OUT, `${NAME}-profile-legacy`);
let session;

try {
  // ===== 1. Default OFF: current session only ======================================
  session = await open(freshProfile, server);
  let app = session.app;
  expect('1a fresh profile: no Continue reading', !(await app.has('Continue reading')));
  const settingsEntry = await app.announcing('Keep for next time is off');
  expect('1a fresh profile: Home states the choice is off, on its Settings entry',
    settingsEntry !== null && haystack(settingsEntry).includes('Settings'), { settingsEntry });
  await app.openSettings();
  let keep = await app.keepControl();
  expect('1a fresh profile: the Settings switch is off', keep.checked === 'false', { keep });
  await app.closeSettings();

  await app.pasteDocument(SOURCE);
  await app.scrollBy(900);
  await app.scrollBy(-120);
  await delay(1200);
  await app.returnHome();
  const continueOff = await app.announcing('Continue reading');
  expect('1b OFF: Continue is offered and announced as this session only',
    continueOff !== null && haystack(continueOff).includes('Current session only') &&
      !(await app.has('Saved in this browser')),
    { continueNode: continueOff });
  const offStorage = await app.storage();
  expect('1c OFF: no document and no position in IndexedDB',
    !offStorage.keys.includes('document') && !offStorage.keys.includes('position'),
    { storage: offStorage });
  await close(session, '1 OFF session');

  session = await open(freshProfile, server);
  app = session.app;
  expect('1d OFF relaunch: the document is gone and nothing offers to continue',
    !(await app.has('Continue reading')) && !(await app.has('Remove unreadable saved data')));

  // ===== 2. ON: stored, Home-first, restored ====================================
  await app.toggleKeep();
  keep = await app.keepControl();
  expect('2a turning the choice on takes effect', keep.checked === 'true', { keep });
  const afterOn = await app.storage();
  expect('2a the choice itself is stored', afterOn.settings?.keepForNextTime === true, { storage: afterOn });
  await app.closeSettings();
  expect('2a Home now states the choice is on', await app.has('Keep for next time is on'));

  await app.pasteDocument(SOURCE);
  const topSignature = await app.blockSignature();
  await app.scrollBy(1400);
  await app.scrollBy(-120);
  await delay(1500);
  const leftSignature = await app.blockSignature();
  expect('2b precondition: the reader really moved away from the top',
    topSignature.length > 0 && leftSignature.length > 0 &&
      JSON.stringify(topSignature) !== JSON.stringify(leftSignature),
    { topSignature, leftSignature });
  await app.returnHome();
  const onStorage = await app.storage();
  expect('2c ON: document and a matching position are in IndexedDB',
    onStorage.document && onStorage.position && onStorage.position.documentId === onStorage.document.id &&
      onStorage.position.blockIndex > 0,
    { storage: onStorage });
  const continueOn = await app.announcing('Continue reading');
  expect('2c ON: Continue is announced as saved in this browser',
    continueOn !== null && haystack(continueOn).includes('Saved in this browser'),
    { continueNode: continueOn });
  await close(session, '2 ON session');

  session = await open(freshProfile, server);
  app = session.app;
  const continueRelaunch = await app.announcing('Continue reading');
  expect('2d ON relaunch: lands on Home, not in the reader, with a saved Continue',
    (await app.has('Paste Markdown')) && continueRelaunch !== null &&
      haystack(continueRelaunch).includes('Saved in this browser'),
    { continueNode: continueRelaunch });
  await app.tap('Continue reading');
  await waitForValue(async () => !(await app.has('Paste Markdown')), 'the reader to open', 20000);
  await delay(1500);
  const restoredSignature = await app.blockSignature();
  expect('2e ON relaunch: Continue restores the reading place, not the top',
    restoredSignature.length > 0 &&
      JSON.stringify(restoredSignature) !== JSON.stringify(topSignature),
    {
      topSignature,
      leftSignature,
      restoredSignature,
      stored: onStorage.position,
      matchesWhereReadingStopped: JSON.stringify(restoredSignature) === JSON.stringify(leftSignature),
    });

  // ===== 3. ON -> OFF: verified removal ===========================================
  await app.returnHome();
  await app.toggleKeep();
  await app.waitFor('Removed from this browser.');
  const afterOff = await app.storage();
  expect('3a ON->OFF: document and position are gone from IndexedDB',
    !afterOff.keys.includes('document') && !afterOff.keys.includes('position'),
    { storage: afterOff });
  expect('3a ON->OFF: the OFF choice is stored', afterOff.settings?.keepForNextTime === false, { storage: afterOff });
  await close(session, '3 ON->OFF session');

  session = await open(freshProfile, server);
  app = session.app;
  const continueAfterRemoval = await app.has('Continue reading');
  await app.openSettings();
  keep = await app.keepControl();
  expect('3b after removal, a relaunch offers nothing and the choice is off',
    !continueAfterRemoval && keep.checked === 'false', { keep, continueAfterRemoval });
  await close(session, '3 relaunch');

  // ===== 4. Real v1.1.0 profile opened by this build ===============================
  server.setRoot(LEGACY);
  session = await open(legacyProfile, server);
  app = session.app;
  expect('4a v1.1.0 bundle: has no retention choice', !(await app.has('Keep for next time')));
  await app.pasteDocument(SOURCE);
  await app.scrollBy(1400);
  await app.scrollBy(-120);
  await delay(1500);
  let legacySettingsCreated = false;
  try {
    await app.openReaderMenu();
    await app.tap('Appearance');
    await app.tap('Dark');
    await app.escape();
    legacySettingsCreated = true;
  } catch (error) {
    record('4a note: could not change appearance in v1.1.0', { note: String(error) });
  }
  await delay(1200);
  const legacyStorage = await app.storage();
  expect('4b v1.1.0 kept the document and position automatically',
    legacyStorage.document && legacyStorage.position, { storage: legacyStorage });
  if (legacySettingsCreated) {
    expect('4b v1.1.0 settings record has no retention field',
      legacyStorage.settings && !('keepForNextTime' in legacyStorage.settings), { storage: legacyStorage });
  }
  await close(session, '4 v1.1.0 session');

  server.setRoot(BUNDLE);
  session = await open(legacyProfile, server, { clearCaches: true });
  app = session.app;
  const migrated = await app.storage();
  expect('4c this build removed the v1.1.0 document and position before anything showed them',
    !migrated.keys.includes('document') && !migrated.keys.includes('position'), { storage: migrated });
  expect('4c Home reports the removal and offers nothing to continue',
    (await app.has('Previously saved reading data was removed')) && !(await app.has('Continue reading')));
  expect('4c no identity of the removed document is shown',
    !(await app.has('Pasted document')) && !(await app.has(FIXTURE_TITLE)));
  await app.openSettings();
  keep = await app.keepControl();
  expect('4c the choice starts off', keep.checked === 'false', { keep });
  if (legacySettingsCreated) {
    expect('4d appearance settings survived the removal',
      migrated.settings?.appearance === 'dark', { storage: migrated });
  }
  await close(session, '4 migrated session');

  evidence.requestLog = server.requestLog;
  evidence.requestLogCount = server.requestLog.length;
} catch (error) {
  evidence.failures += 1;
  evidence.fatal = String(error?.stack ?? error);
  console.error(error);
  try { await session?.browser.close(); } catch { /* already gone */ }
} finally {
  await server.close();
  evidence.finishedAt = new Date().toISOString();
  const file = join(OUT, `${NAME}-df039-evidence.json`);
  await writeFile(file, JSON.stringify(evidence, null, 2));
  await removeDirectory(freshProfile);
  await removeDirectory(legacyProfile);
  console.log(`\n${evidence.failures === 0 ? 'ALL PASSED' : `${evidence.failures} FAILURE(S)`} - ${file}`);
  process.exitCode = evidence.failures === 0 ? 0 : 1;
}
