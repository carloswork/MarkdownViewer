// DF-085 Reader-mode G-1′: a Human-operated Explorer-origin two-file drag onto
// the Reader, in Chrome, Edge and Firefox, on the release build.
//
// Verification support, not product code. Nothing here is imported by `lib/`.
//
//   node test/browser/df085_reader_g1.mjs --playwright <dir> --bundle <release bundle>
//     --fixtures <empty folder> --out <evidence dir> [--browsers chrome,edge,firefox]
//     (--dry-run | --human [--wait-seconds N])
//
// For each browser: launch it HEADED with a passive drop recorder (a
// capture-phase listener that only reads the event). Seed `Keep for next
// time` ON with one saved document, r-base.md, open the app and choose
// Continue reading, so the Reader is showing at root. The pre-state is
// asserted and recorded BEFORE the window is declared ready. Then
// df020_g1_explorer.ps1 runs in -DryRun mode only: it places a File Explorer
// window on the fixtures beside the browser and records both windows'
// identities. It selects nothing and sends no input.
//
//   --dry-run  stops there: a rehearsal of the setup. No drag is expected.
//   --human    waits for the Human to drag r-zeta.md and r-Alpha.md from
//              Explorer onto the Reader, then records the received drop, the
//              saved set, the tabs, the URL and screenshots.
//
// Automated checks 1-5 are recorded as PASS or FAIL. The Human attestations
// A1 (Explorer is the source) and A2 (the gesture was the Human's own, through
// the native interaction path) cannot be observed by the browser: they are
// recorded as pending Human attestation, never as PASS.
//
// Playwright drives the browser only to open the page, choose Continue
// reading and read state. It never dispatches a drag. Requires an unlocked,
// interactive desktop; windows are moved.

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
if (DRY === HUMAN) throw new Error('Choose exactly one of --dry-run or --human');
const WAIT_MS = Number(argument('wait-seconds', '600')) * 1000;
const INJECTOR = resolve('test/browser/df020_g1_explorer.ps1');

const sha = (bytes) => createHash('sha256').update(bytes).digest('hex');

// The two dropped fixtures, offered in reverse filename order: D-2 order is
// r-Alpha.md, r-zeta.md (case-insensitive), and r-Alpha.md sorts before the
// already-open r-base.md, so an append can be told from a global sort.
const FIXTURE_FILES = {
  'r-zeta.md': '# R Zeta\n\nThe second dropped fixture, by D-2 order.\n',
  'r-Alpha.md': '# R Alpha\n\nThe first dropped fixture, by D-2 order.\n',
};
const ORDER = 'r-zeta.md,r-Alpha.md';
await mkdir(FIXTURES, { recursive: true });
for (const [name, text] of Object.entries(FIXTURE_FILES)) await writeFile(join(FIXTURES, name), text);

// The already-open document, saved in the current retained format.
const BASE_ID = 'df085-base';
const BASE_SOURCE = '# R Base\n\nThe document already open in the Reader.\n';
const SAVED_AT = '2026-11-22T00:00:00.000Z';
const SEED = {
  settings: JSON.stringify({ appearance: 'system', fontScale: 1.0, wrapCode: false, keepForNextTime: true }),
  document: JSON.stringify(['saudo-document-set', 2, {
    documents: [{
      id: BASE_ID, title: 'R Base', source: BASE_SOURCE, createdAt: SAVED_AT, updatedAt: SAVED_AT,
      sourceName: 'r-base.md', origin: 'file', scriptPreference: 'auto',
    }],
  }]),
  position: JSON.stringify(['saudo-reading-state', 2, { activeId: BASE_ID, positions: {} }]),
};

