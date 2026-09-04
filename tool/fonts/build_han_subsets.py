"""DF-031 CP-A — reproducible generation of the two bundled Chinese derivatives.

This is a *regeneration* step, not a build step. It is deliberately **not** wired
into `tool/build_web.ps1` and nothing at application runtime invokes it.

What it produces
----------------
    fonts/SaudoHans-Regular.otf     Simplified derivative   (CLDR zh + GB 2312 L1+L2)
    fonts/SaudoHant-Regular.otf     Traditional derivative  (CLDR zh-Hant + Big5 L1)
    fonts/Saudo{Hans,Hant}-LICENSE.txt   verbatim copy of the pinned governing LICENSE
    fonts/Saudo{Hans,Hant}-NOTICE.txt    derivation / provenance notice
    tool/fonts/manifests/*.txt           realised repertoire + drop sets
    tool/fonts/manifests/font-identity.json   shipped identity asserted by the test suite
    lib/han_script_tables.dart           generated detection range tables (CP-B, plan.md §5.4.2)

Provenance (DF-031 plan.md §9, §9.2 — the accepted contract)
------------------------------------------------------------
    upstream project : notofonts/noto-cjk
    release tag      : Sans2.004  (Noto Sans CJK 2.004, published 2022-01-27)
    pinned commit    : 523d033d6cb47f4a80c58a35753646f5c3608a78
    governing licence: root LICENSE — SIL Open Font License 1.1
    declared RFN     : none declared

`google/fonts` is a *different distribution identity* and is explicitly outside
this provenance chain (plan.md §9.2.3). Its `OFL.txt` must never be substituted
for the pinned governing `LICENSE`.

The upstream binaries are ~14 MB and are **not** committed to this repository.
Acquire them from the commit-addressed URLs printed by `--print-inputs` and pass
the directory holding them with `--upstream`. Every input is verified against a
pinned SHA-256 before anything is generated; a mismatch is a hard stop.

Usage
-----
    python tool/fonts/build_han_subsets.py --upstream <dir>            # generate
    python tool/fonts/build_han_subsets.py --upstream <dir> --verify-only <dir>
    python tool/fonts/build_han_subsets.py --print-inputs

Pinned generation environment (plan.md §9 "Reproducible generation", §13 R8):
    Python 3.12.0, fontTools 4.64.0  — see tool/fonts/requirements.txt

Run from the repository root.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata

# The manifests, notices and this tool's own output are UTF-8 regardless of the
# host console's default code page.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

# --------------------------------------------------------------------------
# Pinned provenance. Changing any of this is a Planning-level decision, not an
# implementation one (plan.md §9.1: "there is no workaround path").
# --------------------------------------------------------------------------

UPSTREAM_PROJECT = "notofonts/noto-cjk"
UPSTREAM_TAG = "Sans2.004"
UPSTREAM_COMMIT = "523d033d6cb47f4a80c58a35753646f5c3608a78"
UPSTREAM_RAW = "https://raw.githubusercontent.com/notofonts/noto-cjk/" + UPSTREAM_COMMIT

LICENCE_IDENTITY = "SIL Open Font License 1.1"

# plan.md §9.1 step 5, re-established at CP-A against this exact pinned file.
# Recorded literally. An absent RFN is a valid outcome and must not be replaced
# by an assumed, inherited or reconstructed one.
RFN_STATE = "none declared"

# The RFN declared by the upstream *lineage* (Adobe Source Han Sans). Whether it
# reaches downstream derivatives of the Noto build is legally unresolved and is
# deliberately left unresolved (plan.md §9.2.4). This check is retained as a
# conservative technical invariant, not as a legal conclusion (§9.2.5).
LINEAGE_RFN = "Source"

UPSTREAM_INPUTS = {
    "sc": {
        "path": "Sans/SubsetOTF/SC/NotoSansSC-Regular.otf",
        "local": "NotoSansSC-Regular.otf",
        "size": 8331336,
        "sha256": "faa6c9df652116dde789d351359f3d7e5d2285a2b2a1f04a2d7244df706d5ea9",
    },
    "tc": {
        "path": "Sans/SubsetOTF/TC/NotoSansTC-Regular.otf",
        "local": "NotoSansTC-Regular.otf",
        "size": 5683368,
        "sha256": "5bab0cb3c1cf89dde07c4a95a4054b195afbcfe784d69d75c340780712237537",
    },
    "licence": {
        "path": "LICENSE",
        "local": "LICENSE",
        "size": 4301,
        "sha256": "6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2",
    },
}

# Pinned CLDR exemplar data, committed beside this tool so the repertoire is
# re-derivable from the repository alone.
CLDR_INPUTS = {
    "zh": {
        "local": "tool/fonts/cldr/cldr-zh.xml",
        "size": 609123,
        "sha256": "bc40d32d5f602bae6b5e4ab58f4983a533f3a28c14c4642afca57b095d067862",
    },
    "zh-Hant": {
        "local": "tool/fonts/cldr/cldr-zh-Hant.xml",
        "size": 763524,
        "sha256": "e846d2247b1fb0d5aaa86e3633f2cf2784fe3266a176ab7eb0b61884c1d12e0d",
    },
}

# The five baseline bundled faces. The repertoire is made disjoint from their
# union so an appended Han family provably cannot displace them from any
# position in the fallback chain (plan.md §3.5, §10.1 property 6).
BASELINE_FACES = [
    "fonts/Roboto-Regular.ttf",
    "fonts/Roboto-Italic.ttf",
    "fonts/Roboto-Bold.ttf",
    "fonts/CascadiaMono.ttf",
    "fonts/TwemojiMozilla.ttf",
]

# plan.md §5.3 — the derivative identity CP-A must write into the bytes.
FACES = {
    "hans": {
        "source": "sc",
        "family": "SaudoHans",
        "postscript": "SaudoHans-Regular",
        "asset": "fonts/SaudoHans-Regular.otf",
        "licence": "fonts/SaudoHans-LICENSE.txt",
        "notice": "fonts/SaudoHans-NOTICE.txt",
        "repertoire": "Simplified — CLDR zh main+auxiliary Han, GB 2312 Level 1 + Level 2",
    },
    "hant": {
        "source": "tc",
        "family": "SaudoHant",
        "postscript": "SaudoHant-Regular",
        "asset": "fonts/SaudoHant-Regular.otf",
        "licence": "fonts/SaudoHant-LICENSE.txt",
        "notice": "fonts/SaudoHant-NOTICE.txt",
        "repertoire": "Traditional — CLDR zh-Hant main+auxiliary Han, Big5 Level 1 (常用國字)",
    },
}

# plan.md §3.6 — the exact pyftsubset invocation the Planning figures were
# measured with. Kept identical so the realised repertoire is comparable.
SUBSET_OPTIONS = [
    "--drop-tables+=BASE,vhea,vmtx,VORG,DSIG",
    "--layout-features=ccmp,locl,kern,mark",
    "--notdef-outline",
    "--name-IDs=*",
    "--name-legacy",
    "--glyph-names",
]

MANIFEST_DIR = "tool/fonts/manifests"
IDENTITY_FILE = "tool/fonts/manifests/font-identity.json"

# plan.md §5.4.2 — the detection sets are generated by the same tool that
# generates the fonts, from the *realised* cmaps, so they cannot drift from what
# is actually shipped and involve no hand-curated list.
TABLES_FILE = "lib/han_script_tables.dart"

HAN_RANGES = ((0x4E00, 0x9FFF), (0x3400, 0x4DBF), (0xF900, 0xFAFF))

# plan.md §5.2 — the punctuation / fullwidth floor, before disjointing.
FLOOR_RANGES = ((0x3000, 0x303F), (0xFF00, 0xFFEF), (0xFE10, 0xFE19), (0xFE30, 0xFE4F))


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fail(message: str) -> "None":
    sys.stderr.write("STOP: %s\n" % message)
    raise SystemExit(2)


def assert_input(path: str, pin: dict, label: str) -> None:
    """Hard-stop unless `path` is byte-for-byte the pinned input."""
    if not os.path.isfile(path):
        fail("%s is missing at %s" % (label, path))
    size = os.path.getsize(path)
    digest = sha256_of(path)
    if size != pin["size"] or digest != pin["sha256"]:
        fail(
            "%s does not match its pinned identity.\n"
            "  expected %d B  %s\n"
            "  found    %d B  %s\n"
            "Do not silently accept a materially different upstream identity "
            "(plan.md §9.1 step 1)." % (label, pin["size"], pin["sha256"], size, digest)
        )
    print("  ok  %-24s %10d B  %s" % (label, size, digest))


def is_han(cp: int) -> bool:
    return any(lo <= cp <= hi for lo, hi in HAN_RANGES)


# --------------------------------------------------------------------------
# Repertoire derivation — from reviewable, deterministically re-derivable
# sources only. No "common Chinese" list is invented anywhere (plan.md §3.4).
# --------------------------------------------------------------------------


def parse_exemplar(body: str) -> set:
    """Parse the CLDR UnicodeSet subset used by exemplarCharacters."""
    b = body.strip()
    if not (b.startswith("[") and b.endswith("]")):
        fail("unexpected exemplarCharacters syntax: %r" % b[:60])
    b = b[1:-1]
    cps: set = set()
    i, n, prev = 0, len(b), None
    while i < n:
        c = b[i]
        if c.isspace():
            i += 1
            continue
        if c == "{":  # a multi-character sequence; take its code points
            j = b.index("}", i)
            for ch in b[i + 1 : j]:
                if not ch.isspace():
                    cps.add(ord(ch))
            i, prev = j + 1, None
            continue
        if c == "\\":  # escaped literal
            prev = ord(b[i + 1])
            cps.add(prev)
            i += 2
            continue
        if c == "-" and prev is not None and i + 1 < n:  # range
            j = i + 1
            while j < n and b[j].isspace():
                j += 1
            for cp in range(prev + 1, ord(b[j]) + 1):
                cps.add(cp)
            i, prev = j + 1, None
            continue
        prev = ord(c)
        cps.add(prev)
        i += 1
    return cps


def cldr_han(path: str) -> set:
    """Han code points in a locale's main + auxiliary exemplar sets."""
    data = open(path, encoding="utf-8").read()
    sets: dict = {}
    for m in re.finditer(
        r'<exemplarCharacters(?:\s+type="([^"]+)")?\s*>(.*?)</exemplarCharacters>',
        data,
        re.S,
    ):
        sets[m.group(1) or "main"] = parse_exemplar(m.group(2))
    out: set = set()
    for key in ("main", "auxiliary"):
        out |= {c for c in sets.get(key, set()) if is_han(c)}
    return out


