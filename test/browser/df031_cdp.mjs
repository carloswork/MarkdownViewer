// DF-031 CP-D1 shared browser-driving support.
//
// Verification support, not product code. Deliberately mirrors the transport
// already proven by `df026_zero_request_runner.mjs` (raw CDP over the built-in
// Node WebSocket, no npm dependency) rather than introducing a driver stack.
//
// The app is Flutter Web/CanvasKit: prose is rasterised into a canvas, so there
// are no DOM text nodes to query in the Viewer. Interaction therefore goes
// through the engine's *semantics* tree, which Flutter does publish as real DOM
// with `aria-label`s and layout boxes once accessibility is enabled. That gives
// stable, label-addressed targets instead of hard-coded pixel guesses.

import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { extname, join, normalize, resolve, sep } from 'node:path';

export function delay(milliseconds) {
  return new Promise((done) => setTimeout(done, milliseconds));
}

export async function waitForValue(producer, description, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const value = await producer();
      if (value) return value;
    } catch (error) {
      lastError = error;
    }
    await delay(60);
  }
  throw new Error(
    `Timed out waiting for ${description}${lastError ? `: ${lastError}` : ''}`,
  );
}

// --- Static server for the release bundle ------------------------------------

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

/// Serves [rootDirectory] on a loopback port. Records every request path so a
/// runner can assert what the page actually asked for.
export async function serveBundle(rootDirectory) {
  const root = resolve(rootDirectory);
  const requestLog = [];
  const server = createServer(async (request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1');
    requestLog.push(url.pathname);
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
        'Content-Type': MIME[extname(target).toLowerCase()] ??
          'application/octet-stream',
        'Content-Length': info.size,
        // The relaunch step reuses the profile, and a cached main.dart.js would
        // hide a change; only IndexedDB is meant to survive.
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
      if (!server.listening) return;
      await new Promise((done) => server.close(done));
    },
  };
}

// --- CDP transport -----------------------------------------------------------

export class CdpSession {
  constructor(webSocketUrl) {
    this.socket = new WebSocket(webSocketUrl);
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = new Map();
  }

