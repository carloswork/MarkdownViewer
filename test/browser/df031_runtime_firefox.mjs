// DF-031 CP-D1 runtime verification, Firefox / Gecko, over WebDriver BiDi.
//
// Verification support, not product code.
//
//   node test/browser/df031_runtime_firefox.mjs \
//     --browser "<path to firefox.exe>" --bundle build/web --out <evidence dir>
//
// Two environment facts shape this runner, and neither is a DF-031 defect:
//
//  1. Firefox speaks **WebDriver BiDi**, not CDP. `--remote-debugging-port`
//     prints `WebDriver BiDi listening on ws://...`, so the transport here is
//     BiDi rather than the CDP the Chromium runner uses.
//  2. On this machine Firefox **cannot capture screenshots at all** - headless
//     and headed, with acceleration disabled, it fails with
//     `RenderCompositorSWGL failed mapping default framebuffer`. So the Firefox
//     evidence is deliberately *behavioural*: fetched font assets, the parsed
//     print CSSOM, `FontFaceSet` state, canvas glyph rasterisation, the
//     semantics tree, and the persisted preference. There is no pixel evidence
//     from Firefox and this runner does not pretend otherwise.
//
// That split is not arbitrary. Flutter Web renders Viewer text through
// CanvasKit/Skia, which rasterises glyphs itself, so the Viewer glyph path is
// largely engine-independent. The print surface uses real DOM/CSS `@font-face`,
// which is exactly where a second engine earns its keep - and that is the part
// this runner asserts hardest.

import { spawn } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import {
  GLYPH_PROBE,
  PRINT_RULES,
  delay,
  removeDirectory,
  serveBundle,
  waitForValue,
} from './df031_cdp.mjs';

function argument(name, fallback) {
  const index = process.argv.indexOf(name);
  if (index === -1 || index + 1 >= process.argv.length) {
    if (fallback !== undefined) return fallback;
    throw new Error(`Missing required argument: ${name}`);
  }
  return process.argv[index + 1];
}

const BROWSER = argument('--browser');
const BUNDLE = resolve(argument('--bundle'));
const OUT = resolve(argument('--out'));
const FIXTURES = resolve(
  argument('--fixtures', join(import.meta.dirname, 'df031_fixtures')),
);
const NAME = 'firefox';

/// The Chromium run loads these fixtures through `Load from file`; Firefox
/// types them through `Paste Markdown` instead (see `loadFixture`). The paste
/// variants are shorter because every character is a key event, and their
/// detector verdicts are pinned in `df031_fixture_probe.dart`.
const PASTE_FIXTURES = {
  'english.md': 'paste_english.md',
  'traditional.md': 'paste_traditional.md',
  'simplified.md': 'paste_simplified.md',
};

const evidence = { browser: NAME, browserPath: BROWSER, transport: 'WebDriver BiDi', steps: [] };
function record(step, data) {
  evidence.steps.push({ step, ...data });
  const flag = data.pass === undefined ? '·' : data.pass ? 'PASS' : 'FAIL';
  console.log(`[${NAME}] ${flag} ${step}`);
  if (data.pass === false) console.log('    ' + JSON.stringify(data));
}
function expect(step, pass, data) {
  record(step, { pass, ...data });
  if (!pass) evidence.failures = (evidence.failures ?? 0) + 1;
}

// --- BiDi transport ----------------------------------------------------------

class BidiSession {
  constructor(url) {
    this.socket = new WebSocket(url);
    this.nextId = 1;
    this.pending = new Map();
    this.events = [];
  }

