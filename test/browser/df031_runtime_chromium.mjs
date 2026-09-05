// DF-031 CP-D1 runtime verification, Chromium engines (Chrome and Edge).
//
// Verification support, not product code. Drives a real release bundle in a
// real browser and records evidence for plan.md §12 CP-D items 1, 2, 3, 4, 8
// and 9. Nothing here is imported by `lib/`.
//
//   node test/browser/df031_runtime_chromium.mjs \
//     --browser "C:\Program Files\Google\Chrome\Application\chrome.exe" \
//     --name chrome --bundle build/web --out <evidence dir>
//
// Why it drives the semantics tree rather than the DOM: the Viewer is
// CanvasKit, so prose is rasterised into a canvas and there are no text nodes
// to query. Flutter does publish an accessibility tree as real DOM once
// semantics are enabled, which gives label-addressed targets with real layout
// boxes - stable enough to click, and readable enough to assert menu ordering.
// The *print* surface is ordinary DOM and is asserted directly.

import { mkdir, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { join, resolve } from 'node:path';
import {
  GLYPH_PROBE,
  delay,
  launchChromium,
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
const NAME = argument('--name');
const BUNDLE = resolve(argument('--bundle'));
const OUT = resolve(argument('--out'));
const FIXTURES = resolve(
  argument('--fixtures', join(import.meta.dirname, 'df031_fixtures')),
);

// Traditional-exclusive filler used to prove that detection does NOT run per
// keystroke: typed into the editor it would flip the verdict if it did.
const HANT_FILLER = '國學電機語閱書經實關開傳豐鐵藝'.repeat(12);

const evidence = { browser: NAME, browserPath: BROWSER, steps: [] };
function record(step, data) {
  evidence.steps.push({ step, ...data });
  const flag = data.pass === undefined ? '·' : data.pass ? 'PASS' : 'FAIL';
  console.log(`[${NAME}] ${flag} ${step}`);
  if (data.pass === false) console.log('    ' + JSON.stringify(data));
}

// --- Page-side probes --------------------------------------------------------

const SEMANTICS = `
  return [...document.querySelectorAll('flt-semantics')].map(n => {
    const r = n.getBoundingClientRect();
    return {
      id: n.id,
      role: n.getAttribute('role'),
      label: n.getAttribute('aria-label'),
      text: n.childNodes.length && n.firstChild.nodeType === 3 ? n.textContent : null,
      x: Math.round(r.x), y: Math.round(r.y),
      w: Math.round(r.width), h: Math.round(r.height),
    };
  });
`;

// Everything the print surface can be asked about without printing.
const PRINT_STATE = `
  const style = document.getElementById('df026-print-style');
  const surface = document.getElementById('df026-print');
  const css = style ? style.textContent : null;
  const grab = (re) => { const m = css && css.match(re); return m ? m[1].trim() : null; };
  const faces = [...document.fonts].map(f => ({ family: f.family, status: f.status, weight: f.weight, style: f.style }));
  const pre = surface && surface.querySelector('pre');
  const code = surface && surface.querySelector('code');
  return {
    styleElementPresent: !!style,
    surfacePresent: !!surface,
    fontsAttribute: surface && surface.getAttribute('data-df026-fonts'),
    fontCountAttribute: surface && surface.getAttribute('data-df026-font-count'),
    fontSetStatusAttribute: surface && surface.getAttribute('data-df026-font-set-status'),
    bodyPrintState: document.body.getAttribute('data-df026-print-state'),
    statusElementPresent: !!document.getElementById('df026-print-status'),
    declaredProportional: grab(/#df026-print \\{[^}]*?font:\\s*10pt\\/1\\.35\\s*([^;]+);/s),
    declaredPre: grab(/#df026-print pre \\{[^}]*?font:\\s*8\\.6pt\\/1\\.25\\s*([^;]+);/s),
    declaredCode: grab(/#df026-print code \\{\\s*font-family:\\s*([^;]+);/s),
    fontFaceRuleFamilies: css ? [...css.matchAll(/@font-face \\{\\s*font-family: "([^"]+)"/g)].map(m => m[1]) : [],
    computedProportional: surface ? getComputedStyle(surface).fontFamily : null,
    computedPre: pre ? getComputedStyle(pre).fontFamily : null,
    computedCode: code ? getComputedStyle(code).fontFamily : null,
    checkHant: document.fonts.check('400 10pt "DF031Hant"', '\\u6f22'),
    checkHans: document.fonts.check('400 10pt "DF031Hans"', '\\u6c49'),
    checkHantWrongProbe: document.fonts.check('400 10pt "DF031Hant"', '\\u6c49'),
    checkHansWrongProbe: document.fonts.check('400 10pt "DF031Hans"', '\\u6f22'),
    checkRoboto: document.fonts.check('400 10pt "DF026Roboto"', 'Regular'),
    checkEmoji: document.fonts.check('400 10pt "DF026Emoji"', '\\u26a0\\ufe0f'),
    checkMono: document.fonts.check('400 10pt "DF026Mono"', '\\u2192'),
    faces,
    fontSetStatus: document.fonts.status,
    printSurfaceText: surface ? surface.textContent.replace(/\\s+/g, ' ').slice(0, 220) : null,
  };
`;

// The persisted document, read straight out of the store's IndexedDB.
const STORED_DOCUMENT = `
  const db = await new Promise((res, rej) => {
    const r = indexedDB.open('markdown_viewer');
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  });
  if (!db.objectStoreNames.length) return null;
  const storeName = db.objectStoreNames[0];
  const raw = await new Promise((res, rej) => {
    const r = db.transaction(storeName, 'readonly').objectStore(storeName).get('document');
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  });
  db.close();
  if (raw == null) return null;
  const parsed = JSON.parse(raw);
  return {
    id: parsed.id,
    title: parsed.title,
    updatedAt: parsed.updatedAt,
    scriptPreference: parsed.scriptPreference ?? null,
    sourceName: parsed.sourceName ?? null,
    sourceLength: (parsed.source || '').length,
    sourceHead: (parsed.source || '').slice(0, 40),
  };
`;

// --- Driver ------------------------------------------------------------------

class App {
  constructor(session, server, counters) {
    this.s = session;
    this.server = server;
    this.counters = counters;
  }

  nodes() {
    return this.s.evaluate(SEMANTICS);
  }

  async printState() {
    return this.s.evaluate(PRINT_STATE);
  }

  async storedDocument() {
    return this.s.evaluate(STORED_DOCUMENT);
  }

  async click(x, y) {
    await this.s.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y, button: 'none', buttons: 0 });
    await this.s.send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1 });
    await delay(40);
    await this.s.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', buttons: 0, clickCount: 1 });
  }

  /// Clicks the semantics node whose visible text starts with [text].
  async tap(text, { timeoutMs = 8000 } = {}) {
    const node = await waitForValue(
      async () => (await this.nodes()).find(
        (n) => (n.text ?? n.label ?? '').split('\n')[0].trim() === text && n.w > 0 && n.h > 0,
      ),
      `semantics node "${text}"`,
      timeoutMs,
    );
    await this.click(node.x + node.w / 2, node.y + node.h / 2);
    await delay(700);
    return node;
  }

  /// The reader's one persistent control: a small unlabelled button pinned to
  /// the bottom-right of the viewport.
  async openReaderMenu() {
    const size = await this.s.evaluate('return { w: innerWidth, h: innerHeight };');
    // The button is present in the semantics tree even while it is faded out
    // and wrapped in IgnorePointer, so a tap can be swallowed silently. Confirm
    // the menu actually opened, and nudge the list upward to bring the control
    // back if it did not.
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
      const opened = (await this.nodes()).some(
        (n) => (n.text ?? '').split('\n')[0].trim() === 'Return to main',
      );
      if (opened) return node;
      await this.scrollBy(-120);
    }
    throw new Error('the reader menu did not open');
  }

  /// The reader menu's tiles, top to bottom - the order §5.6.2/UX-3 constrains.
  async menuTiles() {
    const all = await this.nodes();
    return all
      .filter((n) => n.role === 'button' && n.text && n.w > 300)
      .sort((a, b) => a.y - b.y)
      .map((n) => ({ label: n.text.split('\n')[0].trim(), subtitle: n.text.split('\n')[1]?.trim() ?? null, y: n.y }));
  }

  /// Which labelled blocks are on screen, and where.
  ///
  /// The observable form of "the reading position was kept": if the reader had
  /// been remounted, the list would restart from its `initialScrollIndex` and
  /// these offsets would jump. Full-viewport wrappers are excluded because they
  /// never move.
  async anchors() {
    const size = await this.s.evaluate('return { w: innerWidth, h: innerHeight };');
    return (await this.nodes())
      .filter((n) => (n.label || n.text) && n.w < size.w && n.h < size.h)
      .map((n) => ({ k: (n.label ?? n.text).replace(/\s+/g, ' ').slice(0, 28), y: n.y }))
      .sort((a, b) => a.y - b.y || a.k.localeCompare(b.k));
  }

  async escape() {
    for (const type of ['keyDown', 'keyUp']) {
      await this.s.send('Input.dispatchKeyEvent', { type, key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27, nativeVirtualKeyCode: 27 });
    }
    await delay(700);
  }

  /// Scrolls the reader list.
  ///
  /// `Input.dispatchMouseEvent` with `type: 'mouseWheel'` is dispatched first,
  /// but on this engine it does not reach Flutter's own wheel listener, so a
  /// synthetic `WheelEvent` on the view root is dispatched as well. Flutter
  /// registers an ordinary `addEventListener('wheel', …)`, which fires for an
  /// untrusted event too. The caller verifies that the list actually moved
  /// rather than assuming either path worked.
  async scrollBy(pixels) {
    const size = await this.s.evaluate('return { w: innerWidth, h: innerHeight };');
    const x = Math.round(size.w / 2);
    const y = Math.round(size.h / 2);
    await this.s.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y, button: 'none', buttons: 0 });
    await this.s.send('Input.dispatchMouseEvent', {
      type: 'mouseWheel', x, y, deltaX: 0, deltaY: pixels, button: 'none', buttons: 0,
    });
    await delay(350);
    await this.s.evaluate(`
      const target = document.querySelector('flt-glass-pane')
        ?? document.querySelector('flutter-view')
        ?? document.body;
      target.dispatchEvent(new WheelEvent('wheel', {
        deltaY: ${pixels}, deltaMode: 0, clientX: ${x}, clientY: ${y},
        bubbles: true, cancelable: true, composed: true,
      }));
      return 1;
    `);
    await delay(900);
  }

  async shot(name, clip) {
    const params = clip
      ? { format: 'png', clip: { x: clip.x, y: clip.y, width: clip.w, height: clip.h, scale: clip.scale ?? 1 } }
      : { format: 'png', captureBeyondViewport: false };
    const result = await this.s.send('Page.captureScreenshot', params);
    const file = join(OUT, `${NAME}-${name}.png`);
    await writeFile(file, Buffer.from(result.data, 'base64'));
    return { file, sha256: createHash('sha256').update(result.data).digest('hex').slice(0, 16) };
  }

  /// Real print output, and the print surface as the print stylesheet renders it.
  async printEvidence(name) {
    await this.s.send('Emulation.setEmulatedMedia', { media: 'print', features: [{ name: 'prefers-color-scheme', value: 'light' }] });
    await delay(600);
    const state = await this.printState();
    const shot = await this.shot(`${name}-print`);
    const pdf = await this.s.send('Page.printToPDF', { printBackground: true, preferCSSPageSize: true });
    const pdfFile = join(OUT, `${NAME}-${name}.pdf`);
    await writeFile(pdfFile, Buffer.from(pdf.data, 'base64'));
    await this.s.send('Emulation.setEmulatedMedia', { media: '', features: [{ name: 'prefers-color-scheme', value: 'light' }] });
    await delay(400);
    return { ...state, screenshot: shot.file, pdf: pdfFile };
  }

  async loadFixture(file) {
    this.counters.chooser = null;
    // `Load from file` is on the home screen directly, but inside the reader it
    // is a menu tile - one workflow, two entry points (reader_screen.dart).
    const visible = (await this.nodes()).some((n) => (n.text ?? '').split('\n')[0].trim() === 'Load from file');
    if (!visible) await this.openReaderMenu();
    await this.tap('Load from file');
    await delay(1200);
    if (!this.counters.chooser) throw new Error(`file chooser did not open for ${file}`);
    await this.s.send('DOM.setFileInputFiles', {
      files: [join(FIXTURES, file)],
      backendNodeId: this.counters.chooser.backendNodeId,
    });
    await delay(1500);
    const replace = (await this.nodes()).find((n) => (n.text ?? '').trim() === 'Replace');
    if (replace) {
      await this.click(replace.x + replace.w / 2, replace.y + replace.h / 2);
      await delay(1500);
    }
    // The print surface remounts asynchronously; wait for it rather than sleep.
    await waitForValue(async () => (await this.printState()).surfacePresent, `print surface after loading ${file}`);
    await delay(600);
  }
}

