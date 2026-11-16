// DF-020 V-9: the exact v1.6.1 bundle, given what DF-020 stores.
//
// Verification support, not product code. Nothing here is imported by `lib/`.
//
//   node test/browser/df020_v161_fixture.mjs --browser <chrome.exe> \
//     --playwright <dir with node_modules/playwright> --bundle <v1.6.1 bundle> \
//     --out <file.json>
//
// Seeds IndexedDB exactly as Hive lays it out (database `markdown_viewer`,
// version 1, object store `box`, raw string values) with each reachable
// combination of DF-020 plan §5.2, then starts the v1.6.1 bundle and reads its
// Home through the semantics tree. v1.6.1 must fail closed on DF-020 data:
// generic recovery, no identity, no Continue reading - and its own `Remove
// unreadable saved data` must remove it. Legacy data must still open as before.

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
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
const OUT = resolve(argument('out'));

const settings = JSON.stringify({ appearance: 'system', fontScale: 1.0, wrapCode: false, keepForNextTime: true });
const doc = (id) => ({
  id, title: `Title ${id}`, source: `# Title ${id}\n\nBody ${id}.`,
  createdAt: '2026-11-16T00:00:00.000Z', updatedAt: '2026-11-16T00:00:00.000Z',
  sourceName: `${id}.md`, origin: 'file', scriptPreference: 'auto',
});
const pos = (id, block) => ({ documentId: id, blockIndex: block, fraction: 0, headingText: null, savedAt: '2026-11-16T00:00:00.000Z' });
const v2Documents = JSON.stringify(['saudo-document-set', 2, { documents: [doc('alpha'), doc('beta')] }]);
const v2Reading = JSON.stringify(['saudo-reading-state', 2, { activeId: 'beta', positions: { alpha: pos('alpha', 1), beta: pos('beta', 2) } }]);

const fixtures = [
  { name: 'v2 document + v2 reading state', document: v2Documents, position: v2Reading, expect: 'recovery' },
  { name: 'v2 document + legacy position', document: v2Documents, position: JSON.stringify(pos('alpha', 1)), expect: 'recovery' },
  { name: 'v2 document + no position', document: v2Documents, position: null, expect: 'recovery' },
  { name: 'legacy document + legacy position (unchanged v1.6.1 behaviour)', document: JSON.stringify(doc('alpha')), position: JSON.stringify(pos('alpha', 1)), expect: 'document' },
];

const SEED = (document, position) => `(async () => {
  const db = await new Promise((done, fail) => {
    const r = indexedDB.open('markdown_viewer', 1);
    r.onupgradeneeded = () => r.result.createObjectStore('box');
    r.onsuccess = () => done(r.result);
    r.onerror = () => fail(r.error);
  });
  await new Promise((done, fail) => {
    const tx = db.transaction('box', 'readwrite');
    const s = tx.objectStore('box');
    s.put(${JSON.stringify(settings)}, 'settings');
    s.put(${JSON.stringify(document)}, 'document');
    ${position === null ? '' : `s.put(${JSON.stringify(position)}, 'position');`}
    tx.oncomplete = done; tx.onerror = () => fail(tx.error);
  });
  db.close();
  return 'seeded';
})()`;

const KEYS = `(async () => {
  const db = await new Promise((done) => { const r = indexedDB.open('markdown_viewer'); r.onsuccess = () => done(r.result); });
  const keys = await new Promise((done) => { const r = db.transaction('box').objectStore('box').getAllKeys(); r.onsuccess = () => done(r.result.map(String)); });
  db.close();
  return keys;
})()`;

// Every label and every piece of text the semantics tree exposes, wherever
// Flutter published it (the df039_retention_firefox.mjs probe, flattened).
const SEMANTICS = `[...document.querySelectorAll('flt-semantics')].map((n) => {
  const described = (n.getAttribute('aria-describedby') || '').split(/\s+/).filter(Boolean)
    .map((id) => document.getElementById(id)?.textContent ?? '').join(' ');
  return [n.getAttribute('aria-label'), n.getAttribute('aria-description'), described, n.textContent]
    .filter(Boolean).join(' | ');
}).filter(Boolean)`;

