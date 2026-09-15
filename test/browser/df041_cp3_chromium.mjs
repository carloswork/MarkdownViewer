// DF-041 Checkpoint-3 production browser evidence for Chromium-family browsers.
// Uses the repository's raw-CDP helper and introduces no npm dependency.

import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { inflateSync } from 'node:zlib';

import {
  delay,
  launchChromium,
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
const browserName = argument('name');
const bundlePath = resolve(argument('bundle'));
const fixturePath = resolve(argument('fixture'));
const outputPath = resolve(argument('out'));
const screenshotDirectory = resolve(argument('screenshots', dirname(outputPath)));

const evidence = {
  ticket: 'DF-041',
  checkpoint: 3,
  harness: 'df041_cp3_chromium',
  transport: 'Chrome DevTools Protocol',
  browserName,
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

const semanticsProbe = `
  return [...document.querySelectorAll('flt-semantics')].map(n => {
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
      checked: n.getAttribute('aria-checked'),
      pressed: n.getAttribute('aria-pressed'),
      disabled: n.getAttribute('aria-disabled'),
      x: Math.round(r.x), y: Math.round(r.y),
      w: Math.round(r.width), h: Math.round(r.height),
    };
  });
`;

function haystack(node) {
  return [node.label, node.description, node.describedby, node.all]
    .filter(Boolean).join('\n');
}

// Persistent pane (360) plus divider (1); Reader semantics start at or after it.
const readerRegionStart = 361;
const pad = value => String(value).padStart(2, '0');

// Section-end markers present in materialized Reader semantics. The Reader's
// lazily built block range is contiguous from the top, so a missing end marker
// for section k-1 proves every block of section k is unbuilt.
function readerSectionMarkers(nodes, kind) {
  const found = new Set();
  for (const node of nodes) {
    if (node.x < readerRegionStart) continue;
    for (const match of (node.all ?? '').matchAll(new RegExp(`SECTION-(\\d\\d)-${kind}`, 'g'))) {
      found.add(match[1]);
    }
  }
  return found;
}

function paeth(a, b, c) {
  const p = a + b - c;
  const pa = Math.abs(p - a);
  const pb = Math.abs(p - b);
  const pc = Math.abs(p - c);
  return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
}

// Dependency-free PNG decoder for the 8-bit RGB/RGBA screenshots emitted by
// Chromium. Average luminance is an observable palette check, not a visual
// regression oracle.
function averagePngLuminance(png) {
  const signature = png.subarray(0, 8).toString('hex');
  if (signature !== '89504e470d0a1a0a') throw new Error('Unexpected screenshot format');
  let offset = 8;
  let width;
  let height;
  let bitDepth;
  let colorType;
  let interlace;
  const idat = [];
  while (offset < png.length) {
    const length = png.readUInt32BE(offset);
    const type = png.subarray(offset + 4, offset + 8).toString('ascii');
    const data = png.subarray(offset + 8, offset + 8 + length);
    if (type === 'IHDR') {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      bitDepth = data[8];
      colorType = data[9];
      interlace = data[12];
    } else if (type === 'IDAT') {
      idat.push(data);
    } else if (type === 'IEND') {
      break;
    }
    offset += length + 12;
  }
  const channels = colorType === 6 ? 4 : colorType === 2 ? 3 : colorType === 0 ? 1 : null;
  if (!width || !height || bitDepth !== 8 || channels === null || interlace !== 0) {
    throw new Error(`Unsupported PNG: ${width}x${height}, depth ${bitDepth}, type ${colorType}, interlace ${interlace}`);
  }
  const rowBytes = width * channels;
  const raw = inflateSync(Buffer.concat(idat));
  let source = 0;
  let previous = Buffer.alloc(rowBytes);
  let luminance = 0;
  let samples = 0;
  for (let y = 0; y < height; y++) {
    const filter = raw[source++];
    const row = Buffer.alloc(rowBytes);
    for (let x = 0; x < rowBytes; x++) {
      const encoded = raw[source++];
      const left = x >= channels ? row[x - channels] : 0;
      const up = previous[x];
      const upperLeft = x >= channels ? previous[x - channels] : 0;
      let predictor;
      switch (filter) {
        case 0: predictor = 0; break;
        case 1: predictor = left; break;
        case 2: predictor = up; break;
        case 3: predictor = Math.floor((left + up) / 2); break;
        case 4: predictor = paeth(left, up, upperLeft); break;
        default: throw new Error(`Unsupported PNG filter ${filter}`);
      }
      row[x] = (encoded + predictor) & 0xff;
    }
    for (let x = 0; x < width; x += 4) {
      const pixel = x * channels;
      const r = row[pixel];
      const g = channels === 1 ? r : row[pixel + 1];
      const b = channels === 1 ? r : row[pixel + 2];
      luminance += 0.2126 * r + 0.7152 * g + 0.0722 * b;
      samples += 1;
    }
    previous = row;
  }
  return { width, height, average: luminance / samples };
}

class App {
  constructor(session, chooser) {
    this.session = session;
    this.chooser = chooser;
  }

  nodes() {
    return this.session.evaluate(semanticsProbe);
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

  // Resolves the exact 48-pixel pane button, never its smaller hover tooltip.
  async paneControl(label) {
    return waitForValue(async () => this.mostSpecific((await this.nodes()).filter(node =>
      node.label === label &&
      node.w >= 44 && node.w <= 64 && node.h >= 44 && node.h <= 64 && node.x < readerRegionStart)),
    `pane ${label} control`, 8000);
  }

  // Selection-dependent result state exposed by the results list itself.
  async selectedResult() {
    for (const node of await this.nodes()) {
      const match = (node.label ?? '').match(/^Search results\. Result (\d+) of \d+ selected$/);
      if (match) return Number(match[1]);
    }
    return null;
  }

  // The Reader locator exposes its label as semantics text content.
  async locator() {
    for (const node of await this.nodes()) {
      const first = (node.label ?? node.all ?? '').split('\n')[0];
      const match = first.match(/^Search result (\d+) of (\d+)(?:, (.+))?$/);
      if (match) return { index: Number(match[1]), total: Number(match[2]), heading: match[3] ?? null };
    }
    return null;
  }

  async activeRowVisibility(index, nodes) {
    const all = nodes ?? await this.nodes();
    const list = all.find(node => /^Search results\. Result \d+ of \d+ selected$/.test(node.label ?? ''));
    const row = this.mostSpecific(all.filter(node =>
      new RegExp(`^Result ${index} of \\d+\\.`).test(node.label ?? '') && node.w > 0 && node.h > 0));
    const visible = Boolean(list && row && row.h >= 40 &&
      row.y >= list.y - 1 && row.y + row.h <= list.y + list.h + 1);
    const rect = value => value && { x: value.x, y: value.y, w: value.w, h: value.h };
    return { visible, list: rect(list), row: rect(row) };
  }

  async stepPane(label, expected) {
    const before = await this.selectedResult();
    const control = await this.paneControl(label);
    await this.clickNode(control);
    const settled = await waitForValue(async () => {
      const selected = await this.selectedResult();
      const locator = await this.locator();
      return selected === expected && locator?.index === expected ? { selected, locator } : null;
    }, `${label} to result ${expected}`, 8000).catch(() => null);
    const nodes = await this.nodes();
    const visibility = await this.activeRowVisibility(expected, nodes);
    const locator = settled?.locator ?? await this.locator();
    return {
      label,
      before,
      expected,
      after: settled?.selected ?? await this.selectedResult(),
      locator: locator?.index ?? null,
      heading: locator?.heading ?? null,
      rowVisible: visibility.visible,
      row: visibility.row,
      list: visibility.list,
      control: { x: control.x, y: control.y, w: control.w, h: control.h },
    };
  }

  async appearanceSelection(label) {
    const candidates = (await this.nodes()).filter(node =>
      haystack(node).includes(label) && node.w > 0 && node.h > 0);
    return {
      selected: candidates.some(node =>
        node.selected === 'true' || node.checked === 'true' || node.pressed === 'true'),
      candidates,
    };
  }

  async storedAppearance() {
    return this.session.evaluate(`
      const dbs = indexedDB.databases ? await indexedDB.databases() : [];
      if (!dbs.some(d => d.name === 'markdown_viewer')) return null;
      const db = await new Promise((resolve, reject) => {
        const request = indexedDB.open('markdown_viewer');
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
      });
      const storeName = db.objectStoreNames[0];
      const raw = await new Promise((resolve, reject) => {
        const request = db.transaction(storeName, 'readonly').objectStore(storeName).get('settings');
        request.onsuccess = () => resolve(request.result ?? null);
        request.onerror = () => reject(request.error);
      });
      db.close();
      if (raw == null) return null;
      try { return JSON.parse(raw).appearance ?? null; } catch { return null; }
    `);
  }

  async searchField(timeout = 15000) {
    return waitForValue(() => this.session.evaluate(`
      const node = document.querySelector('input');
      if (!node) return null;
      const rect = node.getBoundingClientRect();
      if (!rect.width || !rect.height) return null;
      return {
        role: 'textbox',
        label: node.getAttribute('aria-label'),
        x: Math.round(rect.x), y: Math.round(rect.y),
        w: Math.round(rect.width), h: Math.round(rect.height),
      };
    `), 'Flutter search input element', timeout);
  }

  async clickNode(node) {
    const x = node.x + node.w / 2;
    const y = node.y + node.h / 2;
    await this.session.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y, button: 'none', buttons: 0 });
    await this.session.send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1 });
    await delay(60);
    await this.session.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', buttons: 0, clickCount: 1 });
    await delay(650);
  }

  async tap(text) {
    const node = await waitForValue(() => this.exact(text), `exact semantics ${JSON.stringify(text)}`, 15000);
    await this.clickNode(node);
    return node;
  }

  async openReaderMenu() {
    const size = await this.session.evaluate('return { w: innerWidth, h: innerHeight };');
    for (let attempt = 0; attempt < 3; attempt++) {
      const button = (await this.nodes()).find(node =>
        node.role === 'button' && !node.text && !node.label &&
        node.w > 20 && node.w <= 70 && node.h > 20 && node.h <= 70 &&
        node.x + node.w > size.w - 110 && node.y + node.h > size.h - 110);
      if (button) {
        await this.clickNode(button);
        if (await this.find('Return to main')) return;
      }
      await this.wheel(-120);
    }
    throw new Error('Reader menu did not open');
  }

  async loadFixture() {
    this.chooser.value = null;
    await this.tap('Load from file');
    const opened = await waitForValue(() => this.chooser.value, 'file chooser', 8000);
    await this.session.send('DOM.setFileInputFiles', {
      files: [fixturePath],
      backendNodeId: opened.backendNodeId,
    });
    await delay(1800);
    const replace = await this.exact('Replace');
    if (replace) await this.clickNode(replace);
    await waitForValue(async () => !(await this.find('Load from file')), 'Reader to open', 20000);
    await delay(1200);
  }

  async openSearchFromMenu() {
    await this.openReaderMenu();
    await this.tap('Search document');
    await delay(1800);
    evidence.searchAfterMenu = await this.nodes();
    await this.searchField();
  }

  async type(text) {
    const field = await this.searchField();
    await this.clickNode(field);
    await this.session.send('Input.insertText', { text });
    await delay(900);
  }

  async key(key, modifiers = 0) {
    const code = key.length === 1 ? `Key${key.toUpperCase()}` : key;
    const virtual = key === 'Enter' ? 13 : key === 'Escape' ? 27 : key.toUpperCase().charCodeAt(0);
    for (const type of ['keyDown', 'keyUp']) {
      await this.session.send('Input.dispatchKeyEvent', {
        type, key, code, modifiers,
        windowsVirtualKeyCode: virtual,
        nativeVirtualKeyCode: virtual,
      });
    }
    await delay(500);
  }

  // Physical-keyboard event shape: a synthetic F carrying only a modifier flag
  // is not recognized as Ctrl+F by Flutter's keyboard converter.
  async controlShortcut(letter) {
    const control = { key: 'Control', code: 'ControlLeft', windowsVirtualKeyCode: 17, nativeVirtualKeyCode: 17, location: 1 };
    const virtual = letter.toUpperCase().charCodeAt(0);
    const target = { key: letter, code: `Key${letter.toUpperCase()}`, windowsVirtualKeyCode: virtual, nativeVirtualKeyCode: virtual };
    await this.session.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', modifiers: 2, ...control });
    await this.session.send('Input.dispatchKeyEvent', { type: 'rawKeyDown', modifiers: 2, ...target });
    await this.session.send('Input.dispatchKeyEvent', { type: 'keyUp', modifiers: 2, ...target });
    await this.session.send('Input.dispatchKeyEvent', { type: 'keyUp', modifiers: 0, ...control });
    await delay(900);
  }

  async wheelAt(x, y, deltaY) {
    await this.session.send('Input.dispatchMouseEvent', {
      type: 'mouseWheel', x: Math.round(x), y: Math.round(y), deltaX: 0, deltaY, button: 'none', buttons: 0,
    });
    await delay(700);
  }

  async wheel(pixels) {
    const size = await this.session.evaluate('return { w: innerWidth, h: innerHeight };');
    const x = Math.round(size.w / 2);
    const y = Math.round(size.h / 2);
    await this.session.send('Input.dispatchMouseEvent', { type: 'mouseWheel', x, y, deltaX: 0, deltaY: pixels, button: 'none', buttons: 0 });
    await delay(700);
  }

  async resize(width, height = 900) {
    await this.session.send('Emulation.setDeviceMetricsOverride', {
      width, height, deviceScaleFactor: 1, mobile: width < 600,
    });
    await delay(1300);
    return { width, height, nodes: await this.nodes() };
  }

  async screenshot(name) {
    const result = await this.session.send('Page.captureScreenshot', { format: 'png', fromSurface: true });
    const path = join(screenshotDirectory, `${browserName}-${name}-${runToken}.png`);
    await writeFile(path, Buffer.from(result.data, 'base64'));
    return path;
  }
}

