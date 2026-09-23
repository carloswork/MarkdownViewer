// Desktop-WebKit runtime measurement harness for editable focus behaviour.
//
// For each surface it reports, AT FOCUS TIME:
//
//   * the DOM element type of the real editable element;
//   * its computed `font-size`;
//   * `window.visualViewport.scale`.
//
// Search is preserved as the control surface.
//
// HARD BOUNDARY - read before using any output of this file.
// Playwright's WebKit is a DESKTOP WebKit build. It selects
// `SafariDesktopTextEditingStrategy`; iOS selects `IOSTextEditingStrategy`, a
// different class with a different creation, placement and style
// re-application lifecycle. NO iOS BEHAVIOUR MAY BE INFERRED FROM THIS
// HARNESS. A desktop run can eliminate a proposed styling approach; it can
// never validate one for iOS.
//
// The harness runs two passes per build, because the engine resolves its
// text-editing strategy once, lazily, and picks `SemanticsTextEditingStrategy`
// when semantics is enabled (engine text_editing.dart `late final strategy`):
//
//   Pass 1 - LOCATOR, semantics ON.  Produces click coordinates only. Its
//            editable measurements are discarded; they are the wrong element.
//   Pass 2 - MEASUREMENT, semantics OFF.  Drives the app by the coordinates
//            from pass 1 and measures the default-strategy editable, i.e. the
//            element a non-VoiceOver user actually gets.
//
// Usage:
//   node df059_cp1_webkit.mjs --url=http://127.0.0.1:8733/ --build=baseline \
//        --out=out.json [--shots=<dir>]

import { webkit } from 'playwright';
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const arg = (name, fallback) => {
  const hit = process.argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.slice(name.length + 3) : fallback;
};

const URL = arg('url', 'http://127.0.0.1:8733/');
const BUILD = arg('build', 'unnamed');
const OUT = arg('out', null);
const SHOTS = arg('shots', null);
const VIEWPORT = { width: 420, height: 860 };

if (SHOTS) mkdirSync(SHOTS, { recursive: true });

// ---------------------------------------------------------------------------
// Probes
// ---------------------------------------------------------------------------

