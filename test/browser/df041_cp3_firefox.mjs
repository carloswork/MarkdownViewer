// DF-041 Checkpoint-3 production browser evidence for Firefox / Gecko.
// Uses Firefox's WebDriver BiDi endpoint and introduces no npm dependency.

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';

import {
  delay,
  removeDirectory,
  serveBundle,
  waitForValue,
} from './df031_cdp.mjs';

function argument(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  if (index === -1) {
    if (fallback === undefined) throw new Error(`Missing --${name}`);
    return fallback;
  }
  return process.argv[index + 1];
}

const browserPath = resolve(argument('browser'));
const bundlePath = resolve(argument('bundle'));
const fixturePath = resolve(argument('fixture'));
const outputPath = resolve(argument('out'));
const screenshotDirectory = resolve(argument('screenshots', dirname(outputPath)));

const evidence = {
  ticket: 'DF-041',
  checkpoint: 3,
  harness: 'df041_cp3_firefox',
  transport: 'WebDriver BiDi',
  documentEntry: 'Paste Markdown (typed)',
  browserName: 'firefox',
  browserPath,
  sourceCommit: 'e8f038fbb6f4dd1bde27f418e9613964c8c8352e',
  startedAt: new Date().toISOString(),
  checks: [],
  failures: 0,
};
const runToken = evidence.startedAt.replace(/[^0-9]/g, '');

function record(name, pass, details = {}) {
  const check = { name, pass: Boolean(pass), ...details };
  evidence.checks.push(check);
  if (!pass) evidence.failures += 1;
  process.stdout.write(`${pass ? 'PASS' : 'FAIL'}  ${name}\n`);
}

class BidiSession {
  constructor(url) {
    this.socket = new WebSocket(url);
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = new Map();
  }

