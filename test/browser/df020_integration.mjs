// DF-020 INT: V-18 end to end, on the release bundle, through Playwright.
//
// Verification support, not product code. Nothing here is imported by `lib/`.
//
//   node test/browser/df020_integration.mjs --engine <chrome|edge|firefox|
//     chromium-mobile|webkit-iphone> --playwright <dir with node_modules/playwright>
//     --bundle <release bundle> --files <empty scratch directory> --out <file.json>
//     [--browser <executable>]
//
// Engines:
//   chrome, edge   installed browsers, Playwright `chromium.launch`.
//   firefox        installed Firefox over WebDriver BiDi (`channel: 'moz-firefox'`).
//   chromium-mobile  installed Chrome with device emulation: 390x844, mobile,
//                  touch (Playwright drives Emulation.setDeviceMetricsOverride).
//                  SIMULATED; never physical-device evidence.
//   webkit-iphone  Playwright desktop WebKit, 390x844, touch, an iPhone Safari
//                  user agent. SIMULATED (desktop WebKit); never iOS evidence.
//
// The app is read through its semantics tree and IndexedDB (database
// `markdown_viewer`, store `box`, keys `document` and `position`).
//
// Disclosed injection differences:
//   - Picker: Chromium and WebKit fill the app's file input through Playwright's
//     file chooser. Firefox over BiDi accepts that call but does not deliver the
//     files to the app's transient input, so on Firefox the runner captures the
//     app's own input element and sets its `files` from a page script, then
//     dispatches `change`. The app's picker code reads them as from a real pick.
//   - Drop: Chromium uses a DevTools-protocol drag with real files (its
//     script-built DataTransfer items carry no filesystem entry); Firefox and
//     WebKit dispatch a script-built DataTransfer, whose items do carry entries.
//     Both are SYNTHETIC drops; native Explorer delivery is G-1.

import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { basename, dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

import { delay, serveBundle } from './df031_cdp.mjs';

function argument(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  if (index === -1) {
    if (fallback === undefined) throw new Error(`Missing --${name}`);
    return fallback;
  }
  return process.argv[index + 1];
}

const ENGINE = argument('engine');
const PLAYWRIGHT = argument('playwright');
const BUNDLE = resolve(argument('bundle'));
const FILES = resolve(argument('files'));
const OUT = resolve(argument('out'));
const EXECUTABLES = {
  chrome: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
  edge: 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  firefox: 'C:/Program Files/Mozilla Firefox/firefox.exe',
  'chromium-mobile': 'C:/Program Files/Google/Chrome/Application/chrome.exe',
};
const BROWSER = argument('browser', EXECUTABLES[ENGINE] ?? '');
const IPHONE_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) ' +
  'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
const MOBILE = ENGINE === 'chromium-mobile' || ENGINE === 'webkit-iphone';
const VIEWPORT = MOBILE ? { width: 390, height: 844 } : { width: 1280, height: 900 };
const CHROMIUM = ['chrome', 'edge', 'chromium-mobile'].includes(ENGINE);

const sha256 = async (path) => createHash('sha256').update(await readFile(path)).digest('hex');

// --- Fixtures -----------------------------------------------------------------

const body = (title) => [
  `# ${title}`,
  ...Array.from({ length: 60 }, (_, i) =>
    `## ${title} section ${i}\n\n${`Paragraph ${i} of ${title}. `.repeat(12)}`),
].join('\n\n');
async function put(relative, contents) {
  const path = join(FILES, relative);
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, contents);
  return path;
}
const F = {
  A: await put('one/A.md', body('Alpha')),
  b: await put('one/b.md', body('Bravo')),
  c: await put('one/c.md', body('Charlie')),
  A2: await put('two/A.md', body('Second Alpha')),
  d: await put('one/d.md', body('Delta')),
  e: await put('one/e.md', body('Echo')),
};

// --- Evidence ---------------------------------------------------------------------

