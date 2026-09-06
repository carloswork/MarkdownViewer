// DF-031 CP-D2 — items 6 and 7.
//
// Item 6  Privacy re-verification on a real strict-CSP release bundle, using the
//         DF-030 instrument shape (raw CDP over the built-in Node WebSocket, no
//         npm dependency) *plus* a two-armed negative control, so a zero result
//         is falsifiable rather than merely unobserved.
// Item 7  Fallback-burst reduction for the code points DF-031 now covers, and
//         the DF-030 finite-containment invariant still holding for residual
//         unsupported ones.
//
// Carried forward unchanged from the accepted DF-030 fallback classifier and five-second quiescence rule.

import { createServer } from 'node:http';
import { createReadStream } from 'node:fs';
import { mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { extname, join, normalize, resolve, sep } from 'node:path';
import { delay, launchChromium, waitForValue } from './df031_cdp.mjs';

const NAME = 'df031-cpd2';

function argument(name, fallback) {
  const index = process.argv.indexOf(name);
  if (index === -1 || index + 1 >= process.argv.length) {
    if (fallback !== undefined) return fallback;
    throw new Error(`Missing required argument: ${name}`);
  }
  return process.argv[index + 1];
}

const BROWSER = argument('--chrome');
const BASELINE_BUNDLE = resolve(argument('--baseline-bundle'));
const DF031_BUNDLE = resolve(argument('--df031-bundle'));
const OUT = resolve(argument('--out'));
const FIXTURES = resolve(argument('--fixtures'));
const TAG = argument('--tag', '');
const tagged = (stem, ext) => `${stem}${TAG ? '-' + TAG : ''}.${ext}`;

const log = (line) => console.log(`[${NAME}] ${line}`);

// --- DF-030 classifier, verbatim ---------------------------------------------

const isFallback = (s) =>
  /Failed to load font|fallback font|fonts\.gstatic\.com|HTTP request to fetch|Font fallback service/i
    .test(s);

function textOf(name, p) {
  if (name === 'Runtime.consoleAPICalled') {
    return (p.args || []).map((a) => a.value ?? a.description ?? a.type).join(' ');
  }
  if (name === 'Log.entryAdded') return p.entry.text;
  return '';
}

// --- Servers ------------------------------------------------------------------

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.otf': 'font/otf',
  '.ttf': 'font/ttf',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.md': 'text/markdown; charset=utf-8',
  '.symbols': 'text/plain; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
};

/// Serves [rootDirectory], plus synthetic routes used only by the negative
/// control. Logs every path so the runner can assert what was actually asked
/// for on this origin.
async function serveBundle(rootDirectory, extraRoutes = {}) {
  const root = resolve(rootDirectory);
  const requestLog = [];
  const server = createServer(async (request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1');
    requestLog.push(url.pathname);
    const extra = extraRoutes[url.pathname];
    if (extra) {
      const body = Buffer.from(extra.body);
      response.writeHead(200, {
        'Content-Type': extra.type,
        'Content-Length': body.length,
        'Cache-Control': 'no-store',
      });
      response.end(body);
      return;
    }
    let relative = decodeURIComponent(url.pathname);
    if (relative === '/' || relative === '') relative = '/index.html';
    const target = normalize(join(root, relative));
    if (!target.startsWith(root + sep) && target !== root) {
      response.writeHead(403).end('Forbidden');
      return;
    }
    try {
      const info = await stat(target);
      if (!info.isFile()) throw new Error('not a file');
      response.writeHead(200, {
        'Content-Type': MIME[extname(target).toLowerCase()] ?? 'application/octet-stream',
        'Content-Length': info.size,
        'Cache-Control': 'no-store',
      });
      createReadStream(target).pipe(response);
    } catch {
      response.writeHead(404, { 'Content-Type': 'text/plain' }).end('Not found');
    }
  });
  await new Promise((done, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', done);
  });
  const { port } = server.address();
  return {
    port,
    origin: `http://127.0.0.1:${port}`,
    requestLog,
    async close() {
      if (server.listening) await new Promise((done) => server.close(done));
    },
  };
}