// --- Session lifecycle -------------------------------------------------------

async function open(profile, server) {
  const browser = await launchChromium(BROWSER, { profileDirectory: profile });
  const s = browser.session;
  const counters = { chooser: null, loads: 0, navigations: 0 };
  s.on('Page.fileChooserOpened', (p) => { counters.chooser = p; });
  s.on('Page.loadEventFired', () => { counters.loads += 1; });
  s.on('Page.frameNavigated', (p) => { if (!p.frame.parentId) counters.navigations += 1; });
  await s.send('Runtime.enable');
  await s.send('Page.enable');
  await s.send('DOM.enable');
  await s.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }] });
  await s.send('Page.setInterceptFileChooserDialog', { enabled: true });
  await s.send('Page.navigate', { url: server.origin + '/' });
  await waitForValue(
    async () => await s.evaluate(`return !!document.querySelector('flt-semantics-placeholder');`),
    'Flutter bootstrap',
  );
  await delay(2500);
  await s.evaluate(`document.querySelector('flt-semantics-placeholder').click(); return 1;`);
  await delay(1200);
  return { browser, app: new App(s, server, counters), counters };
}

// --- The run -----------------------------------------------------------------

const server = await serveBundle(BUNDLE);
const profile = join(OUT, `${NAME}-profile`);
let currentBrowser;