  async connect() {
    await new Promise((done, reject) => {
      this.socket.addEventListener('open', done, { once: true });
      this.socket.addEventListener('error', reject, { once: true });
    });
    this.socket.addEventListener('message', event => {
      const message = JSON.parse(event.data);
      if (message.type === 'event') {
        for (const listener of this.listeners.get(message.method) ?? []) listener(message.params);
        return;
      }
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.type === 'error') {
        pending.reject(new Error(`${pending.method}: ${message.error} ${message.message}`));
      } else {
        pending.resolve(message.result);
      }
    });
  }

  on(method, listener) {
    const listeners = this.listeners.get(method) ?? [];
    listeners.push(listener);
    this.listeners.set(method, listeners);
  }

  send(method, params = {}) {
    const id = this.nextId++;
    return new Promise((done, reject) => {
      this.pending.set(id, { resolve: done, reject, method });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  close() {
    try { this.socket.close(); } catch { /* already closed */ }
  }
}

async function launchFirefox(profile) {
  await mkdir(profile, { recursive: true });
  await writeFile(join(profile, 'user.js'), [
    'user_pref("layout.css.prefers-color-scheme.content-override", 1);',
    'user_pref("browser.shell.checkDefaultBrowser", false);',
    'user_pref("browser.startup.homepage_override.mstone", "ignore");',
    'user_pref("browser.sessionstore.resume_from_crash", false);',
    'user_pref("datareporting.policy.dataSubmissionEnabled", false);',
    'user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);',
    'user_pref("app.update.auto", false);',
    'user_pref("remote.prefs.recommended", true);',
  ].join('\n'));

  const child = spawn(browserPath, [
    '--headless',
    '--no-remote',
    '--new-instance',
    '--profile', profile,
    '--remote-debugging-port', '0',
    '--width', '1280',
    '--height', '900',
    'about:blank',
  ], { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });

  let output = '';
  child.stderr.setEncoding('utf8');
  child.stdout.setEncoding('utf8');
  child.stderr.on('data', chunk => { output += chunk; });
  child.stdout.on('data', chunk => { output += chunk; });
  const endpoint = await waitForValue(
    async () => output.match(/WebDriver BiDi listening on (ws:\/\/\S+)/)?.[1] ?? null,
    'Firefox WebDriver BiDi endpoint',
    60000,
  );
  const session = new BidiSession(`${endpoint}/session`);
  await session.connect();
  const created = await session.send('session.new', {
    capabilities: { alwaysMatch: { acceptInsecureCerts: true } },
  });
  const tree = await session.send('browsingContext.getTree', {});
  return {
    child,
    session,
    context: tree.contexts[0].context,
    capabilities: created.capabilities ?? null,
    startupOutput: output,
    async close() {
      await Promise.race([session.send('browser.close').catch(() => {}), delay(4000)]);
      session.close();
      await Promise.race([
        new Promise(done => (child.exitCode === null ? child.once('exit', done) : done())),
        delay(10000),
      ]);
      if (child.exitCode === null) child.kill();
      await delay(1000);
    },
  };
}

const semanticsProbe = `
  return JSON.stringify([...document.querySelectorAll('flt-semantics')].map(n => {
    const r = n.getBoundingClientRect();
    const describedby = (n.getAttribute('aria-describedby') || '')
      .split(/\\s+/).filter(Boolean)
      .map(id => document.getElementById(id)?.textContent ?? '')
      .join('\\n');
    return {
      role: n.getAttribute('role'),
      label: n.getAttribute('aria-label'),
      description: n.getAttribute('aria-description'),
      describedby: describedby || null,
      text: n.childNodes.length && n.firstChild.nodeType === 3 ? n.textContent : null,
      all: n.textContent || '',
      selected: n.getAttribute('aria-selected'),
      disabled: n.getAttribute('aria-disabled'),
      x: Math.round(r.x), y: Math.round(r.y),
      w: Math.round(r.width), h: Math.round(r.height),
    };
  }));
`;

const cspPreload = `() => {
  window.__df041Csp = [];
  document.addEventListener('securitypolicyviolation', event => {
    window.__df041Csp.push({ directive: event.violatedDirective, blocked: event.blockedURI });
  });
}`;

function haystack(node) {
  return [node.label, node.description, node.describedby, node.all]
    .filter(Boolean).join('\n');
}

// Persistent pane (360) plus divider (1); Reader semantics start at or after it.
const readerRegionStart = 361;

// Whether materialized Reader semantics contain the heading `Section k`. The
// Reader's lazily built block range is contiguous from the top, so an absent
// heading proves every block of that section is unbuilt. The active locator's
// `…, Section k` context is excluded.
function readerHasSectionHeading(nodes, section) {
  const heading = new RegExp(`(?<!, )Section ${section}(?!\\d)`);
  return nodes.some(node => node.x >= readerRegionStart && heading.test(node.all ?? ''));
}

class App {
  constructor(browser) {
    this.session = browser.session;
    this.context = browser.context;
  }

  async evaluate(expression) {
    const result = await this.session.send('script.evaluate', {
      expression: `(async () => { ${expression} })()`,
      target: { context: this.context },
      awaitPromise: true,
      resultOwnership: 'none',
    });
    if (result.type === 'exception') {
      throw new Error(`Page exception: ${JSON.stringify(result.exceptionDetails?.text ?? result)}`);
    }
    return result.result?.value;
  }

  async json(expression) {
    return JSON.parse(await this.evaluate(expression));
  }

  nodes() {
    return this.json(semanticsProbe);
  }

  firstLine(node) {
    return (node.text ?? node.label ?? node.all ?? '').split('\n')[0].trim();
  }

  mostSpecific(nodes) {
    return nodes.sort((a, b) => a.w * a.h - b.w * b.h)[0] ?? null;
  }

  async find(text) {
    return this.mostSpecific(
      (await this.nodes()).filter(node => haystack(node).includes(text) && node.w > 0 && node.h > 0),
    );
  }

  async exact(text) {
    return this.mostSpecific(
      (await this.nodes()).filter(node => this.firstLine(node) === text && node.w > 0 && node.h > 0),
    );
  }

  async waitFor(text, timeout = 15000) {
    return waitForValue(() => this.find(text), `semantics containing ${JSON.stringify(text)}`, timeout);
  }

  async activeElement() {
    return this.json(`
      const a = document.activeElement;
      const r = a?.getBoundingClientRect?.();
      const ancestors = [];
      for (let n = a; n && ancestors.length < 5; n = n.parentElement) {
        ancestors.push({
          tag: n.tagName ?? null,
          label: n.getAttribute?.('aria-label') ?? null,
          role: n.getAttribute?.('role') ?? null,
          text: n.textContent ?? null,
        });
      }
      return JSON.stringify({
        tag: a?.tagName ?? null,
        label: a?.getAttribute?.('aria-label') ?? null,
        role: a?.getAttribute?.('role') ?? null,
        text: a?.textContent ?? null,
        x: r ? Math.round(r.x) : null,
        y: r ? Math.round(r.y) : null,
        w: r ? Math.round(r.width) : null,
        h: r ? Math.round(r.height) : null,
        ancestors,
      });
    `);
  }

  async activeResultIndex(nodes) {
    const matching = (nodes ?? await this.nodes()).map(node => ({
      node,
      match: (node.label ?? '').match(/^Search results\. Result (\d+) of \d+ selected$/),
    })).filter(item => item.match);
    return matching.length ? Number(matching[0].match[1]) : null;
  }

  // Resolves the exact 48-pixel pane button, never its smaller hover tooltip.
  async paneControl(label) {
    return waitForValue(async () => this.mostSpecific((await this.nodes()).filter(node =>
      node.label === label &&
      node.w >= 44 && node.w <= 64 && node.h >= 44 && node.h <= 64 && node.x < readerRegionStart)),
    `pane ${label} control`, 8000);
  }

  // The Reader locator exposes its label as semantics text content.
  async locator(nodes) {
    for (const node of nodes ?? await this.nodes()) {
      const first = (node.label ?? node.all ?? '').split('\n')[0];
      const match = first.match(/^Search result (\d+) of (\d+)(?:, (.+))?$/);
      if (match) return { index: Number(match[1]), total: Number(match[2]), heading: match[3] ?? null };
    }
    return null;
  }

  activeRowVisibility(index, nodes) {
    const list = nodes.find(node => /^Search results\. Result \d+ of \d+ selected$/.test(node.label ?? ''));
    const row = this.mostSpecific(nodes.filter(node =>
      new RegExp(`^Result ${index} of \\d+\\.`).test(node.label ?? '') && node.w > 0 && node.h > 0));
    const visible = Boolean(list && row && row.h >= 40 &&
      row.y >= list.y - 1 && row.y + row.h <= list.y + list.h + 1);
    const rect = value => value && { x: value.x, y: value.y, w: value.w, h: value.h };
    return { visible, list: rect(list), row: rect(row) };
  }

  async stepPane(label, expected) {
    const before = await this.activeResultIndex();
    const control = await this.paneControl(label);
    await this.clickNode(control);
    await waitForValue(async () => {
      const nodes = await this.nodes();
      return (await this.activeResultIndex(nodes)) === expected &&
        (await this.locator(nodes))?.index === expected ? true : null;
    }, `${label} to result ${expected}`, 8000).catch(() => null);
    const nodes = await this.nodes();
    const locator = await this.locator(nodes);
    const visibility = this.activeRowVisibility(expected, nodes);
    return {
      label,
      before,
      expected,
      after: await this.activeResultIndex(nodes),
      locator: locator?.index ?? null,
      heading: locator?.heading ?? null,
      rowVisible: visibility.visible,
      row: visibility.row,
      list: visibility.list,
      control: { x: control.x, y: control.y, w: control.w, h: control.h },
    };
  }

  async searchField(timeout = 15000) {
    return waitForValue(async () => this.json(`
      const node = document.querySelector('input');
      if (!node) return JSON.stringify(null);
      const r = node.getBoundingClientRect();
      return JSON.stringify(r.width && r.height ? {
        role: 'textbox', label: node.getAttribute('aria-label'),
        x: Math.round(r.x), y: Math.round(r.y),
        w: Math.round(r.width), h: Math.round(r.height),
      } : null);
    `), 'Flutter search input element', timeout);
  }

  async clickNode(node) {
    await this.session.send('input.performActions', {
      context: this.context,
      actions: [{
        type: 'pointer', id: 'mouse', parameters: { pointerType: 'mouse' }, actions: [
          { type: 'pointerMove', x: Math.round(node.x + node.w / 2), y: Math.round(node.y + node.h / 2), origin: 'viewport', duration: 100 },
          { type: 'pause', duration: 120 },
          { type: 'pointerDown', button: 0 },
          { type: 'pause', duration: 120 },
          { type: 'pointerUp', button: 0 },
        ],
      }],
    });
    await delay(650);
  }

  async tap(text) {
    const node = await waitForValue(() => this.exact(text), `exact semantics ${JSON.stringify(text)}`, 15000);
    await this.clickNode(node);
    return node;
  }

  async key(...values) {
    const actions = [];
    for (const value of values) actions.push({ type: 'keyDown', value }, { type: 'keyUp', value });
    await this.session.send('input.performActions', {
      context: this.context,
      actions: [{ type: 'key', id: 'keyboard', actions }],
    });
    await delay(500);
  }

  async wheelAt(x, y, deltaY) {
    await this.session.send('input.performActions', {
      context: this.context,
      actions: [{
        type: 'wheel', id: 'wheel', actions: [
          { type: 'scroll', x: Math.round(x), y: Math.round(y), deltaX: 0, deltaY, duration: 0, origin: 'viewport' },
        ],
      }],
    });
    await delay(700);
  }

  async modifiedKey(modifier, value) {
    await this.session.send('input.performActions', {
      context: this.context,
      actions: [{ type: 'key', id: 'keyboard', actions: [
        { type: 'keyDown', value: modifier },
        { type: 'keyDown', value },
        { type: 'keyUp', value },
        { type: 'keyUp', value: modifier },
      ] }],
    });
    await delay(500);
  }

  async typeText(text) {
    const characters = [...text];
    for (let start = 0; start < characters.length; start += 250) {
      const actions = [];
      for (const character of characters.slice(start, start + 250)) {
        const value = character === '\n' ? '\uE007' : character;
        actions.push({ type: 'keyDown', value }, { type: 'keyUp', value });
      }
      await this.session.send('input.performActions', {
        context: this.context,
        actions: [{ type: 'key', id: 'keyboard', actions }],
      });
    }
  }

  async resize(width, height = 900) {
    await this.session.send('browsingContext.setViewport', {
      context: this.context,
      viewport: { width, height },
      devicePixelRatio: 1,
    });
    await delay(1300);
    return { width, height, nodes: await this.nodes() };
  }

  async screenshot(name) {
    const result = await this.session.send('browsingContext.captureScreenshot', {
      context: this.context,
      origin: 'viewport',
    });
    const path = join(screenshotDirectory, `firefox-${name}-${runToken}.png`);
    await writeFile(path, Buffer.from(result.data, 'base64'));
    return path;
  }

  async openReaderMenu() {
    const size = await this.json('return JSON.stringify({ w: innerWidth, h: innerHeight });');
    for (let attempt = 0; attempt < 3; attempt++) {
      const button = (await this.nodes()).find(node =>
        node.role === 'button' && !node.text && !node.label &&
        node.w > 20 && node.w <= 70 && node.h > 20 && node.h <= 70 &&
        node.x + node.w > size.w - 110 && node.y + node.h > size.h - 110);
      if (button) {
        await this.clickNode(button);
        if (await this.find('Return to main')) return;
      }
    }
    throw new Error('Reader menu did not open');
  }

  async pasteDocument(source) {
    await this.tap('Paste Markdown');
    await waitForValue(async () => (await this.nodes()).some(node => this.firstLine(node) === 'Open'), 'paste editor');
    await this.typeText(source);
    await delay(800);
    await this.tap('Open');
    await waitForValue(async () => !(await this.find('Paste Markdown')), 'Reader to open', 20000);
    await delay(1200);
  }

  async openSearchFromMenu() {
    await this.openReaderMenu();
    await this.tap('Search document');
    await this.searchField();
  }

  async typeSearch(text) {
    const field = await this.searchField();
    await this.clickNode(field);
    await this.typeText(text);
    await delay(900);
  }

  async replaceSearch(text) {
    const field = await this.searchField();
    await this.clickNode(field);
    await this.modifiedKey('\uE009', 'a');
    await this.typeText(text);
    await delay(900);
  }
}

await mkdir(dirname(outputPath), { recursive: true });
await mkdir(screenshotDirectory, { recursive: true });
const server = await serveBundle(bundlePath);
const profile = join(dirname(outputPath), `firefox-profile-${runToken}`);
let browser;

try {
  const executableBytes = await readFile(browserPath);
  const executableInfo = await stat(browserPath);
  const fixture = await readFile(fixturePath, 'utf8');
  const mainDartJs = await readFile(join(bundlePath, 'main.dart.js'));
  evidence.executable = {
    path: browserPath,
    bytes: executableInfo.size,
    sha256: createHash('sha256').update(executableBytes).digest('hex'),
    birthtime: executableInfo.birthtime.toISOString(),
    mtime: executableInfo.mtime.toISOString(),
  };
  evidence.bundle = {
    path: bundlePath,
    mainDartJsBytes: mainDartJs.length,
    mainDartJsSha256: createHash('sha256').update(mainDartJs).digest('hex'),
  };
  evidence.fixture = {
    path: fixturePath,
    bytes: Buffer.byteLength(fixture),
    sha256: createHash('sha256').update(fixture).digest('hex'),
    expectedSectionHeadings: [...fixture.matchAll(/^## Section \d+$/gm)].length,
    expectedLiteralOccurrences: [...fixture.matchAll(/Section/gi)].length,
  };

  browser = await launchFirefox(profile);
  evidence.capabilities = browser.capabilities;
  record('exact Firefox executable launches and exposes WebDriver BiDi',
    browser.capabilities?.browserName === 'firefox' && Boolean(browser.capabilities?.browserVersion),
    { capabilities: browser.capabilities, executable: evidence.executable });

  const session = browser.session;
  const offOrigin = [];
  let networkMonitored = true;
  session.on('network.beforeRequestSent', params => {
    if (params.context !== browser.context) return;
    const url = params.request?.url ?? '';
    if (!url.startsWith(server.origin) && !/^(data|blob|about|moz-extension|resource|chrome):/.test(url)) {
      offOrigin.push(url);
    }
  });
  try {
    await session.send('session.subscribe', { events: ['network.beforeRequestSent'] });
  } catch (error) {
    networkMonitored = false;
    evidence.networkSubscriptionError = String(error);
  }
  await session.send('script.addPreloadScript', { functionDeclaration: cspPreload });
  await session.send('browsingContext.setViewport', {
    context: browser.context,
    viewport: { width: 1280, height: 900 },
    devicePixelRatio: 1,
  });
  const app = new App(browser);
  await session.send('browsingContext.navigate', {
    context: browser.context,
    url: `${server.origin}/`,
    wait: 'complete',
  });
  await waitForValue(
    () => app.evaluate("return !!document.querySelector('flt-semantics-placeholder');"),
    'Flutter semantics bootstrap',
    45000,
  );
  await delay(2200);
  await app.evaluate("document.querySelector('flt-semantics-placeholder').click(); return 1;");
  await delay(1200);

  await app.pasteDocument(fixture);
  record('local fixture opens in Reader', !(await app.find('Paste Markdown')));
  await app.openSearchFromMenu();
  record('menu exposes Search document and opens search', Boolean(await app.searchField()));
  await app.typeSearch('Section');
  const count = await waitForValue(async () => {
    const node = (await app.nodes()).find(item => /^\d+ results$/.test(app.firstLine(item)));
    return node ? Number(app.firstLine(node).match(/^(\d+) results$/)?.[1]) : null;
  }, 'search result count', 15000);
  record('complete-document literal search finds every Section occurrence',
    count === evidence.fixture.expectedLiteralOccurrences,
    {
      count,
      expectedLiteralOccurrences: evidence.fixture.expectedLiteralOccurrences,
      expectedSectionHeadings: evidence.fixture.expectedSectionHeadings,
    });

  const firstRow = await waitForValue(async () => (await app.nodes()).find(node =>
    /^Result 1 of \d+\./.test(node.label ?? '') && node.w > 0 && node.h > 0), 'first result row');
  await app.clickNode(firstRow);
  const firstLocator = await app.waitFor('Search result 1 of', 15000);
  record('result-row selection updates the Reader block locator', Boolean(firstLocator), {
    selectedRow: firstRow,
    readerLocator: firstLocator,
  });

  const wideField = await app.searchField();
  const widePrevious = await app.paneControl('Previous result');
  const wideNext = await app.paneControl('Next result');
  record('1280 layout uses persistent pane controls',
    Boolean(wideField && widePrevious && wideNext && wideField.x < 400),
    { field: wideField, previous: widePrevious, next: wideNext });

  // Row selection moves focus to the Reader locator, so the shortcut starts
  // from outside the search input.
  const startNodes = await app.nodes();
  const beforeShortcut = await app.activeElement();
  await app.modifiedKey('\uE009', 'f');
  const afterShortcut = await app.activeElement();
  record('Ctrl+F is delivered to the app, suppresses browser Find, and focuses the search input',
    beforeShortcut.tag !== 'INPUT' &&
      (afterShortcut.tag === 'INPUT' || /Find in document/i.test(afterShortcut.label ?? '')),
    { beforeShortcut, afterShortcut });

  // Pane Next steps one result at a time until it reaches N >= 12 whose owning
  // section heading was absent from the Reader semantics captured before navigation.
  const navigationTrace = [];
  let current = await app.activeResultIndex(startNodes);
  let distant = null;
  for (let step = 0; current !== null && step < 80; step++) {
    const entry = await app.stepPane('Next result', current + 1);
    navigationTrace.push(entry);
    if (entry.after !== current + 1 || entry.locator !== current + 1) break;
    current += 1;
    const section = Number(entry.heading?.match(/^Section (\d+)$/)?.[1] ?? NaN);
    if (current >= 12 && section >= 2 && !readerHasSectionHeading(startNodes, section)) {
      distant = { index: current, section, absentStartHeading: `Section ${section}` };
      break;
    }
  }
  if (distant) {
    distant.sectionHeadingPresentAfterNavigation = readerHasSectionHeading(await app.nodes(), distant.section);
  }
  const stepsValid = entries => entries.every(entry =>
    entry.after === entry.expected && entry.locator === entry.expected);
  record('pane Next steps one result at a time to a distant initially non-materialized result',
    Boolean(distant) && distant.index >= 12 && distant.sectionHeadingPresentAfterNavigation &&
      navigationTrace.length > 0 && navigationTrace[0].before === 1 && stepsValid(navigationTrace),
    { distant, navigationTrace });

  const distantIndex = distant?.index ?? current;
  const previousStep = await app.stepPane('Previous result', distantIndex - 1);
  const nextStep = await app.stepPane('Next result', distantIndex);
  record('pane Previous and Next move the selected result and block locator by exactly one',
    stepsValid([previousStep, nextStep]), { previousStep, nextStep });
  // Wheel the results list past the active row, then step toward the side the
  // list was scrolled away from: Next with the row above the top edge, then
  // Previous with the row below the bottom edge.
  const oppositeEdge = [];
  for (const [label, direction] of [['Next result', 1], ['Previous result', -1]]) {
    const before = await app.activeResultIndex();
    const { list } = app.activeRowVisibility(before, await app.nodes());
    await app.wheelAt(list.x + list.w / 2, list.y + list.h / 2, direction * (list.h + 24));
    const expected = before + direction;
    const nodesBeforeStep = await app.nodes();
    const activeHiddenBeforeStep = !app.activeRowVisibility(before, nodesBeforeStep).visible;
    const targetBefore = app.activeRowVisibility(expected, nodesBeforeStep);
    const entry = await app.stepPane(label, expected);
    // Semantics rects are clipped to the list viewport, so a partly hidden row
    // reports a shorter rect than its full height once revealed.
    const targetHiddenBeforeStep = !targetBefore.row ||
      Boolean(entry.row && targetBefore.row.h < entry.row.h - 0.5);
    oppositeEdge.push({ ...entry, activeHiddenBeforeStep, targetHiddenBeforeStep, targetRowBeforeStep: targetBefore.row });
  }
  record('pane results list reveals the active row after the list is scrolled past it',
    oppositeEdge.every(entry => entry.activeHiddenBeforeStep && entry.targetHiddenBeforeStep &&
      entry.rowVisible) && stepsValid(oppositeEdge),
    { oppositeEdge });
  const paneSteps = [...navigationTrace, previousStep, nextStep, ...oppositeEdge];
  record('pane results list keeps each newly active row visible during Previous/Next',
    paneSteps.length > 12 && paneSteps.every(entry => entry.rowVisible),
    { steps: paneSteps.length, hidden: paneSteps.filter(entry => !entry.rowVisible) });
  const wideScreenshot = await app.screenshot('wide-light');

  await app.replaceSearch('Section 40');
  await waitForValue(async () => (await app.nodes()).some(node => /1 result/.test(haystack(node))), 'single result');
  await app.key('\uE007');
  await app.waitFor('Search result 1 of 1', 10000);
  await app.clickNode(await app.searchField());
  await app.key('\uE004');
  await app.key('\uE004');
  await app.key('\uE004');
  const paneNextBeforeTransition = await app.activeElement();

  const boundary = [];
  await app.resize(1080);
  const modalFocusFromNext = await app.activeElement();
  for (const width of [1080, 1081, 1082, 2560]) {
    const state = width === 1080 ? { width, nodes: await app.nodes() } : await app.resize(width);
    const labels = state.nodes.map(haystack);
    boundary.push({
      width,
      hasField: Boolean(await app.searchField()),
      hasPrevious: labels.some(value => value.includes('Previous result')),
      hasNext: labels.some(value => value.includes('Next result')),
      selectedResult: await app.activeResultIndex(state.nodes),
    });
  }
  const paneFocusAfterDisposal = await app.activeElement();
  evidence.boundary = boundary;
  record('1080 is modal and excludes modal Previous/Next',
    boundary[0].hasField && !boundary[0].hasPrevious && !boundary[0].hasNext);
  record('1081, 1082, and 2560 use pane Previous/Next',
    boundary.slice(1).every(item => item.hasField && item.hasPrevious && item.hasNext));
  record('live responsive crossings preserve the selected result',
    boundary.every(item => item.selectedResult === 1));
  record('pane Next logical focus maps to the selected modal row and restores to pane Next',
    JSON.stringify(paneNextBeforeTransition).includes('Next result') &&
      JSON.stringify(modalFocusFromNext).includes('Result 1 of 1') &&
      JSON.stringify(paneFocusAfterDisposal).includes('Next result'),
    { paneNextBeforeTransition, modalFocusFromNext, paneFocusAfterDisposal });

  await app.resize(1280);
  await app.clickNode(await app.searchField());
  await app.key('\uE004');
  await app.key('\uE004');
  const panePreviousBeforeTransition = await app.activeElement();
  await app.resize(390, 844);
  const modalFocusFromPrevious = await app.activeElement();
  const mobileNodes = await app.nodes();
  const mobileField = await app.searchField();
  record('mobile modal contains no Previous/Next',
    Boolean(mobileField) &&
      !mobileNodes.some(node => haystack(node).includes('Previous result')) &&
      !mobileNodes.some(node => haystack(node).includes('Next result')));
  const mobileTargets = [
    mobileNodes.find(node => node.label === 'Close results'),
    mobileNodes.find(node => /^Result \d+ of \d+\./.test(node.label ?? '')),
  ].filter(Boolean);
  record('visible mobile search targets meet 48 logical pixels',
    mobileField.w >= 48 && mobileField.h >= 48 &&
      mobileTargets.length > 0 && mobileTargets.every(node => node.w >= 48 && node.h >= 48),
    { field: mobileField, targets: mobileTargets });
  const mobileScreenshot = await app.screenshot('mobile-light');
  await app.key('\uE00C');
  const compactReopen = await app.waitFor('Show search results', 8000).catch(() => null);
  const compactNodes = await app.nodes();
  const compactFocusAfterDismissal = await app.activeElement();
  record('narrow Escape dismisses the sheet to an inert-safe compact navigator',
    Boolean(compactReopen) &&
      compactNodes.some(node => haystack(node).includes('Previous result')) &&
      compactNodes.some(node => haystack(node).includes('Next result')),
    { compactReopen, compactFocusAfterDismissal });
  record('pane Previous logical focus maps to the selected modal row and restores to compact Previous',
    JSON.stringify(panePreviousBeforeTransition).includes('Previous result') &&
      JSON.stringify(modalFocusFromPrevious).includes('Result 1 of 1') &&
      JSON.stringify(compactFocusAfterDismissal).includes('Previous result'),
    { panePreviousBeforeTransition, modalFocusFromPrevious, compactFocusAfterDismissal });

  await app.clickNode(compactReopen);
  await app.replaceSearch('Section 40');
  await waitForValue(async () => (await app.nodes()).some(node => /1 result/.test(haystack(node))), 'single result');
  const traversal = [await app.activeElement()];
  await app.key('\uE004');
  traversal.push(await app.activeElement());
  await app.key('\uE004');
  traversal.push(await app.activeElement());
  record('modal keyboard traversal is search field, ordered result row, then Close',
    (traversal[0].tag === 'INPUT' || /Find in document/i.test(traversal[0].label ?? '')) &&
      JSON.stringify(traversal[1]).includes('Result 1 of 1') &&
      JSON.stringify(traversal[2]).includes('Close results'),
    { traversal });

  const closeResults = await app.find('Close results');
  await app.clickNode(closeResults);
  const closeSearch = await app.waitFor('Close search', 8000);
  await app.clickNode(closeSearch);
  await app.openReaderMenu();
  await app.tap('Appearance');
  await app.tap('Dark');
  await app.key('\uE00C');
  await app.openSearchFromMenu();
  await app.typeSearch('Section');
  await waitForValue(async () => (await app.nodes()).some(node => /\d+ results/.test(haystack(node))), 'dark results');
  const mobileDarkScreenshot = await app.screenshot('mobile-dark');
  const lightPixels = await readFile(mobileScreenshot);
  const darkPixels = await readFile(mobileDarkScreenshot);
  const lightSha256 = createHash('sha256').update(lightPixels).digest('hex');
  const darkSha256 = createHash('sha256').update(darkPixels).digest('hex');
  record('Appearance control produces distinct light and dark search rendering',
    lightSha256 !== darkSha256, { lightSha256, darkSha256 });
  evidence.screenshots = { wideLight: wideScreenshot, mobileLight: mobileScreenshot, mobileDark: mobileDarkScreenshot };

  evidence.cspViolations = await app.json('return JSON.stringify(window.__df041Csp ?? null);');
  evidence.networkMonitored = networkMonitored;
  evidence.offOriginRequests = offOrigin;
  record('search causes no Content-Security-Policy violation',
    Array.isArray(evidence.cspViolations) && evidence.cspViolations.length === 0,
    { violations: evidence.cspViolations });
  record('search causes no off-origin request',
    networkMonitored && offOrigin.length === 0,
    { networkMonitored, offOrigin });

  await session.send('browsingContext.reload', { context: browser.context, wait: 'complete' });
  await delay(3500);
  await app.evaluate("document.querySelector('flt-semantics-placeholder')?.click(); return 1;");
  await delay(1200);
  const afterReload = await app.nodes();
  record('refresh/remount clears the non-retained document and search session',
    afterReload.some(node => haystack(node).includes('Paste Markdown')) &&
      !afterReload.some(node => haystack(node).includes('Find in document')));
} catch (error) {
  evidence.fatal = String(error?.stack ?? error);
  evidence.failures += 1;
  process.stderr.write(`${evidence.fatal}\n`);
} finally {
  evidence.serverRequests = server.requestLog;
  evidence.finishedAt = new Date().toISOString();
  evidence.passed = evidence.failures === 0;
  await writeFile(outputPath, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');
  if (browser) await browser.close();
  await server.close();
  await delay(100);
  await removeDirectory(profile);
  process.stdout.write(`${evidence.passed ? 'ALL PASSED' : `${evidence.failures} FAILURE(S)`} - ${outputPath}\n`);
  process.exitCode = evidence.passed ? 0 : 1;
}