/// A SECOND loopback origin. A different port is a different web origin, so
/// `font-src 'self'` must refuse it exactly as it refuses fonts.gstatic.com,
/// while the transfer stays hermetic and deterministic - no public network is
/// touched to prove the instrument can see a violation.
async function serveOffOrigin(fontBytes) {
  const hits = [];
  const server = createServer((request, response) => {
    hits.push(request.url);
    if (request.url.startsWith('/nc-probe')) {
      response.writeHead(200, {
        'Content-Type': 'font/ttf',
        'Content-Length': fontBytes.length,
        'Access-Control-Allow-Origin': '*',
        'Cache-Control': 'no-store',
      });
      response.end(fontBytes);
      return;
    }
    response.writeHead(404).end('no');
  });
  await new Promise((done, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', done);
  });
  const { port } = server.address();
  return {
    port,
    origin: `http://127.0.0.1:${port}`,
    hits,
    async close() {
      if (server.listening) await new Promise((done) => server.close(done));
    },
  };
}

// --- Recording ----------------------------------------------------------------

/// Attaches every listener the DF-030 privacy invariant is stated over, plus a
/// page-side `securitypolicyviolation` collector. `primaryOrigin` defines what
/// counts as same-origin; anything else on http/https is off-origin.
function record(session, primaryOrigin) {
  const events = [];
  const requests = new Map(); // requestId -> url
  const network = {
    requestWillBeSent: [], responseReceived: [], loadingFinished: [], loadingFailed: [],
  };
  let lastFallbackAt = null;
  const fallback = [];

  const offOrigin = (url) => {
    if (!/^https?:/i.test(url)) return false;
    try {
      return new URL(url).origin !== primaryOrigin;
    } catch {
      return false;
    }
  };

  session.on('Network.requestWillBeSent', (p) => {
    requests.set(p.requestId, p.request.url);
    network.requestWillBeSent.push({
      requestId: p.requestId, url: p.request.url, type: p.type,
      offOrigin: offOrigin(p.request.url),
    });
  });
  session.on('Network.responseReceived', (p) => {
    network.responseReceived.push({
      requestId: p.requestId, url: p.response.url, status: p.response.status,
      encodedDataLength: p.response.encodedDataLength ?? 0,
      offOrigin: offOrigin(p.response.url),
    });
  });
  session.on('Network.loadingFinished', (p) => {
    const url = requests.get(p.requestId) ?? '';
    network.loadingFinished.push({
      requestId: p.requestId, url, encodedDataLength: p.encodedDataLength ?? 0,
      offOrigin: offOrigin(url),
    });
  });
  session.on('Network.loadingFailed', (p) => {
    const url = requests.get(p.requestId) ?? '';
    network.loadingFailed.push({
      requestId: p.requestId, url, errorText: p.errorText,
      blockedReason: p.blockedReason, offOrigin: offOrigin(url),
    });
  });

  for (const name of ['Runtime.consoleAPICalled', 'Log.entryAdded']) {
    session.on(name, (p) => {
      const text = textOf(name, p);
      if (isFallback(text)) {
        lastFallbackAt = Date.now();
        fallback.push({ atMs: Date.now(), name, text });
      }
      if (events.length < 20000) {
        events.push({ atMs: Date.now(), name, level: p.entry?.level ?? p.type, text });
      }
    });
  }

  return {
    network, events, fallback,
    lastFallback: () => lastFallbackAt,
    summary() {
      const offReq = network.requestWillBeSent.filter((e) => e.offOrigin);
      const offResp = network.responseReceived.filter((e) => e.offOrigin);
      const offOk = offResp.filter((e) => e.status >= 200 && e.status < 400);
      const offFin = network.loadingFinished.filter((e) => e.offOrigin);
      const offFail = network.loadingFailed.filter((e) => e.offOrigin);
      const bytes = offFin.reduce((n, e) => n + e.encodedDataLength, 0) +
        offResp.reduce((n, e) => n + e.encodedDataLength, 0);
      return {
        sameOriginRequests: network.requestWillBeSent.length - offReq.length,
        offOriginRequests: offReq.length,
        offOriginResponses: offResp.length,
        offOriginSuccessfulResponses: offOk.length,
        offOriginLoadingFinished: offFin.length,
        offOriginLoadingFailed: offFail.length,
        offOriginTransferredBytes: bytes,
        offOriginUrls: [...new Set([...offReq.map((e) => e.url), ...offResp.map((e) => e.url)])],
        fallbackEventCount: fallback.length,
      };
    },
  };
}

