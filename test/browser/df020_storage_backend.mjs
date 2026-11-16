// DF-020 V-22 runner: the production web storage backend on real engines.
//
// Verification support, not product code. Nothing here is imported by `lib/`.
//
//   flutter build web --release -t tool/df020_storage_backend.dart -o <bundle>
//   node test/browser/df020_storage_backend.mjs --engine chromium|firefox|webkit \
//     --bundle <bundle> --out <file.json> [--browser <exe>] [--playwright <dir>]
//
// Chromium is the installed Chrome, and desktop WebKit is Playwright's WebKit
// (the df059_cp1_webkit.mjs pattern); both are driven through Playwright, and
// Chromium's storage clearing uses the DevTools protocol. Firefox is the
// installed Firefox over WebDriver BiDi (the df039_retention_firefox.mjs
// pattern). Each scenario starts in a fresh, isolated browser profile.
//
// The page under test is tool/df020_storage_backend.dart, which exposes
// `window.df020(step, argsJson)`. Raw IndexedDB requests that play "another
// context" (an upgrade from another tab) are issued from page script.

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

import { delay, removeDirectory, serveBundle, waitForValue } from './df031_cdp.mjs';

function argument(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  if (index === -1 || index + 1 >= process.argv.length) {
    if (fallback !== undefined) return fallback;
    throw new Error(`Missing required argument: --${name}`);
  }
  return process.argv[index + 1];
}

const ENGINE = argument('engine');
const BUNDLE = resolve(argument('bundle'));
const OUT = resolve(argument('out'));
const BROWSER = argument('browser', '');
const PLAYWRIGHT = argument('playwright', '');
const ONLY = argument('only', '');

const evidence = {
  harness: 'df020_storage_backend',
  engine: ENGINE,
  startedAt: new Date().toISOString(),
  scenarios: {},
  failures: [],
};

function expect(scenario, name, pass, data = {}) {
  const entry = { name, pass: Boolean(pass), ...data };
  (evidence.scenarios[scenario] ??= { checks: [] }).checks.push(entry);
  if (!pass) evidence.failures.push(`${scenario}: ${name}`);
  console.log(`${pass ? 'PASS' : 'FAIL'}  [${scenario}] ${name}`);
}

function note(scenario, name, data) {
  (evidence.scenarios[scenario] ??= { checks: [] }).checks.push({ name, note: true, ...data });
  console.log(`NOTE  [${scenario}] ${name} ${JSON.stringify(data)}`);
}

// --- Page script: raw IndexedDB as "another context" ----------------------------

const IDB = String.raw`
window.__df020u ??= {};
window.__df020Upgrade = (tag, version, abortOnUpgrade) => {
  const u = window.__df020u[tag] = { blocked: false, upgraded: false, state: 'pending' };
  const request = indexedDB.open('markdown_viewer', version);
  request.onblocked = () => { u.blocked = true; };
  request.onupgradeneeded = (event) => {
    u.upgraded = true;
    if (abortOnUpgrade) event.target.transaction.abort();
  };
  request.onsuccess = () => {
    u.state = 'success';
    u.version = request.result.version;
    u.db = request.result;
    request.result.onversionchange = () => request.result.close();
  };
  request.onerror = (event) => {
    u.state = 'error:' + (request.error && request.error.name);
    event.preventDefault();
  };
  return 'issued';
};
window.__df020UState = (tag) => {
  const u = window.__df020u[tag];
  return JSON.stringify(u ? { blocked: u.blocked, upgraded: u.upgraded, state: u.state, version: u.version } : null);
};
window.__df020UClose = (tag) => { const u = window.__df020u[tag]; if (u && u.db) u.db.close(); return 'closed'; };
window.__df020Version = () => new Promise((done) => {
  const request = indexedDB.open('markdown_viewer');
  request.onupgradeneeded = (event) => event.target.transaction.abort();
  request.onsuccess = () => { const v = request.result.version; request.result.close(); done(String(v)); };
  request.onerror = (event) => { event.preventDefault(); done('error:' + (request.error && request.error.name)); };
});
'ready';
`;