  async connect() {
    await new Promise((done, reject) => {
      this.socket.addEventListener('open', done, { once: true });
      this.socket.addEventListener('error', reject, { once: true });
    });
    this.socket.addEventListener('message', (event) => {
      const message = JSON.parse(event.data);
      if (message.type === 'event') {
        this.events.push(message);
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
  // Light scheme so the run matches the Chromium captures; the rest simply
  // keeps a first-run Firefox from doing anything but loading the page.
  await writeFile(join(profile, 'user.js'), [
    'user_pref("layout.css.prefers-color-scheme.content-override", 1);',
    'user_pref("browser.shell.checkDefaultBrowser", false);',
    'user_pref("browser.startup.homepage_override.mstone", "ignore");',
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
    '--width', '1280',
    '--height', '1600',
    'about:blank',
  ], { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });

  let stderr = '';
  let stdout = '';
  child.stderr.setEncoding('utf8');
  child.stdout.setEncoding('utf8');
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  child.stdout.on('data', (chunk) => { stdout += chunk; });

  const url = await waitForValue(
    async () => {
      const match = (stderr + stdout).match(/WebDriver BiDi listening on (ws:\/\/\S+)/);
      return match ? match[1] : null;
    },
    'Firefox WebDriver BiDi endpoint',
    60000,
  );

  // Firefox advertises the browser-level endpoint; a client creates a session
  // by connecting to `/session` on it. Connecting to the bare URL is refused.
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
    sessionId: created.sessionId,
    stderrText: () => stderr,
    async close() {
      session.close();
      if (child.exitCode === null) child.kill();
      await Promise.race([
        new Promise((done) => child.once('exit', done)),
        delay(6000),
      ]);
    },
  };
}

// --- Page driving ------------------------------------------------------------

class App {
  constructor(browser) {
    this.b = browser;
    this.s = browser.session;
    this.context = browser.context;
  }

  /// Evaluates [expression]; probes that return JSON strings are parsed by the
  /// caller. Page exceptions become Node errors rather than silent nulls.
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

  async navigate(url) {
    await this.s.send('browsingContext.navigate', { context: this.context, url, wait: 'complete' });
  }

  async nodes() {
    return this.json(`
      return JSON.stringify([...document.querySelectorAll('flt-semantics')].map(n => {
        const r = n.getBoundingClientRect();
        return {
          role: n.getAttribute('role'),
          label: n.getAttribute('aria-label'),
          text: n.childNodes.length && n.firstChild.nodeType === 3 ? n.textContent : null,
          x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height),
        };
      }));
    `);
  }

  async click(x, y) {
    await this.s.send('input.performActions', {
      context: this.context,
      actions: [{
        type: 'pointer',
        id: 'mouse',
        parameters: { pointerType: 'mouse' },
        // The move needs a duration and the press needs to be held: an
        // instantaneous move-down-up sequence is delivered but Flutter's
        // gesture arena does not resolve it as a tap, so the button never
        // fires. Verified against this app - without these pauses the same
        // click does nothing at all.
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
      async () => (await this.nodes()).find(
        (n) => (n.text ?? n.label ?? '').split('\n')[0].trim() === text && n.w > 0 && n.h > 0,
      ),
      `semantics node "${text}"`,
      timeoutMs,
    );
    await this.click(node.x + node.w / 2, node.y + node.h / 2);
    return node;
  }

  async openReaderMenu() {
    const size = await this.json('return JSON.stringify({ w: innerWidth, h: innerHeight });');
    const node = await waitForValue(
      async () => (await this.nodes()).find(
        (n) => n.role === 'button' && !n.text && !n.label &&
          n.w > 20 && n.w <= 70 && n.h > 20 && n.h <= 70 &&
          n.x + n.w > size.w - 110 && n.y + n.h > size.h - 110,
      ),
      'reader menu button',
    );
    await this.click(node.x + node.w / 2, node.y + node.h / 2);
    await delay(600);
    // Confirm the sheet actually opened; a tap that lands while the control is
    // faded out is swallowed silently.
    await waitForValue(
      async () => (await this.nodes()).some(
        (n) => (n.text ?? '').split('\n')[0].trim() === 'Return to main',
      ),
      'the reader menu',
    );
  }

  async menuTiles() {
    return (await this.nodes())
      .filter((n) => n.role === 'button' && n.text && n.w > 300)
      .sort((a, b) => a.y - b.y)
      .map((n) => ({ label: n.text.split('\n')[0].trim(), subtitle: n.text.split('\n')[1]?.trim() ?? null }));
  }

  async escape() {
    await this.s.send('input.performActions', {
      context: this.context,
      actions: [{
        type: 'key', id: 'keyboard',
        actions: [{ type: 'keyDown', value: '' }, { type: 'keyUp', value: '' }],
      }],
    });
    await delay(700);
  }

  async storedDocument() {
    return this.json(`
      const db = await new Promise((res, rej) => {
        const r = indexedDB.open('markdown_viewer');
        r.onsuccess = () => res(r.result);
        r.onerror = () => rej(r.error);
      });
      if (!db.objectStoreNames.length) return JSON.stringify(null);
      const storeName = db.objectStoreNames[0];
      const raw = await new Promise((res, rej) => {
        const r = db.transaction(storeName, 'readonly').objectStore(storeName).get('document');
        r.onsuccess = () => res(r.result);
        r.onerror = () => rej(r.error);
      });
      db.close();
      if (raw == null) return JSON.stringify(null);
      const p = JSON.parse(raw);
      return JSON.stringify({ id: p.id, title: p.title, updatedAt: p.updatedAt,
        scriptPreference: p.scriptPreference ?? null, sourceName: p.sourceName ?? null,
        sourceLength: (p.source || '').length });
    `);
  }

  async fontAssetRequests() {
    return this.json(`
      return JSON.stringify(performance.getEntriesByType('resource')
        .filter(e => e.name.indexOf('/assets/fonts/') !== -1)
        .map(e => ({ name: e.name.split('/assets/fonts/')[1], decodedBodySize: e.decodedBodySize, transferSize: e.transferSize })));
    `);
  }

  async printState() {
    return this.json(`
      const surface = document.getElementById('df026-print');
      return JSON.stringify({
        surfacePresent: !!surface,
        fontsAttribute: surface && surface.getAttribute('data-df026-fonts'),
        fontCountAttribute: surface && surface.getAttribute('data-df026-font-count'),
        fontSetStatusAttribute: surface && surface.getAttribute('data-df026-font-set-status'),
        bodyPrintState: document.body.getAttribute('data-df026-print-state'),
        statusElementPresent: !!document.getElementById('df026-print-status'),
        fontSetStatus: document.fonts.status,
        checkHant: document.fonts.check('400 10pt "DF031Hant"', '\\u6f22'),
        checkHans: document.fonts.check('400 10pt "DF031Hans"', '\\u6c49'),
        checkRoboto: document.fonts.check('400 10pt "DF026Roboto"', 'Regular'),
        checkEmoji: document.fonts.check('400 10pt "DF026Emoji"', '\\u26a0\\ufe0f'),
        checkMono: document.fonts.check('400 10pt "DF026Mono"', '\\u2192'),
        loadedFaces: [...document.fonts].map(f => ({ family: f.family, status: f.status, weight: f.weight, style: f.style })),
      });
    `);
  }

  async printRules() {
    return this.json(PRINT_RULES);
  }

  /// Captures the page, if Gecko can.
  ///
  /// This was expected to be impossible on this machine (a
  /// `RenderCompositorSWGL failed mapping default framebuffer` failure). It is
  /// attempted rather than assumed, and the outcome is recorded either way, so
  /// the report states what actually happened instead of repeating a prior
  /// belief.
  async shot(name) {
    try {
      const result = await this.s.send('browsingContext.captureScreenshot', { context: this.context });
      const file = join(OUT, `firefox-${name}.png`);
      await writeFile(file, Buffer.from(result.data, 'base64'));
      return file;
    } catch (error) {
      return `capture failed: ${String(error).slice(0, 200)}`;
    }
  }

  /// Types [text] into the focused field, one key at a time.
  ///
  /// WebDriver BiDi has no "insert text" primitive, so this is a key source.
  /// Newlines are sent as the normalised Enter key rather than a literal \n,
  /// which a key action does not accept.
  async typeText(text) {
    const actions = [];
    for (const character of text) {
      const value = character === '\n' ? '' : character;
      actions.push({ type: 'keyDown', value }, { type: 'keyUp', value });
    }
    await this.s.send('input.performActions', {
      context: this.context,
      actions: [{ type: 'key', id: 'keyboard', actions }],
    });
  }

  /// Loads a fixture through the app's own **Paste Markdown** flow.
  ///
  /// This is the one place the Firefox run deliberately differs from the
  /// Chromium run, and the difference is disclosed rather than hidden.
  /// Chromium loads fixtures through `Load from file`, driven with the CDP
  /// command `DOM.setFileInputFiles`. WebDriver BiDi has no equivalent that
  /// works against the transient `<input type="file">` this app's picker
  /// creates, so Firefox uses the other document-entry path the product
  /// already ships. Both paths end in `_openDocument`, so everything asserted
  /// afterwards - detection, the Language tile, the Viewer chain and the print
  /// stacks - is exactly the same product code either way. What Firefox does
  /// NOT independently cover is the `Load from file` transition itself; that is
  /// verified in Chrome and Edge.
  ///
  /// The paste fixtures are shorter than the file fixtures because every
  /// character is typed as a key event. Their detector verdicts are pinned by
  /// `df031_fixture_probe.dart` against the shipping resolver, so they are just
  /// as decisive: 24 exclusive votes to 0 on the intended side, and zero Han at
  /// all for the English one.
  async loadFixture(file) {
    const source = await readFile(join(FIXTURES, PASTE_FIXTURES[file]), 'utf8');

    // Get back to the home screen, which is where Paste Markdown lives.
    const onHome = async () => (await this.nodes())
      .some((n) => (n.text ?? '').split('\n')[0].trim() === 'Paste Markdown');
    if (!await onHome()) {
      await this.openReaderMenu();
      await this.tap('Return to main');
      await delay(1400);
    }

    await this.tap('Paste Markdown');
    await delay(1000);
    // Replacing an existing document is confirmed BEFORE the editor opens on
    // this path (main.dart `_pasteNewDocument`), unlike the file path.
    const replace = (await this.nodes()).find((n) => (n.text ?? '').trim() === 'Replace');
    if (replace) {
      await this.click(replace.x + replace.w / 2, replace.y + replace.h / 2);
      await delay(1600);
    }

    // The editor autofocuses when pasting a new document
    // (paste_sheet.dart: `autofocus: !_isEditing`).
    await waitForValue(
      async () => (await this.nodes()).some((n) => (n.text ?? '').trim() === 'Open'),
      'the paste editor',
    );
    await this.typeText(source);
    await delay(1200);
    await this.tap('Open');
    await waitForValue(
      async () => (await this.printState()).surfacePresent,
      `print surface after pasting ${file}`,
    );
    await delay(800);
  }
}

async function open(profile, server) {
  const browser = await launchFirefox(profile);
  const app = new App(browser);
  await browser.session.send('browsingContext.setViewport', {
    context: browser.context, viewport: { width: 1280, height: 1600 },
  }).catch(() => { /* older builds: keep the window size from the CLI flags */ });
  await app.navigate(server.origin + '/');
  await waitForValue(
    async () => await app.evaluate(`return !!document.querySelector('flt-semantics-placeholder');`),
    'Flutter bootstrap',
  );
  await delay(3000);
  await app.evaluate(`document.querySelector('flt-semantics-placeholder').click(); return 1;`);
  await delay(1500);
  return { browser, app };
}

// --- The run -----------------------------------------------------------------

const server = await serveBundle(BUNDLE);
const profile = join(OUT, 'firefox-profile');
let current;

try {
  await mkdir(OUT, { recursive: true });

  let session = await open(profile, server);
  current = session.browser;
  let app = session.app;
  evidence.userAgent = await app.evaluate('return navigator.userAgent;');
  record('engine', { userAgent: evidence.userAgent });

  // Screenshots are attempted once, so the limitation is recorded as an
  // observation rather than as an assumption.
  try {
    const shot = await session.browser.session.send('browsingContext.captureScreenshot', { context: app.context });
    await writeFile(join(OUT, 'firefox-screenshot-attempt.png'), Buffer.from(shot.data, 'base64'));
    record('firefox screenshot capability', { captured: true, bytes: shot.data.length });
  } catch (error) {
    record('firefox screenshot capability', { captured: false, error: String(error).slice(0, 300) });
  }

  // --- English: no Language tile -------------------------------------------
  await app.loadFixture('english.md');
  await app.openReaderMenu();
  const englishMenu = await waitForValue(
    async () => {
      const tiles = await app.menuTiles();
      return tiles.some((t) => t.label === 'Return to main') ? tiles : null;
    },
    'the reader menu for the English document',
  );
  expect('item3: no Language tile for an English document',
    !englishMenu.some((t) => t.label === 'Language'), { tiles: englishMenu });
  await app.escape();

  // --- Traditional document -------------------------------------------------
  await app.loadFixture('traditional.md');
  const tradFonts = await app.fontAssetRequests();
  const tradPrint = await app.printState();
  const tradRules = await app.printRules();
  const tradNodes = await app.nodes();
  expect('item1: the Viewer loaded the bundled Han font assets in Gecko',
    tradFonts.some((f) => f.name.startsWith('SaudoHant') && f.decodedBodySize > 100000) &&
    tradFonts.some((f) => f.name.startsWith('SaudoHans') && f.decodedBodySize > 100000),
    { fontAssets: tradFonts });
  const tradShot = await app.shot('01-traditional-viewer');
  expect('item1: the document rendered (reader semantics present)',
    tradNodes.length > 0, { nodeCount: tradNodes.length, screenshot: tradShot });
  expect('item2: Traditional auto print stack leads DF031Hant (parsed CSSOM)',
    tradRules.proportional?.includes('"DF031Hant", "DF031Hans"') === true &&
    tradRules.pre?.includes('"DF031Hant", "DF031Hans"') === true &&
    tradRules.code?.includes('"DF031Hant", "DF031Hans"') === true &&
    tradRules.proportional?.trim().endsWith('sans-serif') === true &&
    tradRules.pre?.trim().endsWith('monospace') === true &&
    tradRules.code?.trim().endsWith('monospace') === true &&
    tradRules.fontFaceRules.length === 7 &&
    tradPrint.checkHant === true && tradPrint.checkHans === true,
    { rules: tradRules, print: tradPrint });

  const glyphs = await app.json(GLYPH_PROBE);
  expect('item1: bundled Han faces rasterise real, distinct glyphs in Gecko (not tofu)',
    glyphs.hantShared.ink > 0 && glyphs.hansShared.ink > 0 &&
    glyphs.hantExclusive.ink > 0 && glyphs.hansExclusive.ink > 0 &&
    glyphs.hantShared.hash !== glyphs.hansShared.hash &&
    glyphs.checkHant === true && glyphs.checkHans === true,
    glyphs);

  expect('item8: DF-023 emoji and DF-024 mono faces still load in Gecko',
    tradPrint.checkEmoji === true && tradPrint.checkMono === true && tradPrint.checkRoboto === true &&
    tradPrint.fontCountAttribute === '7' && tradPrint.fontSetStatus === 'loaded',
    { print: tradPrint });

  await app.openReaderMenu();
  const tradTiles = await app.menuTiles();
  const tradMenuShot = await app.shot('02-traditional-menu');
  expect('item3: Language tile present with Automatic — Traditional Chinese',
    tradTiles.find((t) => t.label === 'Language')?.subtitle === 'Automatic — Traditional Chinese',
    { tiles: tradTiles, screenshot: tradMenuShot });
  await app.escape();

  // --- Simplified document, then the override -------------------------------
  await app.loadFixture('simplified.md');
  const simpShot = await app.shot('03-simplified-viewer');
  record('item1: Simplified document captured in Gecko', { screenshot: simpShot });
  const simpRules = await app.printRules();
  expect('item2: Simplified auto print stack leads DF031Hans (parsed CSSOM)',
    simpRules.proportional?.includes('"DF031Hans", "DF031Hant"') === true &&
    simpRules.pre?.includes('"DF031Hans", "DF031Hant"') === true &&
    simpRules.code?.includes('"DF031Hans", "DF031Hant"') === true,
    { rules: simpRules });

  const sentinel = `df031-${Date.now()}`;
  await app.evaluate(`window.__df031Sentinel = ${JSON.stringify(sentinel)}; return 1;`);
  const docBefore = await app.storedDocument();
  const requestsBefore = server.requestLog.length;

  await app.openReaderMenu();
  const scenarioTiles = await app.menuTiles();
  const loadIndex = scenarioTiles.findIndex((t) => t.label === 'Load from file');
  const langIndex = scenarioTiles.findIndex((t) => t.label === 'Language');
  const homeIndex = scenarioTiles.findIndex((t) => t.label === 'Return to main');
  expect('§5.6.6 step 1: Language sits below Load from file and above Return to main',
    langIndex > -1 && loadIndex < langIndex && langIndex < homeIndex &&
    scenarioTiles[langIndex].subtitle === 'Automatic — Simplified Chinese',
    { tiles: scenarioTiles });

  await app.tap('Language');
  // RadioListTiles publish as `aria-label`, unlike the menu's ListTiles.
  const sheetNodes = await waitForValue(
    async () => {
      const all = await app.nodes();
      return all.some((n) => (n.text ?? n.label ?? '').trim() === 'Traditional Chinese') ? all : null;
    },
    'the Language selection sheet',
  );
  const sheetLabels = sheetNodes
    .filter((n) => n.text || n.label)
    .map((n) => (n.text ?? n.label).replace(/\n/g, ' | '));
  expect('§5.6.6 step 2: sheet offers Auto / Traditional / Simplified with the detected result',
    sheetLabels.some((l) => l.trim().startsWith('Auto')) &&
    sheetLabels.some((l) => l.trim() === 'Traditional Chinese') &&
    sheetLabels.some((l) => l.trim() === 'Simplified Chinese') &&
    sheetLabels.join(' ~ ').includes('Detected: Simplified Chinese'),
    { sheetLabels });

  await app.tap('Traditional Chinese');
  await delay(1800);
  await app.escape();
  const overrideShot = await app.shot('04-after-override-traditional');
  record('item3: Viewer captured in Gecko after the explicit override', { screenshot: overrideShot });
  const overrideRules = await app.printRules();
  const docAfter = await app.storedDocument();
  const sentinelAfter = await app.evaluate('return window.__df031Sentinel ?? null;');
  expect('§5.6.6 step 3: print follows an EXPLICIT preference, with no reload and no re-read',
    overrideRules.proportional?.includes('"DF031Hant", "DF031Hans"') === true &&
    overrideRules.pre?.includes('"DF031Hant", "DF031Hans"') === true &&
    overrideRules.code?.includes('"DF031Hant", "DF031Hans"') === true &&
    sentinelAfter === sentinel &&
    server.requestLog.length === requestsBefore &&
    docBefore.id === docAfter.id && docBefore.updatedAt === docAfter.updatedAt &&
    docAfter.scriptPreference === 'traditionalChinese',
    { rules: overrideRules, sentinelAfter, docBefore, docAfter,
      newRequests: server.requestLog.slice(requestsBefore) });

  await app.openReaderMenu();
  const explicitTiles = await app.menuTiles();
  expect('§5.6.6 step 3f: the menu shows explicit Traditional Chinese',
    explicitTiles.find((t) => t.label === 'Language')?.subtitle === 'Traditional Chinese',
    { tiles: explicitTiles });
  await app.escape();

  evidence.launchA = { englishMenu, tradTiles, tradFonts, tradRules, simpRules, overrideRules, glyphs, docBefore, docAfter };

  // --- Relaunch persistence -------------------------------------------------
  await session.browser.close();
  await delay(2000);
  session = await open(profile, server);
  current = session.browser;
  app = session.app;
  const relaunchDoc = await app.storedDocument();
  await waitForValue(async () => (await app.printState()).surfacePresent, 'print surface after relaunch');
  const relaunchRules = await app.printRules();
  await app.openReaderMenu();
  const relaunchTiles = await app.menuTiles();
  expect('item3: the explicit choice survives an app relaunch',
    relaunchDoc?.scriptPreference === 'traditionalChinese' &&
    relaunchTiles.find((t) => t.label === 'Language')?.subtitle === 'Traditional Chinese' &&
    relaunchRules.proportional?.includes('"DF031Hant", "DF031Hans"') === true,
    { relaunchDoc, tiles: relaunchTiles, rules: relaunchRules });

  await app.tap('Language');
  await app.tap('Auto');
  await delay(1800);
  const autoDoc = await app.storedDocument();
  const autoRules = await app.printRules();
  await app.escape();
  await app.openReaderMenu();
  const autoTiles = await app.menuTiles();
  expect('§5.6.6 step 4: Auto clears the override and detection resumes',
    autoDoc?.scriptPreference === 'auto' &&
    autoTiles.find((t) => t.label === 'Language')?.subtitle === 'Automatic — Simplified Chinese' &&
    autoRules.proportional?.includes('"DF031Hans", "DF031Hant"') === true,
    { autoDoc, tiles: autoTiles, rules: autoRules });
  await app.escape();

  evidence.launchB = { relaunchDoc, relaunchTiles, relaunchRules, autoDoc, autoTiles, autoRules };
  evidence.serverRequestLog = server.requestLog;
} catch (error) {
  evidence.error = String(error.stack ?? error);
  evidence.failures = (evidence.failures ?? 0) + 1;
  console.error(error);
  if (current) evidence.browserStderr = current.stderrText().slice(-4000);
} finally {
  if (current) await current.close();
  await server.close();
  await writeFile(join(OUT, 'firefox-evidence.json'), JSON.stringify(evidence, null, 2));
  await removeDirectory(profile);
}

console.log(`[${NAME}] failures: ${evidence.failures ?? 0}`);
process.exitCode = evidence.failures ? 1 : 0;
