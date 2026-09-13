// DF-041 Checkpoint-1 optimized Flutter Web performance harness.
// Uses the repository's raw-CDP helper and introduces no npm dependency.

import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';

import {
  delay,
  launchChromium,
  removeDirectory,
  serveBundle,
  waitForValue,
} from './df031_cdp.mjs';

function argument(name) {
  const index = process.argv.indexOf(name);
  if (index === -1 || index + 1 >= process.argv.length) {
    throw new Error(`Missing required argument: ${name}`);
  }
  return process.argv[index + 1];
}

const chromePath = resolve(argument('--chrome'));
const bundlePath = resolve(argument('--bundle'));
const outputPath = resolve(argument('--out'));

const server = await serveBundle(bundlePath);
const browser = await launchChromium(chromePath, { windowSize: '1280,900' });

try {
  const session = browser.session;
  await session.send('Page.enable');
  await session.send('Runtime.enable');
  const url = `${server.origin}/`;
  const loaded = new Promise((done) =>
    session.on('Page.loadEventFired', () => done()),
  );
  const navigation = await session.send('Page.navigate', { url });
  if (navigation.errorText) {
    throw new Error(`Navigation failed: ${navigation.errorText}`);
  }
  await loaded;

  const raw = await waitForValue(
    () => session.evaluate(`
      return document.body?.dataset?.df041Cp1Performance ?? null;
    `),
    'DF-041 CP1 performance result',
    120000,
  );
  const result = JSON.parse(raw);
  const evidence = {
    generated_at: new Date().toISOString(),
    browser: chromePath,
    bundle: bundlePath,
    mode: 'flutter build web --release',
    requested_paths: server.requestLog,
    ...result,
  };

  await mkdir(dirname(outputPath), { recursive: true });
  await writeFile(outputPath, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');
  process.stdout.write(`${JSON.stringify(evidence)}\n`);
  if (!result.passed) process.exitCode = 1;
} catch (error) {
  process.stderr.write(`${error.stack ?? error}\n${browser.stderrText()}`);
  process.exitCode = 1;
} finally {
  await browser.close();
  await server.close();
  await delay(50);
  await removeDirectory(browser.profile);
}