const evidence = { harness: 'df020_v161_fixture', bundle: BUNDLE, startedAt: new Date().toISOString(), fixtures: [], failures: [] };
const check = (fixture, name, pass, data = {}) => {
  fixture.checks.push({ name, pass: Boolean(pass), ...data });
  if (!pass) evidence.failures.push(`${fixture.name}: ${name}`);
  console.log(`${pass ? 'PASS' : 'FAIL'}  [${fixture.name}] ${name}`);
};

evidence.mainDartJsSha256 = createHash('sha256').update(await readFile(join(BUNDLE, 'main.dart.js'))).digest('hex');
evidence.version = JSON.parse(await readFile(join(BUNDLE, 'version.json'), 'utf8'));
const { chromium } = await import(pathToFileURL(join(PLAYWRIGHT, 'node_modules', 'playwright', 'index.mjs')).href);
const server = await serveBundle(BUNDLE);
const browser = await chromium.launch({ headless: true, executablePath: BROWSER });
evidence.browserVersion = browser.version();

async function semantics(page) {
  await page.waitForSelector('flt-semantics-placeholder', { state: 'attached', timeout: 60000 });
  await delay(2000);
  await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
  await delay(1500);
  return page.evaluate(SEMANTICS);
}

try {
  for (const fixture of fixtures) {
    const record = { name: fixture.name, checks: [] };
    evidence.fixtures.push(record);
    const context = await browser.newContext({ viewport: { width: 1000, height: 1400 } });
    const page = await context.newPage();
    try {
      await page.goto(`${server.origin}/__seed-page-not-the-app`);
      await page.evaluate(SEED(fixture.document, fixture.position));
      await page.goto(`${server.origin}/`);
      const labels = await semantics(page);
      const text = labels.join('\n');
      record.semantics = labels;
      const continueShown = /Continue reading/.test(text);
      const identityShown = /alpha\.md|beta\.md|Title alpha|Title beta/.test(text);
      const recovery = /Remove unreadable saved data/.test(text);
      if (fixture.expect === 'recovery') {
        check(record, 'v1.6.1 shows generic recovery', recovery);
        check(record, 'no Continue reading', !continueShown);
        check(record, 'no document identity', !identityShown);
        await page.getByRole('button', { name: /Remove unreadable saved data/ }).first().click();
        await delay(1200);
        await page.getByRole('button', { name: /^Remove$/ }).first().click();
        await delay(900);
        const keys = await page.evaluate(KEYS);
        const after = (await page.evaluate(SEMANTICS)).join('\n');
        check(record, 'v1.6.1\'s own removal removes both content keys', !keys.includes('document') && !keys.includes('position'), { keys });
        check(record, 'the settings record stays', keys.includes('settings'), { keys });
        check(record, 'removal is reported', /Removed from this browser/.test(after));
      } else {
        check(record, 'v1.6.1 offers its own document as before', continueShown && identityShown && !recovery);
      }
      const keysNow = await page.evaluate(KEYS).catch(() => null);
      record.keysAtEnd = keysNow;
    } catch (error) {
      check(record, 'fixture ran to completion', false, { error: `${error.stack ?? error}` });
    } finally {
      await context.close();
    }
  }
} finally {
  await browser.close();
  await server.close();
}
evidence.passed = evidence.failures.length === 0;
evidence.automaticDeletion = 'none: content keys were removed only by the explicit Remove action';
await mkdir(dirname(OUT), { recursive: true });
await writeFile(OUT, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');
console.log(evidence.passed ? 'ALL PASSED' : `FAILURES: ${evidence.failures.length}`);
process.exitCode = evidence.passed ? 0 : 1;