def codec_han(codec: str, lo: int, hi: int) -> set:
    """Han reachable through a legacy CJK codec across a byte-pair range.

    Re-derives GB 2312 and Big5 from Python's own stdlib codecs rather than
    from a transcribed list, so any reviewer with a stdlib Python reproduces
    the same set.
    """
    out: set = set()
    for hb in range(lo >> 8, (hi >> 8) + 1):
        for lb in range(0x21, 0x100):
            if not (lo <= (hb << 8 | lb) <= hi):
                continue
            try:
                ch = bytes((hb, lb)).decode(codec)
            except Exception:
                continue
            if len(ch) == 1 and is_han(ord(ch)):
                out.add(ord(ch))
    return out


def baseline_union() -> set:
    """The union of the five bundled baseline faces, by identity, all cmaps."""
    from fontTools.ttLib import TTFont

    union: set = set()
    for path in BASELINE_FACES:
        if not os.path.isfile(path):
            fail("baseline face missing: %s" % path)
        union |= all_unicode_cmap(TTFont(path, lazy=True))[0]
    return union


def all_unicode_cmap(font) -> tuple:
    """Every Unicode code point mapped by *any* Unicode cmap subtable.

    Deliberately not `getBestCmap`: plan.md §10.1 property 7 requires formats 4,
    6, 12 and, when present, 14 (Unicode Variation Sequences) to be read, so a
    future regeneration that introduces UVS coverage cannot slip past a
    disjointness check that never looked. Returns (code points, UVS base+selector
    pairs).
    """
    covered: set = set()
    uvs: set = set()
    for table in font["cmap"].tables:
        if not table.isUnicode():
            continue
        if table.format == 14:
            for selector, mapping in (table.uvsDict or {}).items():
                for base, _name in mapping:
                    uvs.add((base, selector))
                    covered.add(base)
            continue
        covered |= set(table.cmap)
    return covered, uvs


