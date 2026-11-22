// DF-085: the compiled-build synthetic drop onto the Reader.
//
// Verification support, not product code. Nothing here is imported by `lib/`.
//
//   node test/browser/df085_reader_drop.mjs --browser <chrome.exe> \
//     --playwright <dir with node_modules/playwright> --bundle <production bundle> \
//     --files <empty scratch directory> --out <file.json>
//
// Chromium (installed Chrome, through Playwright). Each case starts in a fresh
// context with `Keep for next time` ON, opens the Reader by dropping a first
// file on Home, then drops real files on the Reader through the DevTools
// protocol (`Input.dispatchDragEvent` with file paths), so the production drop
// handler classifies real `DataTransferItem`s and entries. What loaded is read
// back from IndexedDB and from the semantics tree. A narrow-layout screenshot
// is saved next to the JSON for the S-5 readability check.
//
// This is SIMULATED input: the browser synthesizes the drag. It is not native
// Explorer evidence (that is the Human-operated Reader-mode G-1' capture).

import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

import { delay, serveBundle } from './df031_cdp.mjs';

function argument(name) {
  const index = process.argv.indexOf(`--${name}`);
  if (index === -1) throw new Error(`Missing --${name}`);
  return process.argv[index + 1];
}

const BROWSER = argument('browser');
const PLAYWRIGHT = argument('playwright');
const BUNDLE = resolve(argument('bundle'));
const FILES = resolve(argument('files'));
const OUT = resolve(argument('out'));

const sha256 = async (path) => createHash('sha256').update(await readFile(path)).digest('hex');
const settings = JSON.stringify({ appearance: 'system', fontScale: 1.0, wrapCode: false, keepForNextTime: true });

async function put(relative, contents) {
  const path = join(FILES, relative);
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, contents);
  return path;
}
const md = (name) => `# Dropped ${name}\n\nParagraph of ${name}.`;
const f = {
  base: await put('base.md', md('base.md')),
  a: await put('a.md', md('a.md')),
  b: await put('b.md', md('b.md')),
  c: await put('c.md', md('c.md')),
  a2: await put('second/a.md', '# Second a\n\nThe second copy of a.md.'),
  empty: await put('e.md', ''),
  rtf: await put('notes.rtf', 'Readable plain text, but not a Markdown name.'),
  badMd: await put('bad.md', Buffer.from([0x23, 0x20, 0xff, 0xfe, 0x00, 0x41])),
  folder: dirname(await put('folder/inside.md', md('inside.md'))),
};

const SEED = `(async () => {
  const db = await new Promise((done, fail) => {
    const r = indexedDB.open('markdown_viewer', 1);
    r.onupgradeneeded = () => r.result.createObjectStore('box');
    r.onsuccess = () => done(r.result);
    r.onerror = () => fail(r.error);
  });
  await new Promise((done, fail) => {
    const tx = db.transaction('box', 'readwrite');
    tx.objectStore('box').put(${JSON.stringify(settings)}, 'settings');
    tx.oncomplete = done; tx.onerror = () => fail(tx.error);
  });
  db.close();
  return 'seeded';
})()`;

const STORED = `(async () => {
  const db = await new Promise((done) => { const r = indexedDB.open('markdown_viewer'); r.onsuccess = () => done(r.result); });
  const read = (key) => new Promise((done) => { const r = db.transaction('box').objectStore('box').get(key); r.onsuccess = () => done(r.result ?? null); });
  const value = { document: await read('document'), position: await read('position') };
  db.close();
  return value;
})()`;

const SEMANTICS = `[...document.querySelectorAll('flt-semantics')].map((n) => {
  const described = (n.getAttribute('aria-describedby') || '').split(/\\s+/).filter(Boolean)
    .map((id) => document.getElementById(id)?.textContent ?? '').join(' ');
  return [n.getAttribute('aria-label'), n.getAttribute('aria-description'), described, n.textContent]
    .filter(Boolean).join(' | ');
}).filter(Boolean).join('\\n')`;

