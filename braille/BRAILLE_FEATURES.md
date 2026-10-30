# Braille Transcription Engine — Feature Summary

`SECRET/nwstudio/braille/` — a two-engine braille transcriber written in ALB
(`ueb.albi` + `nemeth.albi`, driver `braille.alb`), compiled to TypeScript/Node
by ALBW. Exposed over stdio JSON-RPC via MCP and callable directly from JS/TS.

## Engines

| Engine | Input | Output |
|---|---|---|
| **UEB Grade 2** | literary text | contracted braille — matches liblouis `en-ueb-g2.ctb` cell-for-cell on 25,836 tested words (13,747 stratified + 12,000 `a`-slice + 89 curated: **all identical**) |
| **UEB Grade 1** | literary text | uncontracted letter-for-cell |
| **Nemeth** | latex-ish / asciimath math | linear + spatial Nemeth (matrices, cases, binom, stacked arithmetic, long division) |

## UEB G2 pipeline

Text → tokenizer → dictionary (shortforms: `gd`, `brl`, `imm`, `abv`, `af`,
`tgr`, `fr`, `td`, `tn`, `tm`, `paid`, `said`, `quick`, `children`, …) →
context legality pass (`OkAt`/`TheLegal`/`ShLegal` + onset checks) →
greedy longest-match → 6-bit cell stream.

Empirically-derived rule layers (validated against liblouis):

- **Morpheme-boundary rules** — `s|h`/`s|t` crossings blocked
  (`ass|holes`, `guess|timate`) with prefix-merge exemptions
  (`mis|shapen`, `trans|shipping`, `mis|steps`) and onset escapes
  (`str`, `shl`, `shr`)
- **Stem-locked exceptions** — `anes`/`anaes`/`aesthe` stems gate
  `the`-vs-`st` per position + tail (`anesthesia` fires `the`+sia;
  `aesthete` fires `the`+te; `panaesthesia` blocks both)
- **Overlap suppression** — `ment`↔`ion`, `name`↔`ment`,
  `st`↔`tion`/`the`, `cc`↔`ch`, `ff`↔`for` (position-gated: `afford`
  suppresses `ff`, `reafforest` doesn't)
- **Follower/predecessor blocklists** — `ever`, `here`, `one`, `under`,
  `time`, `some`, `through`, `ea`, `be`/`con`/`dis` prefix morphology,
  `en`/`in`+`ess`
- **Numbers** — indicator + numeric-space (cell 16) + alternation
  re-indication + separator handling
- **Capitals** — letter/word/passage modes; lone letters get grade-1
  signs with context suppression (`a.m.` vs `x.` vs `b-c`)
- **Dangerous-spelling list** + whitelisted-prefix shortforms (`paid`
  after `re|un|mis|over|pre|under` only)

## Output formats

One call returns all three encodings plus diagnostics:

- `brf` — BRF/ASCII for embossers
- `uni` — Unicode braille block (U+2800+) for screens
- `cells` — raw dot-mask array for refreshable displays
  (`-1` = newline, capped 256)
- `err` — never-silent error ledger (capped 8); `ok` = `errors=0 && ncells>0`

## MCP surface

`node braille.js` is a stdio JSON-RPC server:

| Tool / resource | Purpose |
|---|---|
| `br_ueb` | `txt` → UEB grade 2 contracted braille |
| `br_ueb_g1` | `txt` → UEB grade 1 uncontracted |
| `br_nemeth` | `txt` → Nemeth (latex-ish/asciimath, incl. spatial) |
| `br_translate` | dispatcher: `sys` = `ueb` \| `ueb-g1` \| `nemeth` |
| `alb://braille/status` | engine status + capability notes |

Args are schema-validated (required keys, types, non-finite rejection).

**Known gaps:** no typeforms/foreign/italic markup; no Nemeth array
colspecs or display environments.

## Use case scenario

A blind student messages an AI tutor: *"what's the answer to problem 4 —
x² + 3x − 10 = 0, and explain it."* The AI:

1. calls `br_nemeth("(x+5)(x-2)")` → spatial Nemeth for the factored form
2. calls `br_ueb("Because five plus negative two is three...")` → G2 prose
3. ships `cells[]` to the student's refreshable display driver, or `brf`
   to an embosser queue, or `uni` to a shared screen for a sighted teacher

Same payload serves all three sinks — no re-transcription.

## Using it in a webpage (raw JS)

The generated `braille.js` is a **flat script** — functions land as
globals under a classic `<script>` tag, and the tail `albMcpListen()`
safely no-ops in a browser (it guards on `process.versions.node`).

### Method 1 — JSON envelope (recommended)

```html
<script src="braille.js"></script>
<script>
  function braille(txt, sys = "ueb") {
    return JSON.parse(BrTranslate(sys, txt));   // also "ueb-g1", "nemeth"
  }
  const r = braille("The quick brown fox");
  // r = {sys, ok, brf:",! QK BR[N FOX", uni:"⠠⠮ ⠟⠅ ⠃⠗⠪⠝ ⠋⠕⠭",
  //      ncells:14, cells:[32,46,...], errors:0, err:[]}
  document.getElementById("out").textContent = r.uni;
</script>
<p id="out" style="font-size:2em"></p>
```

### Method 2 — low-level (cells for hardware/canvas)

```js
Ueb_Transcribe("Grade 2 works");
const uni = Ueb_ToUni();        // "⠠⠛⠗⠁⠙⠑ ⠼⠃ ⠐⠺⠎"
const n   = Ueb_Count();
for (let i = 0; i < n; i++) {
  const c = Ueb_Cell(i);        // 6-bit dot mask; bits 0..5 = dots 1..6; -1 = newline
}
if (Ueb_ErrCount() > 0) console.warn(Ueb_ErrText(0));
```

### Method 3 — ES module / bundler

Functions aren't `export`ed, so scope them via `Function`:

```js
import brailleSrc from "./braille.js?raw";              // vite-style
const api = new Function(brailleSrc +
  ";return {BrTranslate,Ueb_Transcribe,Ueb_ToUni,Ueb_ToBrf,Ueb_Count,Ueb_Cell};")();
const r = JSON.parse(api.BrTranslate("ueb", "hello"));
```

### Deployment notes

- `uni` renders as real Unicode braille glyphs — any modern font covers
  the block; for a hardware look use a braille-display font or draw
  `cells[]` on canvas as dots
- Long documents: `cells` truncates at 256 — page through or call
  per-paragraph
- `albMcpListen()` at file end is harmless in-browser; strip it if you
  want zero noise
- Nemeth math input is the ASCII/latex-ish grammar, not real LaTeX
  `\commands`