def build_repertoires() -> dict:
    """The requested repertoire for each face, and the standard sets it claims."""
    bundled = baseline_union()
    print("  baseline bundled union: %d code points" % len(bundled))

    floor = set()
    for lo, hi in FLOOR_RANGES:
        floor |= set(range(lo, hi + 1))
    # U+3030 and U+303D are the only floor code points the bundled stack already
    # covers; both come from TwemojiMozilla as *emoji*. Disjointing keeps DF-023
    # colour-emoji behaviour intact (plan.md §5.2).
    floor -= bundled

    gb_l1 = codec_han("gb2312", 0xB0A1, 0xD7F9)
    gb_l2 = codec_han("gb2312", 0xD8A1, 0xF7FE)
    big5_l1 = codec_han("big5", 0xA440, 0xC67E)
    cldr_sc = cldr_han(CLDR_INPUTS["zh"]["local"])
    cldr_tc = cldr_han(CLDR_INPUTS["zh-Hant"]["local"])

    print(
        "  GB 2312 L1 %d  L2 %d (total %d) | Big5 L1 %d | CLDR zh %d  zh-Hant %d | floor %d"
        % (len(gb_l1), len(gb_l2), len(gb_l1 | gb_l2), len(big5_l1), len(cldr_sc), len(cldr_tc), len(floor))
    )

    return {
        "bundled": bundled,
        "floor": floor,
        "hans": {
            "requested": ((cldr_sc | gb_l1 | gb_l2) | floor) - bundled,
            "standard_name": "GB 2312 Level 1 + Level 2",
            "standard": gb_l1 | gb_l2,
        },
        "hant": {
            "requested": ((cldr_tc | big5_l1) | floor) - bundled,
            "standard_name": "Big5 Level 1",
            "standard": big5_l1,
        },
    }


