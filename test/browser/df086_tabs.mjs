// DF-086: document-tab order, keyboard access and `Move document` in a
// compiled build.
//
// Verification support, not product code. Nothing here is imported by `lib/`.
//
//   node test/browser/df086_tabs.mjs --browser chrome|edge|firefox|webkit \
//     --playwright <dir with node_modules/playwright> --bundle <release bundle> \
//     --out <file.json> [--cases kb,kb5,menu,narrow,drag,r1,r7] \
//     [--files <scratch dir, for the RO-14 Reader drop>] [--runs 10] \
//     [--r7-runs 5] [--modes off,on]
//
// Each case starts in a fresh browser context with a saved set of three
// documents under `Keep for next time` ON (decision.md, implementation.md,
// plan.md, in D-2 order), then continues reading. Outcomes are read from
// IndexedDB (the stored order and the stored active document: the
// authoritative oracle) and, with accessibility semantics on, from the
// semantics DOM.
//
// Semantics mode. Flutter's web accessibility tree is off unless assistive
// technology (or this harness, through the placeholder) turns it on.
//   * kb     (semantics ON): KB-1 tabs are role=tab with tabindex=0 in one
//            tablist, close controls keep `Close <name>`; KB-2 Tab and
//            Shift+Tab order; KB-3 Enter and Space activate, no reorder;
//            KB-6 a screenshot of the focus outline; KB-7 the Reader menu
//            button's name.
//   * kb5    (semantics OFF): there is no DOM focus to read, so each sample is
//            a fresh page: Tab (or Shift+Tab) k times, then Enter (or Space),
//            and the stored state says what acted.
//   * menu   (semantics ON, wide): KB-4, keyboard only: Reader menu ->
//            Move document -> Move to first / Move right / Move left.
//   * narrow (semantics ON, 390 px): NS-1, Move up / Move down and the
//            Documents sheet's order.
//   * drag   (semantics OFF, and ON recorded): RO-1..RO-5 by mouse, RO-6 and
//            RO-7 by touch (DevTools touch in Chromium; synthetic touch
//            PointerEvents elsewhere), RO-13, and RO-14 (a Reader file drop
//            after a manual move; Chromium, with --files).
//   * r1     RO-8 / risk R-1: a mouse drag held still at the right edge of an
//            overflowing strip, --runs consecutive fresh runs per mode.
//   * r7     RO-7b / risk R-7 (Chromium): a touch swipe of an overflowing
//            strip (held, and flinging to the end), then a long-press drag.
//   * entry  (with kb): forward Tab from the Reader menu through the page exit.
//
// This is SIMULATED input (Playwright keyboard and mouse). It is not native
// Human, physical-device or screen-reader evidence.

import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

import { delay, serveBundle } from './df031_cdp.mjs';

function argument(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  if (index === -1) {
    if (fallback !== undefined) return fallback;
    throw new Error(`Missing --${name}`);
  }
  return process.argv[index + 1];
}

const BROWSER = argument('browser');
const PLAYWRIGHT = argument('playwright');
const BUNDLE = resolve(argument('bundle'));
const OUT = resolve(argument('out'));
const CASES = argument('cases', 'kb,entry,kb5,menu,narrow,drag,r1,r7').split(',');
const FILES = argument('files', '') ? resolve(argument('files')) : null;

const sha = async (path) => createHash('sha256').update(await readFile(path)).digest('hex');
const pw = await import(pathToFileURL(join(PLAYWRIGHT, 'node_modules', 'playwright', 'index.mjs')).href);

