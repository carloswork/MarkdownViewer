// DF-039 runtime verification for browser-local retention, Chromium engines
// (Chrome and Edge).
//
// Verification support, not product code. Nothing here is imported by `lib/`.
// It drives a real release bundle in a real browser against real IndexedDB and
// records evidence for the retention behaviour that widget tests cannot reach:
//
//   1. With "Keep for next time" off (the default), a document is kept for the
//      current session only, nothing is written to storage, and a relaunch
//      forgets it.
//   2. With it on, the document and reading place are stored, a relaunch lands
//      on Home rather than in the reader, and "Continue reading" restores the
//      place.
//   3. Turning it off removes both, verified by reading IndexedDB directly.
//   4. A profile created by the real, previously deployed v1.1.0 bundle - which
//      kept documents automatically - is opened by this build at the same
//      origin, and the old document is removed before it can be reached.
//   5. Every request stays on the serving origin, and no Content-Security-Policy
//      violation occurs.
//
//   node test/browser/df039_retention_chromium.mjs \
//     --browser "C:\Program Files\Google\Chrome\Application\chrome.exe" \
//     --name chrome --bundle build/web --legacy <v1.1.0 bundle dir> \
//     --out <evidence dir>
//
// The two bundles must be served at the *same* origin, because IndexedDB is
// scoped by origin. The shared `serveBundle` helper binds a random port per
// root, so this harness runs its own server whose root can be switched while
// the port stays fixed.
//
// Two facts about Flutter web's semantics tree shape the probes below. Rendered
// Markdown blocks publish a node with a layout box but no text, so reading
// position is read from block geometry rather than from headings. And the text
// a control announces may sit in `aria-label`, in `aria-description`, or in an
// element referenced by `aria-describedby`, so text is searched in all three.

import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { extname, join, normalize, resolve, sep } from 'node:path';
import {
  delay,
  launchChromium,
  removeDirectory,
  waitForValue,
} from './df031_cdp.mjs';

function argument(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  if (index === -1) {
    if (fallback === undefined) throw new Error(`missing --${name}`);
    return fallback;
  }
  return process.argv[index + 1];
}

const BROWSER = argument('browser');
const NAME = argument('name');
const BUNDLE = resolve(argument('bundle'));
const LEGACY = resolve(argument('legacy'));
const OUT = resolve(argument('out'));
const FIXTURE = resolve(argument(
  'fixture',
  join('test', 'browser', 'df039_fixtures', 'long.md'),
));

