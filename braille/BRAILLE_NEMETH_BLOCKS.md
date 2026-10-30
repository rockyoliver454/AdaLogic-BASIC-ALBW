# BRAILLE / NEMETH language blocks — status + feature roadmap

Raw multiline data blocks in ALB (ALBW backend only, for now).

```alb
BRAILLE
The quick brown fox
END BRAILLE

NEMETH
x^2/(x+1)
END NEMETH
```

## Current state (implemented)

- `BRAILLE` / `NEMETH` as **contextual openers**: a lone keyword at line
  start (trailing `-- comment` allowed) opens a verbatim block; the same
  words stay legal identifiers everywhere else (`LET braille = 7` works).
- Terminator: a line holding only `END BRAILLE` / `END NEMETH` (or glued
  `ENDBRAILLE` / `ENDNEMETH`), case-insensitive. A bare `END` line does
  NOT close the block — it stays verbatim content and cannot collide
  with an outer `BEGIN .. END`. `END NEMETH` inside a BRAILLE block is
  literal text (terminator must match the opener's word).
- Capture is **zero-allocation**: the token's span indexes the fixed
  input buffer; the AST carries only `Token_Index`. The emitter slices
  the body out of the raw lexeme (`Block_Inner_Text`) and writes it as
  a compile-time static TS string literal — no dynamic string building
  anywhere in the generated program's data path.
- Standalone **statements** — no assignment, no implicit print.
- ALBW lowering:
  - `BRAILLE` → `Ueb_Transcribe("...")`   (UEB Grade 2, contracted)
  - `NEMETH`  → `Nemeth_Transcribe("...")` (Nemeth math)
- **Auto-weave**: `albw` prescans the main file; on a block opener it
  weaves `ueb.albi` / `nemeth.albi` (resolved via source dir → CWD →
  `ALB_LIB`) *before* user code and injects `IMPORT UEB` / `IMPORT
  NEMETH` unless the file already has them. Include-vault dedup
  prevents double-weave when the user includes the engine manually.
- Blocks hidden inside `.albi` includes escape the prescan → post-weave
  check fails loudly (`engine was not woven`) instead of emitting a
  call to a missing routine.
- Outputs reachable after the block runs (one shot — engine state):
  - `Ueb.ToUni()`  — Unicode braille (U+2800+)
  - `Ueb.ToBrf()`  — BRF/NABCC (embosser-safe ASCII)
  - `Ueb.Count()` / `Ueb.Cell(i)` — raw 6-bit dot masks, `-1` = newline
  - `Ueb.ErrCount()` / `Ueb.ErrText(i)` — error ledger
  - same surface on `Nemeth.*`
- Nemeth tokenizer now accepts real `\n` (token kind 17 → `Newline()`;
  CR skipped) — multiline NEMETH bodies produce line-break cells.

## Ergonomics (A1–A3, shipped — fixture `albw/tests/1217_braille_nemeth_capture`)

- **Opener tails** (`Block_Opener_Ok` in the tokenizer, mirrored by
  `Line_Opens_Word_Block` in the albw prescan) — any order:
  `BRAILLE [G1] [VERIFY] [OUT "path"] [AS name]`,
  `NEMETH [VERIFY] [OUT "path"] [AS name]` — `G1` selects
  `Ueb_TranscribeG1` (uncontracted). Bad tails (`BRAILLE ZZZ`,
  `NEMETH G1`, `OUT` without a quoted path) fall through to a loud
  parser error, never open a block.
- **`VERIFY`** — after transcription, `ErrCount > 0` → `ALB_FATAL`
  with the count + first ledger entry (never emboss bad braille;
  smoke-verified runtime fatal, the runner only goldens compile
  errors so this path is exercised manually).
- **`OUT "path"`** — writes the BRF transcript via
  `ALB_FlushBuffer` at block point (node → real file, browser →
  download). Round-trip verified by fixture 1219 reading the file
  back through `OPEN`/`READ`.
- **Row readback (D2)** — `Nemeth.RowCount()` / `Nemeth.RowBrf(r)` /
  `Nemeth.RowUni(r)` split the cell stream on `-1` sentinels; named
  captures get `name.rows` / `name.row(i)` / `name.rowbrf(i)`
  emitted against the snapshot (survives later blocks). Note for
  engine authors: compare cells through a local (`c = ncell[i]`)
  never `ncell[i] = #NEM_LF` — emitted arrays are BigInt64 and
  `bigint === number` is always false in JS.
- **Named capture** (`BRAILLE AS poem`): the emitter snapshots engine
  state into `poem_uni` / `poem_brf` / `poem_ncells` / `poem_errs` /
  `poem_cells[]` / `poem_errtxt[]` plus accessor fns `poem_cell(i)` /
  `poem_err(i)` — consecutive blocks can't clobber. Reachable via
  dotted sugar: `poem.uni`, `poem.brf`, `poem.ncells`, `poem.errs`,
  `poem.cell(i)`, `poem.err(i)` — the generic `a.b → a_b` routine
  resolution does the mapping; no new syntax. Gotcha: bare
  `poem_cell(0)` does NOT work — an undeclared call falls into the
  Prolog `ALB_PRED` path; always use the dotted form.
- **Inline builtins** — expression-callable one-shots that auto-weave
  the same engines via prescan (`Line_Has_Call`): `BRF(s)`/`UNI(s)`
  → UEB G2 BRF/Unicode; `BRFG1(s)` → G1 BRF; `NBRF(s)`/`NUNI(s)` →
  Nemeth. Each emits a comma-expr (Transcribe, then ToBrf/ToUni) —
  pure, composable in PRINT/LET/concats.
- **MCP resources (E1)** — a named capture inside an `MCP SERVER`
  program self-registers `alb://braille/<name>` /
  `alb://nemeth/<name>` at block-execution time (`typeof` guard
  makes it a no-op without the MCP preamble). `resources/read`
  returns a JSON payload `{brf, uni, ncells, errors, errorText}`.
- Fixtures: `albw/tests/1215_braille_nemeth_blocks` (+.expected),
  `1216_braille_unterminated` (.errw = `unclosed string literal`),
  `1217_braille_nemeth_capture`, `1218_braille_mcp_resources`
  (+.stdin), `1219_braille_verify_out_rows` (+.expected).
- Known quirk: `albStdout` writes latin1, so `PRINT Ueb.ToUni()` emits
  raw cell bytes on node stdout — the string is correct; browser/file
  paths keep real braille. Pre-existing ALBW byte-output contract.

## Files touched

- `src/COMPILER/tokenizer.ads` — `Tok_Braille_Block`, `Tok_Nemeth_Block`
- `src/COMPILER/tokenizer.adb` — `At_Line_Start`, `Block_Opener_Ok`
  (validates `G1`/`AS name` tails), `Is_End_Word_Line`,
  `Scan_Word_Block`, word-dispatch branches
- `src/COMPILER/ast.ads` — `AST_Braille_Block`, `AST_Nemeth_Block`
- `src/COMPILER/parser.adb` — two statement branches in `Parse_Statement`
- `src/EMITTER/emit_native_typescript.adb` — `Block_Inner_Text`,
  `Block_Opener_Flags` (G1/VERIFY/OUT/AS), `Emit_Block_Capture`
  (named snapshot bindings + `name_cell`/`name_err`/`name_row`/
  `name_rowbrf` accessors + `alb://` MCP resource registration),
  two emit arms (G1/G2 select, VERIFY check, OUT write, static
  literal), inline builtin interception in `AST_Func_Call`
- `src/albw.adb` — `Line_Opens_Word_Block`, `Line_Has_Call`,
  `Is_Word_Char`, `Path_Ends_With`, `Prescan_For_Raw_Blocks`,
  weave-time flags, pre-weave engine + IMPORT injection, post-weave
  loud check
- `SECRET/nwstudio/braille/nemeth.albi` + `stdlib/nemeth.albi` —
  newline token (kind 17) in `Tok`, `t = 17 → Newline()` in `Parse`,
  `RowCount`/`RowBrf`/`RowUni` row readback
- `stdlib/ueb.albi` — copy of the validated engine (canonical home so
  `ALB_LIB` resolution finds it from any directory)

Other backends: the tokens/AST are shared, but only ALBW emits them —
non-ALBW emitters fall through to their existing "unsupported stmt"
comment arm (same degradation every ALBW-only feature gets).

---

## Feature roadmap

Ordered by leverage. Effort = rough gut estimate.

### A. Ergonomics — SHIPPED (fixture 1217)

| # | Feature | Sketch | Effort | Status |
|---|---------|--------|--------|--------|
| A1 | **Named capture** — snapshot the triple into named bindings so consecutive blocks don't clobber each other | `BRAILLE AS poem` → `poem.uni`, `poem.brf`, `poem.ncells`, `poem.errs`, `poem.cell(i)`, `poem.err(i)` | ~1 day | DONE — dotted `a.b → a_b` resolution; snapshot arrays + accessor fns |
| A2 | **Inline expression builtins** — one-shot transcription inside expressions/PRINT | `BRF("hi")`, `UNI("hi")`, `NBRF("x^2")`, `NUNI("x^2")`, `BRFG1("hi")` | ~1-2 h | DONE — comma-expr emits, prescan auto-weave |
| A3 | **Grade selector** on the opener | `BRAILLE G1 ... END BRAILLE` → `Ueb_TranscribeG1` | ~30 m | DONE — combinable with `AS name` |

### B. Direction

| # | Feature | Sketch | Effort |
|---|---------|--------|--------|
| B1 | **Back-translation** (braille/BRF → text) — bidirectional tooling: read embosser files, proofing, round-trip tests | `UNBRAILLE` block or `UnBrf(cells)` | ~8 d (new engine pass through the contraction dictionary) — split: **B1b Nemeth cells→source** (self-marked stream, ~2d) then **B1a UEB cells→text** (disambiguation, ~6d) |
| B2 | **NEMETH → LaTeX/MathML** export — ALB as math-format bridge | `Nemeth.ToLatex()` / `ToMathML()` | ~2-3 d | DONE — fixture 1220; `NEMETH AS mx` also snapshots `mx.latex` / `mx.mathml` / `mx.src`, and `alb://nemeth/<name>` resources carry `latex` + `mathml` fields |

### C. Compile-time muscle

| # | Feature | Sketch | Effort |
|---|---------|--------|--------|
| C1 | **Fail-on-error mode** — never silently emit bad braille: transcription errors fatal at startup (or a build-time charset precheck warning) | `BRAILLE VERIFY` or `#BRAILLE_STRICT` | ~2 h | DONE — `VERIFY` tail → `ALB_FATAL` w/ first ledger entry |
| C2 | **G1 compile-time folding** — G1 is a pure letter→cell map, foldable inside the emitter so `BRAILLE G1` becomes a literal with zero engine code. G2 folding needs the whole engine in the compiler — skip | emitter-side fold | ~1 d |

### D. Output sinks

| # | Feature | Sketch | Effort |
|---|---------|--------|--------|
| D1 | **Embosser/file out** — write BRF at block point using existing file builtins | `BRAILLE OUT "poem.brf"` | ~2 h | DONE — `OUT "path"` → `ALB_FlushBuffer` |
| D2 | **Spatial grid readback for NEMETH** — matrices/spatial as multiline uni text for display drivers | `Nemeth.ToGrid()` / `ToRows()` | ~1 d | DONE — `RowCount`/`RowBrf`/`RowUni` + `name.rows`/`name.row`/`name.rowbrf` |

### E. Agent surface

| # | Feature | Sketch | Effort |
|---|---------|--------|--------|
| E1 | **MCP resources for named blocks** — `BRAILLE AS poem` auto-registers `alb://braille/poem` so an agent reads transcripts with zero user glue | MCP resource emit | ~4 h | DONE — JSON payload via `albMcpResources` |

---

## Design constraints (carry forward)

- Zero dynamic heap / JPL rules: block bodies stay token-span views;
  generated strings are compile-time literals only. No interpolation
  inside blocks (would need runtime string building) — compose via
  multiple blocks + `|` concat at the ALB level instead.
- Contextual keywords only — `braille`/`nemeth` remain identifiers.
- ALBW only until the user asks for more backends; shared front end
  means other backends get the generic unsupported-stmt path.
- Never silently miscompile: unterminated block = lexer error; engine
  not woven = driver error; transcription errors live in the ledger.
- `stdlib/ueb.albi` + `stdlib/nemeth.albi` are the canonical copies —
  the `SECRET/nwstudio/braille/` versions are the dev workspace; keep
  them in sync (nemeth already carries the newline-token patch).

## B2 translator notes (nemeth.albi `Lx*`)

- `Nemeth.ToLatex(s)` / `ToMathML(s)` run `LxRun(s, mode)` — an
  independent ITERATIVE renderer over the shared `Tok()` token stream
  (no recursion, no AST; `pf_*` parser frames aren't reusable).
  Bounded `lf_*` frame stack, `#NLX_FR = 64` deep.
- `LxRun` calls `FillSym()` itself — NOT `Reset()` (that would clobber
  a live transcription + ledger). `SymFind` needs `ns_*` populated;
  `IsFunc`/`LxSymL`/`LxSymM`/`LxBig` are hardcoded tables.
- `/` wraps the previous factor into a stacked fraction
  (`x^2/(x+1)` → `\frac{x^{2}}{x+1}`) — the push consumes the saved
  parent base (`lf_lst`/`lf_sup`/`lf_sub`/`lf_sv*` cleared) so it
  isn't re-emitted before the frac.
- `^`/`_` set `lx_pend`; next delivered unit lands in `lx_sup`/`lx_sub`
  and materializes on the following atom. Big-ops (`LxBig`) render
  `<munder>`/`<mover>`/`<munderover>` instead of `msub`/`msup`.
- Groups save parent text context on `lf_cur`/`lf_lst`/`lf_sv*`, and
  `LxDeliver` cascades completed units into operand-hungry frames
  (`\frac` 11→12, `\sqrt` 9/10, slash-frac 12) until one lands.
- `\left`/`\right` ride `lx_lr` into `LxGroupEnd`'s `rgt` param so
  they attach to the delimiters, not the unit.
- **`LxFlush` must clear `lx_have`.** Commit points that consume
  `lx_cur` without resetting pending-atom state re-emit the last base
  (the B2 cell-duplication / `\\` double-emit bug class).
- Translation errors go to the shared `nerr` ledger —
  `Nemeth.ErrCount()` sees them; the next `Transcribe`/`Reset` clears.

## B1b reader notes (nemeth.albi `Nb*`) — SHIPPED

Public API:

    Nemeth.ToSource()        -- decode the current transcript
    Nemeth.FromCells(n)      -- decode ncell[0..n-1]
    Nemeth.FromBrf(b)        -- BRF ASCII -> source (reverse brfa[])
    Nemeth.FromUni(u)        -- U+2800 braille string -> source

Inline builtins (auto-weave, mirror NBRF/NUNI):

    UNBRF("...brf ascii...")  -> canonical source
    UNUNI("...u+2800 text...")-> canonical source
    --  LET results need AS STRING (LET infers numeric for unknown-
    --  signature builtins):  LET s AS STRING = UNBRF(b)

NEMETH captures additionally emit `name_rsrc` — the canonical
re-read of the captured cells (`Eng"_FromCells(name_ncells)`),
snapshot AFTER errs/errtxt so the capture's ledger stays the
transcription ledger; the live ledger afterward holds decode
diagnostics.  `alb://nemeth/<name>` resources carry `rsrc`.

Contract: each entry clears the error ledger, decodes to CANONICAL
source — `Transcribe(From*(x))` reproduces the input cells, not the
original source text.  Round-trip verified on the full construct
corpus (fixture 1221: numbers, letters, caps/capwords, scripts,
nested scripts, fracs/nested/mixed, roots/indexed roots, all groups,
all six environments, symbols, primes, `lim`-words).

### Canonicalization (ambiguous source forms → one spelling)

- all fracs → `\frac{n}{d}` (slant `/`, mixed `1½`, `\dfrac` collapse in)
- paren-frac `57` wrapped in `55/62` → `\binom{n}{k}` → `(\frac{n}{k})`
- scripts always braced: `x_{1}^{2}`; `48`-chain composes
  left-to-right (`x^2_1` → `x^{2}_{1}`)
- `\left/\right`, `\text{...}` → bare `()` + letters (same cells)
- `Vmatrix` ≡ `vmatrix` (encoder emits identical `32,51` brackets —
  a true cell-level collision; `vmatrix` is canonical)
- `40,5` spaced → `=`, unspaced → `\kappa` (pack wins)
- `33` spaced → `\cdot`, unspaced → `|` toggle
- words emit bare letters — `lim`, `sin` (no backslash; same cells)
- `\aleph` is unreachable: `32,32,1` is capword-`A`-start by rule —
  cap interpretation wins (identical cells, RT-safe)

### Cell-grammar rules (learned from dumps, verified)

- `32`-runs go through `NbDots` FIRST: `k`×`32` + `57/12/60` is a
  frac marker at nesting level `k`; + `55/62/51` is env bracket
  furniture; `k=1`+letter → cap; `k=2`+letters → capword; else fall
  back to `ns_pack` longest-match (`\therefore`, `\infty`, ...) or
  commas.
- `60` + digit cell → numeral ALWAYS (even mid-denominator);
  `60` + non-digit closes a `ph=1` frac.
- `48` + letter + letter → sub marker; `48` + letter + non-letter →
  ELI single letter; `48` + non-letter → sub (needs base).
- `16` → end open script frames; `16,5` → `<`.
- Spaces inside a script operand are decided by `nb_dang` (operand
  ends in a dangling infix op → space is content) plus the next
  cell: a complete operand ends on `24/48`, `-1`, letters, `+/ -/'`,
  numerals and structural opens; `40`-ops/`43`-shape/`56`-punct
  continue it.  (`x \to 0` and `i = 0` stay inside; `x^2 + y` and
  `\sum_i x` split correctly.)
- Env rows: `LF` ends a row (`\\`), `LF LF` ends the env; `32`/`8,32`/
  `40,32`-prefixed brackets inside an env are row furniture and are
  skipped; `0`-runs ≥2 before content are `&`, before furniture/`LF`
  they are alignment padding (emitted as plain spaces).
- `nmk[]` position tracking is unnecessary for reading — the dot-6
  nesting level already disambiguates `57/12/60` markers.

### Error ledger

Malformed input reports, never guesses: `unclosed construct`,
`unmatched )` / `]` / `\}` / `\rfloor` / `\rceil` / `\rangle`,
`stray frac line`, `frac line level mismatch`,
`frac close level mismatch`, `script with no base`,
`newline inside construct`, `stray radical marker`,
`stray env close`, `unknown cell N`, `bad dot-4 sequence`,
`bad op-indicator sequence`, `bad punct-indicator sequence`,
`lone numeric indicator`, `nesting too deep`.

### Known cell-level ambiguities (documented, RT-safe)

The encoder produces identical cell streams for distinct source —
the reader picks the canonical reading and re-encodes the same
cells: `x^{a b}` ≡ `x^{a} b`, `x^{yz}w` ≡ `x^{yzw}`,
`x^{a \frac{1}{2}}` ≡ `x^{a} \frac{1}{2}`, `Vmatrix` ≡ `vmatrix`,
`a | b` ≡ `a \cdot b`, `\aleph` ≡ capword-`A`, `40,5`-unspaced `\kappa`
vs `=`.  Arbitrary (non-encoder) streams decode best-effort with
ambiguity resolved by the same rules.

### Architecture

`NbRun` — iterative walk over `nb_cell[]`, same frame-stack shape as
`Lx*` (64 deep).  Frame kinds: 1 frac, 2 rad, 3 sup, 4 sub, 5 group,
6 env, 7 `|`-bar.  `nb_flag` saves parent pending-base state;
`nb_ph` is per-frame phase (frac num/den, rad idx/body, env
Bmatrix-close-seen); `nb_pd` saves parent `nb_dang`.  Pop delivers
`nb_txt`/`nb_aux0`/`nb_lvl0`/`nb_kind0` and restores the parent —
kept strictly separated so phases can't corrupt saved state.

## ALBW runtime trim (--rt-trim) — SHIPPED

Every albw compile filters `Emit_Runtime`'s preamble down to the
helpers the program's emitted text actually uses:

- `Emit`/`New_Line_Emit`/`Line` buffer into `Out_Lines` instead of
  writing `Out_File` directly; `Rt_Start`/`Rt_End` mark
  `Emit_Runtime`'s line range.
- `Flush_Output` splits that range into decl units (column-0
  `function|const|let|var|async function` = named; `type`/`export`/
  `interface`/`enum`/`class` = always-kept; other lines attach to
  the preceding unit; pre-first-unit lines always emit).
- Seed = identifier-run scan of all non-runtime lines + `--rt-keep`
  names; fixpoint closure pulls helper-references-helper until
  stable (bounded 64 passes).
- Failure mode is over-inclusion ONLY: a helper name inside a
  string literal gets kept, never dropped.  Under-inclusion would
  need runtime-constructed names — audited: none exist (only
  `eval('require')`/`globalThis.process` patterns).
- Flags: `--rt-trim[=on|off]` (default on), `--rt-keep=<name>`
  repeatable.  plumbed at both Compile_To_File sites (main + MCP
  scratch-compile).
- Measured: hello-world .ts 470KB→8.9KB; braille.js 630→555KB;
  nemeth tests 490→419KB; ueb_test 209→138KB.  Fixture 1222
  self-inspects its own T1222.ts (split needles — whole-name
  literals would self-mark).
- Out of scope (phase 2): woven .albi module bodies are NOT
  trimmed — `NBRF`-only programs still carry the whole Nemeth
  reader/renderer; same machinery applies later.
