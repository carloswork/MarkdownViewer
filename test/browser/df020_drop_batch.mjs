// DF-020 CP4: the compiled-build synthetic drop of a batch.
//
// Verification support, not product code. Nothing here is imported by `lib/`.
//
//   node test/browser/df020_drop_batch.mjs --browser <chrome.exe> \
//     --playwright <dir with node_modules/playwright> --bundle <production bundle> \
//     --files <empty scratch directory> --out <file.json>
//
// Chromium (installed Chrome, through Playwright). Each case starts in a fresh
// context with `Keep for next time` ON, then drops real files on Home through
// the DevTools protocol (`Input.dispatchDragEvent` with file paths), so the
// production drop handler classifies real `DataTransferItem`s and entries.
// What loaded is read back from IndexedDB, where the app saves the open set,
// and from the semantics tree.
//
// This is SIMULATED input: the browser synthesizes the drag. It is not native
// Explorer evidence (that is G-1 at INT).

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

// The files, written fresh for this run.
async function put(relative, contents) {
  const path = join(FILES, relative);
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, contents);
  return path;
}
const md = (name) => `# Dropped ${name}\n\nThe dropped copy of ${name}.`;
const f = {
  c: await put('c.md', md('c.md')),
  // Windows filenames are case-insensitive, so A.md lives apart from a.md.
  A: await put('upper/A.md', md('A.md')),
  b: await put('b.md', md('b.md')),
  a: await put('a.md', md('a.md')),
  a2: await put('second/a.md', '# Second a\n\nThe second copy of a.md.'),
  notes1: await put('one/notes.md', md('notes.md')),
  notes2: await put('two/notes.md', md('notes.md')),
  empty: await put('e.md', ''),
  photo: await put('photo.png', Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0xff, 0xfe, 0x00])),
  folder: dirname(await put('folder/inside.md', md('inside.md'))),
  // PC-2: readable text with an unsupported name, and malformed bytes with a
  // Markdown name.
  rtf: await put('notes.rtf', 'Readable plain text, but not a Markdown name.'),
  badMd: await put('bad.md', Buffer.from([0x23, 0x20, 0xff, 0xfe, 0x00, 0x41])),
  baseB: await put('base/b.md', md('b.md')),
  baseD: await put('base/d.md', md('d.md')),
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
  harness: 'df020_drop_batch',
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
const VIEWPORT = { width: 1200, height: 900 };

async function openApp(page) {
  await page.goto(`${server.origin}/`);
  await page.waitForSelector('flt-semantics-placeholder', { state: 'attached', timeout: 60000 });
  await delay(1500);
  await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
  await delay(1500);
}

async function dropFiles(page, cdp, files, items = []) {
  const at = { x: VIEWPORT.width / 2, y: VIEWPORT.height / 2 };
  const data = { items, files, dragOperationsMask: 1 };
  for (const type of ['dragEnter', 'dragOver', 'drop']) {
    await cdp.send('Input.dispatchDragEvent', { type, ...at, data });
  }
  await delay(2000);
}

