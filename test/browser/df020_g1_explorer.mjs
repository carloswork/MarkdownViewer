// DF-020 G-1 (Method 1): OS-injected Explorer-origin multi-file drag into
// Chrome, Edge and Firefox, on the integration build.
//
// Verification support, not product code. Nothing here is imported by `lib/`.
//
//   node test/browser/df020_g1_explorer.mjs --playwright <dir> --bundle <release bundle>
//     --fixtures <empty folder> --out <evidence dir> [--browsers chrome,edge,firefox]
//     [--dry-run | --human [--wait-seconds N]]
//
// --human (G-1′): the same capture, but the Human performs the drag. The injector
// runs only in -DryRun mode, to place the Explorer and browser windows side by side
// and record their identities; no input is sent. The runner then waits for the
// Human's drop and records it exactly as for Method 1. Criteria 1 and 2 (Explorer
// is the source; the gesture began on the Explorer items) cannot be observed by
// the browser and are recorded as pending Human attestation, never as PASS.
//
// For each browser: launch it HEADED with `Keep for next time` ON and a passive
// drop recorder (a capture-phase listener that only reads the event), open the
// app on Home, then run df020_g1_explorer.ps1. That script selects the three
// fixtures in a real File Explorer window in reversed order and performs ONE
// OS-injected mouse drag (user32 SendInput) onto the browser window. Afterwards
// this runner records the received drop (time, isTrusted, files, item kinds),
// the app's saved set (names and contents, from IndexedDB), the tab state and
// screenshots, and correlates the drop with the injected gesture's timestamps.
//
// Playwright drives the browser only to open the page and read state. It never
// dispatches a drag: no `Input.dispatchDragEvent`, no script-built DataTransfer.
// Requires an unlocked, interactive desktop; the real cursor moves.

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
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
const PLAYWRIGHT = argument('playwright');
const BUNDLE = resolve(argument('bundle'));
const FIXTURES = resolve(argument('fixtures'));
const OUT = resolve(argument('out'));
const BROWSERS = argument('browsers', 'chrome,edge,firefox').split(',');
const DRY = process.argv.includes('--dry-run');
const HUMAN = process.argv.includes('--human');
const WAIT_MS = Number(argument('wait-seconds', '600')) * 1000;
const INJECTOR = resolve('test/browser/df020_g1_explorer.ps1');

const sha = (bytes) => createHash('sha256').update(bytes).digest('hex');
const FIXTURE_FILES = {
  'g1-A.md': '# G1 Alpha\n\nThe first fixture, by D-2 order.\n',
  'g1-b.md': '# G1 Bravo\n\nThe second fixture.\n',
  'g1-c.md': '# G1 Charlie\n\nThe third fixture.\n',
};
await mkdir(FIXTURES, { recursive: true });
for (const [name, text] of Object.entries(FIXTURE_FILES)) await writeFile(join(FIXTURES, name), text);

const SETTINGS_ON = JSON.stringify({ appearance: 'system', fontScale: 1.0, wrapCode: false, keepForNextTime: true });
const evidence = {
  harness: 'df020_g1_explorer',
  evidenceClass: HUMAN ? 'Human-operated Explorer-origin native drag (G-1′)' : 'OS-injected Explorer-origin native drag (T-3); not Human-operated',
  startedAt: new Date().toISOString(),
  dryRun: DRY,
  human: HUMAN,
  bundle: { path: BUNDLE, mainDartJsSha256: sha(await readFile(join(BUNDLE, 'main.dart.js'))) },
  injector: { path: INJECTOR, sha256: sha(await readFile(INJECTOR)) },
  runner: { sha256: sha(await readFile(resolve('test/browser/df020_g1_explorer.mjs'))) },
  fixtures: Object.fromEntries(Object.entries(FIXTURE_FILES).map(([n, t]) => [n, sha(Buffer.from(t))])),
  deliveryStatement: HUMAN
    ? 'The drag was performed by the Human with the physical mouse from a File Explorer window; the harness sent no input, no DevTools-protocol drag (Input.dispatchDragEvent) and no script-built DataTransfer.'
    : 'The drag was performed by OS-injected mouse input from a File Explorer item; no DevTools-protocol drag (Input.dispatchDragEvent) and no script-built DataTransfer was used.',
  browsers: [],
  failures: [],
};

const pw = await import(pathToFileURL(join(PLAYWRIGHT, 'node_modules', 'playwright', 'index.mjs')).href);
const server = await serveBundle(BUNDLE);