const evidence = {
  harness: 'df039_retention_chromium',
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
        // Only IndexedDB may survive between launches. A cached main.dart.js
        // would let the v1.1.0 bundle masquerade as this build after the swap.
        'Cache-Control': 'no-store',
      });
      createReadStream(target).pipe(response);
    } catch {
      response.writeHead(404, { 'Content-Type': 'text/plain' }).end('Not found');
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

// --- Page probes ---------------------------------------------------------------

// Note on escapes: these probes are template literals evaluated in the page, so
// a regular-expression backslash must be written doubled to survive into it.
const SEMANTICS = `
  return [...document.querySelectorAll('flt-semantics')].map(n => {
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
      disabled: n.getAttribute('aria-disabled'),
      x: Math.round(r.x), y: Math.round(r.y),
      w: Math.round(r.width), h: Math.round(r.height),
    };
  });
`;

// Reads the store's raw keys without ever *creating* its database. Opening an
// IndexedDB database that does not exist creates an empty one, and Hive would
// then find a database with no object store and fail to open its box.
const STORAGE = `
  const dbs = indexedDB.databases ? await indexedDB.databases() : null;
  if (dbs && !dbs.some(d => d.name === 'markdown_viewer')) {
    return { database: false, keys: [] };
  }
  const db = await new Promise((res, rej) => {
    const r = indexedDB.open('markdown_viewer');
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  });
  if (!db.objectStoreNames.length) { db.close(); return { database: true, keys: [] }; }
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
  return {
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
  };
`;

const CSP_COLLECTOR = `
  window.__df039Csp = [];
  document.addEventListener('securitypolicyviolation', (e) => {
    window.__df039Csp.push({ directive: e.violatedDirective, blocked: e.blockedURI });
  });
`;

/// Everything a semantics node announces, wherever Flutter published it.
function haystack(n) {
  return [n.label, n.description, n.describedby, n.all].filter(Boolean).join('\n');
}

// --- Driver ----------------------------------------------------------------------

class App {
  constructor(session) {
    this.s = session;
  }

  nodes() {
    return this.s.evaluate(SEMANTICS);
  }

  storage() {
    return this.s.evaluate(STORAGE);
  }

  firstLine(node) {
    return (node.text ?? node.label ?? node.all ?? '').split('\n')[0].trim();
  }

  async has(needle) {
    return (await this.nodes()).some((n) => haystack(n).includes(needle));
  }

  /// The smallest node in [nodes], or null.
  mostSpecific(nodes) {
    return nodes.sort((a, b) => a.w * a.h - b.w * b.h)[0] ?? null;
  }

  /// The most specific node announcing [needle], if any.
  ///
  /// Smallest by area, not first in document order. A full-screen container's
  /// text content includes every descendant's text, so the first match is an
  /// ancestor that announces nothing itself - which is exactly what an earlier
  /// version of this harness recorded. The control's own node is the smallest.
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

  async click(x, y) {
    await this.s.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y, button: 'none', buttons: 0 });
    await this.s.send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1 });
    await delay(40);
    await this.s.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', buttons: 0, clickCount: 1 });
  }

  /// Clicks the smallest visible semantics node whose first line is [text].
  async tap(text, { timeoutMs = 10000 } = {}) {
    const node = await waitForValue(
      async () => (await this.nodes())
        .filter((n) => this.firstLine(n) === text && n.w > 0 && n.h > 0)
        .sort((a, b) => a.w * a.h - b.w * b.h)[0],
      `semantics node "${text}"`,
      timeoutMs,
    );
    await this.click(node.x + node.w / 2, node.y + node.h / 2);
    await delay(900);
    return node;
  }

  /// The "Keep for next time" switch, with its checked and disabled state.
  ///
  /// Selected by role, never by text: the migration notice also contains the
  /// words "Keep for next time", and a text match picked the notice instead.
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
    for (const type of ['keyDown', 'keyUp']) {
      await this.s.send('Input.dispatchKeyEvent', { type, key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27, nativeVirtualKeyCode: 27 });
    }
    await delay(700);
  }

  async scrollBy(pixels) {
    const size = await this.s.evaluate('return { w: innerWidth, h: innerHeight };');
    const x = Math.round(size.w / 2);
    const y = Math.round(size.h / 2);
    await this.s.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y, button: 'none', buttons: 0 });
    await this.s.send('Input.dispatchMouseEvent', { type: 'mouseWheel', x, y, deltaX: 0, deltaY: pixels, button: 'none', buttons: 0 });
    await delay(350);
    await this.s.evaluate(`
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
  ///
  /// Rendered Markdown blocks publish a semantics node with a layout box but no
  /// text, so position cannot be read from headings. Block heights differ, so
  /// the offsets and heights of the visible blocks identify where in the
  /// document the viewport sits. Full-viewport containers are excluded.
  async blockSignature() {
    const size = await this.s.evaluate('return { w: innerWidth, h: innerHeight };');
    return (await this.nodes())
      .filter((n) => !n.label && !n.text && n.role === null &&
        n.w > 600 && n.w < size.w - 20 && n.h > 20 && n.h < size.h &&
        n.y >= 0 && n.y < size.h)
      .map((n) => [n.y, n.h])
      .sort((a, b) => a[0] - b[0])
      .slice(0, 8);
  }

  /// The reader's persistent menu button, pinned bottom-right. It hides while
  /// reading forward, so a failed open is retried after a small upward scroll.
  async openReaderMenu() {
    const size = await this.s.evaluate('return { w: innerWidth, h: innerHeight };');
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
    await this.waitFor('Load from file');
  }

  async loadFixture(chooser) {
    chooser.value = null;
    await this.tap('Load from file');
    const opened = await waitForValue(async () => chooser.value, 'file chooser', 8000);
    await this.s.send('DOM.setFileInputFiles', { files: [FIXTURE], backendNodeId: opened.backendNodeId });
    await delay(1500);
    if (await this.has('Replace current document?')) await this.tap('Replace');
    await waitForValue(async () => !(await this.has('Load from file')), 'the reader to open', 15000);
    await delay(1200);
  }

  cspViolations() {
    return this.s.evaluate('return window.__df039Csp ?? [];');
  }
}

// --- Session lifecycle -------------------------------------------------------------

async function open(profile, server, { clearCaches = false } = {}) {
  const browser = await launchChromium(BROWSER, { profileDirectory: profile, windowSize: '1024,1400' });
  const s = browser.session;
  const chooser = { value: null };
  const offOrigin = [];
  s.on('Page.fileChooserOpened', (p) => { chooser.value = p; });
  s.on('Network.requestWillBeSent', ({ request }) => {
    const url = request.url;
    if (!url.startsWith(server.origin) && !/^(data|blob|about|chrome|edge|devtools):/.test(url)) {
      offOrigin.push(url);
    }
  });
  await s.send('Runtime.enable');
  await s.send('Page.enable');
  await s.send('DOM.enable');
  await s.send('Network.enable');
  await s.send('Page.addScriptToEvaluateOnNewDocument', { source: CSP_COLLECTOR });
  await s.send('Page.setInterceptFileChooserDialog', { enabled: true });
  if (clearCaches) {
    // Service workers and Cache Storage only. IndexedDB is the thing under test
    // and must survive untouched.
    await s.send('Storage.clearDataForOrigin', {
      origin: server.origin,
      storageTypes: 'service_workers,cache_storage',
    });
  }
  await s.send('Page.navigate', { url: `${server.origin}/` });
  await waitForValue(
    async () => s.evaluate(`return !!document.querySelector('flt-semantics-placeholder');`),
    'Flutter bootstrap',
    30000,
  );
  await delay(2500);
  await s.evaluate(`document.querySelector('flt-semantics-placeholder').click(); return 1;`);
  await delay(1500);
  return { browser, app: new App(s), chooser, offOrigin };
}

async function close(session, label) {
  const csp = await session.app.cspViolations().catch(() => null);
  evidence.pageLifetimes ??= [];
  evidence.pageLifetimes.push({ label, cspViolations: csp, offOriginRequests: session.offOrigin });
  expect(`${label}: no Content-Security-Policy violation`, Array.isArray(csp) && csp.length === 0, { csp });
  expect(`${label}: no off-origin request`, session.offOrigin.length === 0, { offOrigin: session.offOrigin });
  await session.browser.close();
  await delay(800);
}

// --- The run -------------------------------------------------------------------------

await mkdir(OUT, { recursive: true });
evidence.bundles = {
  df039: { root: BUNDLE, mainDartJsSha256: await sha256(join(BUNDLE, 'main.dart.js')) },
  legacy: { root: LEGACY, mainDartJsSha256: await sha256(join(LEGACY, 'main.dart.js')) },
  fixture: { path: FIXTURE, sha256: await sha256(FIXTURE) },
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

  await app.loadFixture(session.chooser);
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

  await app.loadFixture(session.chooser);
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
    (await app.has('Load from file')) && continueRelaunch !== null &&
      haystack(continueRelaunch).includes('Saved in this browser'),
    { continueNode: continueRelaunch });
  await app.tap('Continue reading');
  await waitForValue(async () => !(await app.has('Load from file')), 'the reader to open', 15000);
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
      // Recorded rather than required: exact equality depends on the debounce
      // having flushed the very last scroll offset before the reader closed.
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
  await app.loadFixture(session.chooser);
  await app.scrollBy(1400);
  await app.scrollBy(-120);
  await delay(1500);
  // v1.1.0 writes its settings record only on an appearance change. Make one,
  // so the profile carries the exact settings shape that release wrote.
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
  const fixtureName = FIXTURE.split(/[\\/]/).pop();
  expect('4c no identity of the removed document is shown', !(await app.has(fixtureName)), { fixtureName });
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