  async connect() {
    await new Promise((done, reject) => {
      this.socket.addEventListener('open', done, { once: true });
      this.socket.addEventListener('error', reject, { once: true });
    });
    this.socket.addEventListener('message', (event) => {
      const message = JSON.parse(event.data);
      if (message.id) {
        const pending = this.pending.get(message.id);
        if (!pending) return;
        this.pending.delete(message.id);
        if (message.error) {
          pending.reject(
            new Error(`${pending.method}: ${JSON.stringify(message.error)}`),
          );
        } else {
          pending.resolve(message.result);
        }
        return;
      }
      for (const listener of this.listeners.get(message.method) ?? []) {
        listener(message.params);
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

  /// Evaluates [expression] and returns its JSON value, turning a thrown page
  /// exception into a thrown Node error rather than a silent undefined.
  async evaluate(expression) {
    const result = await this.send('Runtime.evaluate', {
      // `async` unconditionally: some probes await IndexedDB, and awaiting a
      // non-promise body costs nothing.
      expression: `(async () => { ${expression} })()`,
      returnByValue: true,
      awaitPromise: true,
    });
    if (result.exceptionDetails) {
      throw new Error(
        `Page exception: ${JSON.stringify(result.exceptionDetails.exception ?? result.exceptionDetails)}`,
      );
    }
    return result.result.value;
  }

  close() {
    try {
      this.socket.close();
    } catch {
      /* already gone */
    }
  }
}

// --- Chromium launch ---------------------------------------------------------

export async function launchChromium(
  binaryPath,
  { profileDirectory, windowSize = '1280,1600', headless = true } = {},
) {
  const profile = profileDirectory ??
    (await mkdtemp(join(tmpdir(), 'df031-cpd-')));
  // A relaunch reuses the profile so IndexedDB survives, but Chrome leaves the
  // previous run's DevToolsActivePort behind - reading it would connect to a
  // dead port. Clear it so the wait below observes only this launch.
  await rm(join(profile, 'DevToolsActivePort'), { force: true });
  const args = [
    ...(headless ? ['--headless=new'] : []),
    '--remote-debugging-port=0',
    `--user-data-dir=${profile}`,
    `--window-size=${windowSize}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-extensions',
    '--hide-scrollbars',
    '--force-device-scale-factor=1',
    'about:blank',
  ];
  const child = spawn(binaryPath, args, {
    stdio: ['ignore', 'ignore', 'pipe'],
    windowsHide: true,
  });
  let stderr = '';
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', (chunk) => {
    stderr += chunk;
  });

  const devToolsPort = await waitForValue(async () => {
    const raw = await readFile(join(profile, 'DevToolsActivePort'), 'utf8');
    const port = Number(raw.split(/\r?\n/, 1)[0]);
    return Number.isFinite(port) && port > 0 ? port : null;
  }, `${binaryPath} DevTools port`);

  const target = await waitForValue(async () => {
    const response = await fetch(`http://127.0.0.1:${devToolsPort}/json/list`);
    const targets = await response.json();
    return targets.find((candidate) => candidate.type === 'page');
  }, 'page target');

  const session = new CdpSession(target.webSocketDebuggerUrl);
  await session.connect();

  return {
    profile,
    session,
    stderrText: () => stderr,
    async close() {
      session.close();
      if (child.exitCode === null) child.kill();
      await Promise.race([
        new Promise((done) => child.once('exit', done)),
        delay(5000),
      ]);
    },
  };
}

/// Reads the print stacks back out of the browser's own parsed CSSOM.
///
/// Stronger than matching the stylesheet text with a regular expression: this
/// is what the engine actually parsed out of the `@media print` block, so a
/// rule the browser rejected cannot be reported as present. It also works
/// identically in Gecko, which has no media-emulation command over BiDi.
///
/// Evaluates to a JSON **string** so the BiDi and CDP value encodings agree.
export const PRINT_RULES = String.raw`
  const style = document.getElementById('df026-print-style');
  if (!style || !style.sheet) return JSON.stringify({ found: false });
  const faces = [];
  let printBlock = null;
  for (const rule of style.sheet.cssRules) {
    if (rule.constructor.name === 'CSSFontFaceRule' || rule.type === 5) {
      faces.push({ family: rule.style.getPropertyValue('font-family'), src: rule.style.getPropertyValue('src') });
    }
    if ((rule.conditionText || rule.media?.mediaText || '').indexOf('print') !== -1) printBlock = rule;
  }
  const wanted = { '#df026-print': null, '#df026-print pre': null, '#df026-print code': null };
  if (printBlock) {
    for (const rule of printBlock.cssRules) {
      if (rule.selectorText in wanted) {
        wanted[rule.selectorText] = rule.style.getPropertyValue('font-family') ||
          rule.style.getPropertyValue('font');
      }
    }
  }
  return JSON.stringify({
    found: true,
    printBlockPresent: !!printBlock,
    fontFaceRules: faces,
    proportional: wanted['#df026-print'],
    pre: wanted['#df026-print pre'],
    code: wanted['#df026-print code'],
  });
`;

/// Page-side glyph rasterisation probe, shared by the CDP and BiDi runners.
///
/// Screenshots prove "not tofu" only to a human eye, and on this machine
/// Firefox cannot produce them at all. This rasterises the bundled print faces
/// into a 2D canvas and measures the result, which is engine-independent and
/// objective:
///
///  - `ink` counts non-transparent pixels. A face that failed to load leaves
///    the system fallback or an empty box, so ink alone is weak - but zero ink
///    is a definite failure.
///  - the alpha hash distinguishes *shapes*. The two packs are Noto Sans SC and
///    TC subsets, so a code point shared by both must rasterise differently
///    under each. That is the property an explicit preference is supposed to
///    change, measured rather than asserted.
///
/// Evaluates to a JSON **string** so the BiDi and CDP value encodings agree.
export const GLYPH_PROBE = String.raw`
  const shared = '骨直者令';   // in BOTH repertoires
  const hansOnly = '汉';                   // Simplified-exclusive
  const hantOnly = '漢';                   // Traditional-exclusive
  const draw = (family, text) => {
    const canvas = document.createElement('canvas');
    canvas.width = 128 * text.length;
    canvas.height = 128;
    const ctx = canvas.getContext('2d', { willReadFrequently: true });
    if (!ctx) return null;
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.fillStyle = '#000';
    ctx.textBaseline = 'top';
    ctx.font = '96px "' + family + '"';
    ctx.fillText(text, 4, 4);
    const data = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
    let ink = 0;
    let hash = 2166136261;
    for (let i = 3; i < data.length; i += 4) {
      if (data[i] > 16) ink++;
      hash = Math.imul(hash ^ data[i], 16777619) >>> 0;
    }
    return { ink, hash, width: Math.round(ctx.measureText(text).width) };
  };
  await Promise.all([
    document.fonts.load('400 96px "DF031Hant"', hantOnly + shared),
    document.fonts.load('400 96px "DF031Hans"', hansOnly + shared),
  ]);
  return JSON.stringify({
    hantShared: draw('DF031Hant', shared),
    hansShared: draw('DF031Hans', shared),
    hantExclusive: draw('DF031Hant', hantOnly),
    hansExclusive: draw('DF031Hans', hansOnly),
    checkHant: document.fonts.check('400 10pt "DF031Hant"', hantOnly),
    checkHans: document.fonts.check('400 10pt "DF031Hans"', hansOnly),
    loadedDf031Faces: [...document.fonts]
      .filter((f) => f.family.indexOf('DF031') === 0)
      .map((f) => ({ family: f.family, status: f.status })),
  });
`;

/// Best-effort cleanup. A browser can still hold a profile file open moments
/// after exit; losing a temporary directory must never fail a verification run
/// or mask the evidence it already wrote.
export async function removeDirectory(path) {
  try {
    await rm(path, { recursive: true, force: true, maxRetries: 20, retryDelay: 150 });
  } catch (error) {
    process.stderr.write(`Warning: could not remove ${path}: ${error}\n`);
  }
}