const LAUNCH = {
  chrome: () => pw.chromium.launch({ headless: false, executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe' }),
  edge: () => pw.chromium.launch({ headless: false, executablePath: 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' }),
  firefox: () => pw.firefox.launch({ headless: false, channel: 'moz-firefox', executablePath: 'C:/Program Files/Mozilla Firefox/firefox.exe' }),
};
const PROCESS = { chrome: 'chrome', edge: 'msedge', firefox: 'firefox' };

for (const name of BROWSERS) {
  const record = { browser: name, checks: [] };
  evidence.browsers.push(record);
  const check = (label, pass, data = {}) => {
    record.checks.push({ name: label, pass: Boolean(pass), ...data });
    if (!pass) evidence.failures.push(`${name}: ${label}`);
    console.log(`${pass ? 'PASS' : 'FAIL'}  [${name}] ${label}`);
  };
  const browser = await LAUNCH[name]();
  record.version = browser.version();
  const context = await browser.newContext({ viewport: null });
  await context.addInitScript(() => {
    window.__g1 = [];
    const note = (e) => window.__g1.push({
      type: e.type, t: Date.now(), isTrusted: e.isTrusted,
      files: e.dataTransfer ? [...e.dataTransfer.files].map((f) => ({ name: f.name, size: f.size })) : [],
      items: e.dataTransfer ? [...e.dataTransfer.items].map((i) => i.kind) : [],
      types: e.dataTransfer ? [...e.dataTransfer.types] : [],
    });
    window.addEventListener('drop', note, true);
    window.addEventListener('dragenter', (e) => { if (!window.__g1.some((x) => x.type === 'dragenter')) note(e); }, true);
  });
  const page = await context.newPage();
  try {
    await page.goto(`${server.origin}/__seed-page-not-the-app`);
    await page.evaluate(async (settings) => {
      const db = await new Promise((done, fail) => {
        const r = indexedDB.open('markdown_viewer', 1);
        r.onupgradeneeded = () => r.result.createObjectStore('box');
        r.onsuccess = () => done(r.result); r.onerror = () => fail(r.error);
      });
      await new Promise((done) => { const tx = db.transaction('box', 'readwrite'); tx.objectStore('box').put(settings, 'settings'); tx.oncomplete = done; });
      db.close();
    }, SETTINGS_ON);
    await page.goto(`${server.origin}/`);
    await page.waitForSelector('flt-semantics-placeholder', { state: 'attached', timeout: 90000 });
    await delay(2000);
    const title = await page.title();
    record.pageTitle = title;

    const log = join(OUT, `g1-${name}-injector.json`);
    const shot = join(OUT, `g1-${name}-desktop.png`);
    const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', INJECTOR,
      '-Folder', FIXTURES, '-Order', 'g1-c.md,g1-b.md,g1-A.md', '-TargetProcess', PROCESS[name],
      '-TargetTitle', title, '-Log', log, '-Screenshot', DRY ? '' : shot];
    if (DRY || HUMAN) args.push('-DryRun');
    const run = spawnSync('powershell.exe', args, { encoding: 'utf8', timeout: 120000 });
    record.injectorExit = run.status;
    record.injectorStdout = run.stdout?.split(/\r?\n/).filter(Boolean).slice(-30);
    if (run.stderr?.trim()) record.injectorStderr = run.stderr.trim().slice(0, 2000);
    const steps = JSON.parse((await readFile(log, 'utf8')).replace(/^\uFEFF/, ''));
    record.injector = steps;
    check(HUMAN ? 'the window arrangement ran without error (no input sent)' : 'the injector ran without error', run.status === 0 && !steps.some((s) => s.step === 'error'), { exit: run.status });
    if (DRY) continue;

    if (HUMAN) {
      record.readyAt = Date.now();
      console.log(`READY [${name}] drag the three files from Explorer onto the browser window (waiting up to ${WAIT_MS / 1000} s)`);
      const deadline = Date.now() + WAIT_MS;
      while (Date.now() < deadline && !(await page.evaluate(() => window.__g1.some((e) => e.type === 'drop')))) await delay(500);
      record.dropWaitEndedAt = Date.now();
    }
    await delay(3000);
    if (HUMAN) {
      const shotScript = `Add-Type -AssemblyName System.Drawing; Add-Type -Name P -Namespace W -MemberDefinition '[DllImport("user32.dll")] public static extern System.IntPtr SetProcessDpiAwarenessContext(System.IntPtr v); [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);'; [void][W.P]::SetProcessDpiAwarenessContext([IntPtr](-4)); $x=[W.P]::GetSystemMetrics(76); $y=[W.P]::GetSystemMetrics(77); $w=[W.P]::GetSystemMetrics(78); $h=[W.P]::GetSystemMetrics(79); $b=New-Object System.Drawing.Bitmap $w,$h; $g=[System.Drawing.Graphics]::FromImage($b); $g.CopyFromScreen($x,$y,0,0,$b.Size); $b.Save('${shot.replace(/'/g, "''")}',[System.Drawing.Imaging.ImageFormat]::Png)`;
      spawnSync('powershell.exe', ['-NoProfile', '-Command', shotScript], { encoding: 'utf8', timeout: 60000 });
    }
    const events = await page.evaluate(() => window.__g1);
    record.events = events;
    const drops = events.filter((e) => e.type === 'drop');
    const leftUp = steps.find((s) => s.step === 'left-up (drop)')?.t;
    const leftDown = steps.find((s) => s.step === 'left-down')?.t;
    const windows = steps.find((s) => s.step === 'windows');
    record.correlation = { leftDown, leftUp, drop: drops[0]?.t, dropMinusLeftUpMs: drops[0] && leftUp ? drops[0].t - leftUp : null };
    if (HUMAN) {
      record.correlation = { readyAt: record.readyAt, drop: drops[0]?.t, dropAfterReadyMs: drops[0] ? drops[0].t - record.readyAt : null };
      record.attestations = [
        { criterion: '1. Explorer is the drag source', status: 'pending Human attestation', explorerWindow: windows?.source },
        { criterion: '2. the gesture began on the Explorer items, by the Human', status: 'pending Human attestation' },
      ];
      check('3. the browser received one native drop, trusted, after the window was ready',
        drops.length === 1 && drops[0].isTrusted && drops[0].types.includes('Files') && drops[0].t >= record.readyAt, { drops, correlation: record.correlation });
    } else {
    check('1. Explorer is the drag source (UIA: CabinetWClass, explorer.exe)',
      windows?.source?.class === 'CabinetWClass' && windows?.source?.process === 'explorer', { source: windows?.source });
    check('2. the gesture began on the Explorer items, via injected OS input',
      steps.some((s) => s.step === 'selection-verified') && Boolean(leftDown) && steps.some((s) => s.step === 'mouse-at-source'));
    check('3. the browser received one native drop, trusted, after the injected release',
      drops.length === 1 && drops[0].isTrusted && drops[0].types.includes('Files') &&
        record.correlation.dropMinusLeftUpMs !== null && Math.abs(record.correlation.dropMinusLeftUpMs) < 3000, { drops, correlation: record.correlation });
    }
    const received = drops[0]?.files.map((f) => f.name).sort() ?? [];
    check('4. three files were delivered, and only files', JSON.stringify(received) === '["g1-A.md","g1-b.md","g1-c.md"]' && drops[0]?.items.every((k) => k === 'file'), { received, items: drops[0]?.items });

    const stored = await page.evaluate(async () => {
      const db = await new Promise((done) => { const r = indexedDB.open('markdown_viewer'); r.onsuccess = () => done(r.result); });
      const read = (key) => new Promise((done) => { const r = db.transaction('box').objectStore('box').get(key); r.onsuccess = () => done(r.result ?? null); });
      const v = { document: await read('document'), position: await read('position') };
      db.close();
      return v;
    });
    const set = stored.document ? JSON.parse(stored.document)[2].documents : [];
    const active = stored.position ? JSON.parse(stored.position)[2].activeId : null;
    record.stored = { names: set.map((d) => d.sourceName), activeId: active, ids: set.map((d) => d.id) };
    check('5a. loaded in D-2 order g1-A.md, g1-b.md, g1-c.md', JSON.stringify(record.stored.names) === '["g1-A.md","g1-b.md","g1-c.md"]', { stored: record.stored });
    check('5b. the first in D-2 order is active', active === set[0]?.id);
    check('5c. the contents are the fixtures, byte for byte', set.length === 3 && set.every((d) => d.source === FIXTURE_FILES[d.sourceName]));
    await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
    await delay(1200);
    const tabs = await page.evaluate(() => [...document.querySelectorAll('flt-semantics[role="tab"]')].map((n) => ({ label: n.getAttribute('aria-label'), selected: n.getAttribute('aria-selected') })));
    record.tabs = tabs;
    check('5d. three tabs, g1-A.md selected', tabs.length === 3 && tabs.find((t) => t.selected === 'true')?.label === 'g1-A.md', { tabs });
    await page.screenshot({ path: join(OUT, `g1-${name}-page.png`) });
  } catch (error) {
    check('the run completed', false, { error: `${error.stack ?? error}` });
  } finally {
    await context.close();
    await browser.close();
  }
}
await server.close();
evidence.passed = evidence.failures.length === 0;
await mkdir(OUT, { recursive: true });
await writeFile(join(OUT, 'g1-evidence.json'), `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');
console.log(evidence.passed ? 'ALL PASSED' : `FAILURES: ${evidence.failures.join('; ')}`);
process.exitCode = evidence.passed ? 0 : 1;