// --- Engines ----------------------------------------------------------------------

async function playwrightEngine(kind) {
  const module = await import(pathToFileURL(join(PLAYWRIGHT, 'node_modules', 'playwright', 'index.mjs')).href);
  const type = kind === 'chromium' ? module.chromium : module.webkit;
  const browser = await type.launch({
    headless: true,
    ...(kind === 'chromium' ? { executablePath: BROWSER } : {}),
  });
  evidence.browserVersion = `${kind} ${browser.version()}`;
  return {
    async context(origin) {
      const context = await browser.newContext();
      return {
        async page() {
          const page = await context.newPage();
          await page.goto(`${origin}/`);
          await page.waitForFunction(() => document.body?.dataset?.df020Ready === 'true', null, { timeout: 90000 });
          await page.evaluate(IDB);
          return {
            call: async (step, args = {}) =>
              JSON.parse(await page.evaluate(([s, a]) => window.df020(s, a), [step, JSON.stringify(args)])),
            js: (expression) => page.evaluate(expression),
            clearIndexedDb: kind === 'chromium'
              ? async () => {
                const cdp = await context.newCDPSession(page);
                await cdp.send('Storage.clearDataForOrigin', { origin, storageTypes: 'indexeddb' });
                return true;
              }
              : null,
            close: () => page.close(),
          };
        },
        close: () => context.close(),
      };
    },
    close: () => browser.close(),
  };
}