const LAUNCH = {
  chrome: () => pw.chromium.launch({ headless: true, executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe' }),
  edge: () => pw.chromium.launch({ headless: true, executablePath: 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' }),
  firefox: () => pw.firefox.launch({ headless: true, channel: 'moz-firefox', executablePath: 'C:/Program Files/Mozilla Firefox/firefox.exe' }),
  webkit: () => pw.webkit.launch({ headless: true }),
};

// --- Fixtures --------------------------------------------------------------

const NAMES = ['decision.md', 'implementation.md', 'plan.md'];
const SAVED_AT = '2026-11-23T00:00:00.000Z';
const idOf = (name) => `df086-${name.replace('.md', '')}`;
const body = (name) => `# ${name}\n\n${Array.from({ length: 30 }, (_, i) => `Paragraph ${i} of ${name}.`).join('\n\n')}\n`;

function seedValues(active, names = NAMES) {
  return {
    settings: JSON.stringify({ appearance: 'system', fontScale: 1.0, wrapCode: false, keepForNextTime: true }),
    document: JSON.stringify(['saudo-document-set', 2, {
      documents: names.map((name) => ({
        id: idOf(name), title: name, source: body(name), createdAt: SAVED_AT, updatedAt: SAVED_AT,
        sourceName: name, origin: 'file', scriptPreference: 'auto',
      })),
    }]),
    position: JSON.stringify(['saudo-reading-state', 2, { activeId: idOf(active), positions: {} }]),
  };
}

const SEED = (values) => (async (v) => {
  const db = await new Promise((done, fail) => {
    const r = indexedDB.open('markdown_viewer', 1);
    r.onupgradeneeded = () => r.result.createObjectStore('box');
    r.onsuccess = () => done(r.result);
    r.onerror = () => fail(r.error);
  });
  await new Promise((done, fail) => {
    const tx = db.transaction('box', 'readwrite');
    for (const [key, value] of Object.entries(v)) tx.objectStore('box').put(value, key);
    tx.oncomplete = done; tx.onerror = () => fail(tx.error);
  });
  db.close();
  return 'seeded';
})(values);

const STORED = () => (async () => {
  const db = await new Promise((done) => { const r = indexedDB.open('markdown_viewer'); r.onsuccess = () => done(r.result); });
  const read = (key) => new Promise((done) => { const r = db.transaction('box').objectStore('box').get(key); r.onsuccess = () => done(r.result ?? null); });
  const value = { document: await read('document'), position: await read('position') };
  db.close();
  return value;
})();

const decode = (s) => {
  const set = s.document ? JSON.parse(s.document)[2].documents : [];
  const activeId = s.position ? JSON.parse(s.position)[2].activeId : null;
  return { names: set.map((d) => d.sourceName), active: set.find((d) => d.id === activeId)?.sourceName ?? null };
};

// --- Semantics DOM readers (semantics ON only) -----------------------------

const TABS = () => [...document.querySelectorAll('[role=tab]')].map((n) => {
  const r = n.getBoundingClientRect();
  const list = n.closest('[role=tablist]');
  return {
    label: n.getAttribute('aria-label'),
    selected: n.getAttribute('aria-selected'),
    tabindex: n.getAttribute('tabindex'),
    owner: list ? 'tablist' : null,
    tablists: document.querySelectorAll('[role=tablist]').length,
    sameList: list === document.querySelector('[role=tablist]'),
    x: r.x + r.width / 2, y: r.y + r.height / 2, left: r.left, right: r.right, w: r.width,
  };
}).sort((a, b) => a.x - b.x);

const FOCUS = () => {
  const a = document.activeElement;
  if (!a || a === document.body) return null;
  const label = a.getAttribute('aria-label') || (a.textContent || '').trim().split('\n')[0];
  return { role: a.getAttribute('role'), label: (label || '').slice(0, 40), tabindex: a.getAttribute('tabindex'), inTab: !!a.closest('[role=tab]') };
};

const NODES = () => [...document.querySelectorAll('flt-semantics')].map((n) => ({
  role: n.getAttribute('role'),
  label: n.getAttribute('aria-label') || (n.textContent || '').trim().split('\n')[0],
  disabled: n.getAttribute('aria-disabled'),
  tabindex: n.getAttribute('tabindex'),
}));

// --- Evidence ----------------------------------------------------------------

const evidence = {
  harness: 'df086_tabs',
  evidenceClass: 'automated browser input (Playwright keyboard and mouse) on the release build; not native Human, physical-device or screen-reader evidence',
  startedAt: new Date().toISOString(),
  browser: BROWSER,
  bundle: { path: BUNDLE, mainDartJsSha256: await sha(join(BUNDLE, 'main.dart.js')) },
  runner: { sha256: await sha(new URL(import.meta.url)) },
  playwright: JSON.parse(await readFile(join(PLAYWRIGHT, 'node_modules', 'playwright', 'package.json'), 'utf8')).version,
  cases: [],
  failures: [],
};

function check(rec, name, pass, data = {}) {
  rec.checks.push({ name, pass: Boolean(pass), ...data });
  if (!pass) evidence.failures.push(`${rec.name}: ${name}`);
  console.log(`${pass ? 'PASS' : 'FAIL'}  [${BROWSER}] [${rec.name}] ${name}${pass ? '' : ` ${JSON.stringify(data).slice(0, 400)}`}`);
}
function note(rec, name, data) {
  (rec.observations ??= []).push({ name, ...data });
  console.log(`NOTE  [${BROWSER}] [${rec.name}] ${name} ${JSON.stringify(data).slice(0, 400)}`);
}

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const containsRun = (seq, run) => {
  for (let i = 0; i + run.length <= seq.length; i++) if (same(seq.slice(i, i + run.length), run)) return i;
  return -1;
};

const server = await serveBundle(BUNDLE);
const browser = await LAUNCH[BROWSER]();
evidence.browserVersion = browser.version();
const WIDE = { width: 1000, height: 900 };
const NARROW = { width: 390, height: 844 };

/// Opens a fresh context on the seeded set and continues reading.
/// With semantics off, `Continue reading` is clicked at [continueAt].
async function open({ viewport = WIDE, active = 'plan.md', names = NAMES, semantics = true, continueAt = null, contextOptions = {} } = {}) {
  const context = await browser.newContext({ viewport, ...contextOptions });
  const page = await context.newPage();
  await page.goto(`${server.origin}/__seed-page-not-the-app`);
  await page.evaluate(SEED, seedValues(active, names));
  await page.goto(`${server.origin}/`);
  await page.waitForSelector('flt-semantics-placeholder', { state: 'attached', timeout: 90000 });
  await delay(1500);
  if (semantics) {
    await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
    await delay(1200);
    const button = page.getByRole('button', { name: /Continue reading/ }).first();
    await button.waitFor({ state: 'attached', timeout: 30000 });
    await button.click({ force: true });
  } else {
    await page.mouse.click(continueAt.x, continueAt.y);
  }
  await delay(1800);
  return { context, page };
}

const tabs = (page) => page.evaluate(TABS);
const order = async (page) => (await tabs(page)).map((t) => t.label);
const selected = async (page) => (await tabs(page)).find((t) => t.selected === 'true')?.label ?? null;
const stored = async (page) => decode(await page.evaluate(STORED));
const focus = (page) => page.evaluate(FOCUS);
const nodes = (page) => page.evaluate(NODES);

async function press(page, key, wait = 150) {
  await page.keyboard.press(key);
  await delay(wait);
}

/// Presses Tab until the focused element's label matches [pattern].
async function tabTo(page, pattern, { limit = 40, key = 'Tab' } = {}) {
  for (let k = 0; k < limit; k++) {
    const f = await focus(page);
    if (f && pattern.test(f.label)) return f;
    await press(page, key, 120);
  }
  const f = await focus(page);
  return f && pattern.test(f.label) ? f : null;
}

async function runCase(name, bodyFn) {
  const rec = { name, checks: [] };
  evidence.cases.push(rec);
  try {
    await bodyFn(rec);
  } catch (error) {
    check(rec, 'case ran to completion', false, { error: `${error.stack ?? error}` });
  }
}

try {
  // --- KB-1, KB-2, KB-3, KB-6, KB-7: semantics ON -------------------------
  if (CASES.includes('kb')) {
    await runCase('kb (semantics on)', async (rec) => {
      const { context, page } = await open({ active: 'plan.md' });
      try {
        const t = await tabs(page);
        check(rec, 'KB-1 three role=tab nodes in D-2 order', same(t.map((x) => x.label), NAMES), { tabs: t });
        check(rec, 'KB-1 every tab has tabindex=0', t.length === 3 && t.every((x) => x.tabindex === '0'), { tabindex: t.map((x) => x.tabindex) });
        check(rec, 'KB-1 one tablist owns every tab', t.every((x) => x.owner === 'tablist' && x.sameList && x.tablists === 1));
        const all = await nodes(page);
        for (const name of NAMES) {
          check(rec, `S10-06 close control still exposes "Close ${name}"`, all.some((n) => n.label === `Close ${name}`));
        }
        const menu = all.filter((n) => n.label === 'Reader menu');
        check(rec, 'KB-7 the Reader menu button is a button named "Reader menu"', menu.length === 1 && menu[0].role === 'button', { menu });

        // In-page path. The Reader opens with focus on the Reader menu button,
        // the last focusable element. Shift+Tab from it, then Tab back, never
        // leaves the page, so every browser fires its focus events normally.
        const start = await focus(page);
        check(rec, 'the Reader opens with focus on the Reader menu button', start?.label === 'Reader menu', { start });
        const backward = [];
        for (let k = 0; k < 12 && backward.at(-1) !== 'decision.md'; k++) { await press(page, 'Shift+Tab'); backward.push((await focus(page))?.label ?? null); }
        const backRun = ['Close plan.md', 'plan.md', 'Close implementation.md', 'implementation.md', 'Close decision.md', 'decision.md'];
        check(rec, 'KB-2 Shift+Tab visits close control, its tab, previous close control ... in exact reverse', containsRun(backward, backRun) >= 0, { backward });
        const forward = [];
        for (let k = 0; k < 5; k++) { await press(page, 'Tab'); forward.push((await focus(page))?.label ?? null); }
        check(rec, 'KB-1 Tab visits tab, its close control, next tab ... in order', same(forward, ['Close decision.md', 'implementation.md', 'Close implementation.md', 'plan.md', 'Close plan.md']), { forward });

        // KB-3: Enter on implementation.md, Space on decision.md.
        await tabTo(page, /^implementation\.md$/, { key: 'Shift+Tab' });
        await press(page, 'Enter', 1200);
        const afterEnter = { selected: await selected(page), stored: await stored(page), focus: await focus(page) };
        check(rec, 'KB-3 Enter activates the focused tab (selected and stored)', afterEnter.selected === 'implementation.md' && afterEnter.stored.active === 'implementation.md', afterEnter);
        check(rec, 'KB-3 focus stays on the activated tab', afterEnter.focus?.label === 'implementation.md' && afterEnter.focus?.role === 'tab', afterEnter);

        // KB-6: the focus outline is drawn (screenshot for the record).
        const shot = join(dirname(OUT), `df086-${BROWSER}-kb6-focus.png`);
        await page.screenshot({ path: shot, clip: { x: 0, y: 0, width: 600, height: 60 } });
        note(rec, 'KB-6 focus-outline screenshot', { path: shot, focused: 'implementation.md' });

        await tabTo(page, /^decision\.md$/, { key: 'Shift+Tab' });
        await press(page, ' ', 1200);
        const afterSpace = { selected: await selected(page), stored: await stored(page) };
        check(rec, 'KB-3 Space activates the focused tab (selected and stored)', afterSpace.selected === 'decision.md' && afterSpace.stored.active === 'decision.md', afterSpace);
        check(rec, 'KB-3 keyboard activation does not reorder (shown and stored)', same(await order(page), NAMES) && same(afterSpace.stored.names, NAMES), { order: await order(page), stored: afterSpace.stored });

      } finally {
        await context.close();
      }
    });
  }

  // --- KB-1 / KB-3 entry path: semantics ON, fresh page --------------------
  if (CASES.includes('kb')) {
    await runCase('entry (semantics on)', async (rec) => {
      // Forward Tab as a user starts: from the Reader menu button, which has
      // focus when the Reader opens and is the last focusable element. Entering
      // the Flutter view lands on the Reader menu first (the pre-existing
      // first-entry stop, plan R-2); Tab then leaves the page and re-enters it
      // at the tabs. Playwright-driven Firefox cannot follow that round trip:
      // once Tab has left the page it still moves activeElement but fires no
      // focus events, on any page (reproduced on a plain three-element page,
      // CP1 evidence), so Flutter is never told. There the activation after
      // re-entry is recorded, not checked.
      const { context, page } = await open({ active: 'decision.md' });
      try {
        const entry = [];
        for (let k = 0; k < 14 && entry.at(-1) !== 'plan.md'; k++) { await press(page, 'Tab'); entry.push((await focus(page))?.label ?? null); }
        check(rec, 'KB-1 entry path: forward Tab from the Reader menu reaches the tabs in order', containsRun(entry, ['decision.md', 'Close decision.md', 'implementation.md', 'Close implementation.md', 'plan.md']) >= 0, { entry });
        await press(page, 'Enter', 1200);
        const afterEntry = { selected: await selected(page), stored: (await stored(page)).active };
        if (BROWSER === 'firefox') {
          note(rec, 'entry path: Enter on plan.md after the page round trip (not checkable in automated Firefox)', afterEntry);
        } else {
          check(rec, 'KB-3 entry path: Enter after the page round trip activates plan.md', afterEntry.selected === 'plan.md' && afterEntry.stored === 'plan.md', afterEntry);
        }
      } finally {
        await context.close();
      }
    });
  }

  // --- KB-5: semantics OFF -------------------------------------------------
  if (CASES.includes('kb5')) {
    await runCase('kb5 (semantics off)', async (rec) => {
      // Where `Continue reading` is, read once with semantics on.
      const calib = await browser.newContext({ viewport: WIDE });
      let continueAt;
      try {
        const page = await calib.newPage();
        await page.goto(`${server.origin}/__seed-page-not-the-app`);
        await page.evaluate(SEED, seedValues('plan.md'));
        await page.goto(`${server.origin}/`);
        await page.waitForSelector('flt-semantics-placeholder', { state: 'attached', timeout: 90000 });
        await delay(1500);
        await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
        await delay(1200);
        const box = await page.getByRole('button', { name: /Continue reading/ }).first().boundingBox();
        continueAt = { x: box.x + box.width / 2, y: box.y + box.height / 2 };
      } finally {
        await calib.close();
      }
      note(rec, 'Continue reading position (from a semantics-on calibration)', continueAt);

      // One sample: fresh page, semantics off, [key] k times, then [act].
      async function sample(key, k, act) {
        const { context, page } = await open({ active: 'plan.md', semantics: false, continueAt });
        try {
          const before = await stored(page);
          for (let j = 0; j < k; j++) await press(page, key, 150);
          await press(page, act, 1500);
          const after = await stored(page);
          const placeholder = await page.evaluate(() => document.querySelectorAll('flt-semantics').length);
          let outcome = 'none';
          if (after.names.length < before.names.length) {
            outcome = `close:${before.names.find((n) => !after.names.includes(n))}`;
          } else if (after.active !== before.active) {
            outcome = `activate:${after.active}`;
          }
          if (!same(after.names.filter((n) => before.names.includes(n)), before.names.filter((n) => after.names.includes(n)))) outcome += ':REORDERED';
          return { k, key, act, outcome, semanticsNodes: placeholder };
        } finally {
          await context.close();
        }
      }

      const forward = [];
      for (let k = 1; k <= 10; k++) forward.push(await sample('Tab', k, 'Enter'));
      note(rec, 'Tab k, Enter', { outcomes: forward.map((s) => `${s.k}:${s.outcome}`) });
      const fwdRun = ['activate:decision.md', 'close:decision.md', 'activate:implementation.md', 'close:implementation.md', 'none', 'close:plan.md'];
      const fwdAt = containsRun(forward.map((s) => s.outcome), fwdRun);
      check(rec, 'KB-5 Tab reaches each tab then its close control, in order; Enter activates a tab', fwdAt >= 0, { outcomes: forward.map((s) => s.outcome) });
      // Tab also reaches the engine's own `Enable accessibility` placeholder,
      // and Enter on it turns semantics on: such a sample is not a tab stop.
      // The samples that make up the run must all have kept semantics off.
      note(rec, 'semantics nodes after each sample (non-zero: Enter reached the placeholder)', { nodes: forward.map((s) => `${s.k}:${s.semanticsNodes}`) });
      check(rec, 'KB-5 the matched run ran with semantics off', fwdAt >= 0 && forward.slice(fwdAt, fwdAt + fwdRun.length).every((s) => s.semanticsNodes === 0));

      const backward = [];
      for (let k = 1; k <= 10; k++) backward.push(await sample('Shift+Tab', k, 'Enter'));
      note(rec, 'Shift+Tab k, Enter', { outcomes: backward.map((s) => `${s.k}:${s.outcome}`) });
      const backRun = ['close:plan.md', 'none', 'close:implementation.md', 'activate:implementation.md', 'close:decision.md', 'activate:decision.md'];
      const backAt = containsRun(backward.map((s) => s.outcome), backRun);
      check(rec, 'KB-5 Shift+Tab visits the same stops in exact reverse', backAt >= 0, { outcomes: backward.map((s) => s.outcome) });
      check(rec, 'KB-5 the reverse run ran with semantics off', backAt >= 0 && backward.slice(backAt, backAt + backRun.length).every((s) => s.semanticsNodes === 0), { nodes: backward.map((s) => `${s.k}:${s.semanticsNodes}`) });

      if (fwdAt >= 0) {
        const spaceDecision = await sample('Tab', forward[fwdAt].k, ' ');
        const spaceImpl = await sample('Tab', forward[fwdAt + 2].k, ' ');
        check(rec, 'KB-5 Space activates a focused tab', spaceDecision.outcome === 'activate:decision.md' && spaceImpl.outcome === 'activate:implementation.md', { spaceDecision, spaceImpl });
      }
    });
  }

  // --- KB-4: keyboard-only Move document, wide, semantics ON ---------------
  if (CASES.includes('menu')) {
    await runCase('menu (semantics on, wide)', async (rec) => {
      const { context, page } = await open({ active: 'plan.md' });
      try {
        // Opens the Reader menu by keyboard and chooses [action] in Move document.
        async function moveByKeyboard(action) {
          const button = await tabTo(page, /^Reader menu$/);
          if (!button) return { ok: false, why: 'Reader menu not reached' };
          await press(page, 'Enter', 900);
          const tile = await tabTo(page, /^Move document/);
          if (!tile) return { ok: false, why: 'Move document not reached' };
          await press(page, 'Enter', 900);
          const sheet = await nodes(page);
          const choice = await tabTo(page, new RegExp(`^${action}`), { limit: 12 });
          if (!choice) return { ok: false, why: `${action} not reached`, sheet };
          await press(page, 'Enter', 1500);
          return { ok: true, sheet };
        }

        const m1 = await moveByKeyboard('Move to first');
        const s1 = await stored(page);
        check(rec, 'KB-4 Move to first by keyboard: shown and stored order, moved document stays active',
          m1.ok && same(await order(page), ['plan.md', 'decision.md', 'implementation.md']) && same(s1.names, ['plan.md', 'decision.md', 'implementation.md']) && s1.active === 'plan.md' && (await selected(page)) === 'plan.md',
          { m1, order: await order(page), stored: s1 });
        const offered = (m1.sheet ?? []).map((n) => n.label);
        check(rec, 'wide sheet offers Move to first, Move left, Move right (no up/down)',
          ['Move to first', 'Move left', 'Move right'].every((l) => offered.some((o) => o.startsWith(l))) && !offered.some((o) => /^Move (up|down)/.test(o)), { offered });

        // Now first: Move to first and Move left are disabled.
        await tabTo(page, /^Reader menu$/);
        await press(page, 'Enter', 900);
        await tabTo(page, /^Move document/);
        await press(page, 'Enter', 900);
        const disabled = (await nodes(page)).filter((n) => /^Move (to first|left|right)/.test(n.label)).map((n) => ({ label: n.label, disabled: n.disabled }));
        check(rec, 'unavailable moves are disabled (first: Move to first, Move left)',
          disabled.find((n) => n.label.startsWith('Move to first'))?.disabled === 'true' && disabled.find((n) => n.label.startsWith('Move left'))?.disabled === 'true' && disabled.find((n) => n.label.startsWith('Move right'))?.disabled !== 'true',
          { disabled });
        await press(page, 'Escape', 900);

        const m2 = await moveByKeyboard('Move right');
        const s2 = await stored(page);
        check(rec, 'KB-4 Move right by keyboard', m2.ok && same(s2.names, ['decision.md', 'plan.md', 'implementation.md']) && s2.active === 'plan.md', { m2, stored: s2 });
        const m3 = await moveByKeyboard('Move left');
        const s3 = await stored(page);
        check(rec, 'KB-4 Move left by keyboard', m3.ok && same(s3.names, ['plan.md', 'decision.md', 'implementation.md']) && s3.active === 'plan.md', { m3, stored: s3 });
        check(rec, 'KB-1 after moves, tabs still focusable in the new order', same((await tabs(page)).map((t) => `${t.label}:${t.tabindex}`), ['plan.md:0', 'decision.md:0', 'implementation.md:0']), { tabs: await tabs(page) });
      } finally {
        await context.close();
      }
    });
  }

  // --- NS-1: narrow, semantics ON -----------------------------------------
  if (CASES.includes('narrow')) {
    await runCase('narrow (semantics on, 390 px)', async (rec) => {
      const { context, page } = await open({ viewport: NARROW, active: 'decision.md' });
      try {
        check(rec, 'no tab strip at 390 px', (await tabs(page)).length === 0);
        await page.getByRole('button', { name: 'Reader menu' }).click({ force: true });
        await delay(900);
        await page.getByRole('button', { name: /^Move document/ }).click({ force: true });
        await delay(900);
        const offered = (await nodes(page)).map((n) => n.label);
        check(rec, 'NS-1 narrow sheet offers Move to first, Move up, Move down (no left/right)',
          ['Move to first', 'Move up', 'Move down'].every((l) => offered.some((o) => o.startsWith(l))) && !offered.some((o) => /^Move (left|right)/.test(o)), { offered: offered.filter((o) => /^Move/.test(o)) });
        await page.getByRole('button', { name: /^Move down/ }).click({ force: true });
        await delay(1500);
        const s = await stored(page);
        check(rec, 'NS-1 Move down: stored order, active unchanged', same(s.names, ['implementation.md', 'decision.md', 'plan.md']) && s.active === 'decision.md', { stored: s });
        await page.getByRole('button', { name: 'Reader menu' }).click({ force: true });
        await delay(900);
        await page.getByRole('button', { name: /^Documents \(3\)/ }).click({ force: true });
        await delay(1200);
        const list = (await nodes(page)).map((n) => n.label).filter((l) => NAMES.includes(l));
        check(rec, 'NS-1 Documents sheet shows the new order', same(list, ['implementation.md', 'decision.md', 'plan.md']), { list });
      } finally {
        await context.close();
      }
    });
  }

  // --- RO-10 restore in one context (semantics ON) -------------------------
  if (CASES.includes('menu')) {
    await runCase('restore (semantics on)', async (rec) => {
      const { context, page } = await open({ active: 'implementation.md' });
      try {
        await tabTo(page, /^Reader menu$/);
        await press(page, 'Enter', 900);
        await tabTo(page, /^Move document/);
        await press(page, 'Enter', 900);
        await tabTo(page, /^Move to first/, { limit: 12 });
        await press(page, 'Enter', 1500);
        const before = await stored(page);
        await page.reload();
        await page.waitForSelector('flt-semantics-placeholder', { state: 'attached', timeout: 90000 });
        await delay(1500);
        await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
        await delay(1200);
        await page.getByRole('button', { name: /Continue reading/ }).first().click({ force: true });
        await delay(1800);
        check(rec, 'RO-10 reload restores the manual order and the active document',
          same(before.names, ['implementation.md', 'decision.md', 'plan.md']) && same(await order(page), before.names) && (await selected(page)) === 'implementation.md',
          { before, order: await order(page), selected: await selected(page) });
      } finally {
        await context.close();
      }
    });
  }
  // --- R-1 / RO-8 and R-7 / RO-7b: drag on an overflowing strip -----------
  //
  // Ten documents overflow the 1000 px strip. Each run is a fresh context.
  // The oracle is the stored order and the stored active document (Keep ON),
  // never the positions of semantic rectangles. Semantics OFF is the primary
  // mode (plan §3.3); semantics ON is run and recorded.
  const LONG = Array.from({ length: 10 }, (_, k) => `m${k}-a-fairly-long-document-name.md`);
  const RUNS = Number(argument('runs', '10'));
  const R7_RUNS = Number(argument('r7-runs', '5'));
  const RO7_TRIALS = Number(argument('ro7-trials', '10'));
  const MODES = argument('modes', 'off,on').split(',');
  const FLING_WAIT = Number(argument('fling-wait', '1200'));
  const SHOTS = argument('shots', '') === '1';
  const moved = (names, from, to) => { const next = [...names]; const [item] = next.splice(from, 1); next.splice(to, 0, item); return next; };

  /// Tab rectangles and the Continue reading position, read once with
  /// semantics on: layout does not depend on the semantics mode.
  async function calibrate(contextOptions = {}) {
    const context = await browser.newContext({ viewport: WIDE, ...contextOptions });
    try {
      const page = await context.newPage();
      await page.goto(`${server.origin}/__seed-page-not-the-app`);
      await page.evaluate(SEED, seedValues(LONG[0], LONG));
      await page.goto(`${server.origin}/`);
      await page.waitForSelector('flt-semantics-placeholder', { state: 'attached', timeout: 90000 });
      await delay(1500);
      await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
      await delay(1200);
      const button = page.getByRole('button', { name: /Continue reading/ }).first();
      const box = await button.boundingBox();
      await button.click({ force: true });
      await delay(1800);
      return { continueAt: { x: box.x + box.width / 2, y: box.y + box.height / 2 }, tabs: await tabs(page) };
    } finally {
      await context.close();
    }
  }

  /// After a run with semantics off, turns semantics on to read the layout.
  async function layoutAfter(page) {
    const already = await page.evaluate(() => document.querySelectorAll('[role=tab]').length);
    if (!already) {
      await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
      await delay(1200);
    }
    return tabs(page);
  }

  if (CASES.includes('r1')) {
    await runCase('r1 (RO-8: mouse drag held at the right edge of an overflowing strip)', async (rec) => {
      const cal = await calibrate();
      const t0 = cal.tabs;
      const vw = WIDE.width;
      check(rec, 'pre: the strip overflows', t0.length === 10 && t0[9].right > vw, { lastRight: t0[9]?.right });
      const lastVisible = t0.filter((t) => t.right <= vw).length - 1;
      const releaseX = vw - 5;
      note(rec, 'calibration', { continueAt: cal.continueAt, y: t0[0].y, lastFullyVisibleIndex: lastVisible, releaseX });
      for (const mode of MODES) {
        const results = [];
        for (let run = 1; run <= RUNS; run++) {
          const { context, page } = await open({ active: LONG[0], names: LONG, semantics: mode === 'on', continueAt: cal.continueAt });
          try {
            const a = t0[0];
            await page.mouse.move(a.x, a.y);
            await page.mouse.down();
            for (let k = 1; k <= 15; k++) { await page.mouse.move(a.x + ((releaseX - a.x) * k) / 15, a.y); await delay(30); }
            // Hold the pointer still at the edge while the strip scrolls to its
            // end (a real held mouse sends no further moves).
            await delay(6000);
            await page.mouse.up();
            await delay(1500);
            const s = await stored(page);
            const t = await layoutAfter(page);
            const dropped = t.find((x) => x.label === LONG[0]);
            const toIndex = s.names.indexOf(LONG[0]);
            const ok = toIndex > lastVisible && same(s.names, moved(LONG, 0, toIndex)) && s.active === LONG[0]
              && dropped && dropped.left >= 0 && dropped.right <= vw && dropped.selected === 'true';
            results.push({ run, ok: Boolean(ok), toIndex, active: s.active, dropped: dropped && { left: Math.round(dropped.left), right: Math.round(dropped.right) } });
            console.log(`      r1 ${mode} run ${run}: ${ok ? 'applied' : 'NOT applied'} to=${toIndex} active=${s.active}`);
          } finally {
            await context.close();
          }
        }
        const applied = results.filter((r) => r.ok).length;
        let consecutive = 0;
        for (const r of results) consecutive = r.ok ? consecutive + 1 : 0;
        const record = { mode, applied, runs: results.length, results };
        if (mode === 'off') {
          check(rec, `RO-8 semantics off: drop after auto-scroll applied ${applied}/${results.length} (needs ${RUNS}/${RUNS} consecutive), stored order, dropped tab active, both edges in view`, applied === results.length && results.length === RUNS, record);
        } else {
          note(rec, `RO-8 semantics ${mode} (recorded): applied ${applied}/${results.length}`, record);
        }
      }
    });
  }

  if (CASES.includes('r7') && BROWSER !== 'firefox' && BROWSER !== 'webkit') {
    await runCase('r7 (RO-7b: touch swipe of an overflowing strip, then long-press drag)', async (rec) => {
      const cal = await calibrate({ hasTouch: true });
      const t0 = cal.tabs;
      const y = t0[0].y;
      // The same swipe in a semantics-on context, to measure how far it moves the strip.
      const swipe400 = async (touch) => {
        await touch('touchStart', 850, y);
        for (let k = 1; k <= 20; k++) { await touch('touchMove', 850 - 20 * k, y); await delay(16); }
        await delay(300);
        await touch('touchEnd', 450, y);
        await delay(1200);
      };
      let swipeShift;
      {
        const { context, page } = await open({ active: LONG[0], names: LONG, semantics: true, contextOptions: { hasTouch: true } });
        try {
          const cdp = await context.newCDPSession(page);
          await swipe400((type, x, yy) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x: Math.round(x), y: Math.round(yy) }] }));
          swipeShift = (await tabs(page))[0].left - t0[0].left;
        } finally {
          await context.close();
        }
      }
      note(rec, 'calibration', { continueAt: cal.continueAt, y, firstLeft: Math.round(t0[0].left), swipeShift: Math.round(swipeShift), endShift: Math.round((WIDE.width - 8) - t0[9].right) });
      // Two swipe styles: `held` stops before lifting (no fling; the strip
      // moves by a measured shift); `fling` lifts while moving fast, as
      // Planning's P3 did, and the strip flings to its end. The long press
      // starts on a tab's label (a long press on its close control shows the
      // control's tooltip instead, as before DF-086) and moves exactly one
      // tab width left (the ten tabs are equally wide), onto the tab before.
      const flingSwipe = async (touch) => {
        await touch('touchStart', 900, y);
        for (let k = 1; k <= 5; k++) { await touch('touchMove', 900 - 160 * k, y); await delay(16); }
        await touch('touchEnd', 100, y);
        await delay(FLING_WAIT);
      };
      const tabWidth = t0[1].left - t0[0].left;
      const endShift = (WIDE.width - 8) - t0[9].right;
      const labelX = (i, shift) => t0[i].left + shift + 100;
      for (const style of ['held', 'fling']) {
        for (const mode of MODES) {
          const results = [];
          for (let run = 1; run <= R7_RUNS; run++) {
            const { context, page } = await open({ active: LONG[0], names: LONG, semantics: mode === 'on', continueAt: cal.continueAt, contextOptions: { hasTouch: true } });
            try {
              const cdp = await context.newCDPSession(page);
              const touch = (type, x, yy) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x: Math.round(x), y: Math.round(yy) }] });
              await (style === 'held' ? swipe400(touch) : flingSwipe(touch));
              const swipe = await stored(page);
              const pressed = style === 'held' ? 3 : 7;
              const shift = style === 'held' ? swipeShift : endShift;
              const seen = mode === 'on' ? Math.round((await tabs(page))[0].left - t0[0].left) : null;
              const ax = labelX(pressed, shift);
              const bx = ax - tabWidth;
              await touch('touchStart', ax, y);
              await delay(800);
              if (SHOTS) await page.screenshot({ path: join(dirname(OUT), `r7-${style}-${mode}-${run}-a-pressed.png`), clip: { x: 0, y: 0, width: 1000, height: 60 } });
              for (let k = 1; k <= 10; k++) { await touch('touchMove', ax + ((bx - ax) * k) / 10, y); await delay(30); }
              if (SHOTS) await page.screenshot({ path: join(dirname(OUT), `r7-${style}-${mode}-${run}-b-dragging.png`), clip: { x: 0, y: 0, width: 1000, height: 60 } });
              await touch('touchEnd', bx, y);
              await delay(1500);
              const s = await stored(page);
              // Exactly one tab moved one place left, and it is active.
              const ok = same(swipe.names, LONG) && swipe.active === LONG[0] && same(s.names, moved(LONG, pressed, pressed - 1)) && s.active === LONG[pressed];
              let movedIndex = -1;
              for (let i = 1; i < LONG.length; i++) if (same(s.names, moved(LONG, i, i - 1))) movedIndex = i;
              const t = await layoutAfter(page);
              results.push({ run, ok: Boolean(ok), pressed, expectedShift: Math.round(shift), shiftSeenWithSemantics: seen, afterSwipe: { orderUnchanged: same(swipe.names, LONG), active: swipe.active }, movedIndex, storedActive: s.active, finalOrderShown: t.map((x) => x.label.slice(0, 2)).join(',') });
              console.log(`      r7 ${style} ${mode} run ${run}: ${ok ? 'applied' : 'NOT applied'} moved=${movedIndex} active=${s.active?.slice(0, 2)}`);
            } finally {
              await context.close();
            }
          }
          const applied = results.filter((r) => r.ok).length;
          check(rec, `RO-7b ${style} swipe, semantics ${mode}: the swipe scrolls without reordering, then a long-press drag applies (${applied}/${results.length})`, applied === results.length, { style, mode, applied, runs: results.length, results });
        }
      }
    });
  }
  // --- Drag rows on a short strip: RO-1..RO-5, RO-7, RO-13, RO-14 ----------
  //
  // Three documents, D-2 order, decision.md active. Positions come from one
  // semantics-on calibration (layout does not depend on the mode). Each
  // sub-case is a fresh context; semantics OFF is primary, ON is recorded.
  // The oracle is the stored order and active document.
  const CLOSE_RECTS = () => [...document.querySelectorAll('flt-semantics[role=button]')]
    .filter((n) => /^Close /.test((n.textContent || '').trim()))
    .map((n) => { const r = n.getBoundingClientRect(); return { name: (n.textContent || '').trim().split('\n')[0].slice(6), x: r.x + r.width / 2, y: r.y + r.height / 2 }; });

  async function calibrateShort() {
    const context = await browser.newContext({ viewport: WIDE });
    try {
      const page = await context.newPage();
      await page.goto(`${server.origin}/__seed-page-not-the-app`);
      await page.evaluate(SEED, seedValues('decision.md'));
      await page.goto(`${server.origin}/`);
      await page.waitForSelector('flt-semantics-placeholder', { state: 'attached', timeout: 90000 });
      await delay(1500);
      await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
      await delay(1200);
      const button = page.getByRole('button', { name: /Continue reading/ }).first();
      const box = await button.boundingBox();
      await button.click({ force: true });
      await delay(1800);
      return { continueAt: { x: box.x + box.width / 2, y: box.y + box.height / 2 }, tabs: await tabs(page), closes: await page.evaluate(CLOSE_RECTS) };
    } finally {
      await context.close();
    }
  }

  async function mouseDrag(page, from, to, { steps = 12 } = {}) {
    await page.mouse.move(from.x, from.y);
    await page.mouse.down();
    for (let k = 1; k <= steps; k++) { await page.mouse.move(from.x + ((to.x - from.x) * k) / steps, from.y + ((to.y - from.y) * k) / steps); await delay(30); }
    await page.mouse.up();
    await delay(1500);
  }

  /// Touch input: the DevTools protocol in Chromium; elsewhere, synthetic
  /// PointerEvents of type `touch` sent to the element under the point
  /// (Flutter's web engine reads pointer events). Both are simulated input.
  async function touchDriver(page, context) {
    if (BROWSER === 'chrome' || BROWSER === 'edge') {
      const cdp = await context.newCDPSession(page);
      return {
        kind: 'cdp',
        send: (type, x, y) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x: Math.round(x), y: Math.round(y) }] }),
      };
    }
    await page.evaluate(() => { window.__touchTarget = null; });
    return {
      kind: 'synthetic-pointer',
      send: (type, x, y) => page.evaluate(([t, px, py]) => {
        const name = { touchStart: 'pointerdown', touchMove: 'pointermove', touchEnd: 'pointerup' }[t];
        if (t === 'touchStart') window.__touchTarget = document.elementFromPoint(px, py);
        const target = window.__touchTarget ?? document.elementFromPoint(px, py);
        target.dispatchEvent(new PointerEvent(name, {
          pointerId: 7, pointerType: 'touch', isPrimary: true, bubbles: true, cancelable: true, composed: true,
          clientX: px, clientY: py, screenX: px, screenY: py, buttons: t === 'touchEnd' ? 0 : 1, button: 0, pressure: t === 'touchEnd' ? 0 : 0.5, width: 10, height: 10,
        }));
        if (t === 'touchEnd') window.__touchTarget = null;
      }, [type, x, y]),
    };
  }

  if (CASES.includes('drag')) {
    await runCase('drag (RO-1..RO-5, RO-7, RO-13, RO-14 on a short strip)', async (rec) => {
      const cal = await calibrateShort();
      const at = Object.fromEntries(cal.tabs.map((t) => [t.label, t]));
      const close = Object.fromEntries(cal.closes.map((c) => [c.name, c]));
      // Where each tab and its close control are for a given order (tabs sit
      // side by side from the first tab's left edge, each keeping its width).
      const layout = (order) => {
        let x = cal.tabs[0].left;
        const out = {};
        for (const name of order) {
          const t = at[name];
          out[name] = { x: x + t.w / 2, y: t.y, closeX: x + (close[name].x - t.left) };
          x += t.w;
        }
        return out;
      };
      note(rec, 'calibration', { continueAt: cal.continueAt, tabs: cal.tabs.map((t) => `${t.label}@${Math.round(t.x)}`), closes: cal.closes.map((c) => `${c.name}@${Math.round(c.x)}`) });
      for (const mode of MODES) {
        const sem = mode === 'on';
        const label = (s) => `${s} [semantics ${mode}]`;
        const run = async (body, contextOptions = {}) => {
          const { context, page } = await open({ active: 'decision.md', semantics: sem, continueAt: cal.continueAt, contextOptions });
          try { return await body(page, context); } finally { await context.close(); }
        };
        // RO-1 and RO-13: plan.md onto decision.md, then close the active tab.
        await run(async (page, context) => {
          await mouseDrag(page, at['plan.md'], at['decision.md']);
          const s = await stored(page);
          check(rec, label('RO-1 mouse-drag plan.md onto decision.md: plan | decision | implementation, plan.md active (D-004), stored'),
            same(s.names, ['plan.md', 'decision.md', 'implementation.md']) && s.active === 'plan.md', s);
          if (sem) {
            const t = await tabs(page);
            check(rec, label('RO-1 one tablist owns every tab after the drop'), t.length === 3 && t.every((x) => x.owner === 'tablist' && x.sameList && x.tablists === 1));
          }
          // plan.md (active, first) is closed: its right neighbour decision.md becomes active (D-11).
          const s4 = await stored(page);
          const first = layout(['plan.md', 'decision.md', 'implementation.md'])['plan.md'];
          await page.mouse.click(first.closeX, first.y);
          await delay(1500);
          const s2 = await stored(page);
          check(rec, label('RO-13 closing the active first tab after a reorder activates its right neighbour in the new order (D-11)'),
            s4.active === 'plan.md' && !s2.names.includes('plan.md') && s2.names[0] === 'decision.md' && s2.active === 'decision.md', { before: s4, after: s2 });
        });
        // RO-14: after a manual move, a file dropped on the Reader is appended after it.
        if (FILES && (BROWSER === 'chrome' || BROWSER === 'edge')) {
          await run(async (page, context) => {
            await mouseDrag(page, at['plan.md'], at['decision.md']);
            await mkdir(FILES, { recursive: true });
            const file = join(FILES, 'appendix.md');
            await writeFile(file, '# Appendix\n\nDropped on the Reader after a manual move.\n');
            const cdp = await context.newCDPSession(page);
            for (const type of ['dragEnter', 'dragOver', 'drop']) await cdp.send('Input.dispatchDragEvent', { type, x: 333, y: 450, data: { items: [], files: [file], dragOperationsMask: 1 } });
            await delay(2500);
            const s3 = await stored(page);
            check(rec, label('RO-14 a Reader drop after the manual move appends after it and becomes active'),
              same(s3.names, ['plan.md', 'decision.md', 'implementation.md', 'appendix.md']) && s3.active === 'appendix.md', s3);
          });
        }
        // RO-2: decision.md rightwards onto plan.md.
        await run(async (page) => {
          await mouseDrag(page, at['decision.md'], at['plan.md']);
          const s = await stored(page);
          check(rec, label('RO-2 mouse-drag rightwards takes the target place; dragged tab active'),
            same(s.names, ['implementation.md', 'plan.md', 'decision.md']) && s.active === 'decision.md', s);
        });
        // RO-3 and RO-4: a click selects; a drop on its own place only activates.
        await run(async (page) => {
          const before = await page.evaluate(STORED);
          await page.mouse.click(at['implementation.md'].x, at['implementation.md'].y);
          await delay(1200);
          const s = await stored(page);
          check(rec, label('RO-3 a click selects without reordering'), same(s.names, NAMES) && s.active === 'implementation.md', s);
          const p = at['plan.md'];
          await mouseDrag(page, p, { x: p.x + 24, y: p.y });
          const after = await page.evaluate(STORED);
          const s2 = decode(after);
          check(rec, label('RO-4 a drop on its own place activates it; the stored set is byte-identical'),
            s2.active === 'plan.md' && after.document === before.document, { s2 });
        });
        // RO-5: released off the strip.
        await run(async (page) => {
          const before = await page.evaluate(STORED);
          await mouseDrag(page, at['plan.md'], { x: 300, y: 400 });
          const after = await page.evaluate(STORED);
          check(rec, label('RO-5 a drag released off the strip changes nothing (stored set and active)'),
            after.document === before.document && decode(after).active === 'decision.md', decode(after));
        });
        // RO-6 / RO-7: a quick touch drag does not reorder; a long press then
        // drag (no prior swipe) does. Repeated in fresh contexts: with
        // semantics ON a long-press drag was found to fail intermittently
        // (risk R-7, routed to the Human); that mode is measured, not gated.
        const ro7 = [];
        for (let trial = 1; trial <= RO7_TRIALS; trial++) {
          await run(async (page, context) => {
            const touch = await touchDriver(page, context);
            const p = at['plan.md'];
            const d = at['decision.md'];
            await touch.send('touchStart', p.x, p.y);
            for (let k = 1; k <= 8; k++) { await touch.send('touchMove', p.x + ((d.x - p.x) * k) / 8, p.y); await delay(16); }
            await touch.send('touchEnd', d.x, p.y);
            await delay(1200);
            const s0 = await stored(page);
            await touch.send('touchStart', p.x, p.y);
            await delay(800);
            for (let k = 1; k <= 10; k++) { await touch.send('touchMove', p.x + ((d.x - p.x) * k) / 10, p.y); await delay(30); }
            await touch.send('touchEnd', d.x, p.y);
            await delay(1500);
            const s = await stored(page);
            ro7.push({ trial, kind: touch.kind, quickDragKeptOrder: same(s0.names, NAMES), longPressApplied: same(s.names, ['plan.md', 'decision.md', 'implementation.md']) && s.active === 'plan.md', stored: s });
          }, { hasTouch: true });
        }
        const kind = ro7[0]?.kind;
        const quick = ro7.filter((r) => r.quickDragKeptOrder).length;
        const applied = ro7.filter((r) => r.longPressApplied).length;
        console.log(`      RO-6/RO-7 ${mode}: quick drag kept order ${quick}/${ro7.length}; long press applied ${applied}/${ro7.length}`);
        check(rec, label(`RO-6 a quick touch drag does not reorder (${kind}) ${quick}/${ro7.length}`), quick === ro7.length, { ro7 });
        if (sem) {
          note(rec, label(`RO-7 touch long press then drag (${kind}): applied ${applied}/${ro7.length} - measured; R-7 semantics-on limitation routed to the Human`), { ro7 });
        } else {
          check(rec, label(`RO-7 touch long press then drag reorders; dragged tab active (${kind}) ${applied}/${ro7.length}`), applied === ro7.length, { ro7 });
        }
      }
    });
  }
} finally {
  await browser.close();
  await server.close();
}

evidence.finishedAt = new Date().toISOString();
evidence.summary = {
  cases: evidence.cases.length,
  checks: evidence.cases.reduce((n, c) => n + c.checks.length, 0),
  failures: evidence.failures.length,
};
await writeFile(OUT, JSON.stringify(evidence, null, 2) + '\n');
console.log(JSON.stringify(evidence.summary));
process.exitCode = evidence.failures.length ? 1 : 0;