const evidence = {
  harness: 'df085_reader_drop',
  evidenceClass: 'simulated (DevTools-protocol drag with real files); not native Explorer evidence',
  startedAt: new Date().toISOString(),
  bundle: { path: BUNDLE, mainDartJsSha256: await sha256(join(BUNDLE, 'main.dart.js')) },
  cases: [],
  failures: [],
};
const check = (record, name, pass, data = {}) => {
  record.checks.push({ name, pass: Boolean(pass), ...data });
  if (!pass) evidence.failures.push(`${record.name}: ${name}`);
  console.log(`${pass ? 'PASS' : 'FAIL'}  [${record.name}] ${name}`);
};

function decode(stored) {
  const set = stored.document ? JSON.parse(stored.document) : null;
  const reading = stored.position ? JSON.parse(stored.position) : null;
  const documents = set?.[2]?.documents ?? [];
  return {
    names: documents.map((d) => d.sourceName),
    ids: documents.map((d) => d.id),
    sources: documents.map((d) => d.source),
    activeId: reading?.[2]?.activeId ?? null,
    positionIds: Object.keys(reading?.[2]?.positions ?? {}),
  };
}

const { chromium } = await import(pathToFileURL(join(PLAYWRIGHT, 'node_modules', 'playwright', 'index.mjs')).href);
const server = await serveBundle(BUNDLE);
const browser = await chromium.launch({ headless: true, executablePath: BROWSER });
evidence.browserVersion = browser.version();
const MEDIUM = { width: 1000, height: 900 }; // tabs; Search would be a sheet
const WIDE = { width: 1400, height: 900 }; // the persistent Search pane
const NARROW = { width: 390, height: 844 };

async function openApp(page) {
  await page.goto(`${server.origin}/`);
  await page.waitForSelector('flt-semantics-placeholder', { state: 'attached', timeout: 60000 });
  await delay(1500);
  await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
  await delay(1500);
}

async function dropFiles(page, cdp, files, items = []) {
  const size = page.viewportSize();
  const at = { x: Math.round(size.width / 3), y: Math.round(size.height / 2) };
  const data = { items, files, dragOperationsMask: 1 };
  for (const type of ['dragEnter', 'dragOver', 'drop']) {
    await cdp.send('Input.dispatchDragEvent', { type, ...at, data });
  }
  await delay(2000);
}

async function tap(page, role, name) {
  const locator = page.getByRole(role, { name, exact: typeof name === 'string' }).first();
  await locator.waitFor({ state: 'attached', timeout: 15000 });
  await locator.click({ force: true });
  await delay(700);
}
async function menuAction(page, name) {
  const size = page.viewportSize();
  await page.mouse.click(size.width - 16 - 24, size.height - 20 - 24);
  await delay(900);
  await tap(page, 'button', name);
  await delay(600);
}
const query = (page) => page.evaluate(() => [...document.querySelectorAll('input, textarea')].map((i) => i.value));

async function runCase(name, body, viewport = MEDIUM) {
  const record = { name, viewport, checks: [] };
  evidence.cases.push(record);
  const context = await browser.newContext({ viewport });
  const page = await context.newPage();
  try {
    await page.goto(`${server.origin}/__seed-page-not-the-app`);
    await page.evaluate(SEED);
    await openApp(page);
    const cdp = await context.newCDPSession(page);
    await body({ record, page, cdp });
  } catch (error) {
    check(record, 'the case ran to completion', false, { error: `${error.stack ?? error}` });
  } finally {
    await context.close();
  }
}

const text = (page) => page.evaluate(SEMANTICS);
const stored = async (page) => decode(await page.evaluate(STORED));
const raw = (page) => page.evaluate(STORED);
const url = (page) => page.evaluate(() => location.href);
const onReader = (shown) => !/Continue reading/.test(shown);