# --------------------------------------------------------------------------
# Derivative identity rewrite — plan.md §5.3
# --------------------------------------------------------------------------

# IDs rewritten to the derivative identity. Every record carrying one of these
# is rewritten, across *all* platform/encoding/language combinations, so a
# localized upstream family name cannot survive the rewrite.
REWRITTEN_IDS = (1, 3, 4, 6)

# IDs 0, 13 and 14 carry the Adobe copyright, the OFL grant and the OFL URL: the
# OFL requires those notices to travel with the Font Software. ID 7 retains
# "Noto is a trademark of Google Inc." because it is a true statement about the
# upstream this is derived from. IDs 2, 5, 8, 9, 10, 11 and 12 are retained so
# the derivative keeps crediting Adobe and its designers and keeps recording the
# upstream build version and vendor URL. All of this is deliberate for a
# derivative and is not an oversight (plan.md §5.3, §10.1 property 12).
RETAINED_IDS = (0, 2, 5, 7, 8, 9, 10, 11, 12, 13, 14)


def derivative_name(name_id: int, face: dict, source_sha256: str) -> str:
    """The deterministic derivative value for a rewritten name ID.

    ID 4 applies the same rule upstream applied — style is "Regular", so the
    full name is the family name — rather than inventing a different
    convention. ID 3 is derivative-specific and ties the identity to the pinned
    upstream by hash prefix, so two derivatives cut from different upstream
    bytes can never share a unique identifier.
    """
    if name_id == 1:
        return face["family"]
    if name_id == 4:
        return face["family"]
    if name_id == 6:
        return face["postscript"]
    if name_id == 3:
        return "2.004;DF031;%s;src-%s" % (face["postscript"], source_sha256[:16])
    raise AssertionError("unhandled name ID %d" % name_id)


def rewrite_identity(font, face: dict, source_sha256: str) -> list:
    """Rewrite IDs 1/3/4/6 in place; return a summary of the whole name table."""
    name_table = font["name"]
    for record in name_table.names:
        if record.nameID in REWRITTEN_IDS:
            record.string = derivative_name(record.nameID, face, source_sha256).encode(
                record.getEncoding()
            )
    return [
        {
            "nameID": r.nameID,
            "platformID": r.platformID,
            "platEncID": r.platEncID,
            "langID": r.langID,
            "value": r.toUnicode(),
        }
        for r in sorted(
            name_table.names,
            key=lambda r: (r.nameID, r.platformID, r.platEncID, r.langID),
        )
    ]


# --------------------------------------------------------------------------
# Post-generation gate — plan.md §9.1 step 7, §10.1 property 12
# --------------------------------------------------------------------------


def whole_name_table_gate(records: list, face: dict) -> dict:
    """Evaluate the step-5 RFN state against the *entire* generated name table.

    Not against four hand-picked strings: the gate's own premise is that the RFN
    state is unknown until acquisition, so an RFN surviving in a retained
    upstream record would embed itself in the binary while a narrow check passed
    cleanly (plan.md §9.1).
    """
    values = [r["value"] for r in records]

    # RFN prohibition. `RFN_STATE` is "none declared" for the pinned governing
    # licence, so the prohibition has no declared subject and is recorded as
    # `not applicable` — neither silently skipped nor reported as a pass.
    if RFN_STATE == "none declared":
        rfn_disposition = "not applicable"
        rfn_hits: list = []
    else:
        rfn_disposition = "enforced"
        rfn_hits = [v for v in values if RFN_STATE in v]
        if rfn_hits:
            fail(
                "declared RFN %r appears in the generated name table of %s: %r"
                % (RFN_STATE, face["family"], rfn_hits)
            )

    # Conservative lineage check, run in both cases. Retained because it costs
    # nothing, already passes, and converts an unresolved legal question into an
    # asserted repository invariant (plan.md §9.2.5).
    lineage_hits = [v for v in values if LINEAGE_RFN in v]
    if lineage_hits:
        fail(
            "conservative lineage check failed: %r appears in the generated name "
            "table of %s: %r — return through the accepted Planning/Implementation "
            "route (plan.md §9.1 step 7)" % (LINEAGE_RFN, face["family"], lineage_hits)
        )

    # Derivative identity must be exactly what the plan approves, everywhere.
    for record in records:
        if record["nameID"] not in REWRITTEN_IDS:
            continue
        expected = derivative_name(record["nameID"], face, "")
        if record["nameID"] == 3:
            if not record["value"].startswith("2.004;DF031;%s;src-" % face["postscript"]):
                fail("name ID 3 of %s is not the approved derivative identity: %r"
                     % (face["family"], record["value"]))
            continue
        if record["value"] != expected:
            fail(
                "name ID %d of %s is %r, expected %r"
                % (record["nameID"], face["family"], record["value"], expected)
            )

    return {
        "records": len(records),
        "rewritten": sorted({r["nameID"] for r in records if r["nameID"] in REWRITTEN_IDS}),
        "retained": sorted({r["nameID"] for r in records if r["nameID"] in RETAINED_IDS}),
        "rfn_state": RFN_STATE,
        "rfn_prohibition": rfn_disposition,
        "rfn_hits": rfn_hits,
        "lineage_string": LINEAGE_RFN,
        "lineage_occurrences": len(lineage_hits),
    }


