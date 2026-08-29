import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';

function argument(name) {
  const index = process.argv.indexOf(name);
  if (index === -1 || index + 1 >= process.argv.length) {
    throw new Error(`Missing required argument: ${name}`);
  }
  return process.argv[index + 1];
}

function delay(milliseconds) {
  return new Promise((resolveDelay) => setTimeout(resolveDelay, milliseconds));
}

async function waitForValue(producer, description, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const value = await producer();
      if (value) return value;
    } catch (error) {
      lastError = error;
    }
    await delay(50);
  }
  throw new Error(
    `Timed out waiting for ${description}${lastError ? `: ${lastError}` : ''}`,
  );
}

async function listen(server) {
  await new Promise((resolveListen, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolveListen);
  });
  return server.address().port;
}

async function closeServer(server) {
  if (!server.listening) return;
  await new Promise((resolveClose, reject) => {
    server.close((error) => (error ? reject(error) : resolveClose()));
  });
}

async function waitForExit(child, timeoutMs = 5000) {
  if (child.exitCode !== null) return;
  await Promise.race([
    new Promise((resolveExit) => child.once('exit', resolveExit)),
    delay(timeoutMs).then(() => {
      if (child.exitCode === null) child.kill();
    }),
  ]);
}

class CdpSession {
  constructor(webSocketUrl) {
    this.socket = new WebSocket(webSocketUrl);
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = new Map();
  }

  async connect() {
    await new Promise((resolveOpen, reject) => {
      this.socket.addEventListener('open', resolveOpen, { once: true });
      this.socket.addEventListener('error', reject, { once: true });
    });
    this.socket.addEventListener('message', (event) => {
      const message = JSON.parse(event.data);
      if (message.id) {
        const pending = this.pending.get(message.id);
        if (!pending) return;
        this.pending.delete(message.id);
        if (message.error) {
          pending.reject(new Error(JSON.stringify(message.error)));
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

  once(method) {
    return new Promise((resolveEvent) => {
      const listener = (params) => {
        const listeners = this.listeners.get(method) ?? [];
        this.listeners.set(
          method,
          listeners.filter((candidate) => candidate !== listener),
        );
        resolveEvent(params);
      };
      this.on(method, listener);
    });
  }

  send(method, params = {}) {
    const id = this.nextId++;
    return new Promise((resolveCommand, reject) => {
      this.pending.set(id, { resolve: resolveCommand, reject });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  close() {
    this.socket.close();
  }
}

const chromePath = resolve(argument('--chrome'));
const htmlPath = resolve(argument('--html'));
const html = await readFile(htmlPath);
const profileDirectory = await mkdtemp(`${tmpdir()}\\df026-c1-chrome-`);
const sameOriginProbeRequests = [];
const server = createServer((request, response) => {
  if (request.url === '/harness.html') {
    response.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Content-Length': html.length,
      'Cache-Control': 'no-store',
    });
    response.end(html);
    return;
  }
  sameOriginProbeRequests.push(request.url);
  response.writeHead(404, { 'Content-Type': 'text/plain' });
  response.end('Unexpected request');
});

let chrome;
let session;
let chromeStderr = '';
try {
  const harnessPort = await listen(server);
  const harnessUrl = `http://127.0.0.1:${harnessPort}/harness.html`;
  chrome = spawn(
    chromePath,
    [
      '--headless=new',
      '--remote-debugging-port=0',
      `--user-data-dir=${profileDirectory}`,
      '--no-first-run',
      '--no-default-browser-check',
      'about:blank',
    ],
    { stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true },
  );
  chrome.stderr.setEncoding('utf8');
  chrome.stderr.on('data', (chunk) => {
    chromeStderr += chunk;
  });

  const devToolsPort = await waitForValue(async () => {
    const activePort = await readFile(
      `${profileDirectory}\\DevToolsActivePort`,
      'utf8',
    );
    return Number(activePort.split(/\r?\n/, 1)[0]);
  }, 'Chrome DevTools port');

  const target = await waitForValue(async () => {
    const response = await fetch(`http://127.0.0.1:${devToolsPort}/json/list`);
    const targets = await response.json();
    return targets.find((candidate) => candidate.type === 'page');
  }, 'Chrome page target');

  session = new CdpSession(target.webSocketDebuggerUrl);
  await session.connect();

  const requests = [];
  session.on('Network.requestWillBeSent', ({ request, type }) => {
    requests.push({
      url: request.url,
      method: request.method,
      resourceType: type,
    });
  });
  await session.send('Network.enable');
  await session.send('Page.enable');

  const loaded = session.once('Page.loadEventFired');
  const navigation = await session.send('Page.navigate', { url: harnessUrl });
  if (navigation.errorText) {
    throw new Error(`Harness navigation failed: ${navigation.errorText}`);
  }
  await loaded;
  await delay(750);

  const requestsBeyondNavigation = requests.filter(
    (request, index) =>
      index !== 0 ||
      request.url !== harnessUrl ||
      request.method !== 'GET' ||
      request.resourceType !== 'Document',
  );
  const evidence = {
    harnessUrl,
    requests,
    requestsBeyondNavigation,
    sameOriginProbeRequests,
  };
  if (requestsBeyondNavigation.length !== 0 || sameOriginProbeRequests.length !== 0) {
    throw new Error(`Unexpected request: ${JSON.stringify(evidence)}`);
  }
  process.stdout.write(`${JSON.stringify(evidence)}\n`);
} catch (error) {
  process.stderr.write(`${error.stack ?? error}\n${chromeStderr}`);
  process.exitCode = 1;
} finally {
  session?.close();
  if (chrome && chrome.exitCode === null) chrome.kill();
  if (chrome) await waitForExit(chrome);
  await closeServer(server);
  try {
    await rm(profileDirectory, {
      recursive: true,
      force: true,
      maxRetries: 10,
      retryDelay: 100,
    });
  } catch (error) {
    process.stderr.write(
      `Warning: Chrome profile cleanup failed after retries: ${error.stack ?? error}\n`,
    );
  }
}
