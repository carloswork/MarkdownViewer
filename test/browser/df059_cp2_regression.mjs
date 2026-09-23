// Local regression and privacy harness for the 16px editor change.
//
// The companion focus probe answers "does the editable compute to >=16px".
// This harness answers whether the real change regresses anything
// locally, does it leak anything, and what does it cost visually.
//
// Per build it records:
//
//   * EVERY network request the running app makes, flagged off-origin, from
//     first navigation to the end of the session (AC6's privacy half, applied
//     to the app rather than to the exported print HTML);
//   * the editable element's type, computed font-size and line-height, and
//     `window.visualViewport.scale`, at focus time on both editor routes and
//     on Search (the control);
//   * overflow and clipping probes - document and element scroll extents
//     against their client extents - on every surface;
//   * editing, selection and clipboard behaviour driven through the engine's
//     own pipeline, not by poking `.value`;
//   * Reader navigation across the menu;
//   * screenshots at five viewport widths for the responsive comparison.
//
// HARD BOUNDARY. This is DESKTOP WebKit
// (`SafariDesktopTextEditingStrategy`); iOS runs `IOSTextEditingStrategy`.
// Nothing here tests, reproduces or bears on the iPhone defect. This is a local
// product and regression check only.
//
// Usage:
//   node df059_cp2_regression.mjs --url=http://127.0.0.1:8736/ \
//        --build=prepared --out=out.json --shots=<dir>

import { webkit } from 'playwright';
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const arg = (name, fallback) => {
  const hit = process.argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.slice(name.length + 3) : fallback;
};

const URL = arg('url', 'http://127.0.0.1:8736/');
const BUILD = arg('build', 'unnamed');
const OUT = arg('out', null);
const SHOTS = arg('shots', null);

// 320 is the narrowest phone still worth supporting; 390 is the reporter's
// device class; 420 matches the companion probe so the numbers are comparable; 768 and 1280
// cover the tablet and wide layouts.
const VIEWPORTS = [
  { name: 'w320', width: 320, height: 568 },
  { name: 'w390', width: 390, height: 844 },
  { name: 'w420', width: 420, height: 860 },
  { name: 'w768', width: 768, height: 1024 },
  { name: 'w1280', width: 1280, height: 800 },
];
const PRIMARY = VIEWPORTS.find((v) => v.name === 'w420');

if (SHOTS) mkdirSync(SHOTS, { recursive: true });

const SAMPLE =
  '# Probe heading\n\nalpha bravo charlie delta echo foxtrot golf hotel india.';

// ---------------------------------------------------------------------------
// Probes
// ---------------------------------------------------------------------------