/// The DF-030 termination rule, verbatim: poll for up to 30 s; stop after five
/// seconds without fallback evidence, or after ten seconds if none was ever
/// seen.
async function waitForQuiescence(rec, startedAt) {
  let terminal = 'max-window';
  for (let i = 0; i < 120; i++) {
    await delay(250);
    const last = rec.lastFallback();
    if (last !== null && Date.now() - last >= 5000) {
      terminal = 'five-second-fallback-quiescence';
      break;
    }
    if (last === null && Date.now() - startedAt >= 10000) {
      terminal = 'no-fallback-seen-for-ten-seconds';
      break;
    }
  }
  return terminal;
}

// --- Page-side probes ---------------------------------------------------------

const SEMANTICS = `
  return [...document.querySelectorAll('flt-semantics')].map(n => {
    const r = n.getBoundingClientRect();
    return {
      role: n.getAttribute('role'),
      label: n.getAttribute('aria-label'),
      text: n.childNodes.length && n.firstChild.nodeType === 3 ? n.textContent : null,
      x: Math.round(r.x), y: Math.round(r.y),
      w: Math.round(r.width), h: Math.round(r.height),
    };
  });
`;

const CSP_META = `
  const m = [...document.querySelectorAll('meta[http-equiv="Content-Security-Policy" i]')]
    .map(e => e.getAttribute('content').replace(/\\s+/g, ' ').trim());
  return m;
`;

const VIOLATION_COLLECTOR = `
  window.__cspViolations = [];
  document.addEventListener('securitypolicyviolation', (e) => {
    window.__cspViolations.push({
      blockedURI: e.blockedURI,
      effectiveDirective: e.effectiveDirective || e.violatedDirective,
      disposition: e.disposition,
    });
  });
`;

// --- App driving --------------------------------------------------------------

class App {
  constructor(session, server, counters) {
    this.s = session;
    this.server = server;
    this.counters = counters;
  }

  nodes() {
    return this.s.evaluate(SEMANTICS);
  }

