// Paired local-bundle browser check of where the Reader stands after Search
// closes.
//
// The same script runs unchanged against a baseline and a candidate bundle
// served locally from build/web by the repository's own static server; only
// the bundle directory differs. It never targets production.
//
//   node test/browser/df063_cp3_chromium.mjs <browserPath> <bundleDir> <route> <out.json> <fixture.md>
//
// Routes: W1 W2 W3 W4 W5 N1 N2 N3, optionally suffixed -R (Keep for next time
// on first) or -HOME (after close: Return to main -> Continue reading).
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { launchChromium, delay, serveBundle, waitForValue } from './df031_cdp.mjs';

const [browserPath, bundleDir, route, outputPath, fixturePath] = process.argv.slice(2);
const server = await serveBundle(bundleDir);
const url = `${server.origin}/`;
const base = route.replace(/-(R|HOME)$/, '');
const retained = route.endsWith('-R');
const home = route.endsWith('-HOME');
const narrow = base.startsWith('N');
const result = {
  harness: 'df063_cp3_chromium', bundleDir, url, route, fixturePath,
  bundleMainSha256: createHash('sha256').update(await readFile(join(bundleDir, 'main.dart.js'))).digest('hex'),
  startedAt: new Date().toISOString(), steps: [],
};
const browser = await launchChromium(browserPath, { windowSize: '1280,900' });
const session = browser.session;
let chooser = null;
session.on('Page.fileChooserOpened', (value) => { chooser = value; });

const nodes = () => session.evaluate(`
  return [...document.querySelectorAll('flt-semantics')].map(n => {
    const r = n.getBoundingClientRect();
    return { role: n.getAttribute('role'), label: n.getAttribute('aria-label'), text: n.textContent || '',
      x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) };
  });
`);
const line = (n) => (n.label || n.text || '').split('\n')[0].trim();
const smallest = (ns) => ns.sort((a, b) => a.w * a.h - b.w * b.h)[0] ?? null;
async function find(predicate) {
  return smallest((await nodes()).filter((n) => n.w > 0 && n.h > 0 && predicate(n)));
}
async function click(n) {
  const x = n.x + n.w / 2, y = n.y + n.h / 2;
  await session.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y, button: 'none', buttons: 0 });
  await session.send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1 });
  await delay(60);
  await session.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', buttons: 0, clickCount: 1 });
  await delay(450);
}
const exact = (text) => waitForValue(() => find((n) => line(n) === text), `exact ${text}`, 10000);
const viewportSize = () => session.evaluate('return {w: innerWidth, h: innerHeight};');

async function storedPosition() {
  return session.evaluate(`
    const dbs = await indexedDB.databases(); if (!dbs.some(d => d.name === 'markdown_viewer')) return {db: false};
    const db = await new Promise((resolve, reject) => { const r = indexedDB.open('markdown_viewer'); r.onsuccess = () => resolve(r.result); r.onerror = () => reject(r.error); });
    const name = db.objectStoreNames[0];
    const os = db.transaction(name, 'readonly').objectStore(name);
    const read = k => new Promise((resolve, reject) => { const r = os.get(k); r.onsuccess = () => resolve(r.result ?? null); r.onerror = () => reject(r.error); });
    const raw = await read('position'); db.close();
    let value = null; try { value = raw == null ? null : JSON.parse(raw); } catch { value = {decode: 'failed'}; }
    return {db: true, position: value};
  `);
}