// The three plan-required readings, plus enough context to tell which element
// was measured and whether it was genuinely focused at the moment of reading.
const focusProbe = (page, surface) =>
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
        // The engine writes the `font` shorthand to the style ATTRIBUTE
        // (text_editing.dart applyToDomElement), so an author rule needs
        // `!important` to win. Record both so the cascade outcome is visible.
        inlineFontShorthand: el.style.font || '',
        inlineFontSize: el.style.fontSize || '',
        computedFontFamily: cs.fontFamily.slice(0, 64),
        computedLineHeight: cs.lineHeight,
        isActiveElement: document.activeElement === el,
        inTextEditingHost: !!el.closest('flt-text-editing-host'),
        rect: { x: round(r.x), y: round(r.y), w: round(r.width), h: round(r.height) },
        transform: cs.transform,
        opacity: cs.opacity,
        color: cs.color,
        caretColor: cs.caretColor,
        selectionStart: 'selectionStart' in el ? el.selectionStart : null,
        selectionEnd: 'selectionEnd' in el ? el.selectionEnd : null,
        valueLength: 'value' in el ? String(el.value ?? '').length : null,
        scrollTop: el.scrollTop,
        scrollHeight: el.scrollHeight,
        clientHeight: el.clientHeight,
        // A hidden-element font override raises the HIDDEN element's font-size while the painted
        // text stays at the Dart size, so the two can disagree about where a
        // given character sits. The browser positions native selection UI from
        // the hidden element; Flutter paints the caret and text on canvas from
        // the Dart style. Measure the divergence directly rather than reasoning
        // about it: advance width of the text before the caret, under the
        // element's COMPUTED font versus the engine's INLINE (painted-intent)
        // font. Zero means the two agree.
        caretMetrics: (() => {
          try {
            const value = 'value' in el ? String(el.value ?? '') : '';
            const head = value.slice(0, el.selectionStart ?? 0);
            // Only the caret's own line contributes to its x position.
            const upto = head.slice(head.lastIndexOf('\n') + 1);
            if (!upto) return { before: '', computedPx: 0, engineIntentPx: 0, deltaPx: 0 };
            const ctx = document.createElement('canvas').getContext('2d');
            const computedFont =
              `${cs.fontStyle} ${cs.fontWeight} ${cs.fontSize}/${cs.lineHeight} ${cs.fontFamily}`;
            const engineFont = el.style.font || computedFont;
            const measure = (font) => {
              ctx.font = font;
              return Math.round(ctx.measureText(upto).width * 100) / 100;
            };
            const computedPx = measure(computedFont);
            const engineIntentPx = measure(engineFont);
            return {
              before: upto.slice(-24),
              computedFont,
              engineFont,
              computedPx,
              engineIntentPx,
              deltaPx: Math.round((computedPx - engineIntentPx) * 100) / 100,
            };
          } catch (e) {
            return { error: String(e) };
          }
        })(),
      };
    };

    // The real editable is the engine-tagged element inside the light-DOM
    // text-editing host (dom_manager.dart flt-text-editing-host,
    // text_editing.dart HybridTextEditing.textEditingClass).
    const host = document.querySelector('flt-text-editing-host');
    const engineEditables = host
      ? Array.from(host.querySelectorAll('.flt-text-editing')).map(describe)
      : [];

    const active = document.activeElement;
    const activeIsEngineEditable =
      !!active &&
      !!(active.closest && active.closest('flt-text-editing-host')) &&
      !!(active.classList && active.classList.contains('flt-text-editing'));

    return {
      surface: surfaceName,
      semanticsEnabled: !!document.querySelector('flt-semantics'),
      // --- the three plan-required readings ------------------------------
      // `focusedEditable` is the authoritative row: the element that actually
      // held focus when the reading was taken.
      focusedEditable: activeIsEngineEditable ? describe(active) : null,
      engineEditables,
      visualViewport: vv
        ? {
            scale: vv.scale,
            width: round(vv.width),
            height: round(vv.height),
            offsetTop: round(vv.offsetTop),
            offsetLeft: round(vv.offsetLeft),
            pageTop: round(vv.pageTop),
          }
        : null,
      // -------------------------------------------------------------------
      devicePixelRatio: window.devicePixelRatio,
      activeElementTag: active ? active.tagName.toLowerCase() : null,
      activeElementClass: active ? active.className || '' : '',
      // Every input/textarea in the document, so a stray engine-internal field
      // cannot be mistaken for the editable (the Cycle 4 dumps contain a 13px
      // "MS Shell Dlg" <input> that is not the editing element).
      allFields: Array.from(document.querySelectorAll('input, textarea')).map(describe),
      viewportMeta: Array.from(document.querySelectorAll('meta[name="viewport"]')).map((m) => ({
        content: m.getAttribute('content'),
        fltViewport: m.hasAttribute('flt-viewport'),
      })),
      // An optional override, if present, is an application-owned <style>.
      // Record every document-level stylesheet rule that mentions the engine's
      // editable class, so the harness proves what was actually served.
      authorEditableRules: Array.from(document.styleSheets).flatMap((sheet) => {
        let rules = [];
        try {
          rules = Array.from(sheet.cssRules || []);
        } catch (e) {
          return [];
        }
        return rules
          .filter((r) => r.cssText && r.cssText.indexOf('flt-text-editing') !== -1)
          .map((r) => r.cssText);
      }),
    };
  }, surface);

const semanticsTree = (page) =>
  page.evaluate(() =>
    Array.from(document.querySelectorAll('flt-semantics'))
      .map((e, i) => {
        const r = e.getBoundingClientRect();
        return {
          i,
          role: e.getAttribute('role') || '',
          label: e.getAttribute('aria-label') || '',
          text: (e.textContent || '').trim().slice(0, 80),
          rect: {
            x: Math.round(r.x),
            y: Math.round(r.y),
            w: Math.round(r.width),
            h: Math.round(r.height),
          },
        };
      })
      .filter((n) => (n.role || n.text || n.label) && n.rect.w > 0 && n.rect.h > 0),
  );

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

const boot = async (browser, { semantics }) => {
  const page = await browser.newPage({ viewport: VIEWPORT });
  await page.goto(URL, { waitUntil: 'load' });
  await page.waitForFunction(() => document.body.getAttribute('flt-embedding'), null, {
    timeout: 90000,
  });
  await page.waitForTimeout(4500);
  if (semantics) await enableSemantics(page);
  return page;
};

const findNode = (tree, pattern) =>
  tree.find((n) => pattern.test(n.label) || pattern.test(n.text)) || null;

// Flutter's semantics tree nests: an ancestor container's `textContent`
// concatenates every descendant label, so a substring match can select the
// full-viewport scrim instead of the tile. Match the control itself: an
// interactive node whose own trimmed text IS the label.
const findControl = (tree, label) => {
  const want = label.toLowerCase();
  const exact = tree.find(
    (n) =>
      (n.role || n.label) &&
      (n.text.trim().toLowerCase() === want || n.label.trim().toLowerCase() === want),
  );
  if (exact) return exact;
  // Fall back to the smallest node that contains the label, which is still
  // never the scrim.
  const containing = tree
    .filter((n) => n.text.toLowerCase().includes(want) || n.label.toLowerCase().includes(want))
    .sort((a, b) => a.rect.w * a.rect.h - b.rect.w * b.rect.h);
  return containing[0] || null;
};

