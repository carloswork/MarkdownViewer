# DF-026 Glyph Parity Fixture

Fixture identity: `df026-glyphs.md`. Required by acceptance criterion 17.

The rule this fixture tests is **no regression**, not coverage: the print path
must show **no tofu where the reader shows a glyph**. If the print path renders a
glyph the reader cannot, that is an improvement and passes.

Each string below appears **first in a paragraph, then in a table cell**. The
strings are tested as **whole sequences** and must never be decomposed into
isolated scalars — `⚠️` in particular is U+26A0 followed by U+FE0F.

## Class A — expected to render in both the reader and the print output

Covered by the bundled faces: U+2192 by `CascadiaMono`, the remainder by
`TwemojiMozilla`.

GLYPH-CLASS-A-START

Arrow: →

Warning: ⚠️

Check: ✅

Cross: ❌

Celebration: 🎉

Rocket: 🚀

Combined run: → ⚠️ ✅ ❌ 🎉 🚀

| Name | Code point | Glyph |
| --- | --- | --- |
| Arrow | U+2192 | → |
| Warning | U+26A0 U+FE0F | ⚠️ |
| Check | U+2705 | ✅ |
| Cross | U+274C | ❌ |
| Celebration | U+1F389 | 🎉 |
| Rocket | U+1F680 | 🚀 |
| Combined run | all of the above | → ⚠️ ✅ ❌ 🎉 🚀 |

GLYPH-CLASS-A-END

## Class B — known-uncovered baseline, tofu here is NOT a failure

**No shipped font covers these.** DF-024 accepted them as remaining tofu, and the
product documents CJK and post-bundled-font emoji as uncovered. They appear here
so the comparison is explicit rather than silent.

Tofu in **both** the reader and the print output is the **expected, passing**
result. Tofu in the print output where the **reader shows a glyph** is a
regression and fails. A glyph in the print output where the reader shows tofu is
an improvement and passes.

GLYPH-CLASS-B-START

CJK: 中

Shaking face: 🫨

Combined run: 中 🫨

| Name | Code point | Glyph |
| --- | --- | --- |
| CJK | U+4E2D | 中 |
| Shaking face | U+1FAE8 | 🫨 |
| Combined run | both of the above | 中 🫨 |

GLYPH-CLASS-B-END

## Inline and code contexts

The print stylesheet routes code through `DF026Mono` with `DF026Emoji` as
fallback, so the same strings are repeated here to exercise that path.

Inline code, class A: `→ ⚠️ ✅ ❌ 🎉 🚀`

Inline code, class B: `中 🫨`

```text
Fenced code, class A: → ⚠️ ✅ ❌ 🎉 🚀
Fenced code, class B: 中 🫨
```

GLYPH-FIXTURE-END-MARKER