  async click(x, y) {
    await this.s.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y, button: 'none', buttons: 0 });
    await this.s.send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1 });
    await delay(40);
    await this.s.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', buttons: 0, clickCount: 1 });
  }

  async tap(text, { timeoutMs = 12000 } = {}) {
    const node = await waitForValue(
      async () => (await this.nodes()).find(
        (n) => (n.text ?? n.label ?? '').split('\n')[0].trim() === text && n.w > 0 && n.h > 0,
      ),
      `semantics node "${text}"`,
      timeoutMs,
    );
    await this.click(node.x + node.w / 2, node.y + node.h / 2);
    await delay(700);
    return node;
  }

  async openReaderMenu() {
    const size = await this.s.evaluate('return { w: innerWidth, h: innerHeight };');
    for (let attempt = 0; attempt < 3; attempt++) {
      const node = await waitForValue(
        async () => (await this.nodes()).find(
          (n) => n.role === 'button' && !n.text && !n.label &&
            n.w > 20 && n.w <= 70 && n.h > 20 && n.h <= 70 &&
            n.x + n.w > size.w - 110 && n.y + n.h > size.h - 110,
        ),
        'reader menu button',
      );
      await this.click(node.x + node.w / 2, node.y + node.h / 2);
      await delay(900);
      const opened = (await this.nodes()).some(
        (n) => (n.text ?? '').split('\n')[0].trim() === 'Load from file',
      );
      if (opened) return;
      await this.s.send('Input.dispatchMouseEvent', {
        type: 'mouseWheel', x: size.w / 2, y: size.h / 2, deltaX: 0, deltaY: -240,
      });
      await delay(500);
    }
    throw new Error('reader menu did not open');
  }

  async loadFixture(file) {
    this.counters.chooser = null;
    const visible = (await this.nodes()).some(
      (n) => (n.text ?? '').split('\n')[0].trim() === 'Load from file',
    );
    if (!visible) await this.openReaderMenu();
    await this.tap('Load from file');
    await delay(1200);
    if (!this.counters.chooser) throw new Error(`file chooser did not open for ${file}`);
    await this.s.send('DOM.setFileInputFiles', {
      files: [join(FIXTURES, file)],
      backendNodeId: this.counters.chooser.backendNodeId,
    });
    await delay(1500);
    const replace = (await this.nodes()).find((n) => (n.text ?? '').trim() === 'Replace');
    if (replace) {
      await this.click(replace.x + replace.w / 2, replace.y + replace.h / 2);
      await delay(1500);
    }
    await waitForValue(
      async () => await this.s.evaluate(
        `return !!document.getElementById('df026-print-style');`,
      ),
      `print surface after loading ${file}`,
    );
    await delay(800);
  }
}

/// Boots one browser against one bundle and returns the app plus its recorder.
async function boot(bundle, { extraRoutes = {} } = {}) {
  const server = await serveBundle(bundle, extraRoutes);
  const browser = await launchChromium(BROWSER, { windowSize: '1280,1600' });
  const s = browser.session;
  const counters = { chooser: null };
  s.on('Page.fileChooserOpened', (p) => { counters.chooser = p; });
  await s.send('Runtime.enable');
  await s.send('Page.enable');
  await s.send('Log.enable');
  await s.send('DOM.enable');
  await s.send('Network.enable');
  const rec = record(s, server.origin);
  await s.send('Page.addScriptToEvaluateOnNewDocument', { source: VIOLATION_COLLECTOR });
  await s.send('Page.setInterceptFileChooserDialog', { enabled: true });
  await s.send('Page.navigate', { url: server.origin + '/' });
  await waitForValue(
    async () => await s.evaluate(`return !!document.querySelector('flt-semantics-placeholder');`),
    'Flutter bootstrap',
  );
  await delay(2500);
  await s.evaluate(`document.querySelector('flt-semantics-placeholder').click(); return 1;`);
  await delay(1200);
  return { server, browser, s, rec, app: new App(s, server, counters) };
}

// --- Phases -------------------------------------------------------------------

/// Loads the given fixtures, waits for DF-030 quiescence, and reports the
/// privacy summary and the fallback burst for that build.
async function runDocuments(label, bundle, fixtures) {
  log(`--- ${label}: ${fixtures.join(', ')} ---`);
  const ctx = await boot(bundle);
  try {
    const csp = await ctx.s.evaluate(CSP_META);
    const startedAt = Date.now();
    for (const fixture of fixtures) await ctx.app.loadFixture(fixture);
    const terminal = await waitForQuiescence(ctx.rec, startedAt);
    const violations = await ctx.s.evaluate('return window.__cspViolations || [];');
    const shot = await ctx.s.send('Page.captureScreenshot', { format: 'png' });
    const file = join(OUT, tagged(`cpd2-${label}`, 'png'));
    await writeFile(file, Buffer.from(shot.data, 'base64'));
    const summary = ctx.rec.summary();
    const result = {
      label, bundle, fixtures, csp, terminal,
      durationMs: Date.now() - startedAt,
      summary,
      cspViolations: violations,
      fallbackEvents: ctx.rec.fallback,
      lastFallbackOffsetMs: ctx.rec.lastFallback() === null
        ? null : ctx.rec.lastFallback() - startedAt,
      sameOriginPaths: [...new Set(ctx.server.requestLog)],
      screenshot: file,
    };
    log(`    off-origin req/resp/ok/bytes = ${summary.offOriginRequests}/` +
      `${summary.offOriginResponses}/${summary.offOriginSuccessfulResponses}/` +
      `${summary.offOriginTransferredBytes}  fallbackEvents=${summary.fallbackEventCount}` +
      `  cspViolations=${violations.length}  terminal=${terminal}`);
    return result;
  } finally {
    await ctx.browser.close();
    await ctx.server.close();
  }
}

