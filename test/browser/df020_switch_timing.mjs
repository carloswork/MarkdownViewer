// DF-020 V-17 runner: switch-to-first-frame against open-to-first-frame.
//
// Verification support, not product code. Nothing here is imported by `lib/`.
//
//   node test/browser/df020_switch_timing.mjs --browser <chrome.exe> \
//     --playwright <dir with node_modules/playwright> --bundle <timing bundle> \
//     --product <production bundle> --fixture test/browser/df039_fixtures/long.md \
//     --out <file.json>
//
// Chromium (installed Chrome, through Playwright over the DevTools protocol).
// Conditions: 1280x900 with F1 (the DF-041 1 MiB synthetic document) and F2
// (long.md), and 390x844 with F1. Each condition: 3 warm-up and 15 measured
// opens of the fixture (a new ID each time, closed afterwards), and 3 warm-up
// and 15 measured switches into it, alternating with a small document.
// A sample is the time from the session change being applied to the first
// frame after the incoming Reader's first build. Pass: in every condition the
// median switch is at most 1.2x the median open.

import { createHash } from 'node:crypto';
import os from 'node:os';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

import { serveBundle } from './df031_cdp.mjs';

function argument(name) {
  const index = process.argv.indexOf(`--${name}`);
  if (index === -1) throw new Error(`Missing --${name}`);
  return process.argv[index + 1];
}

const BROWSER = argument('browser');
const PLAYWRIGHT = argument('playwright');
const BUNDLE = resolve(argument('bundle'));
const PRODUCT = resolve(argument('product'));
const FIXTURE = resolve(argument('fixture'));
const OUT = resolve(argument('out'));

const WARMUP = 3;
const MEASURED = 15;
const sha256 = async (path) => createHash('sha256').update(await readFile(path)).digest('hex');
const stats = (values) => {
  const sorted = [...values].sort((a, b) => a - b);
  const at = (q) => sorted[Math.min(sorted.length - 1, Math.ceil(q * sorted.length) - 1)];
  return { n: sorted.length, median: at(0.5), p90: at(0.9), max: sorted[sorted.length - 1] };
};

const evidence = {
  harness: 'df020_switch_timing',
  startedAt: new Date().toISOString(),
  bundle: { path: BUNDLE, mainDartJsSha256: await sha256(join(BUNDLE, 'main.dart.js')) },
  product: { path: PRODUCT, mainDartJsSha256: await sha256(join(PRODUCT, 'main.dart.js')) },
  fixtureF2: { path: FIXTURE, sha256: await sha256(FIXTURE) },
  machine: {
    cpu: os.cpus()[0]?.model ?? 'unknown',
    logicalCores: os.cpus().length,
    memoryGiB: Math.round((os.totalmem() / 2 ** 30) * 10) / 10,
    platform: `${os.type()} ${os.release()} (${os.arch()})`,
    hostnameHash: createHash('sha256').update(os.hostname()).digest('hex').slice(0, 12),
    node: process.version,
  },
  sdk: 'Flutter 3.47.2 (C:\dev\flutter-3.47.2), Dart 3.13.2',
  conditions: [],
  failures: [],
};

// The timing code must be compiled out of the product build.
const productJs = await readFile(join(PRODUCT, 'main.dart.js'), 'utf8');
const timingJs = await readFile(join(BUNDLE, 'main.dart.js'), 'utf8');
evidence.markerAbsentFromProduct = !productJs.includes('df020-timing');
evidence.markerPresentInTimingBuild = timingJs.includes('df020-timing');
if (!evidence.markerAbsentFromProduct) evidence.failures.push('the product bundle contains the df020-timing marker');
if (!evidence.markerPresentInTimingBuild) evidence.failures.push('the timing build does not contain its marker');

const { chromium } = await import(pathToFileURL(join(PLAYWRIGHT, 'node_modules', 'playwright', 'index.mjs')).href);
const server = await serveBundle(BUNDLE);
const browser = await chromium.launch({ headless: true, executablePath: BROWSER });
evidence.browserVersion = browser.version();
const f2 = await readFile(FIXTURE, 'utf8');

async function measure(page, act) {
  const before = JSON.parse(await page.evaluate(() => window.df020Marks())).length;
  const id = await act();
  const start = Date.now();
  for (;;) {
    const marks = JSON.parse(await page.evaluate(() => window.df020Marks())).slice(before);
    const applied = marks.find((m) => m.phase === 'df020-timing:applied' && m.id === id);
    const shown = marks.find((m) => m.phase === 'df020-timing:shown' && m.id === id &&
      applied && m.t >= applied.t);
    if (applied && shown) return { id, ms: shown.t - applied.t };
    if (Date.now() - start > 60000) throw new Error(`no first frame for ${id}`);
    await new Promise((done) => setTimeout(done, 20));
  }
}

async function runCondition(name, viewport, fixture) {
  const context = await browser.newContext({ viewport });
  const page = await context.newPage();
  await page.goto(`${server.origin}/`);
  await page.waitForFunction(() => document.body?.dataset?.df020TimingReady === 'true', null, { timeout: 90000 });
  const openFixture = () => fixture === 'F1'
    ? page.evaluate(() => window.df020OpenStress())
    : page.evaluate((text) => window.df020Open('f2.md', text), f2);
  const small = await page.evaluate(() => window.df020Open('small.md', '# Small\n\nA short document.'));
  await page.waitForTimeout(500);

  const opens = [];
  for (let i = 0; i < WARMUP + MEASURED; i++) {
    const { id, ms } = await measure(page, openFixture);
    if (i >= WARMUP) opens.push(ms);
    await page.evaluate((x) => window.df020Close(x), id);
    await page.waitForTimeout(150);
  }

  const fixtureId = await measure(page, openFixture).then((r) => r.id);
  const switches = [];
  for (let i = 0; i < WARMUP + MEASURED; i++) {
    await measure(page, async () => { await page.evaluate((x) => window.df020Activate(x), small); return small; });
    const { ms } = await measure(page, async () => {
      await page.evaluate((x) => window.df020Activate(x), fixtureId);
      return fixtureId;
    });
    if (i >= WARMUP) switches.push(ms);
  }
  await context.close();

  const open = stats(opens);
  const sw = stats(switches);
  const ratio = sw.median / open.median;
  const pass = ratio <= 1.2;
  const over2x = switches.filter((s) => s > 2 * open.median);
  const result = { name, viewport, fixture, open, switch: sw, ratio, pass, switchesOver2xMedianOpen: over2x, opens, switches };
  evidence.conditions.push(result);
  if (!pass) evidence.failures.push(`${name}: median switch ${sw.median.toFixed(1)} ms > 1.2 x median open ${open.median.toFixed(1)} ms`);
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${name}: open median ${open.median.toFixed(1)} ms, switch median ${sw.median.toFixed(1)} ms, ratio ${ratio.toFixed(3)}`);
}

try {
  await runCondition('wide F1', { width: 1280, height: 900 }, 'F1');
  await runCondition('wide F2', { width: 1280, height: 900 }, 'F2');
  await runCondition('narrow F1', { width: 390, height: 844 }, 'F1');
} catch (error) {
  evidence.failures.push(`run: ${error.stack ?? error}`);
} finally {
  await browser.close();
  await server.close();
}
evidence.passed = evidence.failures.length === 0;
await mkdir(dirname(OUT), { recursive: true });
await writeFile(OUT, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');
console.log(evidence.passed ? 'ALL PASSED' : `FAILURES: ${evidence.failures.join('; ')}`);
process.exitCode = evidence.passed ? 0 : 1;