const probe = (page, surface) =>
  page.evaluate((surfaceName) => {
    const round = (n) => Math.round(n * 100) / 100;
    const vv = window.visualViewport;

    const describe = (el) => {
      if (!el) return null;
      const cs = getComputedStyle(el);
      const r = el.getBoundingClientRect();
      return {
        elementType: el.tagName.toLowerCase(),
        className: el.className || '',
        computedFontSize: cs.fontSize,
        computedLineHeight: cs.lineHeight,
        inlineFontShorthand: el.style.font || '',
        isActiveElement: document.activeElement === el,
        rect: { x: round(r.x), y: round(r.y), w: round(r.width), h: round(r.height) },
        selectionStart: 'selectionStart' in el ? el.selectionStart : null,
        selectionEnd: 'selectionEnd' in el ? el.selectionEnd : null,
        valueLength: 'value' in el ? String(el.value ?? '').length : null,
        // Overflow inside the editable itself. `white-space: pre-wrap` means a
        // horizontal overflow would indicate the element is not wrapping where
        // it should.
        scrollWidth: el.scrollWidth,
        clientWidth: el.clientWidth,
        scrollHeight: el.scrollHeight,
        clientHeight: el.clientHeight,
        overflowsHorizontally: el.scrollWidth > el.clientWidth,
      };
    };

    const host = document.querySelector('flt-text-editing-host');
    const active = document.activeElement;
    const activeIsEngineEditable =
      !!active &&
      !!(active.closest && active.closest('flt-text-editing-host')) &&
      !!(active.classList && active.classList.contains('flt-text-editing'));

    const doc = document.documentElement;
    return {
      surface: surfaceName,
      focusedEditable: activeIsEngineEditable ? describe(active) : null,
      engineEditables: host
        ? Array.from(host.querySelectorAll('.flt-text-editing')).map(describe)
        : [],
      visualViewport: vv
        ? { scale: vv.scale, width: round(vv.width), height: round(vv.height) }
        : null,
      // Page-level clipping / overflow. A horizontal document overflow on a
      // phone width is the classic symptom of a layout regression.
      page: {
        innerWidth: window.innerWidth,
        innerHeight: window.innerHeight,
        docScrollWidth: doc.scrollWidth,
        docClientWidth: doc.clientWidth,
        docScrollHeight: doc.scrollHeight,
        docClientHeight: doc.clientHeight,
        horizontalOverflow: doc.scrollWidth > doc.clientWidth,
        devicePixelRatio: window.devicePixelRatio,
      },
      // The Flutter render surface. If the canvas is wider than the viewport
      // something has pushed the layout out.
      canvases: Array.from(document.querySelectorAll('flt-scene-host canvas, canvas')).map(
        (c) => {
          const r = c.getBoundingClientRect();
          return { w: round(r.width), h: round(r.height), x: round(r.x), y: round(r.y) };
        },
      ),
    };
  }, surface);

const semanticsTree = (page) =>
  page.evaluate(() =>
    Array.from(document.querySelectorAll('flt-semantics'))
      .map((e) => {
        const r = e.getBoundingClientRect();
        return {
          role: e.getAttribute('role') || '',
          label: e.getAttribute('aria-label') || '',
          text: (e.textContent || '').trim().slice(0, 80),
          rect: {
            x: Math.round(r.x), y: Math.round(r.y),
            w: Math.round(r.width), h: Math.round(r.height),
          },
        };
      })
      .filter((n) => (n.role || n.text || n.label) && n.rect.w > 0 && n.rect.h > 0),
  );

// Match the control itself, never the ancestor whose textContent concatenates
// every descendant label (a lesson from the companion probe).
const findControl = (tree, label) => {
  const want = label.toLowerCase();
  const exact = tree.find(
    (n) =>
      (n.role || n.label) &&
      (n.text.trim().toLowerCase() === want || n.label.trim().toLowerCase() === want),
  );
  if (exact) return exact;
  const containing = tree
    .filter((n) => n.text.toLowerCase().includes(want) || n.label.toLowerCase().includes(want))
    .sort((a, b) => a.rect.w * a.rect.h - b.rect.w * b.rect.h);
  return containing[0] || null;
};

const findReaderMenu = (tree, vp) => {
  const c = tree.filter(
    (n) =>
      /button/i.test(n.role) && !n.text &&
      n.rect.w <= 72 && n.rect.h <= 72 &&
      n.rect.x > vp.width * 0.5 && n.rect.y > vp.height * 0.5,
  );
  return c[c.length - 1] || null;
};

const centre = (n) => ({ x: n.rect.x + n.rect.w / 2, y: n.rect.y + n.rect.h / 2 });

const enableSemantics = async (page) => {
  await page.evaluate(() => {
    const p = document.querySelector('flt-semantics-placeholder');
    if (p) {
      p.style.cssText =
        'position:fixed;left:0;top:0;width:120px;height:60px;z-index:2147483647;opacity:0.01;';
    }
  });
  await page.waitForTimeout(300);
  await page.mouse.click(40, 20);
  await page.waitForTimeout(2500);
};

