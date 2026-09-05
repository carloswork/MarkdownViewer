// DF-031 CP-D1, evidence item 8: no regressions.
//
// Verification support, not product code.
//
// "DF-023 colour emoji, DF-024 arrows/box-drawing and Latin typography are
// unchanged" is a claim about a *difference*, so it needs a real before. This
// renders the same zero-Han fixture in the pre-DF-031 release build
// (3077a3ac, v1.0.6) and in the DF-031 build, on the same engine, at the same
// size, and compares the pixels.
//
// The fixture is deliberately Han-free while the Viewer's fallback chain always
// carries both Han families regardless of document (markdown_theme.dart
// appends them unconditionally). So this is exactly the disjoint-repertoire
// claim under test: if either bundled Chinese face displaced an emoji, an
// arrow, a box-drawing character or a Latin glyph, these captures would differ.
//
//   node test/browser/df031_baseline_compare.mjs \
//     --browser <chrome.exe> --baseline <dir> --candidate <dir> --out <dir>

import { createHash } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import {
  delay,
  launchChromium,
  removeDirectory,
  serveBundle,
  waitForValue,
} from './df031_cdp.mjs';

function argument(name, fallback) {
  const index = process.argv.indexOf(name);
  if (index === -1 || index + 1 >= process.argv.length) {
    if (fallback !== undefined) return fallback;
    throw new Error(`Missing required argument: ${name}`);
  }
  return process.argv[index + 1];
}

const BROWSER = argument('--browser');
const OUT = resolve(argument('--out'));
const FIXTURES = resolve(
  argument('--fixtures', join(import.meta.dirname, 'df031_fixtures')),
);

const SEMANTICS = `
  return [...document.querySelectorAll('flt-semantics')].map(n => {
    const r = n.getBoundingClientRect();
    return { role: n.getAttribute('role'),
             text: n.childNodes.length && n.firstChild.nodeType === 3 ? n.textContent : null,
             x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) };
  });
`;

async function capture(label, bundleDirectory) {
  const server = await serveBundle(bundleDirectory);
  const browser = await launchChromium(BROWSER);
  const s = browser.session;
  let chooser = null;
  try {
    s.on('Page.fileChooserOpened', (p) => { chooser = p; });
    await s.send('Runtime.enable');
    await s.send('Page.enable');
    await s.send('DOM.enable');
    await s.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }] });
    await s.send('Page.setInterceptFileChooserDialog', { enabled: true });
    await s.send('Page.navigate', { url: server.origin + '/' });
    await waitForValue(
      async () => await s.evaluate(`return !!document.querySelector('flt-semantics-placeholder');`),
      'Flutter bootstrap',
    );
    await delay(2500);
    await s.evaluate(`document.querySelector('flt-semantics-placeholder').click(); return 1;`);
    await delay(1200);

    const node = await waitForValue(
      async () => (await s.evaluate(SEMANTICS)).find((n) => (n.text ?? '').startsWith('Load from file')),
      'Load from file',
    );
    const x = node.x + node.w / 2;
    const y = node.y + node.h / 2;
    await s.send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1 });
    await s.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', buttons: 0, clickCount: 1 });
    await delay(1300);
    if (!chooser) throw new Error('file chooser did not open');
    await s.send('DOM.setFileInputFiles', { files: [join(FIXTURES, 'english.md')], backendNodeId: chooser.backendNodeId });
    await delay(4000);

    const full = await s.send('Page.captureScreenshot', { format: 'png' });
    await writeFile(join(OUT, `regression-${label}-full.png`), Buffer.from(full.data, 'base64'));
    // The emoji / arrow / box-drawing band, magnified, so a one-glyph change is
    // visible rather than merely hashed.
    const band = await s.send('Page.captureScreenshot', {
      format: 'png', clip: { x: 60, y: 290, width: 620, height: 100, scale: 4 },
    });
    await writeFile(join(OUT, `regression-${label}-band.png`), Buffer.from(band.data, 'base64'));
    return {
      label,
      fullSha256: createHash('sha256').update(full.data).digest('hex'),
      bandSha256: createHash('sha256').update(band.data).digest('hex'),
      fullBytes: Buffer.from(full.data, 'base64').length,
    };
  } finally {
    await browser.close();
    await server.close();
    await removeDirectory(browser.profile);
  }
}

await mkdir(OUT, { recursive: true });
const baseline = await capture('baseline', resolve(argument('--baseline')));
const candidate = await capture('df031', resolve(argument('--candidate')));

const result = {
  baseline,
  candidate,
  fullIdentical: baseline.fullSha256 === candidate.fullSha256,
  bandIdentical: baseline.bandSha256 === candidate.bandSha256,
};
await writeFile(join(OUT, 'regression-evidence.json'), JSON.stringify(result, null, 2));
console.log(JSON.stringify(result, null, 2));
console.log(result.fullIdentical && result.bandIdentical
  ? 'PASS item8: zero-Han rendering is byte-identical before and after DF-031'
  : 'DIFFERS: inspect regression-*-full.png / regression-*-band.png');