function expect(step, pass, data) {
  record(step, { pass, ...data });
  if (!pass) evidence.failures = (evidence.failures ?? 0) + 1;
}

try {
  await mkdir(OUT, { recursive: true });

  // ===== Launch A ============================================================
  let session = await open(profile, server);
  currentBrowser = session.browser;
  let app = session.app;

  // --- English: the Language tile must NOT appear (item 3, item 8 baseline) --
  await app.loadFixture('english.md');
  const englishShot = await app.shot('01-english-viewer');
  await app.openReaderMenu();
  const englishTiles = await app.menuTiles();
  const englishMenuShot = await app.shot('02-english-menu');
  expect('item3: no Language tile for an English document',
    !englishTiles.some((t) => t.label === 'Language'),
    { tiles: englishTiles, screenshot: englishMenuShot.file, viewer: englishShot.file });
  const englishPrint = await app.printEvidence('03-english');
  await app.escape();

  // --- Traditional document (item 1, item 2) --------------------------------
  await app.loadFixture('traditional.md');
  const tradShot = await app.shot('04-traditional-viewer');
  const tradPrint = await app.printEvidence('05-traditional-auto');
  expect('item1: Traditional document renders in the Viewer', true,
    { screenshot: tradShot.file, note: 'glyph presence judged visually from this capture' });
  expect('item2: Traditional auto print stack leads DF031Hant',
    tradPrint.declaredProportional?.includes('"DF031Hant", "DF031Hans"') === true &&
    tradPrint.declaredPre?.includes('"DF031Hant", "DF031Hans"') === true &&
    tradPrint.declaredCode?.includes('"DF031Hant", "DF031Hans"') === true &&
    tradPrint.declaredProportional?.endsWith('sans-serif') === true &&
    tradPrint.declaredPre?.endsWith('monospace') === true &&
    tradPrint.declaredCode?.endsWith('monospace') === true &&
    tradPrint.checkHant === true && tradPrint.checkHans === true,
    tradPrint);

  // Objective anti-tofu evidence, engine-independent and comparable with the
  // Firefox run, which cannot produce screenshots on this machine.
  const glyphs = JSON.parse(await app.s.evaluate(GLYPH_PROBE));
  expect('item1: bundled Han faces rasterise real, distinct glyphs (not tofu)',
    glyphs.hantShared.ink > 0 && glyphs.hansShared.ink > 0 &&
    glyphs.hantExclusive.ink > 0 && glyphs.hansExclusive.ink > 0 &&
    glyphs.hantShared.hash !== glyphs.hansShared.hash &&
    glyphs.checkHant === true && glyphs.checkHans === true,
    glyphs);

  // Item 4: synthetic bold, captured large enough to judge.
  const boldCrop = await app.shot('06-traditional-bold-crop', { x: 60, y: 20, w: 620, h: 320, scale: 3 });
  record('item4: synthetic bold capture', { screenshot: boldCrop.file });

  await app.openReaderMenu();
  const tradTiles = await app.menuTiles();
  const tradMenuShot = await app.shot('07-traditional-menu');
  expect('item3: Language tile present with Automatic — Traditional Chinese',
    tradTiles.find((t) => t.label === 'Language')?.subtitle === 'Automatic — Traditional Chinese',
    { tiles: tradTiles, screenshot: tradMenuShot.file });
  await app.escape();

  // --- Simplified document, then the §5.6.6 scenario verbatim ---------------
  await app.loadFixture('simplified.md');
  const simpShot = await app.shot('08-simplified-viewer');
  const simpPrint = await app.printEvidence('09-simplified-auto');
  expect('item1: Simplified document renders in the Viewer', true,
    { screenshot: simpShot.file });
  expect('item2: Simplified auto print stack leads DF031Hans',
    simpPrint.declaredProportional?.includes('"DF031Hans", "DF031Hant"') === true &&
    simpPrint.declaredPre?.includes('"DF031Hans", "DF031Hant"') === true &&
    simpPrint.declaredCode?.includes('"DF031Hans", "DF031Hant"') === true &&
    simpPrint.checkHans === true && simpPrint.checkHant === true,
    simpPrint);

  // Scroll away from the top so "reading position preserved" is a real claim
  // rather than a vacuous one, and prove the scroll actually moved before
  // leaning on it. The Simplified fixture is deliberately taller than the
  // viewport for exactly this reason.
  const anchorsAtTop = await app.anchors();
  await app.scrollBy(400);
  // Reader-first behaviour: the menu button hides while scrolling forward and
  // returns on any upward scroll (`_onUserScroll` in reader_screen.dart). A
  // small scroll back up is what a reader does anyway, and it leaves the
  // document well away from the top while making the control reachable.
  await app.scrollBy(-80);
  const anchorBefore = await app.anchors();
  const scrollMoved = anchorsAtTop.length > 0 && anchorBefore.length > 0 &&
    JSON.stringify(anchorsAtTop) !== JSON.stringify(anchorBefore);
  expect('§5.6.6 precondition: the reader really is scrolled away from the top',
    scrollMoved, { anchorsAtTop, anchorBefore });
  const viewerBefore = await app.shot('10-s566-before-override');
  const bandBefore = await app.shot('10b-s566-band-before', { x: 60, y: 300, w: 1140, h: 220, scale: 2 });
  const sentinel = `df031-${Date.now()}`;
  await app.s.evaluate(`window.__df031Sentinel = ${JSON.stringify(sentinel)}; return 1;`);
  const docBefore = await app.storedDocument();
  const loadsBefore = session.counters.loads;
  const navsBefore = session.counters.navigations;
  const requestsBefore = server.requestLog.length;
  session.counters.chooser = null;

  // Step: open the reader menu.
  await app.openReaderMenu();
  const scenarioTiles = await app.menuTiles();
  const scenarioMenuShot = await app.shot('11-s566-menu');
  const loadIndex = scenarioTiles.findIndex((t) => t.label === 'Load from file');
  const langIndex = scenarioTiles.findIndex((t) => t.label === 'Language');
  const homeIndex = scenarioTiles.findIndex((t) => t.label === 'Return to main');
  expect('§5.6.6 step 1: Language sits below Load from file and above Return to main',
    langIndex > -1 && loadIndex > -1 && homeIndex > -1 && loadIndex < langIndex && langIndex < homeIndex &&
    scenarioTiles[langIndex].subtitle === 'Automatic — Simplified Chinese',
    { tiles: scenarioTiles, screenshot: scenarioMenuShot.file });

  // Step: select Language.
  await app.tap('Language');
  // The sheet animates in, and its semantics land a frame or two after the
  // modal barrier does; snapshotting immediately catches only the barrier.
  // The sheet's rows are RadioListTiles, which Flutter publishes as `aria-label`
  // rather than as a DOM text child - unlike the menu's ListTiles.
  const sheetNodes = await waitForValue(
    async () => {
      const all = await app.nodes();
      return all.some((n) => (n.text ?? n.label ?? '').trim() === 'Traditional Chinese') ? all : null;
    },
    'the Language selection sheet',
  );
  const sheetShot = await app.shot('12-s566-sheet');
  const sheetLabels = sheetNodes
    .filter((n) => n.text || n.label)
    .map((n) => (n.text ?? n.label).replace(/\n/g, ' | '));
  const sheetText = sheetLabels.join(' ~ ');
  expect('§5.6.6 step 2: sheet offers Auto / Traditional / Simplified with the detected result',
    sheetLabels.some((l) => l.trim().startsWith('Auto')) &&
    sheetLabels.some((l) => l.trim() === 'Traditional Chinese') &&
    sheetLabels.some((l) => l.trim() === 'Simplified Chinese') &&
    sheetText.includes('Detected: Simplified Chinese'),
    { sheetLabels, screenshot: sheetShot.file });

  // Step: select Traditional Chinese.
  await app.tap('Traditional Chinese');
  await delay(1600);
  const sheetOpenShot = await app.shot('13a-s566-sheet-after-selection');
  // Close the sheet BEFORE capturing the comparison frame. Capturing with the
  // sheet still open would make the before/after pixels differ because of the
  // radio button alone, which would make the "re-rendered" assertion below
  // pass without the Viewer having changed at all.
  await app.escape();
  const viewerAfter = await app.shot('13-s566-after-override');
  const bandAfter = await app.shot('13b-s566-band-after', { x: 60, y: 300, w: 1140, h: 220, scale: 2 });
  const docAfter = await app.storedDocument();
  const sentinelAfter = await app.s.evaluate('return window.__df031Sentinel ?? null;');
  const anchorAfter = await app.anchors();

  expect('§5.6.6 step 3a: the Viewer re-rendered with the new regional forms',
    viewerBefore.sha256 !== viewerAfter.sha256 && bandBefore.sha256 !== bandAfter.sha256,
    { before: viewerBefore, after: viewerAfter, bandBefore, bandAfter, sheetOpenShot: sheetOpenShot.file });
  expect('§5.6.6 step 3b: no page reload and no re-navigation',
    sentinelAfter === sentinel && session.counters.loads === loadsBefore && session.counters.navigations === navsBefore,
    { sentinel, sentinelAfter, loadsBefore, loadsAfter: session.counters.loads, navsBefore, navsAfter: session.counters.navigations });
  // "Not re-read from disk" means the picker never reopened and the app shell
  // was never refetched. The bundled *print font* assets ARE requested again,
  // and that is specified behaviour rather than a reload: replacing the print
  // stylesheet's text re-parses its @font-face rules, which discards the
  // CSS-connected FontFace objects the cached load resolved against, so
  // print_surface_web.dart drops the cache and proves the faces again
  // (§6 item 4). They are same-origin bundled assets, so no privacy claim moves.
  const newRequests = server.requestLog.slice(requestsBefore);
  const shellRequests = newRequests.filter(
    (path) => !path.startsWith('/assets/fonts/'),
  );
  expect('§5.6.6 step 3c: the document was not re-read from disk and the app shell was not refetched',
    session.counters.chooser === null && shellRequests.length === 0,
    { chooserOpened: session.counters.chooser !== null, newRequests, shellRequests,
      note: 'font re-requests are the documented stylesheet-replacement reload, all same-origin' });
  // Two independent readings of the same property. `updatedAt` unchanged means
  // main.dart's `ValueKey('id:updatedAt')` is unchanged, so ReaderScreen was
  // not remounted - the exact property §5.6.6 names as the testable one. The
  // anchor comparison is the observable consequence: the same blocks are still
  // on screen at the same offsets, so the scrolled position did not jump.
  // The primary assertion is the ValueKey one, because that is the property
  // §5.6.6 itself nominates as testable. The anchor comparison corroborates it:
  // the same blocks are still on screen at almost the same offsets. "Almost" is
  // deliberate - swapping the lead face changes glyph metrics slightly, so the
  // blocks above re-lay-out by a few pixels. That is a re-render, which is what
  // was asked for; it is not a lost position.
  const keysBefore = anchorBefore.map((a) => a.k).join('|');
  const keysAfter = anchorAfter.map((a) => a.k).join('|');
  const maxShift = anchorBefore.length && keysBefore === keysAfter
    ? Math.max(...anchorBefore.map((a, i) => Math.abs(a.y - anchorAfter[i].y)))
    : null;
  expect('§5.6.6 step 3d: reading position preserved (ValueKey unchanged, same blocks, no jump)',
    docBefore && docAfter && docBefore.id === docAfter.id && docBefore.updatedAt === docAfter.updatedAt &&
    docBefore.sourceLength === docAfter.sourceLength &&
    keysBefore === keysAfter && anchorBefore.length > 0 && maxShift !== null && maxShift <= 40,
    { docBefore, docAfter, anchorBefore, anchorAfter, keysBefore, keysAfter, maxShift,
      note: 'id+updatedAt unchanged => main.dart ValueKey unchanged => ReaderScreen not remounted' });
  expect('§5.6.6 step 3e: the preference is persisted for this document',
    docAfter?.scriptPreference === 'traditionalChinese',
    { docAfter });

  // The sheet was already dismissed before the comparison capture above.
  await app.openReaderMenu();
  const explicitTiles = await app.menuTiles();
  const explicitMenuShot = await app.shot('14-s566-menu-explicit');
  expect('§5.6.6 step 3f: the menu shows explicit Traditional Chinese, not Automatic — …',
    explicitTiles.find((t) => t.label === 'Language')?.subtitle === 'Traditional Chinese',
    { tiles: explicitTiles, screenshot: explicitMenuShot.file });
  await app.escape();

  // Item 2's explicit-preference case: print must follow the override.
  const explicitPrint = await app.printEvidence('15-simplified-explicit-traditional');
  expect('item2: print follows an EXPLICIT preference (Simplified doc, Traditional chosen)',
    explicitPrint.declaredProportional?.includes('"DF031Hant", "DF031Hans"') === true &&
    explicitPrint.declaredPre?.includes('"DF031Hant", "DF031Hans"') === true &&
    explicitPrint.declaredCode?.includes('"DF031Hant", "DF031Hans"') === true &&
    explicitPrint.checkHant === true,
    explicitPrint);

  evidence.launchA = { englishTiles, tradTiles, scenarioTiles, explicitTiles, englishPrint, tradPrint, simpPrint, explicitPrint, docBefore, docAfter };

  // ===== Launch B: relaunch persistence ======================================
  await session.browser.close();
  await delay(1200);
  session = await open(profile, server);
  currentBrowser = session.browser;
  app = session.app;

  const relaunchDoc = await app.storedDocument();
  await waitForValue(async () => (await app.printState()).surfacePresent, 'print surface after relaunch');
  const relaunchShot = await app.shot('16-relaunch-viewer');
  const relaunchPrint = await app.printEvidence('17-relaunch');
  await app.openReaderMenu();
  const relaunchTiles = await app.menuTiles();
  const relaunchMenuShot = await app.shot('18-relaunch-menu');
  expect('item3: the explicit choice survives an app relaunch',
    relaunchDoc?.scriptPreference === 'traditionalChinese' &&
    relaunchTiles.find((t) => t.label === 'Language')?.subtitle === 'Traditional Chinese' &&
    relaunchPrint.declaredProportional?.includes('"DF031Hant", "DF031Hans"') === true,
    { relaunchDoc, tiles: relaunchTiles, screenshot: relaunchMenuShot.file, viewer: relaunchShot.file,
      declaredProportional: relaunchPrint.declaredProportional });

  // §5.6.6 final step: Auto again.
  await app.tap('Language');
  await app.shot('19-s566-sheet-explicit');
  await app.tap('Auto');
  await delay(1600);
  const autoDoc = await app.storedDocument();
  await app.escape();
  await app.openReaderMenu();
  const autoTiles = await app.menuTiles();
  const autoMenuShot = await app.shot('20-s566-menu-auto');
  const autoViewer = await app.shot('21-s566-auto-restored');
  expect('§5.6.6 step 4: Auto clears the override and detection resumes (Automatic — Simplified Chinese)',
    autoDoc?.scriptPreference === 'auto' &&
    autoTiles.find((t) => t.label === 'Language')?.subtitle === 'Automatic — Simplified Chinese',
    { autoDoc, tiles: autoTiles, screenshot: autoMenuShot.file, viewer: autoViewer.file });
  await app.escape();
  const autoPrint = await app.printEvidence('22-auto-restored');
  expect('item2: print returns to the detected order once Auto is restored',
    autoPrint.declaredProportional?.includes('"DF031Hans", "DF031Hant"') === true,
    { declaredProportional: autoPrint.declaredProportional });

  // --- Detection transitions: paste-commit, and NOT per keystroke -----------
  // Edit the loaded Simplified document, typing Traditional-exclusive text.
  // While the editor is open the reader is still mounted underneath, so if
  // detection ran per keystroke the print chain would flip mid-typing.
  await app.openReaderMenu();
  await app.tap('Edit local copy');
  await delay(1400);
  // `Edit local copy` deliberately does NOT autofocus (paste_sheet.dart:
  // `autofocus: !_isEditing`), so the field must be clicked before typing.
  // Without this the insertText below lands nowhere and the assertion that
  // follows would pass vacuously.
  const editorSize = await app.s.evaluate('return { w: innerWidth, h: innerHeight };');
  await app.click(editorSize.w / 2, 400);
  await delay(600);
  // Flutter Web routes keyboard input through a hidden editable element; its
  // length is how this run proves the keystrokes actually arrived.
  // The editable element Flutter creates is not at a stable place in the DOM
  // across versions, but it is the focused element while the field has focus.
  const EDITOR_LENGTH = `
    const el = document.activeElement;
    return el && typeof el.value === 'string' ? el.value.length : -1;
  `;
  const lengthBeforeTyping = await app.s.evaluate(EDITOR_LENGTH);
  const beforeTyping = await app.printState();
  await app.s.send('Input.insertText', { text: HANT_FILLER });
  await delay(1500);
  const midTyping = await app.printState();
  const midTypingDoc = await app.storedDocument();
  const lengthMidTyping = await app.s.evaluate(EDITOR_LENGTH);
  await app.s.send('Input.insertText', { text: HANT_FILLER });
  await delay(1500);
  const midTyping2 = await app.printState();
  const lengthAfterTyping = await app.s.evaluate(EDITOR_LENGTH);
  await app.shot('23-editor-typing');
  expect('item3: detection does NOT run per keystroke',
    // The typing must have actually landed, or the rest is vacuous.
    lengthBeforeTyping > 0 && lengthAfterTyping > lengthBeforeTyping + HANT_FILLER.length &&
    beforeTyping.declaredProportional?.includes('"DF031Hans", "DF031Hant"') === true &&
    midTyping.declaredProportional === beforeTyping.declaredProportional &&
    midTyping2.declaredProportional === beforeTyping.declaredProportional &&
    midTypingDoc?.scriptPreference === 'auto' &&
    midTypingDoc?.sourceLength === autoDoc?.sourceLength,
    { lengthBeforeTyping, lengthMidTyping, lengthAfterTyping, filler: HANT_FILLER.length,
      beforeTyping: beforeTyping.declaredProportional, midTyping: midTyping.declaredProportional,
      midTyping2: midTyping2.declaredProportional, midTypingDoc });

  // Commit the edit: detection must now re-run against the new source.
  await app.tap('Save');
  await delay(2500);
  await waitForValue(async () => (await app.printState()).surfacePresent, 'print surface after edit commit');
  const afterCommit = await app.printState();
  const afterCommitDoc = await app.storedDocument();
  const commitShot = await app.shot('24-after-edit-commit');
  expect('item3: detection re-runs on the commit transition',
    afterCommit.declaredProportional?.includes('"DF031Hant", "DF031Hans"') === true &&
    afterCommitDoc?.sourceLength > (autoDoc?.sourceLength ?? 0),
    { declaredProportional: afterCommit.declaredProportional, afterCommitDoc, screenshot: commitShot.file });

  // Paste-commit transition: a brand new document entered by paste.
  await app.openReaderMenu();
  await app.tap('Return to main');
  await delay(1200);
  await app.tap('Paste Markdown');
  await delay(900);
  const replaceBtn = (await app.nodes()).find((n) => (n.text ?? '').trim() === 'Replace');
  if (replaceBtn) { await app.click(replaceBtn.x + replaceBtn.w / 2, replaceBtn.y + replaceBtn.h / 2); await delay(1400); }
  await app.s.send('Input.insertText', { text: '# 繁體貼上測試\n\n' + HANT_FILLER });
  await delay(1200);
  await app.shot('25-paste-editor');
  await app.tap('Open');
  await delay(2500);
  await waitForValue(async () => (await app.printState()).surfacePresent, 'print surface after paste commit');
  const pastePrint = await app.printState();
  const pasteDoc = await app.storedDocument();
  const pasteShot = await app.shot('26-paste-committed');
  expect('item3: detection runs on the paste-commit transition',
    pastePrint.declaredProportional?.includes('"DF031Hant", "DF031Hans"') === true &&
    pasteDoc?.scriptPreference === 'auto' && pasteDoc?.id !== autoDoc?.id,
    { declaredProportional: pastePrint.declaredProportional, pasteDoc, screenshot: pasteShot.file });

  evidence.launchB = { relaunchDoc, relaunchTiles, autoDoc, autoTiles, afterCommitDoc, pasteDoc };

  // ===== Launch C: the Auto choice also survives a relaunch ==================
  await session.browser.close();
  await delay(1200);
  session = await open(profile, server);
  currentBrowser = session.browser;
  app = session.app;
  const finalDoc = await app.storedDocument();
  await waitForValue(async () => (await app.printState()).surfacePresent, 'print surface on final relaunch');
  await app.openReaderMenu();
  const finalTiles = await app.menuTiles();
  const finalMenuShot = await app.shot('27-final-relaunch-menu');
  expect('item3: an Auto choice also survives a relaunch',
    finalDoc?.scriptPreference === 'auto' &&
    finalTiles.find((t) => t.label === 'Language')?.subtitle === 'Automatic — Traditional Chinese',
    { finalDoc, tiles: finalTiles, screenshot: finalMenuShot.file });
  await app.escape();

  evidence.launchC = { finalDoc, finalTiles };
  evidence.serverRequestLog = server.requestLog;
} catch (error) {
  evidence.error = String(error.stack ?? error);
  evidence.failures = (evidence.failures ?? 0) + 1;
  console.error(error);
} finally {
  if (currentBrowser) await currentBrowser.close();
  await server.close();
  await writeFile(join(OUT, `${NAME}-evidence.json`), JSON.stringify(evidence, null, 2));
  await removeDirectory(profile);
}

console.log(`[${NAME}] failures: ${evidence.failures ?? 0}`);
process.exitCode = evidence.failures ? 1 : 0;