const evidence = {
  harness: 'df085_reader_g1',
  evidenceClass: HUMAN ? 'Human-operated Explorer-origin native drag onto the Reader (Reader-mode G-1′)' : 'dry run: setup rehearsal only; no drag',
  startedAt: new Date().toISOString(),
  dryRun: DRY,
  human: HUMAN,
  bundle: { path: BUNDLE, mainDartJsSha256: sha(await readFile(join(BUNDLE, 'main.dart.js'))) },
  injector: { path: INJECTOR, sha256: sha(await readFile(INJECTOR)), mode: '-DryRun (window arrangement only; no input)' },
  runner: { sha256: sha(await readFile(resolve('test/browser/df085_reader_g1.mjs'))) },
  fixtures: Object.fromEntries(Object.entries(FIXTURE_FILES).map(([n, t]) => [n, sha(Buffer.from(t))])),
  deliveryStatement: 'The harness sent no input, no DevTools-protocol drag (Input.dispatchDragEvent) and no script-built DataTransfer. Any drop was made by the Human with the physical mouse.',
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

const readStored = () => (async () => {
  const db = await new Promise((done) => { const r = indexedDB.open('markdown_viewer'); r.onsuccess = () => done(r.result); });
  const read = (key) => new Promise((done) => { const r = db.transaction('box').objectStore('box').get(key); r.onsuccess = () => done(r.result ?? null); });
  const v = { document: await read('document'), position: await read('position') };
  db.close();
  return v;
})();
const decode = (stored) => {
  const set = stored.document ? JSON.parse(stored.document)[2].documents : [];
  const active = stored.position ? JSON.parse(stored.position)[2].activeId : null;
  return { names: set.map((d) => d.sourceName), ids: set.map((d) => d.id), sources: set.map((d) => d.source), activeId: active };
};
const semanticsText = () => [...document.querySelectorAll('flt-semantics')]
  .map((n) => [n.getAttribute('aria-label'), n.textContent].filter(Boolean).join(' | ')).join('\n');

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
      type: e.type, t: Date.now(), isTrusted: e.isTrusted, href: location.href,
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
    await page.evaluate(async (seed) => {
      const db = await new Promise((done, fail) => {
        const r = indexedDB.open('markdown_viewer', 1);
        r.onupgradeneeded = () => r.result.createObjectStore('box');
        r.onsuccess = () => done(r.result); r.onerror = () => fail(r.error);
      });
      await new Promise((done) => {
        const tx = db.transaction('box', 'readwrite');
        for (const [key, value] of Object.entries(seed)) tx.objectStore('box').put(value, key);
        tx.oncomplete = done;
      });
      db.close();
    }, SEED);
    await page.goto(`${server.origin}/`);
    await page.waitForSelector('flt-semantics-placeholder', { state: 'attached', timeout: 90000 });
    await delay(2000);
    await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
    await delay(1200);
    const resume = page.getByRole('button', { name: 'Continue reading', exact: true }).first();
    await resume.waitFor({ state: 'attached', timeout: 15000 });
    await resume.click({ force: true });
    await delay(1800);

    // Pre-state, asserted before the window is declared ready.
    const before = decode(await page.evaluate(readStored));
    const shownBefore = await page.evaluate(semanticsText);
    record.preState = { stored: before, href: await page.evaluate(() => location.href) };
    check('pre-state: the Reader is at root with r-base.md open and active, nothing above it',
      !/Continue reading/.test(shownBefore) && /R Base/.test(shownBefore) &&
        JSON.stringify(before.names) === '["r-base.md"]' && before.activeId === BASE_ID &&
        !(await page.evaluate(() => window.__g1.some((e) => e.type === 'drop'))),
      { stored: before });
    const title = await page.title();
    record.pageTitle = title;

    const log = join(OUT, `reader-g1-${name}-arrangement.json`);
    const run = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', INJECTOR,
      '-Folder', FIXTURES, '-Order', ORDER, '-TargetProcess', PROCESS[name],
      '-TargetTitle', title, '-Log', log, '-Screenshot', '', '-DryRun'], { encoding: 'utf8', timeout: 120000 });
    record.arrangementExit = run.status;
    record.arrangementStdout = run.stdout?.split(/\r?\n/).filter(Boolean).slice(-30);
    if (run.stderr?.trim()) record.arrangementStderr = run.stderr.trim().slice(0, 2000);
    const steps = JSON.parse((await readFile(log, 'utf8')).replace(/^\uFEFF/, ''));
    record.arrangement = steps;
    const windows = steps.find((s) => s.step === 'windows');
    check('the window arrangement ran without error (no input sent)', run.status === 0 && !steps.some((s) => s.step === 'error'), { exit: run.status });
    if (DRY) {
      check('dry run: no drop was received', !(await page.evaluate(() => window.__g1.some((e) => e.type === 'drop'))));
      continue;
    }

    record.readyAt = Date.now();
    console.log(`READY [${name}] drag r-zeta.md and r-Alpha.md together from Explorer onto the document in the browser (waiting up to ${WAIT_MS / 1000} s)`);
    const deadline = Date.now() + WAIT_MS;
    while (Date.now() < deadline && !(await page.evaluate(() => window.__g1.some((e) => e.type === 'drop')))) await delay(500);
    record.dropWaitEndedAt = Date.now();
    await delay(3000);
    const shot = join(OUT, `reader-g1-${name}-desktop.png`);
    const shotScript = `Add-Type -AssemblyName System.Drawing; Add-Type -Name P -Namespace W -MemberDefinition '[DllImport("user32.dll")] public static extern System.IntPtr SetProcessDpiAwarenessContext(System.IntPtr v); [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);'; [void][W.P]::SetProcessDpiAwarenessContext([IntPtr](-4)); $x=[W.P]::GetSystemMetrics(76); $y=[W.P]::GetSystemMetrics(77); $w=[W.P]::GetSystemMetrics(78); $h=[W.P]::GetSystemMetrics(79); $b=New-Object System.Drawing.Bitmap $w,$h; $g=[System.Drawing.Graphics]::FromImage($b); $g.CopyFromScreen($x,$y,0,0,$b.Size); $b.Save('${shot.replace(/'/g, "''")}',[System.Drawing.Imaging.ImageFormat]::Png)`;
    spawnSync('powershell.exe', ['-NoProfile', '-Command', shotScript], { encoding: 'utf8', timeout: 60000 });

    const events = await page.evaluate(() => window.__g1);
    record.events = events;
    const drops = events.filter((e) => e.type === 'drop');
    record.attestations = [
      { item: 'A1. Explorer is the drag source', status: 'pending Human attestation', explorerWindow: windows?.source },
      { item: 'A2. the gesture was the Human\'s own, through the native interaction path', status: 'pending Human attestation' },
    ];
    check('1. one native drop, trusted, after ready, while the Reader was showing (pre-state above)',
      drops.length === 1 && drops[0].isTrusted && drops[0].types.includes('Files') && drops[0].t >= record.readyAt,
      { drops, dropAfterReadyMs: drops[0] ? drops[0].t - record.readyAt : null });
    const received = drops[0]?.files.map((f) => f.name).sort() ?? [];
    check('2. two files were delivered, and only files',
      JSON.stringify(received) === '["r-Alpha.md","r-zeta.md"]' && drops[0]?.items.every((k) => k === 'file'),
      { received, items: drops[0]?.items });

    const after = decode(await page.evaluate(readStored));
    record.stored = after;
    check('3. saved set: r-base.md, then r-Alpha.md, r-zeta.md (appended in D-2 order)',
      JSON.stringify(after.names) === '["r-base.md","r-Alpha.md","r-zeta.md"]' && after.ids[0] === BASE_ID, { stored: after });
    check('3b. the contents are the fixtures, byte for byte',
      after.sources[0] === BASE_SOURCE && after.sources[1] === FIXTURE_FILES['r-Alpha.md'] && after.sources[2] === FIXTURE_FILES['r-zeta.md']);
    const tabs = await page.evaluate(() => [...document.querySelectorAll('flt-semantics[role="tab"]')]
      .map((n) => ({ label: n.getAttribute('aria-label'), selected: n.getAttribute('aria-selected') })));
    record.tabs = tabs;
    check('4. r-Alpha.md is active and selected in the tab bar',
      after.activeId === after.ids[1] && tabs.length === 3 && tabs.find((t) => t.selected === 'true')?.label === 'r-Alpha.md', { tabs });
    const href = await page.evaluate(() => location.href);
    check('5. the URL is unchanged', href === record.preState.href && drops[0]?.href === record.preState.href, { before: record.preState.href, after: href });
    await page.screenshot({ path: join(OUT, `reader-g1-${name}-page.png`) });
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
await writeFile(join(OUT, DRY ? 'reader-g1-dry-run.json' : 'reader-g1-evidence.json'), `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');
console.log(evidence.passed ? 'ALL PASSED' : `FAILURES: ${evidence.failures.join('; ')}`);
process.exitCode = evidence.passed ? 0 : 1;