async function runCase(name, body) {
  const record = { name, checks: [] };
  evidence.cases.push(record);
  const context = await browser.newContext({ viewport: VIEWPORT });
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

try {
  await runCase('three files in reversed delivery order', async ({ record, page, cdp }) => {
    await dropFiles(page, cdp, [f.c, f.b, f.A]);
    const saved = await stored(page);
    record.stored = saved;
    check(record, 'loaded in D-2 order: A.md, b.md, c.md', JSON.stringify(saved.names) === '["A.md","b.md","c.md"]');
    check(record, 'the first in D-2 order is active', saved.activeId !== null && saved.activeId === saved.ids[0]);
    check(record, 'the contents are the dropped files', saved.sources[0] === md('A.md'));
    const shown = await text(page);
    check(record, 'the three tabs are shown', ['A.md', 'b.md', 'c.md'].every((n) => shown.includes(n)));
  });

  await runCase('a drop onto the Reader is ignored (S11-07)', async ({ record, page, cdp }) => {
    await dropFiles(page, cdp, [f.c]);
    const before = await stored(page);
    await dropFiles(page, cdp, [f.b]);
    const after = await stored(page);
    record.before = before; record.after = after;
    check(record, 'the first drop loaded c.md', JSON.stringify(before.names) === '["c.md"]');
    check(record, 'nothing changed', JSON.stringify(after) === JSON.stringify(before));
  });

  await runCase('a matching name asks, and a confirmed replacement takes the slot', async ({ record, page, cdp }) => {
    await dropFiles(page, cdp, [f.b, f.a]);
    const first = await stored(page);
    await openApp(page); // Reload: under ON the set restores, on Home.
    await dropFiles(page, cdp, [f.a2, f.c]);
    const asking = await text(page);
    check(record, 'the replacement is confirmed first', /Replace current document\?/.test(asking) && asking.includes('"a.md" and your place in it'));
    check(record, 'one match: no checkbox', !asking.includes('Do the same for other documents'));
    await page.getByRole('button', { name: /^Replace$/ }).first().click();
    await delay(2000);
    const after = await stored(page);
    record.first = first; record.after = after;
    check(record, 'new a.md in the old slot, c.md appended', JSON.stringify(after.names) === '["a.md","b.md","c.md"]');
    check(record, 'the replacement has a new ID and the new content', after.ids[0] !== first.ids[0] && after.sources[0] === '# Second a\n\nThe second copy of a.md.');
    check(record, 'the old copy is absent from both keys', !after.ids.includes(first.ids[0]) && !after.positionIds.includes(first.ids[0]));
    check(record, 'the new a.md is active', after.activeId === after.ids[0]);
  });

  // Each rejection runs over an existing open set (b.md, d.md, saved under
  // ON), which must be left exactly as it was: IDs, contents, order, the
  // active document and the stored positions.
  const unsupported = 'Choose a Markdown file (.md, .markdown or .txt).';
  const rejections = [
    ['an unsupported file with readable text', [f.c, f.rtf], [], `Cannot open "notes.rtf". ${unsupported}`],
    ['an unsupported file with malformed binary content', [f.c, f.photo], [], `Cannot open "photo.png". ${unsupported}`],
    ['a Markdown name with malformed content (a read failure)', [f.c, f.badMd], [], 'Could not read "bad.md": FormatException'],
    ['an empty file in the batch', [f.c, f.empty], [], '"e.md" is empty.'],
    ['a directory in the batch', [f.c, f.folder], [], 'Cannot classify this as a regular file; use the picker.'],
    ['a file with a text item in the same drop', [f.c], [{ mimeType: 'text/plain', data: 'dragged text' }], 'Cannot classify this as a regular file; use the picker.'],
  ];
  const STORED_RAW = STORED;
  for (const [name, files, items, message] of rejections) {
    await runCase(`rejected over an open set: ${name}`, async ({ record, page, cdp }) => {
      await dropFiles(page, cdp, [f.baseD, f.baseB]);
      await openApp(page); // Reload: under ON the set restores, on Home.
      const before = await page.evaluate(STORED_RAW);
      record.before = decode(before);
      check(record, 'the open set is b.md, d.md', JSON.stringify(record.before.names) === '["b.md","d.md"]');
      await dropFiles(page, cdp, files, items);
      const shown = await text(page);
      const after = await page.evaluate(STORED_RAW);
      record.after = decode(after);
      check(record, 'the message is shown', shown.includes(message), { message });
      check(record, 'the stored set and reading state are byte-identical', JSON.stringify(after) === JSON.stringify(before));
      check(record, 'still on Home, with the set still offered', /Load from file/.test(shown) && /Continue reading/.test(shown));
    });
  }

  await runCase('a drop with no file items is a no-op', async ({ record, page, cdp }) => {
    await dropFiles(page, cdp, [f.baseB]);
    await openApp(page);
    const before = await page.evaluate(STORED_RAW);
    await dropFiles(page, cdp, [], [{ mimeType: 'text/plain', data: 'only text' }]);
    const shown = await text(page);
    const after = await page.evaluate(STORED_RAW);
    record.after = decode(after);
    check(record, 'nothing changed', JSON.stringify(after) === JSON.stringify(before));
    check(record, 'no rejection message', !/Cannot classify|Cannot open|Could not read/.test(shown));
    check(record, 'still on Home', /Continue reading/.test(shown));
  });

  // D-5 cannot be injected here, and both attempts are recorded. A
  // DevTools-protocol drag cannot carry two files with one name: Chromium
  // renames the second to `notes (1).md`. A DataTransfer built in the page
  // carries items with no filesystem entry, which the production handler
  // rejects as unclassifiable, before any name is checked. D-5 for a drop is
  // therefore covered by the widget tests through the drop seam (V-10).
  await runCase('limitation: a DevTools drag renames a same-name pair', async ({ record, page, cdp }) => {
    await dropFiles(page, cdp, [f.notes1, f.notes2]);
    record.observedNames = (await stored(page)).names;
    check(record, 'recorded (not a product check)', true);
  });
  await runCase('rejected: items without a filesystem entry (script-built drop)', async ({ record, page }) => {
    const outcome = await page.evaluate(() => {
      const transfer = new DataTransfer();
      for (const text of ['# One', '# Two']) {
        transfer.items.add(new File([text], 'notes.md', { type: 'text/markdown' }));
      }
      const entries = [...transfer.items].map((item) => {
        const entry = item.webkitGetAsEntry?.();
        return entry ? { isFile: entry.isFile, isDirectory: entry.isDirectory } : null;
      });
      const init = { bubbles: true, cancelable: true, dataTransfer: transfer, clientX: 600, clientY: 450 };
      window.dispatchEvent(new DragEvent('dragover', init));
      window.dispatchEvent(new DragEvent('drop', init));
      return { entries };
    });
    record.entries = outcome.entries;
    await delay(2000);
    const shown = await text(page);
    const saved = await stored(page);
    record.stored = saved;
    check(record, 'no item has an entry', outcome.entries.every((e) => e === null));
    check(record, 'rejected fail-closed as unclassifiable', shown.includes('Cannot classify this as a regular file; use the picker.'));
    check(record, 'nothing loaded or saved', saved.names.length === 0 && saved.activeId === null);
  });
} finally {
  await browser.close();
  await server.close();
}
evidence.passed = evidence.failures.length === 0;
await mkdir(dirname(OUT), { recursive: true });
await writeFile(OUT, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');
console.log(evidence.passed ? 'ALL PASSED' : `FAILURES: ${evidence.failures.join('; ')}`);
process.exitCode = evidence.passed ? 0 : 1;
