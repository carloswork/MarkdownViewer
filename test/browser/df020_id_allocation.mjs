// DF-020 V-1w runner: compiled document-ID allocation in Chromium and Firefox.
//
// Verification support, not product code. Nothing here is imported by `lib/`.
//
//   flutter build web --release -t tool/df020_id_allocation.dart -o <bundle>
//   node test/browser/df020_id_allocation.mjs --engine chromium \
//     --browser "<path to chrome.exe or msedge.exe>" --bundle <bundle> --out <file.json>
//   node test/browser/df020_id_allocation.mjs --engine firefox \
//     --browser "<path to firefox.exe>" --bundle <bundle> --out <file.json>
//
// Chromium is driven over CDP with the df031_cdp.mjs helpers. Firefox does not
// speak CDP, so it is driven over WebDriver BiDi the way
// df039_retention_firefox.mjs drives it. Both read the same result, which the
// harness publishes on `document.body.dataset.df020IdAllocation`, and fail the
// run when the harness reports `passed: false`.

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';

import {
  delay,
  launchChromium,
  removeDirectory,
  serveBundle,
  waitForValue,
} from './df031_cdp.mjs';

function argument(name) {
  const index = process.argv.indexOf(`--${name}`);
  if (index === -1 || index + 1 >= process.argv.length) {
    throw new Error(`Missing required argument: --${name}`);
  }
  return process.argv[index + 1];
}

const ENGINE = argument('engine');
const BROWSER = resolve(argument('browser'));
const BUNDLE = resolve(argument('bundle'));
const OUT = resolve(argument('out'));
const RESULT = 'return document.body?.dataset?.df020IdAllocation ?? null;';

async function sha256(path) {
  return createHash('sha256').update(await readFile(path)).digest('hex');
}

async function runChromium(origin) {
  const browser = await launchChromium(BROWSER, { windowSize: '1280,900' });
  try {
    const session = browser.session;
    await session.send('Page.enable');
    await session.send('Runtime.enable');
    const version = await session.send('Browser.getVersion');
    const loaded = new Promise((done) =>
      session.on('Page.loadEventFired', () => done()),
    );
    const navigation = await session.send('Page.navigate', { url: `${origin}/` });
    if (navigation.errorText) {
      throw new Error(`Navigation failed: ${navigation.errorText}`);
    }
    await loaded;
    const raw = await waitForValue(
      () => session.evaluate(RESULT),
      'DF-020 ID allocation result',
      120000,
    );
    return { browserVersion: version.product, raw };
  } catch (error) {
    error.message += `\n${browser.stderrText()}`;
    throw error;
  } finally {
    await browser.close();
    await delay(50);
    await removeDirectory(browser.profile);
  }
}

// --- Firefox over WebDriver BiDi (the df039_retention_firefox.mjs pattern) ---

class BidiSession {
  constructor(url) {
    this.socket = new WebSocket(url);
    this.nextId = 1;
    this.pending = new Map();
  }

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
      if (message.type === 'error') {
        pending.reject(new Error(`${pending.method}: ${message.error} ${message.message}`));
      } else {
        pending.resolve(message.result);
      }
    });
  }

  send(method, params = {}) {
    const id = this.nextId++;
    return new Promise((done, reject) => {
      this.pending.set(id, { resolve: done, reject, method });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  close() {
    try { this.socket.close(); } catch { /* already gone */ }
  }
}

async function runFirefox(origin) {
  const profile = join(dirname(OUT), `df020-id-allocation-firefox-profile-${process.pid}`);
  await mkdir(profile, { recursive: true });
  await writeFile(join(profile, 'user.js'), [
    'user_pref("browser.shell.checkDefaultBrowser", false);',
    'user_pref("browser.startup.homepage_override.mstone", "ignore");',
    'user_pref("datareporting.policy.dataSubmissionEnabled", false);',
    'user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);',
    'user_pref("app.update.auto", false);',
    'user_pref("remote.prefs.recommended", true);',
  ].join('\n'));
  const child = spawn(BROWSER, [
    '--headless', '--no-remote', '--new-instance',
    '--profile', profile,
    '--remote-debugging-port', '0',
    'about:blank',
  ], { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
  let output = '';
  child.stderr.setEncoding('utf8');
  child.stdout.setEncoding('utf8');
  child.stderr.on('data', (chunk) => { output += chunk; });
  child.stdout.on('data', (chunk) => { output += chunk; });

  let session;
  try {
    const url = await waitForValue(
      async () => output.match(/WebDriver BiDi listening on (ws:\/\/\S+)/)?.[1] ?? null,
      'Firefox WebDriver BiDi endpoint',
      60000,
    );
    session = new BidiSession(`${url}/session`);
    await session.connect();
    const created = await session.send('session.new', { capabilities: { alwaysMatch: {} } });
    const tree = await session.send('browsingContext.getTree', {});
    const context = tree.contexts[0].context;
    await session.send('browsingContext.navigate', {
      context, url: `${origin}/`, wait: 'complete',
    });
    const raw = await waitForValue(async () => {
      const result = await session.send('script.evaluate', {
        expression: `(() => { ${RESULT} })()`,
        target: { context },
        awaitPromise: false,
        resultOwnership: 'none',
      });
      return result.result?.type === 'string' ? result.result.value : null;
    }, 'DF-020 ID allocation result', 120000);
    return { browserVersion: `Firefox ${created.capabilities?.browserVersion ?? '?'}`, raw };
  } catch (error) {
    error.message += `\n${output}`;
    throw error;
  } finally {
    if (session) {
      await Promise.race([session.send('browser.close').catch(() => {}), delay(4000)]);
      session.close();
    }
    await Promise.race([
      new Promise((done) => (child.exitCode === null ? child.once('exit', done) : done())),
      delay(10000),
    ]);
    if (child.exitCode === null) child.kill();
    await delay(1500);
    await removeDirectory(profile);
  }
}

const server = await serveBundle(BUNDLE);
try {
  const run = ENGINE === 'chromium'
    ? await runChromium(server.origin)
    : ENGINE === 'firefox'
      ? await runFirefox(server.origin)
      : (() => { throw new Error(`Unknown --engine ${ENGINE}`); })();
  const result = JSON.parse(run.raw);
  const evidence = {
    generated_at: new Date().toISOString(),
    engine: ENGINE,
    browser: BROWSER,
    browserVersion: run.browserVersion,
    bundle: BUNDLE,
    mainDartJsSha256: await sha256(join(BUNDLE, 'main.dart.js')),
    mode: 'flutter build web --release -t tool/df020_id_allocation.dart',
    requested_paths: server.requestLog,
    ...result,
  };
  await mkdir(dirname(OUT), { recursive: true });
  await writeFile(OUT, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');
  process.stdout.write(`${JSON.stringify(evidence)}\n`);
  if (!result.passed) process.exitCode = 1;
} catch (error) {
  process.stderr.write(`${error.stack ?? error}\n`);
  process.exitCode = 1;
} finally {
  await server.close();
}