const evidence = {
  harness: 'df020_integration',
  engine: ENGINE,
  evidenceClass: MOBILE
    ? `SIMULATED (${ENGINE === 'webkit-iphone' ? 'desktop WebKit, iPhone-like viewport, touch and user agent' : 'Chromium device emulation 390x844, mobile, touch'}); not physical-device evidence`
    : 'automated end to end on the installed browser; picker and drop input are injected (see the runner header)',
  viewport: VIEWPORT,
  startedAt: new Date().toISOString(),
  bundle: { path: BUNDLE, mainDartJsSha256: await sha256(join(BUNDLE, 'main.dart.js')) },
  scenarios: [],
  failures: [],
};
let current;
function scenario(name) {
  current = { name, checks: [] };
  evidence.scenarios.push(current);
  console.log(`-- ${name}`);
}
function check(name, pass, data = {}) {
  current.checks.push({ name, pass: Boolean(pass), ...data });
  if (!pass) evidence.failures.push(`${current.name}: ${name}`);
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}${pass ? '' : ` ${JSON.stringify(data).slice(0, 300)}`}`);
}

// --- Browser ---------------------------------------------------------------------

const pw = await import(pathToFileURL(join(PLAYWRIGHT, 'node_modules', 'playwright', 'index.mjs')).href);
let browser;
if (CHROMIUM) browser = await pw.chromium.launch({ headless: true, executablePath: BROWSER });
else if (ENGINE === 'firefox') browser = await pw.firefox.launch({ headless: true, channel: 'moz-firefox', executablePath: BROWSER });
else if (ENGINE === 'webkit-iphone') browser = await pw.webkit.launch({ headless: true });
else throw new Error(`unknown engine ${ENGINE}`);
evidence.browserVersion = browser.version();
const server = await serveBundle(BUNDLE);

async function newContext() {
  const options = { viewport: VIEWPORT };
  if (ENGINE === 'chromium-mobile') Object.assign(options, { isMobile: true, hasTouch: true, deviceScaleFactor: 3 });
  if (ENGINE === 'webkit-iphone') Object.assign(options, { hasTouch: true, userAgent: IPHONE_UA, deviceScaleFactor: 3 });
  const context = await browser.newContext(options);
  if (ENGINE === 'firefox') {
    // Keep the app's own file input, without opening a dialog (see the header).
    await context.addInitScript(() => {
      const click = HTMLInputElement.prototype.click;
      HTMLInputElement.prototype.click = function () {
        if (this.type === 'file') { window.__df020Input = this; return; }
        return click.call(this);
      };
    });
  }
  const page = await context.newPage();
  const cdp = CHROMIUM ? await context.newCDPSession(page) : null;
  return { context, page, cdp };
}

const SETTINGS_ON = JSON.stringify({ appearance: 'system', fontScale: 1.0, wrapCode: false, keepForNextTime: true });
async function seed(page, values) {
  await page.goto(`${server.origin}/__seed-page-not-the-app`);
  await page.evaluate(async (entries) => {
    const db = await new Promise((done, fail) => {
      const r = indexedDB.open('markdown_viewer', 1);
      r.onupgradeneeded = () => r.result.createObjectStore('box');
      r.onsuccess = () => done(r.result);
      r.onerror = () => fail(r.error);
    });
    await new Promise((done, fail) => {
      const tx = db.transaction('box', 'readwrite');
      for (const [key, value] of entries) tx.objectStore('box').put(value, key);
      tx.oncomplete = done; tx.onerror = () => fail(tx.error);
    });
    db.close();
  }, Object.entries(values));
}

async function enableSemantics(page) {
  await page.waitForSelector('flt-semantics-placeholder', { state: 'attached', timeout: 90000 });
  await delay(1200);
  await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
  await delay(1200);
}
async function openApp(page) {
  await page.goto(`${server.origin}/`);
  await enableSemantics(page);
}
async function reload(page) {
  await page.reload();
  await enableSemantics(page);
}

// The semantics tree as nodes: role, label and selected state.
async function nodes(page) {
  return page.evaluate(() => [...document.querySelectorAll('flt-semantics')].map((n) => ({
    role: n.getAttribute('role'),
    label: n.getAttribute('aria-label') ?? '',
    selected: n.getAttribute('aria-selected'),
    current: n.getAttribute('aria-current'),
    text: [
      n.getAttribute('aria-description'),
      ...(n.getAttribute('aria-describedby') ?? '').split(/\s+/).filter(Boolean)
        .map((id) => document.getElementById(id)?.textContent ?? ''),
      n.textContent,
    ].filter(Boolean).join(' '),
  })));
}
async function haystack(page) {
  return (await nodes(page)).map((n) => `${n.label} ${n.text}`).join('\n');
}
async function waitFor(what, producer, timeout = 15000) {
  const start = Date.now();
  let last;
  for (;;) {
    last = await producer();
    if (last) return last;
    if (Date.now() - start > timeout) return null;
    await delay(250);
  }
}
const waitText = (page, pattern, timeout) => waitFor(String(pattern), async () => {
  const text = await haystack(page);
  return (pattern instanceof RegExp ? pattern.test(text) : text.includes(pattern)) ? text : null;
}, timeout);
const tabs = async (page) => (await nodes(page)).filter((n) => n.role === 'tab');
const selectedTab = async (page) => (await tabs(page)).find((n) => n.selected === 'true')?.label ?? null;

async function tap(page, role, name) {
  const locator = page.getByRole(role, { name, exact: typeof name === 'string' }).first();
  await locator.waitFor({ state: 'attached', timeout: 15000 });
  await locator.click({ force: true });
  await delay(700);
}
async function menu(page) {
  const size = page.viewportSize();
  await page.mouse.click(size.width - 16 - 24, size.height - 20 - 24);
  await delay(900);
}
async function menuAction(page, name) {
  await menu(page);
  await tap(page, 'button', name);
  await delay(600);
}
async function home(page) {
  if (await page.getByRole('button', { name: 'Continue reading' }).count()) return;
  await menuAction(page, 'Return to main');
}
async function continueReading(page) {
  await tap(page, 'button', 'Continue reading');
  await delay(1500);
}

// --- Storage ---------------------------------------------------------------------

async function rawStored(page) {
  return page.evaluate(async () => {
    const db = await new Promise((done) => { const r = indexedDB.open('markdown_viewer'); r.onsuccess = () => done(r.result); });
    const read = (key) => new Promise((done) => { const r = db.transaction('box').objectStore('box').get(key); r.onsuccess = () => done(r.result ?? null); });
    const value = { document: await read('document'), position: await read('position'), settings: await read('settings') };
    db.close();
    return value;
  });
}
function decode(raw) {
  const set = raw.document ? JSON.parse(raw.document) : null;
  const reading = raw.position ? JSON.parse(raw.position) : null;
  const documents = Array.isArray(set) ? set[2]?.documents ?? [] : set ? [set] : [];
  return {
    format: Array.isArray(set) ? `v${set[1]}` : set ? 'legacy' : 'absent',
    names: documents.map((d) => d.sourceName ?? `(pasted: ${d.title})`),
    ids: documents.map((d) => d.id),
    titles: documents.map((d) => d.title),
    sources: documents.map((d) => d.source),
    activeId: Array.isArray(reading) ? reading[2]?.activeId ?? null : null,
    positions: Array.isArray(reading) ? reading[2]?.positions ?? {} : reading ? { [reading.documentId]: reading } : {},
    keep: raw.settings ? JSON.parse(raw.settings).keepForNextTime : null,
  };
}
const stored = async (page) => decode(await rawStored(page));
const waitStored = (page, predicate, timeout = 15000) =>
  waitFor('stored', async () => { const s = await stored(page); return predicate(s) ? s : null; }, timeout);
const idOf = (s, name) => s.ids[s.names.indexOf(name)];

// --- Input injection ------------------------------------------------------------

async function deliverPick(page, paths, open) {
  if (ENGINE === 'firefox') {
    await page.evaluate(() => { window.__df020Input = null; });
    await open();
    const files = await Promise.all(paths.map(async (p) => ({ name: basename(p), text: await readFile(p, 'utf8') })));
    const ok = await waitFor('input', () => page.evaluate(() => Boolean(window.__df020Input)), 10000);
    if (!ok) throw new Error('the app did not open its file input');
    await page.evaluate((list) => {
      const transfer = new DataTransfer();
      for (const f of list) transfer.items.add(new File([f.text], f.name, { type: 'text/markdown' }));
      const input = window.__df020Input;
      input.files = transfer.files;
      input.dispatchEvent(new Event('change', { bubbles: true }));
    }, files);
  } else {
    const chooser = page.waitForEvent('filechooser', { timeout: 15000 });
    await open();
    const picked = await chooser;
    if (!picked.isMultiple()) throw new Error('the picker is not multi-select');
    await picked.setFiles(paths);
  }
  await delay(2500);
}
const pickFromHome = (page, paths) => deliverPick(page, paths, () => tap(page, 'button', 'Load from file'));
const pickFromReader = (page, paths) => deliverPick(page, paths, async () => {
  await menu(page);
  await tap(page, 'button', 'Load from file');
});

async function dropFiles(page, cdp, paths) {
  const at = { x: VIEWPORT.width / 2, y: VIEWPORT.height / 2 };
  if (cdp) {
    const data = { items: [], files: paths, dragOperationsMask: 1 };
    for (const type of ['dragEnter', 'dragOver', 'drop']) await cdp.send('Input.dispatchDragEvent', { type, ...at, data });
  } else {
    const files = await Promise.all(paths.map(async (p) => ({ name: basename(p), text: await readFile(p, 'utf8') })));
    await page.evaluate(({ list, at }) => {
      const transfer = new DataTransfer();
      for (const f of list) transfer.items.add(new File([f.text], f.name, { type: 'text/markdown' }));
      const init = { bubbles: true, cancelable: true, dataTransfer: transfer, clientX: at.x, clientY: at.y };
      window.dispatchEvent(new DragEvent('dragover', init));
      window.dispatchEvent(new DragEvent('drop', init));
    }, { list: files, at });
  }
  await delay(2500);
}

async function scrollReader(page, times = 6) {
  await page.mouse.move(VIEWPORT.width / 2, VIEWPORT.height / 2);
  for (let i = 0; i < times; i++) {
    if (MOBILE && ENGINE === 'webkit-iphone') await page.mouse.wheel(0, 700);
    else await page.mouse.wheel(0, 700);
    await delay(150);
  }
  await delay(2500); // the position write is debounced
}

async function paste(page, text) {
  await tap(page, 'button', 'Paste Markdown');
  const field = page.locator('textarea, input[type="text"], [contenteditable="true"]').first();
  await field.waitFor({ state: 'attached', timeout: 15000 });
  await field.focus();
  await page.keyboard.type(text, { delay: 5 });
  await delay(400);
  await tap(page, 'button', 'Open');
  await delay(1500);
}

// --- Desktop scenarios (Chrome, Edge, Firefox) --------------------------------

async function desktop() {
  const { context, page, cdp } = await newContext();
  try {
    await seed(page, { settings: SETTINGS_ON });
    await openApp(page);

    scenario('multi-file picker batch → tabs, D-2 order, first active');
    await pickFromHome(page, [F.c, F.A, F.b]);
    let s = await waitStored(page, (x) => x.names.length === 3);
    check('stored in D-2 order A.md, b.md, c.md', JSON.stringify(s?.names) === '["A.md","b.md","c.md"]', { s });
    check('A.md is active', s && s.activeId === s.ids[0]);
    check('three tabs shown, A.md selected', (await tabs(page)).length === 3 && await selectedTab(page) === 'A.md', { tabs: await tabs(page) });

    scenario('switch-only change, then Keep ON reload restores the set, place and active document');
    await tap(page, 'tab', 'b.md');
    const bId = idOf(s, 'b.md');
    s = await waitStored(page, (x) => x.activeId === bId);
    check('the switch alone is saved (activeId b.md)', Boolean(s));
    await scrollReader(page);
    s = await waitStored(page, (x) => (x.positions[bId]?.blockIndex ?? 0) > 0);
    const placeB = s?.positions[bId];
    check('b.md has a saved reading place', Boolean(placeB), { placeB });
    await reload(page);
    check('Home offers Continue reading', Boolean(await waitText(page, 'Continue reading')));
    await continueReading(page);
    await delay(2500);
    s = await stored(page);
    check('after reload b.md is still active', s.activeId === bId && await selectedTab(page) === 'b.md', { activeId: s.activeId, selected: await selectedTab(page) });
    check('b.md\'s place is restored, not reset', s.positions[bId]?.blockIndex === placeB?.blockIndex, { before: placeB, after: s.positions[bId] });
    check('the set is unchanged', JSON.stringify(s.names) === '["A.md","b.md","c.md"]');

    scenario('Search is cleared on switch');
    await menuAction(page, 'Search document');
    await page.keyboard.type('Paragraph', { delay: 10 });
    await delay(1200);
    const searching = await page.evaluate(() => [...document.querySelectorAll('input, textarea')].some((i) => i.value === 'Paragraph'));
    check('a query is entered in b.md', searching);
    await tap(page, 'tab', 'c.md');
    await tap(page, 'tab', 'b.md');
    await delay(800);
    const still = await page.evaluate(() => [...document.querySelectorAll('input, textarea')].some((i) => i.value === 'Paragraph'));
    check('after switching away and back the query is gone', !still);

    scenario('closing the active document (D-11), then reload');
    await tap(page, 'button', /^Close b\.md/);
    const cId = idOf(s, 'c.md');
    s = await waitStored(page, (x) => x.names.length === 2);
    check('b.md is removed from storage', JSON.stringify(s?.names) === '["A.md","c.md"]' && !(bId in (s?.positions ?? {})), { s });
    check('the right neighbour c.md is active', s?.activeId === cId && await selectedTab(page) === 'c.md');
    await reload(page);
    await waitText(page, 'Continue reading');
    await continueReading(page);
    s = await stored(page);
    check('after reload c.md is active and the set is A.md, c.md', s.activeId === cId && JSON.stringify(s.names) === '["A.md","c.md"]' && await selectedTab(page) === 'c.md');

    scenario('verified replacement from the Reader, then reload');
    const oldA = idOf(s, 'A.md');
    await pickFromReader(page, [F.A2]);
    check('the replacement is confirmed first', Boolean(await waitText(page, 'Replace current document?')));
    await tap(page, 'button', 'Replace');
    s = await waitStored(page, (x) => x.ids.length === 2 && !x.ids.includes(oldA));
    check('the new A.md keeps the slot with a new ID and the new content', s && s.names[0] === 'A.md' && s.ids[0] !== oldA && s.sources[0].startsWith('# Second Alpha'), { s });
    check('the old copy is absent from both keys', s && !s.ids.includes(oldA) && !(oldA in s.positions));
    check('the new A.md is active', s?.activeId === s?.ids[0]);
    await reload(page);
    await waitText(page, 'Continue reading');
    s = await stored(page);
    check('after reload the old copy is still absent', !s.ids.includes(oldA) && s.sources[0].startsWith('# Second Alpha'));
    await continueReading(page);

    scenario('synthetic drop batch on Home → tabs');
    await home(page);
    await dropFiles(page, cdp, [F.e, F.d]);
    s = await waitStored(page, (x) => x.names.length === 4);
    check('d.md and e.md are appended in D-2 order', JSON.stringify(s?.names) === '["A.md","c.md","d.md","e.md"]', { s });
    check('d.md is active', s && s.activeId === idOf(s, 'd.md'));
    check('four tabs shown', (await tabs(page)).length === 4);

    scenario('resize across the 600 px threshold');
    const beforeResize = await stored(page);
    await page.setViewportSize({ width: 500, height: 900 });
    await delay(1500);
    check('narrow: no tab bar', (await tabs(page)).length === 0);
    await menu(page);
    check('narrow: the menu offers Documents (4)', Boolean(await waitText(page, 'Documents (4)', 5000)));
    await page.keyboard.press('Escape');
    await delay(800);
    await page.setViewportSize(VIEWPORT);
    await delay(1500);
    check('wide again: the tab bar is back with d.md selected', (await tabs(page)).length === 4 && await selectedTab(page) === 'd.md');
    const afterResize = await stored(page);
    check('the set and the active document are unchanged', JSON.stringify(afterResize.ids) === JSON.stringify(beforeResize.ids) && afterResize.activeId === beforeResize.activeId);

    scenario('two pastes survive reload');
    await home(page);
    await paste(page, '# Pasted one\n\nThe first pasted document.');
    await home(page);
    await paste(page, '# Pasted two\n\nThe second pasted document.');
    s = await waitStored(page, (x) => x.ids.length === 6);
    const pasted = s ? s.titles.filter((t) => /^Pasted (one|two)$/.test(t)) : [];
    check('both pastes are stored as separate documents', pasted.length === 2, { titles: s?.titles });
    await reload(page);
    await waitText(page, 'Continue reading');
    const afterPaste = await stored(page);
    check('after reload both pastes are still saved', JSON.stringify(afterPaste.ids) === JSON.stringify(s?.ids));
    await continueReading(page);
    const labels = (await tabs(page)).map((t) => t.label);
    check('both pastes are restored as tabs', labels.includes('Pasted one') && labels.includes('Pasted two'), { labels });

    scenario('Remove saved documents verifies absence and returns to an empty Home');
    await home(page);
    await tap(page, 'button', 'Settings');
    await tap(page, 'button', 'Remove saved documents');
    await tap(page, 'button', 'Remove');
    await delay(1500);
    const raw = await rawStored(page);
    check('both content keys are absent', raw.document === null && raw.position === null, { raw: { d: raw.document?.slice(0, 40), p: raw.position?.slice(0, 40) } });
    check('Keep for next time stays on', decode(raw).keep === true);
    const backButton = page.getByRole('button', { name: 'Back' });
    if (await backButton.count()) await backButton.first().click({ force: true });
    await delay(1000);
    check('Home is empty: no Continue reading', !(await haystack(page)).includes('Continue reading'));
  } finally {
    await context.close();
  }

  // Migration from a seeded v1.6.1 record.
  const { context: c2, page: p2 } = await newContext();
  try {
    scenario('migration from a seeded v1.6.1 record');
    const legacy = {
      id: 'legacy-1', title: 'Legacy doc', source: body('Legacy doc'),
      createdAt: '2026-10-01T00:00:00.000Z', updatedAt: '2026-10-01T00:00:00.000Z',
      sourceName: 'legacy.md', origin: 'file', scriptPreference: 'auto',
    };
    const legacyPos = { documentId: 'legacy-1', blockIndex: 9, fraction: 0, headingText: null, savedAt: '2026-10-01T00:00:00.000Z' };
    await seed(p2, { settings: SETTINGS_ON, document: JSON.stringify(legacy), position: JSON.stringify(legacyPos) });
    await openApp(p2);
    const offered = await waitText(p2, /Continue reading/);
    check('Home offers the v1.6.1 document by its identity', Boolean(offered) && /Legacy doc|legacy\.md/.test(offered), { home: offered?.split('\n').filter((l) => /Continue|egacy/.test(l)).slice(0, 4) });
    await continueReading(p2);
    await delay(2000);
    await home(p2);
    await paste(p2, '# After migration\n\nA second document.');
    const s = await waitStored(p2, (x) => x.format === 'v2' && x.ids.length === 2);
    check('the set is migrated to v2 with the legacy document first', s && s.ids[0] === 'legacy-1', { s });
    check('the legacy reading place is carried over', s && s.positions['legacy-1']?.blockIndex === 9, { positions: s?.positions });
  } finally {
    await c2.close();
  }
}

// --- Narrow scenarios (simulated mobile Chromium, desktop-WebKit iPhone-like) --

async function narrow() {
  const { context, page } = await newContext();
  try {
    await seed(page, { settings: SETTINGS_ON });
    await openApp(page);

    scenario('narrow: multi-file pick, the switcher and its active marker');
    await pickFromHome(page, [F.c, F.b, F.A]);
    let s = await waitStored(page, (x) => x.names.length === 3);
    check('stored in D-2 order, A.md active', JSON.stringify(s?.names) === '["A.md","b.md","c.md"]' && s.activeId === s.ids[0], { s });
    check('narrow: no tab bar', (await tabs(page)).length === 0);
    await menuAction(page, 'Documents (3)');
    const sheet = await nodes(page);
    const marked = sheet.filter((n) => /^(A\.md|b\.md|c\.md)/.test(n.label) || /^(A\.md|b\.md|c\.md)$/.test(n.text.trim()));
    current.checks.push({ name: 'switcher rows (recorded)', pass: true, rows: marked.map((n) => ({ role: n.role, label: n.label, selected: n.selected, current: n.current })) });
    // The active row is announced as current (`aria-current`), beside its check mark.
    const activeRows = marked.filter((n) => n.current === 'true');
    check('the switcher marks A.md, and only A.md, active', activeRows.length === 1 && activeRows[0].label === 'A.md', { rows: marked });
    await page.locator('flt-semantics[role="button"][aria-label="b.md"]').first().click({ force: true });
    await delay(1200);
    const bId = idOf(s, 'b.md');
    s = await waitStored(page, (x) => x.activeId === bId);
    check('selecting b.md makes it active (saved)', Boolean(s));

    scenario('narrow: reading place, responsive changes and reload');
    await scrollReader(page);
    s = await waitStored(page, (x) => (x.positions[bId]?.blockIndex ?? 0) > 0);
    const placeB = s?.positions[bId];
    check('b.md has a saved place', Boolean(placeB), { placeB });
    await page.setViewportSize({ width: 800, height: VIEWPORT.height });
    await delay(2000);
    let after = await stored(page);
    check('wide: tabs appear with b.md selected', (await tabs(page)).length === 3 && await selectedTab(page) === 'b.md');
    check('wide: set, active and place unchanged', JSON.stringify(after.ids) === JSON.stringify(s.ids) && after.activeId === bId && after.positions[bId]?.blockIndex === placeB.blockIndex, { after: after.positions[bId], placeB });
    await page.setViewportSize(VIEWPORT);
    await delay(2000);
    after = await stored(page);
    check('narrow again: no tabs; set, active and place unchanged', (await tabs(page)).length === 0 && JSON.stringify(after.ids) === JSON.stringify(s.ids) && after.activeId === bId && after.positions[bId]?.blockIndex === placeB.blockIndex, { after: after.positions[bId] });
    await reload(page);
    check('reload: Home offers Continue reading', Boolean(await waitText(page, 'Continue reading')));
    await continueReading(page);
    await delay(2500);
    after = await stored(page);
    check('reload: set, active b.md and its place restored', JSON.stringify(after.ids) === JSON.stringify(s.ids) && after.activeId === bId && after.positions[bId]?.blockIndex === placeB.blockIndex, { after });

    scenario('narrow: closing (D-11)');
    await menuAction(page, 'Close document');
    const cId = idOf(s, 'c.md');
    let c = await waitStored(page, (x) => x.ids.length === 2);
    check('closing the active b.md activates its right neighbour c.md', c && JSON.stringify(c.names) === '["A.md","c.md"]' && c.activeId === cId, { c });
    await menuAction(page, 'Documents (2)');
    await tap(page, 'button', /^Close A\.md/);
    c = await waitStored(page, (x) => x.ids.length === 1);
    check('closing the inactive A.md keeps c.md active', c && JSON.stringify(c.names) === '["c.md"]' && c.activeId === cId, { c });
    await reload(page);
    await waitText(page, 'Continue reading');
    c = await stored(page);
    check('reload: the closed documents stay closed', JSON.stringify(c.names) === '["c.md"]' && c.activeId === cId);
  } finally {
    await context.close();
  }
}

try {
  if (MOBILE) await narrow();
  else await desktop();
} catch (error) {
  evidence.failures.push(`run: ${error.stack ?? error}`);
  console.log(`ERROR ${error.stack ?? error}`);
} finally {
  await browser.close();
  await server.close();
}
evidence.passed = evidence.failures.length === 0;
evidence.checks = evidence.scenarios.reduce((n, s) => n + s.checks.length, 0);
await mkdir(dirname(OUT), { recursive: true });
await writeFile(OUT, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');
console.log(evidence.passed ? `ALL PASSED (${evidence.checks} checks)` : `FAILURES: ${evidence.failures.join('; ')}`);
process.exitCode = evidence.passed ? 0 : 1;