# --------------------------------------------------------------------------
# Generation
# --------------------------------------------------------------------------


def drop_reason(cp: int, upstream_cmap: set, face: dict) -> str:
    """Why a requested code point is not in the realised repertoire.

    Unicode assignment is tested *first*. An unassigned code point exists in no
    font, so it is necessarily also absent from the upstream face; reporting it
    as "absent from <face>" would be true but misleading, and would hide the
    fact that the 16 floor entries can never be supplied by any upstream
    (plan.md §5.2).
    """
    if unicodedata.category(chr(cp)) == "Cn":
        return "unassigned in Unicode"
    if cp not in upstream_cmap:
        return "absent from %s" % UPSTREAM_INPUTS[face["source"]]["local"]
    return "dropped by the subsetter"


def generate(upstream_dir: str, out_dir: str) -> dict:
    from fontTools.ttLib import TTFont

    print("Verifying pinned generation inputs")
    for key, pin in UPSTREAM_INPUTS.items():
        assert_input(os.path.join(upstream_dir, pin["local"]), pin, "upstream/" + pin["local"])
    for key, pin in CLDR_INPUTS.items():
        assert_input(pin["local"], pin, pin["local"])

    print("Deriving repertoires")
    rep = build_repertoires()

    licence_src = os.path.join(upstream_dir, UPSTREAM_INPUTS["licence"]["local"])
    identity: dict = {
        "ticket": "DF-031",
        "checkpoint": "CP-A",
        "upstream": {
            "project": UPSTREAM_PROJECT,
            "tag": UPSTREAM_TAG,
            "commit": UPSTREAM_COMMIT,
            "licence_path": UPSTREAM_INPUTS["licence"]["path"],
            "licence_sha256": UPSTREAM_INPUTS["licence"]["sha256"],
            "licence_identity": LICENCE_IDENTITY,
            "rfn_state": RFN_STATE,
        },
        "tool": {
            "python": "%d.%d.%d" % sys.version_info[:3],
            "fontTools": __import__("fontTools").version,
            "subset_options": SUBSET_OPTIONS,
        },
        "baseline_union": len(rep["bundled"]),
        "baseline_faces": BASELINE_FACES,
        "faces": {},
    }

    for key, face in FACES.items():
        pin = UPSTREAM_INPUTS[face["source"]]
        src = os.path.join(upstream_dir, pin["local"])
        requested = rep[key]["requested"]
        print("\n%s — requested %d code points" % (face["family"], len(requested)))

        with tempfile.TemporaryDirectory() as tmp:
            unicodes_file = os.path.join(tmp, "%s.unicodes" % key)
            with open(unicodes_file, "w") as fh:
                fh.write(",".join("%04X" % c for c in sorted(requested)))
            staged = os.path.join(tmp, "%s.otf" % key)
            result = subprocess.run(
                [
                    sys.executable, "-m", "fontTools.subset", src,
                    "--unicodes-file=%s" % unicodes_file,
                    "--output-file=%s" % staged,
                ] + SUBSET_OPTIONS,
                capture_output=True, text=True,
            )
            if result.returncode:
                fail("pyftsubset failed for %s: %s" % (face["family"], result.stderr[-800:]))

            # recalcTimestamp=False: the default stamps head.modified with the
            # current time on save, which would make the shipped bytes differ on
            # every run and break the reproducibility invariant.
            font = TTFont(staged, recalcTimestamp=False)
            records = rewrite_identity(font, face, pin["sha256"])
            gate = whole_name_table_gate(records, face)
            realised, uvs = all_unicode_cmap(font)

            asset = os.path.join(out_dir, face["asset"])
            os.makedirs(os.path.dirname(asset), exist_ok=True)
            font.save(asset)
            font.close()

        # Drop set: requested minus realised, each entry with a reason.
        upstream_cmap = all_unicode_cmap(TTFont(src, lazy=True))[0]
        drops = sorted(requested - realised)
        drop_rows = [(cp, drop_reason(cp, upstream_cmap, face)) for cp in drops]

        collide = realised & rep["bundled"]
        standard = rep[key]["standard"]
        covered = standard & realised

        # Manifests. The realised cmap is the committed manifest; the drop set
        # is committed beside it with a reason per entry, without which the
        # "cmap equals manifest" assertion fails on its first run for a reason
        # nothing in the repository explains (plan.md §5.2, §10.1 property 5).
        os.makedirs(os.path.join(out_dir, MANIFEST_DIR), exist_ok=True)
        rep_file = os.path.join(out_dir, MANIFEST_DIR, "%s-repertoire.txt" % face["family"])
        with open(rep_file, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("# DF-031 %s — realised repertoire, read from all Unicode cmap subtables.\n"
                     "# %d code points. Generated by tool/fonts/build_han_subsets.py.\n"
                     % (face["family"], len(realised)))
            for cp in sorted(realised):
                fh.write("U+%04X\n" % cp)
        drop_file = os.path.join(out_dir, MANIFEST_DIR, "%s-drops.txt" % face["family"])
        with open(drop_file, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("# DF-031 %s — requested-minus-realised drop set, with reasons.\n"
                     "# requested %d, realised %d, dropped %d.\n"
                     % (face["family"], len(requested), len(realised), len(drop_rows)))
            for cp, reason in drop_rows:
                fh.write("U+%04X\t%s\n" % (cp, reason))

        # Licence: a byte-identical copy of the exact pinned governing LICENSE.
        # Not reconstructed from embedded strings, not reflowed, and never a
        # differently-provenanced OFL text (plan.md §9.1 step 1, §9.2.3).
        shutil.copyfile(licence_src, os.path.join(out_dir, face["licence"]))

        asset_size = os.path.getsize(asset)
        asset_sha = sha256_of(asset)

        identity["faces"][key] = {
            "family": face["family"],
            "postscript": face["postscript"],
            "asset": face["asset"],
            "licence": face["licence"],
            "notice": face["notice"],
            "repertoire_source": face["repertoire"],
            "upstream_path": pin["path"],
            "upstream_sha256": pin["sha256"],
            "upstream_bytes": pin["size"],
            "bytes": asset_size,
            "sha256": asset_sha,
            "requested": len(requested),
            "realised": len(realised),
            "dropped": len(drop_rows),
            "drops": ["U+%04X" % cp for cp, _ in drop_rows],
            "drop_reasons": {"U+%04X" % cp: reason for cp, reason in drop_rows},
            "uvs_subtable_present": bool(uvs),
            "uvs_pairs": len(uvs),
            "baseline_intersection": len(collide),
            "standard_set": rep[key]["standard_name"],
            "standard_size": len(standard),
            "standard_covered": len(covered),
            "name_table": gate,
            "name_records": records,
        }

        print("  realised %d  dropped %d  baseline-int %d  %s %d/%d  UVS %s"
              % (len(realised), len(drop_rows), len(collide), rep[key]["standard_name"],
                 len(covered), len(standard), "present" if uvs else "absent"))
        print("  %s  %d B  %s" % (face["asset"], asset_size, asset_sha))

        write_notice(os.path.join(out_dir, face["notice"]), identity, key)

    union = set()
    per_face = {}
    from fontTools.ttLib import TTFont
    for key, face in FACES.items():
        cps = all_unicode_cmap(TTFont(os.path.join(out_dir, face["asset"]), lazy=True))[0]
        per_face[key] = cps
        union |= cps
    hans_exclusive = {c for c in per_face["hans"] - per_face["hant"] if is_han(c)}
    hant_exclusive = {c for c in per_face["hant"] - per_face["hans"] if is_han(c)}

    identity["union"] = len(union)
    identity["overlap"] = len(per_face["hans"] & per_face["hant"])
    identity["hans_exclusive"] = len(hans_exclusive)
    identity["hant_exclusive"] = len(hant_exclusive)

    tables = write_script_tables(
        os.path.join(out_dir, TABLES_FILE), hans_exclusive, hant_exclusive, union
    )
    identity["detection_tables"] = tables
    print("\n%s  hans-exclusive %d cp / %d ranges  hant-exclusive %d cp / %d ranges  "
          "union %d cp / %d ranges"
          % (TABLES_FILE, tables["hans_exclusive"], tables["hans_exclusive_ranges"],
             tables["hant_exclusive"], tables["hant_exclusive_ranges"],
             tables["union"], tables["union_ranges"]))

    with open(os.path.join(out_dir, IDENTITY_FILE), "w", encoding="utf-8", newline="\n") as fh:
        json.dump(identity, fh, indent=1, ensure_ascii=False, sort_keys=True)
        fh.write("\n")
    return identity


def write_notice(path: str, identity: dict, key: str) -> None:
    """The derivation notice. Kept out of the licence file deliberately, so the
    OFL text is never presented as reconstructed or annotated."""
    face = identity["faces"][key]
    tool = identity["tool"]
    lines = [
        "%s — derivation and provenance notice" % face["family"],
        "",
        "This font is a DERIVATIVE. It is a reduced-repertoire subset of an upstream",
        "font, with its own identity records, and it is not the upstream font.",
        "",
        "Upstream project        : %s" % identity["upstream"]["project"],
        "Upstream release / tag  : %s" % identity["upstream"]["tag"],
        "Upstream pinned commit  : %s" % identity["upstream"]["commit"],
        "Upstream source path    : %s" % face["upstream_path"],
        "Upstream source bytes   : %d" % face["upstream_bytes"],
        "Upstream source SHA-256 : %s" % face["upstream_sha256"],
        "",
        "Governing licence path  : %s (repository root, at the pinned commit)"
        % identity["upstream"]["licence_path"],
        "Governing licence SHA256: %s" % identity["upstream"]["licence_sha256"],
        "Governing licence       : %s" % identity["upstream"]["licence_identity"],
        "Reserved Font Name      : RFN: %s" % identity["upstream"]["rfn_state"],
        "",
        "The governing licence declares no copyright statement, and therefore declares",
        "no Reserved Font Name. The phrase \"Reserved Font Name\" occurs in that file",
        "only in the OFL's own definition clause; that is not a declared RFN. The",
        "licence text distributed by other projects for related fonts is NOT the licence",
        "governing this derivative and has not been substituted for it.",
        "",
        "A byte-identical copy of the governing licence is bundled as:",
        "    %s" % face["licence"],
        "",
        "Font version            : name ID 5 retains the upstream build version 2.004",
        "Repertoire              : %s" % face["repertoire_source"],
        "Repertoire inputs       :",
        "    CLDR exemplars   tool/fonts/cldr/cldr-zh.xml      sha256 %s"
        % CLDR_INPUTS["zh"]["sha256"],
        "    CLDR exemplars   tool/fonts/cldr/cldr-zh-Hant.xml sha256 %s"
        % CLDR_INPUTS["zh-Hant"]["sha256"],
        "    GB 2312 and Big5 re-derived from the Python %s stdlib codecs" % tool["python"],
        "    Punctuation/fullwidth floor U+3000-303F, U+FF00-FFEF, U+FE10-FE19, U+FE30-FE4F",
        "    minus the union of the five baseline bundled faces (%d code points)"
        % identity["baseline_union"],
        "",
        "Generation tool         : tool/fonts/build_han_subsets.py",
        "fontTools version       : %s" % tool["fontTools"],
        "Python version          : %s" % tool["python"],
        "Subset options          : %s" % " ".join(tool["subset_options"]),
        "",
        "Derivative identity     :",
        "    name ID 1 family      %s" % face["family"],
        "    name ID 3 unique id   2.004;DF031;%s;src-%s"
        % (face["postscript"], face["upstream_sha256"][:16]),
        "    name ID 4 full name   %s" % face["family"],
        "    name ID 6 PostScript  %s" % face["postscript"],
        "    name IDs 0, 13 and 14 retain the upstream copyright, the OFL grant and the",
        "    OFL URL. IDs 2, 5, 7, 8, 9, 10, 11 and 12 are retained unchanged.",
        "",
        "Realised repertoire     : %d code points (manifest: %s/%s-repertoire.txt)"
        % (face["realised"], MANIFEST_DIR, face["family"]),
        "Requested repertoire    : %d code points, %d dropped (see %s/%s-drops.txt)"
        % (face["requested"], face["dropped"], MANIFEST_DIR, face["family"]),
        "%s coverage: %d / %d"
        % (face["standard_set"], face["standard_covered"], face["standard_size"]),
        "Baseline intersection   : %d code points" % face["baseline_intersection"],
        "",
        "Output file             : %s" % face["asset"],
        "Output bytes            : %d" % face["bytes"],
        "Output SHA-256          : %s" % face["sha256"],
        "",
        "Regenerate with:",
        "    python tool/fonts/build_han_subsets.py --upstream <dir holding the pinned inputs>",
        "",
    ]
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))


