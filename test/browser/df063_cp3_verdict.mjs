// Deterministic verdicts over the raw browser-probe JSON.
//
//   node test/browser/df063_cp3_verdict.mjs <dir-with-json>...
//
// Criteria (applied mechanically; written after the W1 pilot outputs had been
// seen):
// - visible: at least one Reader marker seen immediately before close is still
//   in view after close, and no SECTION-01 marker appears that was not already
//   in view before close;
// - retained (-R routes): the stored block after close is within ±2 of the
//   stored block before close, and is not 0;
// - home (-HOME routes): the view after Return to main -> Continue reading
//   satisfies the same visible rule against the pre-close markers.
import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';

const markers = (step) => new Set((step?.markers ?? []).map((m) => m.marker));
const step = (json, label) => json.steps.find((s) => s.label === label);

function visible(before, after) {
  const pre = markers(before);
  const post = markers(after);
  const kept = [...pre].some((m) => post.has(m));
  const newSectionOne = [...post].some((m) => m.startsWith('SECTION-01') && !pre.has(m));
  return { pass: kept && !newSectionOne, pre: [...pre], post: [...post] };
}

const rows = [];
for (const dir of process.argv.slice(2)) {
  for (const name of (await readdir(dir)).filter((f) => f.endsWith('.json')).sort()) {
    const json = JSON.parse(await readFile(join(dir, name), 'utf8'));
    const row = { file: name, route: json.route, bundleMain: json.bundleMainSha256?.slice(0, 12), completed: json.completed };
    if (!json.completed) { row.verdict = 'INCOMPLETE'; row.error = json.error?.split('\n')[0]; rows.push(row); continue; }
    const before = step(json, 'before-close');
    const after = step(json, 'after-close');
    const checks = { visible: visible(before, after) };
    if (json.route?.endsWith('-R')) {
      const b = before.storage?.position?.blockIndex;
      const a = after.storage?.position?.blockIndex;
      checks.retained = { pass: Number.isInteger(a) && Number.isInteger(b) && Math.abs(a - b) <= 2 && a !== 0, before: b, after: a };
    }
    if (json.route?.endsWith('-HOME')) {
      checks.home = visible(before, step(json, 'after-continue-reading'));
    }
    row.checks = checks;
    row.verdict = Object.values(checks).every((c) => c.pass) ? 'PRESERVED' : 'NOT PRESERVED';
    rows.push(row);
  }
}
process.stdout.write(JSON.stringify(rows, null, 2) + '\n');
