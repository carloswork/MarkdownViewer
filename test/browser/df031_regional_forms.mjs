// DF-031 CP-D1 supporting evidence: the two bundled faces really do draw the
// same shared code points differently.
//
// Verification support, not product code.
//
// The glyph probe in the runners establishes this numerically (different alpha
// hashes for the same string). This renders it large and side by side so a
// human reviewing CP-D can see what "an override changes the rendered forms"
// actually means, rather than taking a hash on trust.
//
// The characters are the ones pinned in the fixtures' "regional form" line -
// all 17 verified present in BOTH realised repertoires, so the difference is
// regional convention and never coverage.
//
//   node test/browser/df031_regional_forms.mjs --browser <chrome.exe> --out <dir>

import { copyFile, mkdir, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { delay, launchChromium, removeDirectory, serveBundle, waitForValue } from './df031_cdp.mjs';

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
const FONTS = resolve(argument('--fonts', join(import.meta.dirname, '..', '..', 'fonts')));

const SAMPLE = '骨直者令次海每敏起花化具真值曾增黑';

const PAGE = `<!doctype html><meta charset="utf-8"><title>DF-031 regional forms</title>
<style>
  @font-face { font-family: "DF031Hant"; src: url("SaudoHant-Regular.otf") format("opentype"); font-weight: 400; font-display: block; }
  @font-face { font-family: "DF031Hans"; src: url("SaudoHans-Regular.otf") format("opentype"); font-weight: 400; font-display: block; }
  body { margin: 0; padding: 28px; background: #fff; color: #111;
         font: 15px/1.4 system-ui, sans-serif; }
  h1 { font-size: 17px; margin: 0 0 4px; }
  p.note { margin: 0 0 20px; color: #555; font-size: 13px; }
  .row { margin-bottom: 18px; }
  .label { font-size: 12px; letter-spacing: .06em; text-transform: uppercase; color: #666; margin-bottom: 2px; }
  .sample { font-size: 62px; line-height: 1.25; letter-spacing: 4px; }
  .hant { font-family: "DF031Hant"; }
  .hans { font-family: "DF031Hans"; }
  .bold { font-weight: 700; }
</style>
<h1>DF-031 — the same shared code points under each bundled face</h1>
<p class="note">All 17 characters are present in both realised repertoires, so what differs here is regional convention, not coverage. The third and fourth rows are the synthesised weight at <code>font-weight: 700</code>, which the faces do not ship.</p>
<div class="row"><div class="label">SaudoHant / DF031Hant — regular</div><div class="sample hant">${SAMPLE}</div></div>
<div class="row"><div class="label">SaudoHans / DF031Hans — regular</div><div class="sample hans">${SAMPLE}</div></div>
<div class="row"><div class="label">DF031Hant — synthesised bold (700)</div><div class="sample hant bold">${SAMPLE}</div></div>
<div class="row"><div class="label">DF031Hans — synthesised bold (700)</div><div class="sample hans bold">${SAMPLE}</div></div>

<hr style="margin:28px 0;border:0;border-top:1px solid #ddd">
<h1>Synthetic bold at the sizes the reader actually renders</h1>
<p class="note">markdown_theme.dart sets H1 28 / H2 23 / H3 20 px, and Settings.maxFontScale is 1.60, so 44.8 px is the largest Chinese heading the product can produce. Body text is 17 px regular, shown for contrast. These are the sizes CP-D item 4 is really asking about.</p>
<div class="row"><div class="label">H1 at max scale — 44.8px, weight 700</div><div class="sample hant bold" style="font-size:44.8px">漢字排版測試 敏每曾增黑</div></div>
<div class="row"><div class="label">H1 at default — 28px, weight 700</div><div class="sample hant bold" style="font-size:28px">漢字排版測試 敏每曾增黑</div></div>
<div class="row"><div class="label">H2 — 23px, weight 700</div><div class="sample hant bold" style="font-size:23px">繁體字樣本 敏每曾增黑</div></div>
<div class="row"><div class="label">H3 — 20px, weight 700</div><div class="sample hant bold" style="font-size:20px">區域字形對照 敏每曾增黑</div></div>
<div class="row"><div class="label">Body — 17px, weight 400 (contrast)</div><div class="sample hant" style="font-size:17px">這份文件用來驗證繁體中文的字型渲染 敏每曾增黑</div></div>
`;

const staging = join(OUT, 'regional-forms-page');
await mkdir(staging, { recursive: true });
await writeFile(join(staging, 'index.html'), PAGE, 'utf8');
await copyFile(join(FONTS, 'SaudoHant-Regular.otf'), join(staging, 'SaudoHant-Regular.otf'));
await copyFile(join(FONTS, 'SaudoHans-Regular.otf'), join(staging, 'SaudoHans-Regular.otf'));

const server = await serveBundle(staging);
const browser = await launchChromium(BROWSER, { windowSize: '1500,1100' });
try {
  const s = browser.session;
  await s.send('Runtime.enable');
  await s.send('Page.enable');
  await s.send('Page.navigate', { url: server.origin + '/' });
  await waitForValue(async () => await s.evaluate('return document.fonts.status === "loaded";'), 'font loading');
  await delay(600);
  const shot = await s.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
  const file = join(OUT, 'regional-forms.png');
  await writeFile(file, Buffer.from(shot.data, 'base64'));
  console.log(`wrote ${file}`);
} finally {
  await browser.close();
  await server.close();
  await removeDirectory(browser.profile);
}