await mkdir(dirname(outputPath), { recursive: true });
await mkdir(screenshotDirectory, { recursive: true });
const server = await serveBundle(bundlePath);
const browser = await launchChromium(browserPath, { windowSize: '1280,900' });
const session = browser.session;
const chooser = { value: null };
const offOrigin = [];
session.on('Page.fileChooserOpened', params => { chooser.value = params; });
session.on('Network.requestWillBeSent', ({ request }) => {
  if (!request.url.startsWith(server.origin) && !/^(data|blob|about|chrome|edge|devtools):/.test(request.url)) {
    offOrigin.push(request.url);
  }
});

try {
  await session.send('Runtime.enable');
  await session.send('Page.enable');
  await session.send('DOM.enable');
  await session.send('Network.enable');
  await session.send('Page.addScriptToEvaluateOnNewDocument', { source: `
    window.__df041Csp = [];
    document.addEventListener('securitypolicyviolation', event => {
      window.__df041Csp.push({ directive: event.violatedDirective, blocked: event.blockedURI });
    });
  ` });
  await session.send('Page.setInterceptFileChooserDialog', { enabled: true });
  evidence.browserVersion = await session.send('Browser.getVersion');
  evidence.bundle = {
    path: bundlePath,
    mainDartJsBytes: (await readFile(join(bundlePath, 'main.dart.js'))).length,
    mainDartJsSha256: createHash('sha256').update(await readFile(join(bundlePath, 'main.dart.js'))).digest('hex'),
  };
  evidence.fixture = {
    path: fixturePath,
    bytes: (await readFile(fixturePath)).length,
    sha256: createHash('sha256').update(await readFile(fixturePath)).digest('hex'),
  };

  await session.send('Page.navigate', { url: `${server.origin}/` });
  await waitForValue(
    () => session.evaluate("return !!document.querySelector('flt-semantics-placeholder');"),
    'Flutter semantics bootstrap', 30000,
  );
  await delay(2200);
  await session.evaluate("document.querySelector('flt-semantics-placeholder').click(); return 1;");
  await delay(1200);
  const app = new App(session, chooser);

  await app.loadFixture();
  record('local fixture opens in Reader', !(await app.find('Load from file')));
  await app.openReaderMenu();
  await app.tap('Appearance');
  await app.tap('Light');
  const lightAppearance = await waitForValue(async () => {
    const stored = await app.storedAppearance();
    return stored === 'light' ? stored : null;
  }, 'explicit Light appearance selection', 10000);
  const lightSelection = await app.appearanceSelection('Light');
  record('product Appearance explicitly selects Light', lightAppearance === 'light', {
    storedAppearance: lightAppearance,
    semantics: lightSelection,
  });
  await app.key('Escape');
  await app.openSearchFromMenu();
  record('menu exposes Search document and opens search', Boolean(await app.searchField()));
  await app.type('Section');
  const expectedCount = evidence.fixture.sha256 ===
    'b1be2fa141d3d1a5339b4b02ed229e6e283cb73e7a9a12ca452a6597e82d06f1' ? 391 : null;
  const count = await waitForValue(async () => {
    const node = (await app.nodes()).find(n => /^\d+ results$/.test(app.firstLine(n)));
    return node ? Number(app.firstLine(node).match(/^(\d+) results$/)[1]) : null;
  }, 'exact result count', 15000);
  record('literal query returns the exact retained-fixture count',
    expectedCount !== null && count === expectedCount, { count, expectedCount });

  const field = await app.searchField();
  const previous = await app.paneControl('Previous result');
  const next = await app.paneControl('Next result');
  record('1280 layout uses persistent pane controls', Boolean(field && previous && next && field.x < 400), {
    field, previous, next,
  });

  const firstRow = await waitForValue(async () => (await app.nodes()).find(n =>
    /^Result 1 of \d+\./.test(n.label ?? '') && n.w > 0 && n.h > 0), 'first result row');
  await app.clickNode(firstRow);
  const firstLocator = await waitForValue(async () => {
    const locator = await app.locator();
    return locator?.index === 1 && (await app.selectedResult()) === 1 ? locator : null;
  }, 'result 1 locator after row selection', 10000).catch(() => null);
  record('result-row selection selects result 1 and updates the Reader block locator',
    firstLocator?.index === 1 && firstLocator?.total === count,
    { selectedRow: firstRow, readerLocator: firstLocator });
  const startNodes = await app.nodes();
  const startEndMarkers = readerSectionMarkers(startNodes, 'END');

  const activeElement = () => session.evaluate(`
    const a = document.activeElement;
    return { tag: a?.tagName ?? null, label: a?.getAttribute?.('aria-label') ?? null, role: a?.getAttribute?.('role') ?? null };
  `);
  const beforeShortcut = await activeElement();
  await app.controlShortcut('f');
  const afterShortcut = await activeElement();
  record('Ctrl+F is delivered to the app and moves focus from outside into the search input',
    beforeShortcut.tag !== 'INPUT' &&
      (afterShortcut.tag === 'INPUT' || /Find in document/i.test(afterShortcut.label ?? '')),
    { beforeShortcut, afterShortcut });

  // Pane Next steps one result at a time until it reaches N >= 12 whose owning
  // section was absent from the Reader semantics captured before navigation.
  const navigationTrace = [];
  let current = 1;
  let distant = null;
  for (let step = 0; step < 150; step++) {
    const entry = await app.stepPane('Next result', current + 1);
    navigationTrace.push(entry);
    if (entry.after !== current + 1 || entry.locator !== current + 1) break;
    current += 1;
    const section = Number(entry.heading?.match(/^Section (\d+)$/)?.[1] ?? NaN);
    if (current >= 12 && section >= 2 && !startEndMarkers.has(pad(section - 1))) {
      distant = { index: current, section, absentStartMarker: `SECTION-${pad(section - 1)}-END` };
      break;
    }
  }
  const afterDistantNodes = await app.nodes();
  if (distant) {
    const presentAfter = new Set([
      ...readerSectionMarkers(afterDistantNodes, 'START'),
      ...readerSectionMarkers(afterDistantNodes, 'END'),
    ]);
    distant.sectionContentPresentAfterNavigation = presentAfter.has(pad(distant.section));
  }
  const stepsValid = entries => entries.every(entry =>
    entry.after === entry.expected && entry.locator === entry.expected);
  record('pane Next steps one result at a time to a distant initially non-materialized result',
    Boolean(distant) && distant.index >= 12 && distant.sectionContentPresentAfterNavigation &&
      stepsValid(navigationTrace),
    {
      distant,
      startMaterializedEndMarkers: [...startEndMarkers].sort(),
      navigationTrace,
    });

  const distantIndex = distant?.index ?? current;
  const previousStep = await app.stepPane('Previous result', distantIndex - 1);
  const nextStep = await app.stepPane('Next result', distantIndex);
  record('pane Previous and Next move the selected result and Reader locator by exactly one',
    stepsValid([previousStep, nextStep]), { previousStep, nextStep });
  // Wheel the results list past the active row, then step toward the side the
  // list was scrolled away from: Next with the row above the top edge, then
  // Previous with the row below the bottom edge.
  const oppositeEdge = [];
  for (const [label, direction] of [['Next result', 1], ['Previous result', -1]]) {
    const before = await app.selectedResult();
    const { list } = await app.activeRowVisibility(before);
    await app.wheelAt(list.x + list.w / 2, list.y + list.h / 2, direction * (list.h + 24));
    const expected = before + direction;
    const activeHiddenBeforeStep = !(await app.activeRowVisibility(before)).visible;
    const targetBefore = await app.activeRowVisibility(expected);
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

  const boundary = [];
  for (const [width, height] of [[1080, 900], [1081, 900], [1082, 900], [2560, 900], [390, 844]]) {
    const state = await app.resize(width, height);
    const labels = state.nodes.map(haystack);
    boundary.push({
      width,
      height,
      hasField: Boolean(await app.searchField()),
      hasPrevious: labels.some(v => v.includes('Previous result')),
      hasNext: labels.some(v => v.includes('Next result')),
      hasCompactReopen: labels.some(v => v.includes('Show search results')),
      selectedResult: await app.selectedResult(),
    });
  }
  evidence.boundary = boundary;
  record('1080 is modal and excludes modal Previous/Next',
    boundary[0].hasField && !boundary[0].hasPrevious && !boundary[0].hasNext);
  record('1081, 1082, and 2560 use pane Previous/Next',
    boundary.slice(1, 4).every(v => v.hasField && v.hasPrevious && v.hasNext));
  record('live boundary crossings preserve the selected distant result',
    boundary.every(v => v.selectedResult === distantIndex), { distantIndex });

  const mobileNodes = await app.nodes();
  const mobileField = await app.searchField();
  record('mobile modal contains no Previous/Next',
    Boolean(mobileField) &&
      !mobileNodes.some(n => haystack(n).includes('Previous result')) &&
      !mobileNodes.some(n => haystack(n).includes('Next result')));
  const mobileInteractive = [
    mobileNodes.find(n => n.label === 'Close results'),
    mobileNodes.find(n => /^Result 1 of \d+\./.test(n.label ?? '')),
  ].filter(Boolean);
  record('visible mobile search targets meet 48 logical pixels',
    mobileField.w >= 48 && mobileField.h >= 48 &&
      mobileInteractive.length > 0 && mobileInteractive.every(n => n.w >= 48 && n.h >= 48),
    { mobileField, targets: mobileInteractive });
  const mobileScreenshot = await app.screenshot('mobile-light');

  await app.key('Escape');
  const compactReopen = await waitForValue(
    () => app.find('Show search results'),
    'compact search navigator after Escape',
    6000,
  ).catch(() => null);
  const compactNodes = await app.nodes();
  evidence.afterEscape = compactNodes;
  record('Escape dismisses the sheet to the compact navigator',
    Boolean(compactReopen) &&
      compactNodes.some(n => haystack(n).includes('Previous result')) &&
      compactNodes.some(n => haystack(n).includes('Next result')));
  if (compactReopen) await app.clickNode(compactReopen);
  const reopened = await app.searchField(6000).catch(() => null);
  record('compact navigator reopens narrow search', Boolean(reopened));
  const closeResults = await app.find('Close results');
  if (closeResults) await app.clickNode(closeResults);
  const compactClose = await waitForValue(
    () => app.find('Close search'),
    'compact Close search control',
    6000,
  ).catch(() => null);
  if (compactClose) await app.clickNode(compactClose);
  await app.openReaderMenu();
  await app.tap('Appearance');
  await app.tap('Dark');
  const darkAppearance = await waitForValue(async () => {
    const stored = await app.storedAppearance();
    return stored === 'dark' ? stored : null;
  }, 'explicit Dark appearance selection', 10000);
  const darkSelection = await app.appearanceSelection('Dark');
  record('product Appearance explicitly selects Dark', darkAppearance === 'dark', {
    storedAppearance: darkAppearance,
    semantics: darkSelection,
  });
  await app.key('Escape');
  await app.openSearchFromMenu();
  await app.type('Section');
  await waitForValue(async () => (await app.nodes()).some(n => /\d+ results/.test(haystack(n))),
    'dark-mode search results', 15000);
  const mobileDarkScreenshot = await app.screenshot('mobile-dark');
  const lightPixels = await readFile(mobileScreenshot);
  const darkPixels = await readFile(mobileDarkScreenshot);
  const lightSha256 = createHash('sha256').update(lightPixels).digest('hex');
  const darkSha256 = createHash('sha256').update(darkPixels).digest('hex');
  const lightLuminance = averagePngLuminance(lightPixels);
  const darkLuminance = averagePngLuminance(darkPixels);
  record('explicit Light rendering is observably lighter than explicit Dark rendering',
    lightLuminance.average >= darkLuminance.average + 40,
    { lightSha256, darkSha256, lightLuminance, darkLuminance });

  evidence.screenshots = {
    wideLight: wideScreenshot,
    mobileLight: mobileScreenshot,
    mobileDark: mobileDarkScreenshot,
  };
  evidence.cspViolations = await session.evaluate('return window.__df041Csp ?? [];');
  evidence.offOriginRequests = offOrigin;
  record('search causes no CSP violation', evidence.cspViolations.length === 0, { violations: evidence.cspViolations });
  record('search causes no off-origin request', offOrigin.length === 0, { offOrigin });

  await session.send('Page.reload', { ignoreCache: true });
  await delay(3500);
  await session.evaluate("document.querySelector('flt-semantics-placeholder')?.click(); return 1;");
  await delay(1200);
  const afterReload = await app.nodes();
  record('refresh/remount clears the non-retained document and search session',
    afterReload.some(n => haystack(n).includes('Load from file')) &&
      !afterReload.some(n => haystack(n).includes('Find in document')));
} catch (error) {
  evidence.fatal = String(error?.stack ?? error);
  evidence.failures += 1;
  process.stderr.write(`${evidence.fatal}\n${browser.stderrText()}\n`);
} finally {
  evidence.serverRequests = server.requestLog;
  evidence.finishedAt = new Date().toISOString();
  evidence.passed = evidence.failures === 0;
  await writeFile(outputPath, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');
  await browser.close();
  await server.close();
  await delay(100);
  await removeDirectory(browser.profile);
  process.stdout.write(`${evidence.passed ? 'ALL PASSED' : `${evidence.failures} FAILURE(S)`} - ${outputPath}\n`);
  process.exitCode = evidence.passed ? 0 : 1;
}