/// Opens the Reader through a Home drop of [first], and checks it did.
async function readerWith(record, page, cdp, first) {
  await dropFiles(page, cdp, first);
  const shown = await text(page);
  check(record, 'pre-state: the Reader shows the first drop', onReader(shown) && (await stored(page)).names.length === first.length);
}

const unsupported = 'Choose a Markdown file (.md, .markdown or .txt).';

try {
  await runCase('Reader drop appends in D-2 order; the first new one is active', async ({ record, page, cdp }) => {
    const u0 = await url(page);
    await readerWith(record, page, cdp, [f.c]);
    const first = await stored(page);
    await dropFiles(page, cdp, [f.b, f.a]);
    const after = await stored(page);
    record.after = after;
    check(record, 'appended after the open set in D-2 order: c.md, a.md, b.md', JSON.stringify(after.names) === '["c.md","a.md","b.md"]');
    check(record, 'a.md (first new in D-2 order) is active', after.activeId === after.ids[1]);
    check(record, 'c.md kept its ID', after.ids[0] === first.ids[0]);
    const shown = await text(page);
    check(record, 'still on the Reader, three tabs shown', onReader(shown) && ['a.md', 'b.md', 'c.md'].every((n) => shown.includes(n)));
    check(record, 'URL unchanged (no browser navigation)', (await url(page)) === u0);
  });

  await runCase('Reader drop of a matching name asks; Replace takes the slot (E-1 under ON)', async ({ record, page, cdp }) => {
    await readerWith(record, page, cdp, [f.b, f.a]);
    const first = await stored(page);
    await dropFiles(page, cdp, [f.a2]);
    check(record, 'confirmation asked over the Reader', /Replace current document\?/.test(await text(page)));
    await page.getByRole('button', { name: /^Replace$/ }).first().click();
    await delay(2000);
    const after = await stored(page);
    record.after = after;
    check(record, 'a.md replaced in place with a new ID and the new content', JSON.stringify(after.names) === '["a.md","b.md"]' && after.ids[0] !== first.ids[0] && after.sources[0] === '# Second a\n\nThe second copy of a.md.');
    check(record, 'the old copy is absent from both keys', !after.ids.includes(first.ids[0]) && !after.positionIds.includes(first.ids[0]));
    check(record, 'the new a.md is active, still on the Reader', after.activeId === after.ids[0] && onReader(await text(page)));
  });

  await runCase('Reader drop of a matching name, Cancel: nothing changes (M5)', async ({ record, page, cdp }) => {
    await readerWith(record, page, cdp, [f.b, f.a]);
    const before = await raw(page);
    await dropFiles(page, cdp, [f.a2, f.c]);
    check(record, 'confirmation asked', /Replace current document\?/.test(await text(page)));
    await page.getByRole('button', { name: /^Cancel$/ }).first().click();
    await delay(2000);
    check(record, 'stored set and reading state are byte-identical', JSON.stringify(await raw(page)) === JSON.stringify(before));
    check(record, 'still on the Reader', onReader(await text(page)));
  });

  for (const [name, files, items, message] of [
    ['an unsupported name', [f.c, f.rtf], [], `Cannot open "notes.rtf". ${unsupported}`],
    ['an empty file', [f.c, f.empty], [], '"e.md" is empty.'],
    ['a read failure', [f.c, f.badMd], [], 'Could not read "bad.md": FormatException'],
    ['a directory', [f.c, f.folder], [], 'Cannot classify this as a regular file; use the picker.'],
    ['a file with a text item', [f.c], [{ mimeType: 'text/plain', data: 'dragged text' }], 'Cannot classify this as a regular file; use the picker.'],
  ]) {
    await runCase(`rejected on the Reader: ${name}`, async ({ record, page, cdp }) => {
      const u0 = await url(page);
      await readerWith(record, page, cdp, [f.base, f.b]);
      const before = await raw(page);
      await dropFiles(page, cdp, files, items);
      const shown = await text(page);
      check(record, 'the message is shown on the Reader', shown.includes(message), { message });
      check(record, 'stored set and reading state are byte-identical', JSON.stringify(await raw(page)) === JSON.stringify(before));
      check(record, 'still on the Reader', onReader(shown));
      check(record, 'URL unchanged', (await url(page)) === u0);
    });
  }

  await runCase('a text-only drag over the Reader is not a file drop', async ({ record, page, cdp }) => {
    await readerWith(record, page, cdp, [f.b]);
    const before = await raw(page);
    await dropFiles(page, cdp, [], [{ mimeType: 'text/plain', data: 'only text' }]);
    check(record, 'nothing changed', JSON.stringify(await raw(page)) === JSON.stringify(before));
    check(record, 'no rejection message', !/Cannot classify|Cannot open|Could not read/.test(await text(page)));
  });

  await runCase('S-1: wide, Search pane open, valid drop closes Search and loads', async ({ record, page, cdp }) => {
    await readerWith(record, page, cdp, [f.b, f.a]);
    await menuAction(page, 'Search document');
    await page.keyboard.type('Paragraph', { delay: 10 });
    await delay(1200);
    check(record, 'pre-state: the query is entered', (await query(page)).includes('Paragraph'));
    await dropFiles(page, cdp, [f.c]);
    const after = await stored(page);
    check(record, 'c.md appended and active', JSON.stringify(after.names) === '["a.md","b.md","c.md"]' && after.activeId === after.ids[2]);
    check(record, 'the query is gone (Search closed)', !(await query(page)).includes('Paragraph'));
  }, WIDE);

  await runCase('S-2: wide, Search pane open, rejected drop keeps Search and its query', async ({ record, page, cdp }) => {
    await readerWith(record, page, cdp, [f.b, f.a]);
    await menuAction(page, 'Search document');
    await page.keyboard.type('Paragraph', { delay: 10 });
    await delay(1200);
    check(record, 'pre-state: the query is entered', (await query(page)).includes('Paragraph'));
    const before = await raw(page);
    await dropFiles(page, cdp, [f.c, f.rtf]);
    const shown = await text(page);
    check(record, 'the message is shown', shown.includes(`Cannot open "notes.rtf". ${unsupported}`));
    check(record, 'stored set and reading state are byte-identical', JSON.stringify(await raw(page)) === JSON.stringify(before));
    check(record, 'Search is still open with the same query', (await query(page)).includes('Paragraph'));
  }, WIDE);

  await runCase('S-5: narrow, rejected drop: the message is inside the viewport', async ({ record, page, cdp }) => {
    await readerWith(record, page, cdp, [f.b]);
    const before = await raw(page);
    const message = `Cannot open "notes.rtf". ${unsupported}`;
    await dropFiles(page, cdp, [f.c, f.rtf]);
    const box = await page.evaluate((m) => {
      const node = [...document.querySelectorAll('flt-semantics')]
        .filter((n) => (n.getAttribute('aria-label') ?? n.textContent ?? '').includes(m))
        .pop();
      if (!node) return null;
      const r = node.getBoundingClientRect();
      return { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: innerWidth, height: innerHeight };
    }, message);
    record.messageBox = box;
    check(record, 'the message is shown', Boolean(box));
    check(record, 'its box is entirely inside the viewport', box && box.left >= 0 && box.top >= 0 && box.right <= box.width && box.bottom <= box.height, { box });
    const shot = join(dirname(OUT), 'df085-s5-narrow.png');
    await page.screenshot({ path: shot });
    record.screenshot = shot;
    check(record, 'stored set and reading state are byte-identical', JSON.stringify(await raw(page)) === JSON.stringify(before));
  }, NARROW);
} finally {
  await browser.close();
  await server.close();
}
evidence.passed = evidence.failures.length === 0;
await mkdir(dirname(OUT), { recursive: true });
await writeFile(OUT, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');
console.log(evidence.passed ? 'ALL PASSED' : `FAILURES: ${evidence.failures.join('; ')}`);
process.exitCode = evidence.passed ? 0 : 1;