// The reader's menu control is an unlabelled icon button in the bottom-right
// corner (reader_screen.dart `_MenuButton`), so it cannot be matched by text.
// Match it structurally instead: a small, square-ish button in the lower right
// of the viewport.
const findReaderMenu = (tree) => {
  const candidates = tree.filter(
    (n) =>
      /button/i.test(n.role) &&
      !n.text &&
      n.rect.w <= 72 &&
      n.rect.h <= 72 &&
      n.rect.x > VIEWPORT.width * 0.5 &&
      n.rect.y > VIEWPORT.height * 0.5,
  );
  return candidates[candidates.length - 1] || null;
};

const centre = (node) => ({
  x: node.rect.x + node.rect.w / 2,
  y: node.rect.y + node.rect.h / 2,
});

const shoot = async (page, name) => {
  if (!SHOTS) return null;
  const file = path.join(SHOTS, `${BUILD}-${name}.png`);
  await page.screenshot({ path: file });
  return file;
};

// Type through the real keyboard so the engine's editing pipeline runs, rather
// than poking `.value`, which bypasses it.
// The last line is long and carries NO trailing newline, so the caret comes to
// rest mid-line and `caretMetrics` has something to measure.
const SAMPLE = '# Probe heading\n\nalpha bravo charlie delta echo foxtrot golf hotel india.';
const typeSample = async (page) => {
  await page.keyboard.type(SAMPLE, { delay: 4 });
  await page.waitForTimeout(800);
};

// ---------------------------------------------------------------------------
// Pass 1 - LOCATOR (semantics ON). Coordinates only.
// ---------------------------------------------------------------------------

const locate = async (browser, sink) => {
  const page = await boot(browser, { semantics: true });
  const coords = sink.coords;
  const trees = sink.trees;

  trees.home = await semanticsTree(page);
  const paste = findControl(trees.home, 'Paste Markdown') || findNode(trees.home, /paste/i);
  if (!paste) throw new Error('locator: no Paste Markdown node on Home');
  coords.pasteMarkdown = centre(paste);

  await page.mouse.click(coords.pasteMarkdown.x, coords.pasteMarkdown.y);
  await page.waitForTimeout(3000);
  trees.editor = await semanticsTree(page);

  // The editor field itself, so the measurement pass can focus it explicitly
  // on the `Edit local copy` route, which does NOT autofocus.
  //
  // Flutter does not expose this TextField as a semantics textbox in this
  // build, so there is usually no node to match. The fallback is geometric and
  // is recorded as such: the editor body is the full width below the 56px app
  // bar (paste_sheet.dart `Expanded` inside a 16/4/16/8 padding), so a point a
  // little below the app bar lands inside the field.
  const field =
    trees.editor.find((n) => /textbox/i.test(n.role)) ||
    findNode(trees.editor, /Long-press here/i);
  if (field) {
    coords.editorField = centre(field);
    coords.editorFieldSource = 'semantics';
  } else {
    coords.editorField = { x: VIEWPORT.width / 2, y: 240 };
    coords.editorFieldSource = 'geometric-fallback';
  }

  await typeSample(page);
  trees.editorTyped = await semanticsTree(page);
  const open = findControl(trees.editorTyped, 'Open');
  if (!open) throw new Error('locator: no Open action in the editor app bar');
  coords.open = centre(open);

  await page.mouse.click(coords.open.x, coords.open.y);
  await page.waitForTimeout(3000);
  trees.reader = await semanticsTree(page);

  const menu = findNode(trees.reader, /menu/i) || findReaderMenu(trees.reader);
  if (!menu) throw new Error('locator: no reader menu control');
  coords.readerMenu = centre(menu);

  await page.mouse.click(coords.readerMenu.x, coords.readerMenu.y);
  await page.waitForTimeout(2200);
  trees.menu = await semanticsTree(page);

  const edit = findControl(trees.menu, 'Edit local copy');
  const search = findControl(trees.menu, 'Search document');
  if (!edit) throw new Error('locator: no Edit local copy tile');
  if (!search) throw new Error('locator: no Search document tile');
  coords.editLocalCopy = centre(edit);
  coords.searchDocument = centre(search);

  // The Search field, located from the search sheet.
  await page.mouse.click(coords.searchDocument.x, coords.searchDocument.y);
  await page.waitForTimeout(2500);
  trees.search = await semanticsTree(page);
  const searchField = trees.search.find((n) => /textbox|searchbox/i.test(n.role));
  if (searchField) coords.searchField = centre(searchField);

  await page.close();
  return sink;
};

// ---------------------------------------------------------------------------
// Pass 2 - MEASUREMENT (semantics OFF). The readings that count.
// ---------------------------------------------------------------------------