/// The two negative-control arms. Both attempt the SAME off-origin font load
/// against the SAME second loopback origin, through the SAME recorder:
///   arm 1 runs on the product's own strict-CSP index.html   -> must be blocked
///   arm 2 runs on a page with NO CSP on the same origin     -> must be seen
/// Arm 2 is what makes arm 1 falsifiable.
async function runNegativeControl(bundle) {
  const fontBytes = await readFile(join(bundle, 'assets', 'fonts', 'Roboto-Regular.ttf'));
  const off = await serveOffOrigin(fontBytes);
  log(`--- negative control (off-origin at ${off.origin}) ---`);
  const probe = (origin) => `
    window.__cspViolations = window.__cspViolations || [];
    const face = new FontFace('NcProbe', 'url(${origin}/nc-probe.ttf)');
    document.fonts.add(face);
    let outcome = 'loaded';
    try { await face.load(); } catch (e) { outcome = 'threw: ' + (e && e.name); }
    const span = document.createElement('span');
    span.style.font = '32px NcProbe';
    span.textContent = 'NC';
    document.body.appendChild(span);
    try { await document.fonts.ready; } catch (e) { /* ignore */ }
    await new Promise(r => setTimeout(r, 1500));
    return { outcome, status: face.status };
  `;
  const noCspPage = `<!doctype html><html><head><meta charset="utf-8">
<title>DF-031 CP-D2 negative control - no CSP</title></head><body>
<p>negative control: this page carries no Content-Security-Policy</p></body></html>`;

  const ctx = await boot(bundle, { '/__nc/nocsp.html': { body: noCspPage, type: 'text/html; charset=utf-8' } });
  const arms = {};
  try {
    // Arm 1 - the product page, strict CSP in force.
    const cspArm1 = await ctx.s.evaluate(CSP_META);
    const before = ctx.rec.summary();
    const r1 = await ctx.s.evaluate(probe(off.origin));
    await delay(1500);
    const v1 = await ctx.s.evaluate('return window.__cspViolations || [];');
    const after1 = ctx.rec.summary();
    arms.armStrictCsp = {
      page: 'product index.html (strict CSP)',
      csp: cspArm1,
      probeOutcome: r1,
      offOriginRequests: after1.offOriginRequests - before.offOriginRequests,
      offOriginSuccessfulResponses:
        after1.offOriginSuccessfulResponses - before.offOriginSuccessfulResponses,
      offOriginTransferredBytes:
        after1.offOriginTransferredBytes - before.offOriginTransferredBytes,
      cspViolations: v1,
      offOriginServerHits: [...off.hits],
    };
    log(`    arm1 (strict CSP): outcome=${r1.outcome} offReq=${arms.armStrictCsp.offOriginRequests}` +
      ` ok=${arms.armStrictCsp.offOriginSuccessfulResponses}` +
      ` bytes=${arms.armStrictCsp.offOriginTransferredBytes}` +
      ` violations=${v1.length} serverHits=${off.hits.length}`);

    // Arm 2 - same origin, same instrument, a page with no CSP at all.
    const hitsBeforeArm2 = off.hits.length;
    const before2 = ctx.rec.summary();
    await ctx.s.send('Page.navigate', { url: ctx.server.origin + '/__nc/nocsp.html' });
    await delay(1200);
    const cspArm2 = await ctx.s.evaluate(CSP_META);
    const r2 = await ctx.s.evaluate(probe(off.origin));
    await delay(1500);
    const v2 = await ctx.s.evaluate('return window.__cspViolations || [];');
    const after2 = ctx.rec.summary();
    arms.armNoCsp = {
      page: '/__nc/nocsp.html (no CSP)',
      csp: cspArm2,
      probeOutcome: r2,
      offOriginRequests: after2.offOriginRequests - before2.offOriginRequests,
      offOriginSuccessfulResponses:
        after2.offOriginSuccessfulResponses - before2.offOriginSuccessfulResponses,
      offOriginTransferredBytes:
        after2.offOriginTransferredBytes - before2.offOriginTransferredBytes,
      cspViolations: v2,
      offOriginServerHits: off.hits.slice(hitsBeforeArm2),
    };
    log(`    arm2 (no CSP):     outcome=${r2.outcome} offReq=${arms.armNoCsp.offOriginRequests}` +
      ` ok=${arms.armNoCsp.offOriginSuccessfulResponses}` +
      ` bytes=${arms.armNoCsp.offOriginTransferredBytes}` +
      ` violations=${v2.length} serverHits=${arms.armNoCsp.offOriginServerHits.length}`);
    return arms;
  } finally {
    await ctx.browser.close();
    await ctx.server.close();
    await off.close();
  }
}