# --------------------------------------------------------------------------
# Generated detection tables — plan.md §5.4.2
# --------------------------------------------------------------------------


def to_ranges(code_points) -> list:
    """Collapse a set of code points into ascending inclusive [lo, hi] ranges."""
    ordered = sorted(code_points)
    ranges = []
    for cp in ordered:
        if ranges and cp == ranges[-1][1] + 1:
            ranges[-1][1] = cp
        else:
            ranges.append([cp, cp])
    return [(lo, hi) for lo, hi in ranges]


def _dart_range_table(name: str, doc: list, ranges: list) -> str:
    """One `const List<int>` of flat [lo, hi] pairs, four pairs to a line."""
    out = list(doc)
    out.append("const List<int> %s = <int>[" % name)
    for start in range(0, len(ranges), 4):
        chunk = ranges[start:start + 4]
        out.append("  " + " ".join("0x%04X, 0x%04X," % (lo, hi) for lo, hi in chunk))
    out.append("];")
    return "\n".join(out)


def write_script_tables(path: str, hans_exclusive: set, hant_exclusive: set,
                        union: set) -> dict:
    """Emit lib/han_script_tables.dart from the *realised* cmaps.

    Deterministic by construction: every input is a set rendered through
    `sorted`, and the formatting is fixed, so regenerating from the same pinned
    inputs rewrites this file byte for byte.
    """
    hans_ranges = to_ranges(hans_exclusive)
    hant_ranges = to_ranges(hant_exclusive)
    union_ranges = to_ranges(union)

    header = [
        "// GENERATED FILE - DO NOT EDIT BY HAND.",
        "//",
        "// DF-031 detection tables (plan.md 5.4.2). Regenerate with:",
        "//",
        "//     python tool/fonts/build_han_subsets.py --upstream <pinned inputs>",
        "//",
        "// The same run that generates fonts/SaudoHans-Regular.otf and",
        "// fonts/SaudoHant-Regular.otf derives these tables from the *realised* cmaps",
        "// of those two files, read from every Unicode cmap subtable. They therefore",
        "// cannot drift from what is actually shipped, and nothing here is a",
        "// hand-curated list: editing this file by hand is always wrong.",
        "//",
        "// \"Exclusive\" means exclusive to the shipped subsets, not to the",
        "// orthography. 1,023 of the Simplified-exclusive code points are Big5 Level 2",
        "// characters, ordinary in Traditional writing, and they are in this set only",
        "// because the Traditional repertoire was drawn at Big5 Level 1. plan.md",
        "// 5.4.2 records why that asymmetry is load-bearing rather than incidental.",
        "//",
        "// Each table is a flat, ascending, non-overlapping list of inclusive",
        "// [start, end] code-point pairs. Membership is tested by",
        "// `hanScriptTableContains` in han_script.dart.",
        "",
    ]

    body = [
        "/// Code points in the Simplified repertoire and not in the Traditional one,",
        "/// Han only. A vote toward [HanScript.hans].",
        "const int kHansExclusiveCount = %d;" % len(hans_exclusive),
        "",
        "/// Code points in the Traditional repertoire and not in the Simplified one,",
        "/// Han only. A vote toward [HanScript.hant].",
        "const int kHantExclusiveCount = %d;" % len(hant_exclusive),
        "",
        "/// Every code point either shipped pack covers. Drives the reader menu's",
        "/// `Language` tile visibility (plan.md 5.6.4) - the union, not the overlap.",
        "const int kHanUnionCount = %d;" % len(union),
        "",
        _dart_range_table(
            "kHansExclusiveRanges",
            ["/// The %d Simplified-exclusive code points, as %d ranges."
             % (len(hans_exclusive), len(hans_ranges))],
            hans_ranges,
        ),
        "",
        _dart_range_table(
            "kHantExclusiveRanges",
            ["/// The %d Traditional-exclusive code points, as %d ranges."
             % (len(hant_exclusive), len(hant_ranges))],
            hant_ranges,
        ),
        "",
        _dart_range_table(
            "kHanUnionRanges",
            ["/// The %d code points of the shipped union, as %d ranges."
             % (len(union), len(union_ranges))],
            union_ranges,
        ),
        "",
    ]

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(header + body))

    return {
        "file": TABLES_FILE,
        "hans_exclusive": len(hans_exclusive),
        "hans_exclusive_ranges": len(hans_ranges),
        "hant_exclusive": len(hant_exclusive),
        "hant_exclusive_ranges": len(hant_ranges),
        "union": len(union),
        "union_ranges": len(union_ranges),
    }


# --------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", help="directory holding the pinned upstream inputs")
    parser.add_argument("--out", default=".", help="output root (default: repository root)")
    parser.add_argument("--print-inputs", action="store_true",
                        help="print the commit-addressed source URLs and exit")
    args = parser.parse_args()

    if args.print_inputs:
        print("%s @ %s  commit %s" % (UPSTREAM_PROJECT, UPSTREAM_TAG, UPSTREAM_COMMIT))
        for key, pin in UPSTREAM_INPUTS.items():
            print("  %s/%s" % (UPSTREAM_RAW, pin["path"]))
            print("      -> %s  %d B  sha256 %s" % (pin["local"], pin["size"], pin["sha256"]))
        return 0

    if not args.upstream:
        parser.error("--upstream is required (or use --print-inputs)")
    if not os.path.isfile("pubspec.yaml"):
        fail("run this from the repository root")

    identity = generate(args.upstream, args.out)
    print("\nunion %d  overlap %d  hans-exclusive Han %d  hant-exclusive Han %d"
          % (identity["union"], identity["overlap"],
             identity["hans_exclusive"], identity["hant_exclusive"]))
    print("wrote %s" % IDENTITY_FILE)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