// Section markers in the viewport. The size filter excludes large ancestors but
// not Search pane result rows, so while the pane is open a pane row can add a
// marker to the pre-close set; the verdicts are unaffected because the pane is
// gone after close and a kept marker must then come from the Reader.
async function snapshot(label) {
  const all = await nodes();
  const viewport = await viewportSize();
  const markers = all
    .filter((n) => /SECTION-\d\d-(?:START|END)/.test(n.text) && n.y >= 0 && n.y < viewport.h &&
      n.x >= 0 && n.x < viewport.w && n.w < viewport.w * 0.95 && n.h < 150)
    .map((n) => ({ marker: n.text.match(/SECTION-\d\d-(?:START|END)/)[0], x: n.x, y: n.y }));
  const ui = await session.evaluate(`return {panes: document.querySelectorAll('[aria-label="Close search"]').length};`);
  const item = { label, at: new Date().toISOString(), viewport, ui, markers, storage: await storedPosition() };
  result.steps.push(item);
  process.stdout.write(JSON.stringify({ label, markers: markers.map((m) => m.marker), pos: item.storage.position?.blockIndex }) + '\n');
}
async function wheel(deltaY) {
  const viewport = await viewportSize();
  await session.send('Input.dispatchMouseEvent', { type: 'mouseWheel', x: viewport.w * 0.75, y: viewport.h * 0.55, deltaX: 0, deltaY });
  await delay(900);
}
async function openMenu() {
  const viewport = await viewportSize();
  for (let attempt = 0; attempt < 4; attempt++) {
    const button = await find((n) => n.role === 'button' && !n.label && n.x + n.w > viewport.w - 110 && n.y + n.h > viewport.h - 110);
    if (button) { await click(button); return attempt; }
    await wheel(-180);
  }
  throw new Error('Reader menu unavailable after upward reveal');
}
async function openSearch() { await openMenu(); await click(await exact('Search document')); await delay(650); }
async function key(keyName, code, vk, modifiers = 0) {
  for (const type of ['keyDown', 'keyUp']) {
    await session.send('Input.dispatchKeyEvent', { type, key: keyName, code, modifiers, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk });
  }
}
async function searchInput() {
  return waitForValue(() => session.evaluate(`
    const n = document.querySelector('input'); if (!n) return null; const r = n.getBoundingClientRect();
    return r.width && r.height ? {x: r.x, y: r.y, w: r.width, h: r.height} : null;
  `), 'Search field', 10000);
}
async function setQuery(text) { await click(await searchInput()); await session.send('Input.insertText', { text }); await delay(900); }
async function clearQuery() { await click(await searchInput()); await key('a', 'KeyA', 65, 2); await key('Backspace', 'Backspace', 8); await delay(900); }
async function selectResult() {
  await click(await waitForValue(() => find((n) => /^Result 1 of \d+\./.test(n.label || '')), 'result row', 10000));
  await delay(900);
}
async function closeSearch() {
  if (base === 'W2') { await key('Escape', 'Escape', 27); await delay(800); return; }
  await click(await exact('Close search'));
  await delay(900);
}

try {
  await session.send('Runtime.enable'); await session.send('Page.enable'); await session.send('DOM.enable');
  await session.send('Page.setInterceptFileChooserDialog', { enabled: true });
  result.browserVersion = await session.send('Browser.getVersion');
  result.fixtureSha256 = createHash('sha256').update(await readFile(fixturePath)).digest('hex').toUpperCase();
  await session.send('Page.navigate', { url });
  // A locally served bundle can take tens of seconds to start. Readiness is a
  // condition, not a delay: keep enabling semantics until Home is exposed.
  await waitForValue(async () => {
    await session.evaluate("const p = document.querySelector('flt-semantics-placeholder'); if (p) p.click(); return true;");
    return find((n) => line(n) === 'Load from file');
  }, 'Home exposed through semantics', 90000);
  await delay(900);
  result.servedVersion = await session.evaluate(`return await (await fetch('version.json', {cache: 'no-store'})).json();`);
  if (retained) {
    await click(await exact('Settings')); await delay(650);
    const toggle = await find((n) => n.role === 'switch' && /Keep for next time/.test(n.label || n.text));
    if (!toggle) throw new Error('Keep for next time switch not found');
    await click(toggle); await delay(1000);
    await click(await exact('Back')); await delay(550);
  }
  await click(await exact('Load from file'));
  await waitForValue(() => chooser, 'file chooser', 10000);
  await session.send('DOM.setFileInputFiles', { files: [fixturePath], backendNodeId: chooser.backendNodeId });
  await delay(1500);
  const replace = await find((n) => line(n) === 'Replace'); if (replace) await click(replace);
  await delay(1400);
  await snapshot('reader-loaded');
  if (narrow) {
    await session.send('Emulation.setDeviceMetricsOverride', { width: 800, height: 800, deviceScaleFactor: 1, mobile: false });
    await delay(1100);
  }

  await openSearch();
  if (base === 'N2') {
    await click(await exact('Close results')); await delay(700);
    await wheel(950);
  } else if (base === 'W5') {
    await wheel(950);
  } else {
    await setQuery('SECTION-18-START');
    await selectResult();
    await snapshot('result-selected');
    if (base === 'W3') await clearQuery();
    if (base === 'W4' || base === 'N3') await wheel(900);
  }
  await snapshot('before-close');
  await closeSearch();
  await delay(700); // past the 500 ms position debounce
  await snapshot('after-close');
  if (home) {
    result.menuRevealWheels = await openMenu();
    await click(await exact('Return to main')); await delay(900);
    await click(await exact('Continue reading')); await delay(1400);
    await snapshot('after-continue-reading');
  }
  result.completed = true;
} catch (error) {
  result.completed = false; result.error = String(error?.stack || error); process.stderr.write(result.error + '\n');
} finally {
  result.finishedAt = new Date().toISOString();
  await writeFile(outputPath, JSON.stringify(result, null, 2) + '\n');
  await browser.close();
  await server.close();
}
if (!result.completed) process.exitCode = 1;