// Every request the page makes, with an off-origin flag. This is the privacy
// Privacy audit applied to the running app.
const attachNetworkAudit = (page, origin, sink) => {
  page.on('request', (req) => {
    let offOrigin = true;
    try {
      offOrigin = new globalThis.URL(req.url()).origin !== origin;
    } catch {
      offOrigin = !req.url().startsWith('data:') && !req.url().startsWith('blob:');
    }
    if (req.url().startsWith('data:') || req.url().startsWith('blob:')) offOrigin = false;
    sink.push({
      url: req.url().slice(0, 200),
      method: req.method(),
      resourceType: req.resourceType(),
      offOrigin,
    });
  });
  page.on('requestfailed', (req) =>
    sink.push({ url: req.url().slice(0, 200), failed: true, error: req.failure()?.errorText }),
  );
};

const boot = async (browser, vp, { semantics }, sink, origin) => {
  const page = await browser.newPage({ viewport: { width: vp.width, height: vp.height } });
  const consoleErrors = [];
  page.on('console', (m) => {
    if (m.type() === 'error') consoleErrors.push(m.text().slice(0, 300));
  });
  page.on('pageerror', (e) => consoleErrors.push(`pageerror: ${String(e).slice(0, 300)}`));
  if (sink) attachNetworkAudit(page, origin, sink);
  await page.goto(URL, { waitUntil: 'load' });
  await page.waitForFunction(() => document.body.getAttribute('flt-embedding'), null, {
    timeout: 90000,
  });
  await page.waitForTimeout(4500);
  if (semantics) await enableSemantics(page);
  page.__consoleErrors = consoleErrors;
  return page;
};

// ---------------------------------------------------------------------------
// Locator pass (semantics ON) - coordinates only, per viewport.
// ---------------------------------------------------------------------------

const locate = async (browser, vp, sink) => {
  const page = await boot(browser, vp, { semantics: true }, null, null);
  const coords = {};
  const home = await semanticsTree(page);
  const paste = findControl(home, 'Paste Markdown');
  if (!paste) throw new Error(`${vp.name}: no Paste Markdown on Home`);
  coords.pasteMarkdown = centre(paste);

  await page.mouse.click(coords.pasteMarkdown.x, coords.pasteMarkdown.y);
  await page.waitForTimeout(3000);
  // The editor TextField is not exposed as a semantics textbox in this build,
  // so this coordinate is a geometric fallback and is recorded as such.
  coords.editorField = { x: vp.width / 2, y: Math.min(240, vp.height * 0.35) };
  coords.editorFieldSource = 'geometric-fallback';

  await page.keyboard.type(SAMPLE, { delay: 3 });
  await page.waitForTimeout(700);
  const open = findControl(await semanticsTree(page), 'Open');
  if (!open) throw new Error(`${vp.name}: no Open action`);
  coords.open = centre(open);

  await page.mouse.click(coords.open.x, coords.open.y);
  await page.waitForTimeout(3000);
  const menu = findReaderMenu(await semanticsTree(page), vp);
  if (!menu) throw new Error(`${vp.name}: no reader menu control`);
  coords.readerMenu = centre(menu);

  await page.mouse.click(coords.readerMenu.x, coords.readerMenu.y);
  await page.waitForTimeout(2200);
  const tree = await semanticsTree(page);
  const edit = findControl(tree, 'Edit local copy');
  const search = findControl(tree, 'Search document');
  if (!edit) throw new Error(`${vp.name}: no Edit local copy tile`);
  if (!search) throw new Error(`${vp.name}: no Search document tile`);
  coords.editLocalCopy = centre(edit);
  coords.searchDocument = centre(search);
  coords.menuTiles = tree
    .filter((n) => /button/i.test(n.role) && n.text)
    .map((n) => ({ text: n.text, rect: n.rect }));

  await page.close();
  return coords;
};

// ---------------------------------------------------------------------------
// Primary pass (semantics OFF) - the measurements and the regression checks.
// ---------------------------------------------------------------------------