// --- Run ----------------------------------------------------------------------

await mkdir(OUT, { recursive: true });
const evidence = { startedAt: new Date().toISOString(), browser: BROWSER };

evidence.browserVersion = await (async () => {
  const ctx = await boot(DF031_BUNDLE);
  try {
    return await ctx.s.send('Browser.getVersion');
  } finally {
    await ctx.browser.close();
    await ctx.server.close();
  }
})();
log(`browser: ${evidence.browserVersion.product}`);

// Item 6 - the untouched product, strict CSP, Chinese documents loaded.
evidence.item6_privacy = await runDocuments(
  'item6-privacy-df031', DF031_BUNDLE, ['traditional.md', 'simplified.md'],
);
evidence.item6_negativeControl = await runNegativeControl(DF031_BUNDLE);

// Item 7 - fallback burst, before and after, over documents whose every code
// point IS in the DF-031 shipped repertoire. The CP-D1 fixtures both contain
// U+21D2, which no shipped face covers, so measuring the "covered code points"
// claim on them would fold a residual code point into the after-count. These
// copies replace that one character with `->` and are verified against the
// built faces' own cmaps: 0 code points uncovered by DF-031, 115 and 190
// distinct code points uncovered by the baseline build.
evidence.item7_baseline = await runDocuments(
  'item7-baseline-chinese', BASELINE_BUNDLE,
  ['covered_traditional.md', 'covered_simplified.md'],
);
evidence.item7_df031 = await runDocuments(
  'item7-df031-chinese', DF031_BUNDLE,
  ['covered_traditional.md', 'covered_simplified.md'],
);

// Item 7 - containment for code points DF-031 still does not cover.
evidence.item7_residual_df031 = await runDocuments(
  'item7-df031-residual', DF031_BUNDLE, ['residual_unsupported.md'],
);
evidence.item7_residual_baseline = await runDocuments(
  'item7-baseline-residual', BASELINE_BUNDLE, ['residual_unsupported.md'],
);

evidence.finishedAt = new Date().toISOString();
const outFile = join(OUT, tagged('cpd2-privacy-fallback', 'json'));
await writeFile(outFile, JSON.stringify(evidence, null, 1));
log(`wrote ${outFile}`);