class BidiSession {
  constructor(url) { this.socket = new WebSocket(url); this.nextId = 1; this.pending = new Map(); }
  async connect() {
    await new Promise((done, reject) => {
      this.socket.addEventListener('open', done, { once: true });
      this.socket.addEventListener('error', reject, { once: true });
    });
    this.socket.addEventListener('message', (event) => {
      const message = JSON.parse(event.data);
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.type === 'error') pending.reject(new Error(`${pending.method}: ${message.error} ${message.message}`));
      else pending.resolve(message.result);
    });
  }
  send(method, params = {}) {
    const id = this.nextId++;
    return new Promise((done, reject) => {
      this.pending.set(id, { resolve: done, reject, method });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }
  close() { try { this.socket.close(); } catch { /* gone */ } }
}

async function firefoxEngine() {
  let launches = 0;
  return {
    // A fresh profile per context: a new Firefox instance.
    async context(origin) {
      const profile = join(dirname(OUT), `df020-ff-${process.pid}-${launches++}`);
      await mkdir(profile, { recursive: true });
      await writeFile(join(profile, 'user.js'), [
        'user_pref("browser.shell.checkDefaultBrowser", false);',
        'user_pref("datareporting.policy.dataSubmissionEnabled", false);',
        'user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);',
        'user_pref("app.update.auto", false);',
        'user_pref("remote.prefs.recommended", true);',
        'user_pref("dom.min_background_timeout_value", 4);',
      ].join('\n'));
      const child = spawn(BROWSER, ['--headless', '--no-remote', '--new-instance', '--profile', profile,
        '--remote-debugging-port', '0', 'about:blank'], { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
      let output = '';
      child.stderr.setEncoding('utf8'); child.stdout.setEncoding('utf8');
      child.stderr.on('data', (c) => { output += c; }); child.stdout.on('data', (c) => { output += c; });
      const url = await waitForValue(async () => output.match(/WebDriver BiDi listening on (ws:\/\/\S+)/)?.[1] ?? null,
        'Firefox WebDriver BiDi endpoint', 60000);
      const session = new BidiSession(`${url}/session`);
      await session.connect();
      const created = await session.send('session.new', { capabilities: { alwaysMatch: {} } });
      evidence.browserVersion = `Firefox ${created.capabilities?.browserVersion ?? '?'}`;
      const evaluate = async (context, expression) => {
        const result = await session.send('script.evaluate', {
          expression, target: { context }, awaitPromise: true, resultOwnership: 'none',
        });
        if (result.type === 'exception') throw new Error(`page exception: ${JSON.stringify(result.exceptionDetails?.text)}`);
        return result.result?.value;
      };
      return {
        async page() {
          const { context } = await session.send('browsingContext.create', { type: 'tab' });
          await session.send('browsingContext.navigate', { context, url: `${origin}/`, wait: 'complete' });
          await waitForValue(async () => (await evaluate(context, `document.body?.dataset?.df020Ready === 'true'`)) || null,
            'harness ready', 90000);
          await evaluate(context, IDB);
          return {
            call: async (step, args = {}) =>
              JSON.parse(await evaluate(context, `window.df020(${JSON.stringify(step)}, ${JSON.stringify(JSON.stringify(args))})`)),
            js: (expression) => evaluate(context, expression),
            clearIndexedDb: null,
            close: () => session.send('browsingContext.close', { context }).catch(() => {}),
          };
        },
        async close() {
          await Promise.race([session.send('browser.close').catch(() => {}), delay(4000)]);
          session.close();
          await Promise.race([new Promise((d) => (child.exitCode === null ? child.once('exit', d) : d())), delay(10000)]);
          if (child.exitCode === null) child.kill();
          await delay(1500);
          await removeDirectory(profile);
        },
      };
    },
    close: async () => {},
  };
}

// --- Scenarios ----------------------------------------------------------------------

const T_OPEN = 5000, T_TX = 20000, T_SET = 20000, T_STARTUP = 20000, SLACK = 1000;
const Q = T_OPEN + T_TX;
const uState = async (page, tag) => JSON.parse(await page.js(`window.__df020UState(${JSON.stringify(tag)})`));

async function contractAndCases(ctx) {
  const page = await ctx.page();
  const contract = await page.call('contract');
  for (const check of contract.checks ?? []) {
    expect('contract', `${check.id}: ${check.name}`, check.pass, { error: check.error, ms: check.ms });
  }
  expect('contract', 'unreachable storage is not created', contract.unavailableDatabaseNotCreated);
  if (!contract.ok) expect('contract', 'the suite ran', false, contract);
  const cases = await page.call('cases');
  if (!cases.ok) expect('cases', 'the cases ran', false, cases);
  for (const key of ['a', 'b', 'c', 'd', 'e', 'g']) {
    expect('cases', `(${key})`, cases[key]?.pass, cases[key]);
  }
  const m = cases.margins ?? {};
  evidence.margins = m;
  const margin = (observed, bound) => observed > 0 ? bound / observed : Infinity;
  expect('cases', 'timing margins are at least 4x', [
    margin(m.openMs, T_OPEN), margin(m.commitMs, T_TX), margin(m.largeCommitMs, T_TX),
    margin(m.settingsWriteMs, T_SET), margin(m.startupOpenMs, T_STARTUP),
  ].every((x) => x >= 4), m);
}

async function scenarioABC(ctx) {
  const page = await ctx.page();
  await page.call('openHive');
  const setup = await page.call('lcSetup');
  expect('A', 'setup wrote both keys', setup.documents && setup.reading, setup);

  await page.js(`window.__df020Upgrade('U', 2, false)`);
  // Engines fire `blocked` at different times after `versionchange` (Firefox
  // later than Chromium), so wait for it rather than for a fixed delay.
  const u = await waitForValue(async () => {
    const state = await uState(page, 'U');
    return state.blocked || state.upgraded ? state : null;
  }, 'the upgrade to report blocked', 5000).catch(async () => uState(page, 'U'));
  // The condition is that the upgrade does not proceed while Hive's connection
  // is held. Whether a `blocked` event also fires differs by engine: Firefox
  // does not fire it when the request comes from the page that holds the
  // blocking connection. C proves Hive held it: the upgrade commits only once
  // Hive's connection is released.
  expect('A', 'the upgrade stays pending while Hive\'s connection is held',
    !u.upgraded && u.state === 'pending', { ...u, blockedEventFired: u.blocked });
  const first = await page.call('lcOp', { op: 'write' });
  expect('A', 'the next operation resolves unavailable within T_open + 1 s',
    first.outcome === 'unavailable' && first.serviceMs <= T_OPEN + SLACK, first);
  const second = await page.call('lcStoreOp');
  expect('A', 'a further queued Store operation also completes, bounded (service time from execution start)',
    second.ok && second.queueOperations >= 1 && second.serviceMs <= Q + SLACK, second);

  const before = await page.call('lcStats');
  const removal = await page.call('lcRemoval');
  expect('B', 'a document-removal Retry and its restore terminate within 7Q, not verified or saved',
    removal.outcome === 'notVerified' && !removal.onVerifiedCalled && !removal.restoreConfirmed &&
    removal.queueOperations === 3 && removal.serviceMs <= 7 * Q + SLACK, removal);
  const whole = await page.call('lcWholeStore');
  expect('B', 'a whole-store Retry terminates in bound, not confirmed',
    whole.outcome !== 'confirmedAbsent' && whole.serviceMs <= 6 * Q + SLACK, whole);
  const after = await page.call('lcStats');
  expect('B', 'at most one open request was pending', after.openRequests - before.openRequests <= 1, { before, after });

  await page.call('closeHive');
  await delay(1000);
  const committed = await uState(page, 'U');
  expect('C', 'releasing Hive lets the upgrade commit', committed.state === 'success' && committed.version === 2, committed);
  await page.js(`window.__df020UClose('U')`);
  const retry = await page.call('lcWholeStore');
  expect('C', 'the deletion Retry issues real deletes (counted at the IndexedDB API) and confirms absence by read',
    retry.outcome === 'confirmedAbsent' && retry.deletesIssued === 2, retry);
  const stats = await page.call('lcStats');
  expect('C', 'the backend recovered on a managed connection', stats.hasConnection === true, stats);
  const version = await page.js('window.__df020Version()');
  expect('C', 'the database is now version 2', version === '2', { version });
  const hive = await page.call('openHive');
  expect('C', 'a fresh production-Hive open(name, 1) now fails with VersionError (recorded, inherited)',
    !hive.ok && /VersionError/i.test(hive.error ?? ''), { error: hive.error });
}

async function scenarioD(ctx) {
  const page = await ctx.page();
  await page.call('openHive');
  await page.call('lcSetup');
  if (page.clearIndexedDb) {
    await page.call('lcHoldNextWrite');
    const inFlight = page.call('lcOp', { op: 'write' });
    await delay(300);
    await page.clearIndexedDb();
    const aborted = await inFlight;
    expect('D', 'the in-flight transaction resolves failed after storage clearing', aborted.outcome === 'failed', aborted);
    await page.call('lcRelease');
    const stats = await page.call('lcStats');
    expect('D', 'the close event invalidated the connection', stats.hasConnection === false, stats);
    const later = await page.call('lcOp', { op: 'read' });
    expect('D', 'a later operation stays bounded', later.ok && later.serviceMs <= T_OPEN + SLACK, later);
    note('D', 'mechanism', { mechanism: 'CDP Storage.clearDataForOrigin (indexeddb)' });
  } else {
    await page.call('lcDispatchClose');
    const stats = await page.call('lcStats');
    expect('D', 'a dispatched close event invalidates the connection (handler-level evidence only)',
      stats.hasConnection === false, stats);
    note('D', 'mechanism', { mechanism: 'harness-dispatched close event; handler-level evidence only' });
  }
  await page.call('closeHive');
  const reopened = await page.call('openHive');
  const recovered = await page.call('lcOp', { op: 'write' });
  expect('D', 'recovery follows once Hive reopens as at a reload', reopened.ok && recovered.outcome === 'committed',
    { reopened, recovered });
}

async function scenarioE(ctx, staleEpoch) {
  const tag = staleEpoch ? 'E (stale epoch)' : 'E';
  const page = await ctx.page();
  await page.call('openHive');
  await page.call('lcSetup');
  await page.js(`window.__df020Upgrade('U', 2, false)`);
  await delay(500);
  const timedOut = await page.call('lcOp', { op: 'write' });
  expect(tag, 'the operation times out unavailable while its open is pending', timedOut.outcome === 'unavailable', timedOut);
  const pendingStats = await page.call('lcStats');
  if (staleEpoch) await page.call('lcBumpEpoch');
  await page.call('closeHive');
  await delay(1500);
  await page.js(`window.__df020UClose('U')`);
  const stats = await page.call('lcStats');
  expect(tag, 'no duplicate open request was issued', stats.openRequests === pendingStats.openRequests, { pendingStats, stats });
  if (staleEpoch) {
    expect(tag, 'a late connection from a stale epoch is closed, not adopted',
      stats.lateClosed === 1 && stats.lateAdopted === 0, stats);
    return;
  }
  expect(tag, 'exactly one late connection was adopted', stats.lateAdopted === 1 && stats.hasConnection === true, stats);
  const later = await page.call('lcOp', { op: 'write' });
  expect(tag, 'a later operation succeeds on the adopted connection', later.outcome === 'committed', later);
  await page.js(`window.__df020Upgrade('U3', 3, false)`);
  await delay(1500);
  const probe = await uState(page, 'U3');
  expect(tag, 'no Saudo connection leaks: a further upgrade completes without blocked',
    probe.state === 'success' && !probe.blocked, probe);
  await page.js(`window.__df020UClose('U3')`);
  note(tag, 'C8 late commit', { coveredBy: 'contract C8, compiled against the production backend in this engine' });
}

async function scenarioF(ctx) {
  const page = await ctx.page();
  await page.call('openHive');
  await page.call('lcSetup');
  await page.call('lcHoldNextWrite');
  const held = await page.call('lcOp', { op: 'write' });
  expect('F', 'the held content operation returns indeterminate within its bound',
    held.outcome === 'indeterminate' && held.serviceMs <= T_TX + SLACK + T_OPEN, held);
  const settings = await page.call('lcSaveSettings', { keep: false });
  expect('F', 'a settings save behind it terminates indeterminate within T_set + 1 s',
    settings.outcome === 'indeterminate' && settings.serviceMs <= T_SET + SLACK, settings);
  const removal = await page.call('lcRemoval');
  expect('F', 'a document-removal Retry and its restore terminate within 7Q with no verified or saved claim',
    removal.outcome === 'notVerified' && !removal.restoreConfirmed && removal.queueOperations === 3 &&
    removal.serviceMs <= 7 * Q + SLACK, removal);
  const whole = await page.call('lcWholeStore');
  expect('F', 'a whole-store Retry terminates in bound with no confirmed claim',
    whole.outcome !== 'confirmedAbsent' && whole.serviceMs <= 6 * Q + SLACK, whole);
  const off = await page.call('lcDisable');
  expect('F', 'ON→OFF applies OFF, bounds the preference write, still attempts removal, reports truthfully',
    off.ok && off.effectivePolicy === 'off' && off.preference === 'indeterminate' &&
    off.deletesIssued >= 1 && off.cleanup !== 'confirmedAbsent' && !off.contentConfirmedAbsent &&
    !off.removedAndWillNotReturn && off.serviceMs <= T_SET + 6 * Q + SLACK, off);
  const offAgain = await page.call('lcSaveSettings', { keep: false });
  const onAgain = await page.call('lcSaveSettings', { keep: true });
  expect('F', 'OFF then ON, both issued while blocked, each resolve indeterminate within T_set + 1 s',
    offAgain.outcome === 'indeterminate' && onAgain.outcome === 'indeterminate' &&
    offAgain.serviceMs <= T_SET + SLACK && onAgain.serviceMs <= T_SET + SLACK, { offAgain, onAgain });
  await page.call('lcRelease');
  await delay(2000);
  const recovery = await page.call('lcWholeStore');
  expect('F', 'after release the Retry issues real deletes and confirms absence', recovery.outcome === 'confirmedAbsent', recovery);
  await page.call('closeHive');
  await page.call('openHive');
  const fresh = await page.call('lcFreshStore');
  expect('F', 'a fresh settings read shows the last-issued value (ON)', fresh.keepForNextTime === true, fresh);
}

async function scenarioG(ctx) {
  const p = await ctx.page();
  await p.call('openHive');
  const seeded = await p.call('gSeed');
  expect('G', 'identifiable ON settings and content are seeded', seeded.documents === 'committed' &&
    seeded.reading === 'committed', seeded);
  const h = await ctx.page();
  await h.js(`window.__df020Upgrade('U1', 2, true)`);
  await delay(800);
  const u1 = await uState(h, 'U1');
  expect('G', 'U1 is blocked by context P', u1.blocked && !u1.upgraded, u1);
  const a = await ctx.page();
  const startup = await a.call('startupInit');
  expect('G', 'Store.init reaches the in-memory path within T_startup + 1 s',
    startup.ok && startup.available === false && startup.initMs <= T_STARTUP + SLACK, startup);
  const home = startup.homeText ?? '';
  expect('G', 'the rendered Home: no Saved in this browser, no identity, no Continue reading, no "nothing saved" claim',
    startup.presence === 'indeterminate' && startup.retained === false && startup.effectivePolicy === 'off' &&
    !/Saved in this browser/.test(home) && !/Continue reading/.test(home) &&
    !/g-seeded\.md|G seeded title/.test(home) &&
    /not allowing this site to store data/.test(home) && /Load from file/.test(home), { ...startup, homeText: home });
  await p.call('closeHive');
  await p.close();
  await delay(1500);
  const u1After = await uState(h, 'U1');
  expect('G', 'U1 reached upgradeneeded and was aborted; the version stays 1',
    u1After.upgraded && /AbortError/.test(u1After.state), u1After);
  await delay(1500);
  const lateStats = await a.call('lcStats');
  expect('G', 'Store.init closed the late-opened box', lateStats.lateBoxesClosed >= 1, lateStats);
  await h.js(`window.__df020Upgrade('U2', 2, true)`);
  await delay(1500);
  const u2 = await uState(h, 'U2');
  expect('G', 'leak probe: U2 reaches upgradeneeded with no blocked', u2.upgraded && !u2.blocked, u2);
  const version = await h.js('window.__df020Version()');
  expect('G', 'a version-less open reports version 1', version === '1', { version });
  await a.close();
  const reload = await ctx.page();
  const normal = await reload.call('startupInit');
  const reloaded = normal.homeText ?? '';
  expect('G', 'a normal reload opens storage, and the seeded settings and content load as before',
    normal.ok && normal.available === true && normal.effectivePolicy === 'on' && normal.keepForNextTime === true &&
    JSON.stringify(normal.retainedIds) === '["g-doc"]' &&
    /Continue reading/.test(reloaded) && /Saved in this browser/.test(reloaded) && /g-seeded\.md/.test(reloaded),
    { ...normal, homeText: reloaded });
}

// Stored values that are not strings: IndexedDB can hold null, undefined or any
// other type under a key, and none of them may be mistaken for absence.
const RAW_SEED = (keep, kind) => `(async () => {
  const db = await new Promise((done, fail) => {
    const r = indexedDB.open('markdown_viewer', 1);
    r.onupgradeneeded = () => r.result.createObjectStore('box');
    r.onsuccess = () => done(r.result);
    r.onerror = () => fail(r.error);
  });
  await new Promise((done, fail) => {
    const tx = db.transaction('box', 'readwrite');
    const s = tx.objectStore('box');
    s.put(JSON.stringify({ appearance: 'system', fontScale: 1, wrapCode: false, keepForNextTime: ${keep} }), 'settings');
    const kind = ${JSON.stringify(kind)};
    if (kind === 'null') s.put(null, 'document');
    if (kind === 'undefined') s.put(undefined, 'document');
    if (kind === 'number') s.put(42, 'document');
    tx.oncomplete = done; tx.onerror = () => fail(tx.error);
  });
  db.close();
  return 'seeded';
})()`;

async function scenarioNonString(ctx, engine, origin) {
  for (const [keep, kind] of [[true, 'absent'], [true, 'null'], [true, 'undefined'], [true, 'number'], [false, 'null']]) {
    const label = `${kind}, ${keep ? 'ON' : 'OFF'}`;
    const fresh = await engine.context(origin);
    try {
      const seed = await fresh.page();
      await seed.js(RAW_SEED(keep, kind));
      const classified = await seed.call('classify', { key: 'document' });
      expect('H', `${label}: the production backend reads ${kind === 'absent' ? 'absent' : 'present-undecodable'}`,
        classified.kind === (kind === 'absent' ? 'absent' : 'undecodable'), classified);
      await seed.close();
      const app = await fresh.page();
      const startup = await app.call('startupInit');
      const home = startup.homeText ?? '';
      if (kind === 'absent') {
        expect('H', `${label}: nothing stored, no recovery`,
          startup.presence === 'absent' && !/Remove unreadable saved data/.test(home), { ...startup, homeText: home });
      } else if (keep) {
        expect('H', `${label}: stored data is present and reaches generic recovery, never absence`,
          startup.presence === 'present' && startup.retained === false &&
          /Remove unreadable saved data/.test(home) && !/Continue reading/.test(home),
          { ...startup, homeText: home });
      } else {
        const after = await app.call('classify', { key: 'document' });
        expect('H', `${label}: startup cleanup removes it rather than missing it`,
          startup.effectivePolicy === 'off' && after.kind === 'absent', { ...startup, after, homeText: home });
      }
    } finally {
      await fresh.close().catch(() => {});
    }
  }
}

// --- Run ------------------------------------------------------------------------------

const server = await serveBundle(BUNDLE);
evidence.origin = server.origin;
evidence.bundleMainDartJsSha256 = createHash('sha256').update(await readFile(join(BUNDLE, 'main.dart.js'))).digest('hex');
const engine = ENGINE === 'firefox' ? await firefoxEngine() : await playwrightEngine(ENGINE);
const scenarios = [
  ['contract+cases', contractAndCases],
  ['A-B-C', scenarioABC],
  ['D', scenarioD],
  ['E', (ctx) => scenarioE(ctx, false)],
  ['E-stale', (ctx) => scenarioE(ctx, true)],
  ['F', scenarioF],
  ['G', scenarioG],
  ['H', 'nonString'],
];
try {
  for (const [name, run] of scenarios) {
    if (ONLY && !ONLY.split(',').includes(name)) continue;
    const started = Date.now();
    if (run === 'nonString') {
      try {
        await scenarioNonString(null, engine, server.origin);
      } catch (error) {
        expect(name, 'scenario ran to completion', false, { error: `${error.stack ?? error}` });
      }
      console.log(`----  ${name} took ${Math.round((Date.now() - started) / 1000)} s`);
      continue;
    }
    const ctx = await engine.context(server.origin);
    try {
      await run(ctx);
    } catch (error) {
      expect(name, 'scenario ran to completion', false, { error: `${error.stack ?? error}` });
    } finally {
      await ctx.close().catch(() => {});
    }
    console.log(`----  ${name} took ${Math.round((Date.now() - started) / 1000)} s`);
  }
} finally {
  await engine.close().catch(() => {});
  await server.close();
}
evidence.finishedAt = new Date().toISOString();
evidence.passed = evidence.failures.length === 0;
await mkdir(dirname(OUT), { recursive: true });
await writeFile(OUT, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');
console.log(evidence.passed ? 'ALL PASSED' : `FAILURES: ${evidence.failures.length}`);
process.exitCode = evidence.passed ? 0 : 1;