const runPrimary = async (browser, coords, origin) => {
  const requests = [];
  const vp = PRIMARY;
  const page = await boot(browser, vp, { semantics: false }, requests, origin);
  const surfaces = [];
  const checks = {};
  const shoot = async (name) => {
    if (!SHOTS) return;
    await page.screenshot({ path: path.join(SHOTS, `${BUILD}-${vp.name}-${name}.png`) });
  };

  surfaces.push(await probe(page, 'home'));
  await shoot('home');

  // --- Paste Markdown -----------------------------------------------------
  await page.mouse.click(coords.pasteMarkdown.x, coords.pasteMarkdown.y);
  await page.waitForTimeout(3000);
  surfaces.push(await probe(page, 'paste-markdown@entry-autofocus'));
  await shoot('paste-markdown-empty');

  await page.keyboard.type(SAMPLE, { delay: 3 });
  await page.waitForTimeout(800);
  surfaces.push(await probe(page, 'paste-markdown@after-typing'));
  await shoot('paste-markdown-typed');

  // --- Editing, selection and clipboard, through the engine ---------------
  await page.keyboard.press('Control+a');
  await page.waitForTimeout(400);
  const selectAll = await probe(page, 'paste-markdown@select-all');
  surfaces.push(selectAll);
  await page.keyboard.press('Control+c');
  await page.waitForTimeout(400);
  await page.keyboard.press('ArrowRight');
  await page.keyboard.press('Control+v');
  await page.waitForTimeout(900);
  const afterPaste = await probe(page, 'paste-markdown@after-copy-paste');
  surfaces.push(afterPaste);
  checks.clipboard = {
    selectedLength: selectAll.focusedEditable?.valueLength ?? null,
    selectionSpannedAll:
      selectAll.focusedEditable?.selectionStart === 0 &&
      selectAll.focusedEditable?.selectionEnd === selectAll.focusedEditable?.valueLength,
    lengthAfterPaste: afterPaste.focusedEditable?.valueLength ?? null,
    doubled:
      !!selectAll.focusedEditable &&
      afterPaste.focusedEditable?.valueLength === selectAll.focusedEditable.valueLength * 2,
  };

  // Undo the paste so the document that reaches the Reader is the sample.
  await page.keyboard.press('Control+z');
  await page.waitForTimeout(700);
  surfaces.push(await probe(page, 'paste-markdown@after-undo'));

  // --- Reader -------------------------------------------------------------
  await page.mouse.click(coords.open.x, coords.open.y);
  await page.waitForTimeout(3000);
  surfaces.push(await probe(page, 'reader'));
  await shoot('reader');

  // Reader navigation: scroll, then the menu.
  await page.mouse.wheel(0, 400);
  await page.waitForTimeout(700);
  surfaces.push(await probe(page, 'reader@scrolled'));
  await shoot('reader-scrolled');
  await page.mouse.wheel(0, -400);
  await page.waitForTimeout(500);

  await page.mouse.click(coords.readerMenu.x, coords.readerMenu.y);
  await page.waitForTimeout(2200);
  surfaces.push(await probe(page, 'reader@menu-open'));
  await shoot('reader-menu');

  // --- Search: THE CONTROL -------------------------------------------------
  await page.mouse.click(coords.searchDocument.x, coords.searchDocument.y);
  await page.waitForTimeout(2500);
  await page.keyboard.type('bravo', { delay: 10 });
  await page.waitForTimeout(900);
  surfaces.push(await probe(page, 'search-CONTROL'));
  await shoot('search-control');

  await page.keyboard.press('Escape');
  await page.waitForTimeout(1500);

  // --- Edit local copy ----------------------------------------------------
  await page.mouse.click(coords.readerMenu.x, coords.readerMenu.y);
  await page.waitForTimeout(2200);
  await page.mouse.click(coords.editLocalCopy.x, coords.editLocalCopy.y);
  await page.waitForTimeout(3000);
  surfaces.push(await probe(page, 'edit-local-copy@entry-no-autofocus'));
  await shoot('edit-local-copy-entry');

  await page.mouse.click(coords.editorField.x, coords.editorField.y);
  await page.waitForTimeout(1200);
  surfaces.push(await probe(page, 'edit-local-copy@focused'));
  await shoot('edit-local-copy-focused');

  // A long line, to force the wrap behaviour the appearance cost is about.
  await page.keyboard.press('Control+End');
  await page.keyboard.type(
    '\n\nA deliberately long line of raw Markdown source text that must wrap inside the editor field.',
    { delay: 3 },
  );
  await page.waitForTimeout(900);
  surfaces.push(await probe(page, 'edit-local-copy@long-line'));
  await shoot('edit-local-copy-long-line');

  checks.consoleErrors = page.__consoleErrors;
  await page.close();
  return { surfaces, requests, checks };
};