const measure = async (browser, coords) => {
  const page = await boot(browser, { semantics: false });
  const surfaces = [];
  const shots = {};

  surfaces.push(await focusProbe(page, 'home'));

  // --- Surface 1: Paste Markdown (autofocus: true) -------------------------
  await page.mouse.click(coords.pasteMarkdown.x, coords.pasteMarkdown.y);
  await page.waitForTimeout(3000);
  surfaces.push(await focusProbe(page, 'paste-markdown@entry-autofocus'));
  shots.pasteMarkdownEmpty = await shoot(page, 'paste-markdown-empty');

  await typeSample(page);
  surfaces.push(await focusProbe(page, 'paste-markdown@after-typing'));
  shots.pasteMarkdownTyped = await shoot(page, 'paste-markdown-typed');

  // --- Surface 2: Reader, then Search (THE CONTROL) ------------------------
  await page.mouse.click(coords.open.x, coords.open.y);
  await page.waitForTimeout(3000);
  surfaces.push(await focusProbe(page, 'reader'));
  shots.reader = await shoot(page, 'reader');

  await page.mouse.click(coords.readerMenu.x, coords.readerMenu.y);
  await page.waitForTimeout(2200);
  await page.mouse.click(coords.searchDocument.x, coords.searchDocument.y);
  await page.waitForTimeout(2500);
  if (coords.searchField) {
    await page.mouse.click(coords.searchField.x, coords.searchField.y);
    await page.waitForTimeout(900);
  }
  await page.keyboard.type('bravo', { delay: 10 });
  await page.waitForTimeout(900);
  surfaces.push(await focusProbe(page, 'search-CONTROL'));
  shots.search = await shoot(page, 'search-control');

  await page.keyboard.press('Escape');
  await page.waitForTimeout(1500);

  // --- Surface 3: Edit local copy (autofocus: false) -----------------------
  // This is also the SECOND EDITING SESSION on the same page, which is the
  // Session-survival check: the engine re-applies its inline style per session.
  await page.mouse.click(coords.readerMenu.x, coords.readerMenu.y);
  await page.waitForTimeout(2200);
  await page.mouse.click(coords.editLocalCopy.x, coords.editLocalCopy.y);
  await page.waitForTimeout(3000);
  surfaces.push(await focusProbe(page, 'edit-local-copy@entry-no-autofocus'));

  if (coords.editorField) {
    await page.mouse.click(coords.editorField.x, coords.editorField.y);
    await page.waitForTimeout(1200);
  }
  surfaces.push(await focusProbe(page, 'edit-local-copy@session-2-focused'));
  shots.editLocalCopy = await shoot(page, 'edit-local-copy-session-2');

  // Caret / selection geometry: select a range through the engine's own
  // pipeline and read back what the editable reports.
  await page.keyboard.press('Control+a');
  await page.waitForTimeout(600);
  surfaces.push(await focusProbe(page, 'edit-local-copy@select-all'));
  shots.editLocalCopySelectAll = await shoot(page, 'edit-local-copy-select-all');

  await page.keyboard.press('ArrowRight');
  await page.keyboard.type(' zulu', { delay: 10 });
  await page.waitForTimeout(800);
  surfaces.push(await focusProbe(page, 'edit-local-copy@session-2-after-typing'));

  // --- Third editing session, to separate "survives once" from "survives" --
  await page.keyboard.press('Escape');
  await page.waitForTimeout(2500);
  await page.mouse.click(coords.readerMenu.x, coords.readerMenu.y);
  await page.waitForTimeout(2200);
  await page.mouse.click(coords.editLocalCopy.x, coords.editLocalCopy.y);
  await page.waitForTimeout(3000);
  if (coords.editorField) {
    await page.mouse.click(coords.editorField.x, coords.editorField.y);
    await page.waitForTimeout(1200);
  }
  surfaces.push(await focusProbe(page, 'edit-local-copy@session-3-focused'));

  await page.close();
  return { surfaces, shots };
};

// ---------------------------------------------------------------------------

(async () => {
  const browser = await webkit.launch();
  const result = {
    harness: 'df059_cp1_webkit.mjs',
    build: BUILD,
    url: URL,
    viewport: VIEWPORT,
    engine: 'playwright-webkit',
    engineVersion: browser.version(),
    platform: `${process.platform} ${process.arch}`,
    node: process.version,
    capturedAt: new Date().toISOString(),
    boundary:
      'Desktop WebKit (SafariDesktopTextEditingStrategy). NOT iOS ' +
      '(IOSTextEditingStrategy). No iOS behaviour may be inferred. ' +
      'This harness can eliminate a candidate; it cannot clear one.',
  };
  try {
    const located = { coords: {}, trees: {} };
    result.locator = located;
    await locate(browser, located);
    const measured = await measure(browser, located.coords);
    result.measurement = measured;
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
  } else {
    console.log(json);
  }
  if (result.status === 'error') {
    console.error(result.error.message);
    process.exitCode = 1;
  }
})();