// ---------------------------------------------------------------------------
// Responsive sweep - screenshots and overflow probes at every viewport.
// ---------------------------------------------------------------------------

const runResponsive = async (browser, coordsByViewport, origin) => {
  const results = [];
  for (const vp of VIEWPORTS) {
    const coords = coordsByViewport[vp.name];
    const page = await boot(browser, vp, { semantics: false }, null, origin);
    const shoot = async (name) => {
      if (!SHOTS) return;
      await page.screenshot({ path: path.join(SHOTS, `${BUILD}-${vp.name}-${name}.png`) });
    };
    const out = { viewport: vp, surfaces: [] };

    out.surfaces.push(await probe(page, `${vp.name}:home`));
    await page.mouse.click(coords.pasteMarkdown.x, coords.pasteMarkdown.y);
    await page.waitForTimeout(2800);
    out.surfaces.push(await probe(page, `${vp.name}:paste-markdown@entry`));
    await shoot('rs-paste-markdown-empty');

    await page.keyboard.type(SAMPLE, { delay: 3 });
    await page.waitForTimeout(800);
    out.surfaces.push(await probe(page, `${vp.name}:paste-markdown@typed`));
    await shoot('rs-paste-markdown-typed');

    await page.mouse.click(coords.open.x, coords.open.y);
    await page.waitForTimeout(2800);
    out.surfaces.push(await probe(page, `${vp.name}:reader`));
    await shoot('rs-reader');

    out.consoleErrors = page.__consoleErrors;
    await page.close();
    results.push(out);
  }
  return results;
};

// ---------------------------------------------------------------------------

(async () => {
  const browser = await webkit.launch();
  const origin = new globalThis.URL(URL).origin;
  const result = {
    harness: 'df059_cp2_regression.mjs',
    build: BUILD,
    url: URL,
    engine: 'playwright-webkit',
    engineVersion: browser.version(),
    platform: `${process.platform} ${process.arch}`,
    node: process.version,
    capturedAt: new Date().toISOString(),
    viewports: VIEWPORTS,
    boundary:
      'Desktop WebKit (SafariDesktopTextEditingStrategy). NOT iOS. CP2 is a ' +
      'local product and regression check; it does not test, reproduce or ' +
      'bear on the iPhone defect.',
  };
  try {
    const coordsByViewport = {};
    for (const vp of VIEWPORTS) coordsByViewport[vp.name] = await locate(browser, vp);
    result.coords = coordsByViewport;
    result.primary = await runPrimary(browser, coordsByViewport[PRIMARY.name], origin);
    result.responsive = await runResponsive(browser, coordsByViewport, origin);
    result.offOriginRequests = result.primary.requests.filter((r) => r.offOrigin);
    result.status = 'ok';
  } catch (err) {
    result.status = 'error';
    result.error = { message: err.message, stack: err.stack };
  } finally {
    await browser.close();
  }

  const json = JSON.stringify(result, null, 2);
  if (OUT) {
    mkdirSync(path.dirname(OUT), { recursive: true });
    writeFileSync(OUT, json, 'utf8');
    console.log(`${BUILD}: ${result.status} -> ${OUT}`);
    if (result.status === 'ok') {
      console.log(`  requests: ${result.primary.requests.length}, off-origin: ${result.offOriginRequests.length}`);
    }
  } else {
    console.log(json);
  }
  if (result.status === 'error') {
    console.error(result.error.message);
    process.exitCode = 1;
  }
})();
